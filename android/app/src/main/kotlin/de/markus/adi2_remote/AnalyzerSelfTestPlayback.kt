package de.markus.adi2_remote

import android.content.Context
import android.media.*
import android.media.audiofx.AudioEffect
import android.os.Build
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.roundToInt

/** Owns the temporary USB mixer preference; all methods run under the self-test lock. */
internal class AnalyzerSelfTestPlayback(
    private val manager: AudioManager, private val device: AudioDeviceInfo, context: Context
) {
    private val journal = context.getSharedPreferences(JOURNAL, Context.MODE_PRIVATE)
    private val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()
    private var preferred: AudioMixerAttributes? = null
    private var preferenceAttempted = false
    private var pcm: ByteBuffer? = null
    var fallbackReason = "Android < 14: Bit-Perfect-Mixer nicht verfügbar"
        private set
    private val effects = runCatching {
        AudioEffect.queryEffects()?.map { "${it.name} (${it.implementor})" }?.distinct()?.joinToString("; ")
    }.getOrNull()?.take(512) ?: "Effekt-Abfrage nicht verfügbar"

    fun create(rate: Int): AudioTrack {
        if (Build.VERSION.SDK_INT >= 34) {
            val encodings = listOf(AudioFormat.ENCODING_PCM_FLOAT, AudioFormat.ENCODING_PCM_24BIT_PACKED,
                AudioFormat.ENCODING_PCM_16BIT, AudioFormat.ENCODING_PCM_32BIT)
            val supported = runCatching { manager.getSupportedMixerAttributes(device) }.getOrElse {
                fallbackReason = "USB-Mixer-Abfrage fehlgeschlagen: ${it.message}"; emptyList()
            }
            val choices = supported.filter {
                it.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT &&
                    it.format.sampleRate == 48000 && rate == 48000 &&
                    it.format.channelMask == AudioFormat.CHANNEL_OUT_STEREO &&
                    it.format.channelIndexMask == 0 && it.format.encoding in encodings
            }.sortedBy { encodings.indexOf(it.format.encoding) }
            if (choices.isEmpty() && !fallbackReason.startsWith("USB-Mixer-Abfrage"))
                fallbackReason = "Kein passender Bit-Perfect-USB-Mixer für 48 kHz Stereo angeboten"
            for (choice in choices) {
                try {
                    check(manager.setPreferredMixerAttributes(attributes, device, choice)) { "Mixer-Einstellung abgelehnt" }
                    preferenceAttempted = true
                    preferred = choice
                    fallbackReason = "Bit-Perfect-Mixer/USB-Route nicht mehr bestätigt"
                    check(journal.edit().putInt(DEVICE_ID, device.id).commit()) { "USB-Mixer-Recovery nicht gespeichert" }
                    return build(choice.format)
                } catch (e: Exception) {
                    fallbackReason = "Bit-Perfect nicht verfügbar: ${e.message}"
                    clear()
                }
            }
        }
        return createNormal(rate)
    }

    fun createNormal(rate: Int): AudioTrack = build(AudioFormat.Builder().setSampleRate(rate)
        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).setEncoding(AudioFormat.ENCODING_PCM_FLOAT).build())

    private fun build(format: AudioFormat): AudioTrack {
        val minimum = AudioTrack.getMinBufferSize(format.sampleRate, format.channelMask, format.encoding)
        check(minimum > 0) { "USB-Wiedergabeformat nicht unterstützt" }
        val bytesPerSample = when (format.encoding) {
            AudioFormat.ENCODING_PCM_16BIT -> 2
            AudioFormat.ENCODING_PCM_24BIT_PACKED -> 3
            else -> 4
        }
        val t = AudioTrack.Builder().setAudioAttributes(attributes).setAudioFormat(format)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(max(minimum, format.sampleRate / 10 * 2 * bytesPerSample)).build()
        try {
            check(t.state == AudioTrack.STATE_INITIALIZED && t.sampleRate == format.sampleRate &&
                t.audioFormat == format.encoding && t.channelCount == 2 && t.format.channelMask == format.channelMask)
            check(t.setPreferredDevice(device)) { "USB-Ausgang abgelehnt" }
            check(t.setVolume(1f) == AudioTrack.SUCCESS)
            check(t.setAuxEffectSendLevel(0f) == AudioTrack.SUCCESS)
            check(t.attachAuxEffect(0) == AudioTrack.SUCCESS)
            t.play()
            return t
        } catch (e: Exception) {
            t.release()
            throw e
        }
    }

    fun bitPerfect(t: AudioTrack): Boolean {
        if (Build.VERSION.SDK_INT < 34) return false
        val expected = preferred ?: return false
        return t.routedDevice?.id == device.id && t.format == expected.format &&
            runCatching { manager.getPreferredMixerAttributes(attributes, device) == expected }.getOrDefault(false)
    }

    /** A rejected/unverifiable preference must not survive into the normal fallback. */
    fun confirmRoute(t: AudioTrack): Boolean {
        if (preferred != null && !bitPerfect(t)) {
            fallbackReason = "Bit-Perfect-Mixer nach USB-Routing nicht bestätigt"
            clear()
            return true
        }
        return false
    }

    fun diagnostics(t: AudioTrack, includeEffectCatalogue: Boolean): Map<String, Any> {
        val verified = bitPerfect(t)
        return mapOf("bitPerfect" to verified, "mixerPreferenceSet" to (preferred != null),
            "playbackMode" to if (verified) "bit-perfect" else "normal + Effekte",
            "bitPerfectVerification" to "USB-Route + exaktes Trackformat + Mixer-Readback; kein externer HAL-Nachweis",
            "mixerFallbackReason" to if (verified) "" else fallbackReason,
            "outputEffects" to if (verified) "Systemeffekte durch Bit-Perfect-Pfad umgangen (Android-API)"
                else "Aktive USB-Effekte öffentlich nicht abfragbar; System-/Herstellereffekte möglich",
            "effectsQueryScope" to "Aktivierung/Zuweisung unbekannt") + if (includeEffectCatalogue) mapOf(
                "availableEffects" to effects,
                "effectsQueryScope" to "queryEffects meldet verfügbare Effekte, nicht deren Aktivierung oder USB-Zuordnung") else emptyMap()
    }

    /** Returns interleaved sample count, like AudioTrack.write(float[]). */
    fun write(t: AudioTrack, block: FloatArray, offset: Int, length: Int): Int {
        if (t.audioFormat == AudioFormat.ENCODING_PCM_FLOAT)
            return t.write(block, offset, length, AudioTrack.WRITE_NON_BLOCKING)
        val bytesPerSample = when (t.audioFormat) {
            AudioFormat.ENCODING_PCM_16BIT -> 2
            AudioFormat.ENCODING_PCM_24BIT_PACKED -> 3
            AudioFormat.ENCODING_PCM_32BIT -> 4
            else -> error("Unbekanntes USB-PCM-Format")
        }
        val size = length * bytesPerSample
        if (pcm == null || pcm!!.capacity() < size) pcm = ByteBuffer.allocateDirect(size).order(ByteOrder.LITTLE_ENDIAN)
        val buffer = pcm!!
        buffer.clear()
        for (i in offset until offset + length) {
            val value = block[i].toDouble().coerceIn(-1.0, 1.0)
            when (bytesPerSample) {
                2 -> buffer.putShort((value * 32768).roundToInt().coerceIn(-32768, 32767).toShort())
                3 -> {
                    val sample = (value * 8388608).roundToInt().coerceIn(-8388608, 8388607)
                    buffer.put(sample.toByte()); buffer.put((sample shr 8).toByte()); buffer.put((sample shr 16).toByte())
                }
                4 -> buffer.putInt((value * 2147483648.0).toLong().coerceIn(-2147483648L, 2147483647L).toInt())
            }
        }
        buffer.flip()
        val written = t.write(buffer, size, AudioTrack.WRITE_NON_BLOCKING)
        if (written < 0) return written
        check(written % (bytesPerSample * 2) == 0) { "Unvollständiger USB-PCM-Frame" }
        return written / bytesPerSample
    }

    fun clear() {
        if (Build.VERSION.SDK_INT >= 34 && preferenceAttempted) {
            val cleared = runCatching { manager.clearPreferredMixerAttributes(attributes, device) }.getOrDefault(false)
            val disconnected = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).none { it.id == device.id }
            check(cleared || disconnected || manager.getPreferredMixerAttributes(attributes, device) == null) {
                "USB-Mixer-Präferenz nicht gelöscht; erneut stoppen"
            }
        }
        if (preferenceAttempted) {
            check(journal.edit().remove(DEVICE_ID).commit()) { "USB-Mixer-Recovery nicht gelöscht" }
        }
        preferred = null
        preferenceAttempted = false
    }

    companion object {
        private const val JOURNAL = "analyzer_selftest_playback"
        private const val DEVICE_ID = "preferredMixerDeviceId"

        /** Recover only our journaled preference, never another app's USB preference. */
        fun clearStale(manager: AudioManager, context: Context) {
            if (Build.VERSION.SDK_INT < 34) return
            val journal = context.getSharedPreferences(JOURNAL, Context.MODE_PRIVATE)
            if (!journal.contains(DEVICE_ID)) return
            val device = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).singleOrNull {
                it.id == journal.getInt(DEVICE_ID, -1) &&
                    it.type in listOf(AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET)
            }
            if (device != null) {
                val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()
                check(manager.clearPreferredMixerAttributes(attributes, device) ||
                    manager.getPreferredMixerAttributes(attributes, device) == null) { "USB-Mixer-Recovery fehlgeschlagen" }
            }
            // Device removal also removes the port's preference in Android audio policy.
            check(journal.edit().remove(DEVICE_ID).commit()) { "USB-Mixer-Recovery nicht gelöscht" }
        }
    }
}
