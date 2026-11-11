package de.markus.adi2_remote

import android.app.Activity
import android.content.Context
import android.media.*
import android.os.Handler
import android.os.Looper
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.*

/** Temporary developer-only playback. Capture reuses the production USB/effect checks. */
internal class AnalyzerSelfTest(
    private val activity: Activity, messenger: BinaryMessenger, private val capture: AnalyzerCapture
) {
    private val channel = MethodChannel(messenger, "adi2/analyzer_selftest")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newCachedThreadPool()
    private val io = Executors.newSingleThreadExecutor()
    private val store = AnalyzerSelfTestStore(activity.filesDir)
    private val lock = Any()
    @Volatile private var generation = 0
    private var track: AudioTrack? = null
    private var playbackOutput: AnalyzerSelfTestPlayback? = null
    private var input: AudioDeviceInfo? = null
    private var output: AudioDeviceInfo? = null
    private var rate = 0
    private var ready: CountDownLatch? = null
    private var measuring: Measurement? = null
    private var lastToneEnd = 0L
    private var measuredLatencyNs = 0L
    private var outputEpoch = 0
    private var tonePending = false
    private fun quietAfterNs() = if (lastToneEnd == 0L) 0L else
        lastToneEnd + AnalyzerSelfTestQuiet.drainNs(measuredLatencyNs)
    private var playbackStamp: Long? = null
    private var lastSamplesNs = 0L
    private var quiet: AnalyzerSelfTestQuiet? = null
    private var captureDiagnostics = emptyMap<String, Any>()
    private var captureError: CaptureFailure? = null
    private var quietStartNs = 0L
    private var quietEndNs = 0L
    private var firstToneCommandNs: Long? = null
    private var firstToneWrittenNs: Long? = null
    private class CaptureFailure(val code: String, val details: Map<String, Any>) : Exception(details["message"] as? String ?: "ADI-2-Aufnahme nicht verfügbar")
    private class SignalBusy(val levels: Map<String, Any>) : Exception("Loopback ist nicht ruhig genug")
    private fun isQuiet() = measuring == null && captureError == null && quiet?.quiet == true &&
        quiet?.readyForTone(System.nanoTime()) == true
    private fun quietDiagnostics(): Map<String, Any?> = mapOf(
        "capture" to captureDiagnostics, "quiet" to quiet?.details(),
        "timing" to mapOf("quietStartNs" to quietStartNs, "quietEndNs" to quietEndNs,
            "firstToneCommandNs" to firstToneCommandNs, "firstToneWrittenNs" to firstToneWrittenNs,
            "testPlaybackActive" to (measuring != null || toneQueued()),
            "lastToneQueuedFrame" to lastToneQueuedFrame,
            "measuredLatencyMs" to measuredLatencyNs / 1e6,
            "quietAfterNs" to quietAfterNs(),
            "drainMs" to AnalyzerSelfTestQuiet.drainNs(measuredLatencyNs) / 1e6,
            "outputPlaybackHeadFrame" to ((track?.playbackHeadPosition?.toLong() ?: 0L) and 0xffffffffL),
            "beforeFirstTestTone" to (firstToneCommandNs == null ||
                (quietEndNs > 0L && quietEndNs < firstToneCommandNs!!)),
            "quietEndToFirstToneMs" to firstToneCommandNs?.let { (it - quietEndNs) / 1e6 }))
    private fun busyDetails(): Map<String, Any> = (quiet?.details() ?: emptyMap()) +
        mapOf("diagnostics" to quietDiagnostics())
    private var writtenFrames = 0L
    private var lastToneQueuedFrame = 0L
    private fun toneQueued() = lastToneQueuedFrame > ((track?.playbackHeadPosition?.toLong() ?: 0L) and 0xffffffffL)
    private var playbackStampFrame: Long? = null

    private class Measurement(val resolution: Int, val index: Int, val rate: Int,
                              val result: MethodChannel.Result) {
        val meter = AnalyzerToneMeasurement(rate, resolution, index)
        val duration get() = meter.duration
        val tone = AnalyzerTestTone(rate, meter.frequency)
        var underruns = 0
        var outputBefore = emptyMap<String, Any>()
        var onset = false
        var onsetNs = 0L
        var firstPlaybackFrame: Long? = null
        var firstWrittenNs: Long? = null
        val commandNs = System.nanoTime()
        var quietBeforeTone = emptyMap<String, Any?>()
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "prepare" -> prepare(result)
                "tone" -> requestTone(call.argument<Int>("bandsPerOctave") ?: 0,
                    call.argument<Int>("index") ?: -1, result)
                "stop" -> {
                    val error = stop()
                    if (error == null) result.success(null) else result.error("audio", error, null)
                }
                "save" -> {
                    val name = call.argument<String>("name")
                    val json = call.argument<String>("json")
                    storage(result) { store.save(requireNotNull(name), requireNotNull(json)) }
                }
                "lastResult" -> storage(result) { store.lastResult() }
                "recovery" -> storage(result) { store.recovery() }
                "clearRecovery" -> storage(result) { store.clearRecovery(); null }
                else -> result.notImplemented()
            }
        }
    }

    private fun storage(result: MethodChannel.Result, operation: () -> Any?) {
        io.execute {
            try {
                val value = operation()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("storage", e.message, null) }
            }
        }
    }

    /** Every request, including the 1 kHz probe, passes the same capture barrier. */
    private fun requestTone(resolution: Int, index: Int, result: MethodChannel.Result) {
        val token: Int
        synchronized(lock) {
            if (track == null || measuring != null || tonePending) {
                result.error("busy", "Audio not ready", null); return
            }
            if (resolution !in listOf(3, 6, 12) || index !in 0 until (29 * resolution / 3 + 1)) {
                result.error("argument", "Invalid band", null); return
            }
            token = generation
            tonePending = true
        }
        worker.execute {
            try {
                val deadline = synchronized(lock) {
                    System.nanoTime() + AnalyzerSelfTestQuiet.drainNs(measuredLatencyNs) + 6_000_000_000L
                }
                while (true) {
                    synchronized(lock) {
                        check(generation == token) { "Abgebrochen" }
                        captureError?.let { throw it }
                        if (isQuiet()) {
                            val m = Measurement(resolution, index, rate, result)
                            m.underruns = track!!.underrunCount
                            m.outputBefore = outputDiagnostics()
                            if (firstToneCommandNs == null) firstToneCommandNs = m.commandNs
                            m.quietBeforeTone = quietDiagnostics()
                            quiet = AnalyzerSelfTestQuiet(rate); quietStartNs = 0; quietEndNs = 0
                            measuring = m
                            main.postDelayed({ synchronized(lock) {
                                if (measuring === m) {
                                    measuring = null
                                    drainOutput()
                                    val healthy = System.nanoTime() - lastSamplesNs < 500_000_000L
                                    result.error(if (healthy) "noSignal" else "audio", "Kein stabiles Loopback-Signal / USB-Aufnahme unterbrochen", null)
                                }
                            } }, ((m.duration + 4) * 1000).toLong())
                            return@execute
                        }
                        if (System.nanoTime() >= deadline) throw SignalBusy(busyDetails())
                    }
                    Thread.sleep(10)
                }
            } catch (e: Exception) {
                val details = synchronized(lock) { if (e is SignalBusy) e.levels else busyDetails() }
                main.post { result.error(if (generation != token) "cancelled" else if (e is CaptureFailure) e.code else "signalBusy", e.message, details) }
            } finally {
                synchronized(lock) { if (generation == token) tonePending = false }
            }
        }
    }

    /** Drop queued PCM and pending writer blocks before discarding capture tail. */
    private fun drainOutput() {
        track?.let { it.pause(); it.flush(); it.stop(); it.play() }
        outputEpoch++
        writtenFrames = 0; lastToneQueuedFrame = 0
        playbackStamp = null; playbackStampFrame = null
        lastToneEnd = System.nanoTime()
        quiet = AnalyzerSelfTestQuiet(rate); quietStartNs = 0; quietEndNs = 0
    }

    private fun prepare(result: MethodChannel.Result) {
        stop()?.let { result.error("audio", it, null); return }
        val token = generation
        val latch = CountDownLatch(1)
        synchronized(lock) {
            ready = latch; input = null; rate = 0; captureError = null; captureDiagnostics = emptyMap()
            firstToneCommandNs = null; firstToneWrittenNs = null; quietStartNs = 0; quietEndNs = 0
        }
        capture.beginSelfTest(::samples) { code, details -> synchronized(lock) {
            captureError = CaptureFailure(code, details)
            captureDiagnostics = details
            ready?.countDown()
            measuring?.let { it.result.error(code, captureError!!.message, mapOf("diagnostics" to quietDiagnostics())) }
            measuring = null
        } }
        worker.execute {
            var prepared = false
            try {
                check(latch.await(6, TimeUnit.SECONDS)) { "Keine USB-Aufnahme / Aufnahmeberechtigung fehlt" }
                synchronized(lock) {
                    captureError?.let { throw it }
                    check(generation == token)
                    val source = input ?: error("USB input missing")
                    val manager = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val candidates = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter {
                        it.type in listOf(AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET) &&
                            it.address == source.address && it.productName.toString() == source.productName.toString()
                    }
                    check(candidates.size == 1) { "USB-Ausgang nicht eindeutig derselben ADI-2-Aufnahme zugeordnet" }
                    output = candidates.single()
                    val playback = AnalyzerSelfTestPlayback(manager, output!!, activity)
                    playbackOutput = playback
                    track = playback.create(rate)
                }
                // Warm up the output route using silence only.
                val deadline = synchronized(lock) {
                    System.nanoTime() + AnalyzerSelfTestQuiet.drainNs(measuredLatencyNs) + 6_000_000_000L
                }
                while (true) {
                    val routed = synchronized(lock) {
                        captureError?.let { throw it }
                        check(generation == token)
                        val t = track!!
                        val written = playbackOutput!!.write(t, FloatArray(rate / 100 * 2), 0, rate / 100 * 2)
                        check(written >= 0 && written % 2 == 0)
                        writtenFrames += written / 2
                        if (t.routedDevice?.id == output?.id && isQuiet()) {
                            if (playbackOutput!!.confirmRoute(t)) {
                                // Clearing a preference may invalidate the track. Rebuild the normal path,
                                // then warm up and verify USB routing again using silence only.
                                runCatching { t.pause(); t.flush(); t.stop() }
                                t.release(); track = null
                                track = playbackOutput!!.createNormal(rate)
                                writtenFrames = 0; lastToneQueuedFrame = 0
                                playbackStamp = null; playbackStampFrame = null
                                false
                            } else true
                        } else false
                    }
                    if (routed) break
                    if (System.nanoTime() >= deadline) {
                        synchronized(lock) {
                            check(track?.routedDevice?.id == output?.id) { "USB-Ausgaberoute fehlt" }
                            check(System.nanoTime() - lastSamplesNs < 500_000_000L) { "USB-Aufnahme unterbrochen" }
                            throw SignalBusy(busyDetails())
                        }
                    }
                    Thread.sleep(10)
                }
                val preparationDiagnostics = synchronized(lock) { quietDiagnostics() }
                prepared = true
                main.post { if (generation == token) result.success(mapOf("sampleRate" to rate,
                    "input" to input!!.productName.toString(), "output" to output!!.productName.toString(),
                    "inputId" to input!!.id, "outputId" to output!!.id,
                    "diagnostics" to preparationDiagnostics, "playback" to synchronized(lock) { outputDiagnostics(true) },
                    "mediaStreamVolume" to (activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager).getStreamVolume(AudioManager.STREAM_MUSIC),
                    "mediaStreamMax" to (activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager).getStreamMaxVolume(AudioManager.STREAM_MUSIC),
                    "mediaStreamMuted" to (activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager).isStreamMute(AudioManager.STREAM_MUSIC))) else result.error("cancelled", "Abgebrochen", null) }
                playback(token)
            } catch (e: Exception) {
                val details = synchronized(lock) { mapOf("diagnostics" to quietDiagnostics()) }
                if (generation == token) stop()
                if (!prepared) main.post {
                    when (e) {
                        is SignalBusy -> result.error("signalBusy", e.message, e.levels)
                        is CaptureFailure -> result.error(e.code, e.message, details)
                        else -> result.error("audio", e.message, details)
                    }
                }
            }
        }
    }

    private fun playback(token: Int) {
        val block = FloatArray(rate / 100 * 2)
        var offset = block.size
        var blockContainsTone = false
        var epoch = outputEpoch
        while (generation == token) {
            synchronized(lock) {
                if (generation != token) return
                captureError?.let { throw it }
                val t = track ?: return
                check(t.routedDevice?.id == output?.id) { "USB-Ausgaberoute geändert" }
                if (epoch != outputEpoch) { offset = block.size; epoch = outputEpoch }
                if (offset == block.size) {
                    val m = measuring
                    if (m != null && m.firstPlaybackFrame == null) m.firstPlaybackFrame = writtenFrames
                    blockContainsTone = m != null
                    for (i in block.indices step 2) {
                        val value = m?.tone?.next() ?: 0f
                        block[i] = value; block[i + 1] = value
                    }
                    offset = 0
                }
                val written = playbackOutput!!.write(t, block, offset, block.size - offset)
                check(written >= 0 && written % 2 == 0) { "USB-Wiedergabe fehlgeschlagen" }
                offset += written
                writtenFrames += written / 2
                if (blockContainsTone && written > 0) {
                    lastToneQueuedFrame = writtenFrames
                    val now = System.nanoTime()
                    if (firstToneWrittenNs == null) firstToneWrittenNs = now
                    if (measuring?.firstWrittenNs == null) measuring?.firstWrittenNs = now
                }
                val timestamp = AudioTimestamp()
                if (t.getTimestamp(timestamp)) {
                    playbackStamp = timestamp.nanoTime
                    playbackStampFrame = timestamp.framePosition
                }
            }
            Thread.sleep(2)
        }
    }

    private fun samples(pcm: FloatArray, length: Int, sampleRate: Int, device: AudioDeviceInfo, readEndNs: Long, diagnostics: Map<String, Any>) {
        synchronized(lock) {
            if (ready != null && input == null) {
                rate = sampleRate; quiet = AnalyzerSelfTestQuiet(rate); input = device; ready?.countDown()
            }
            captureDiagnostics = diagnostics
            lastSamplesNs = readEndNs
            if (rate != sampleRate || device.id != input?.id) { stop(); return }
            val blockStartNs = readEndNs - (length / 2 * 1e9 / rate).toLong()
            // Never feed a test tone or its queued output/USB tail to the quiet gate.
            if (quiet?.addCaptureBlock(pcm, length, blockStartNs, quietAfterNs(), measuring != null || toneQueued()) == true) {
                quietStartNs = quiet!!.windowStartNs
                quietEndNs = quiet!!.windowEndNs
            }
            val m = measuring ?: return
            var start = 0
            if (!m.onset) {
                while (start < length && max(abs(pcm[start]), abs(pcm[start + 1])) < 0.001f) start += 2
                if (start == length) return
                m.onset = true
                m.onsetNs = readEndNs - ((length - start) / 2 * 1e9 / rate).toLong()
                measuredLatencyNs = max(measuredLatencyNs, (m.onsetNs - m.commandNs).coerceAtLeast(0L))
            }
            val data = if (start == 0) pcm else pcm.copyOfRange(start, length)
            m.meter.add(data, length - start)
            if (m.meter.complete) {
                measuring = null
                val measurement = m.meter.result()
                val underruns = (track!!.underrunCount - m.underruns).coerceAtLeast(0)
                val outputAfter = outputDiagnostics()
                val volumeStable = listOf("mediaStreamVolume", "mediaStreamMuted", "mediaStreamDb").all {
                    m.outputBefore[it] == outputAfter[it]
                }
                val outputNs = if (playbackStamp != null && playbackStampFrame != null && m.firstPlaybackFrame != null)
                    playbackStamp!! + ((m.firstPlaybackFrame!! - playbackStampFrame!!) * 1e9 / rate).toLong() else null
                val playbackStable = m.outputBefore["bitPerfect"] == outputAfter["bitPerfect"]
                val invalidReasons = listOfNotNull(
                    (measurement["invalidReason"] as String).takeIf { it.isNotEmpty() },
                    "underrun".takeIf { underruns > 0 },
                    "volumeChanged".takeIf { !volumeStable },
                    "playbackChanged".takeIf { !playbackStable })
                val outputStamp = playbackStamp
                val outputFrame = playbackStampFrame
                drainOutput()
                main.post { m.result.success(measurement + mapOf(
                    "sampleRate" to rate, "quietBeforeTone" to m.quietBeforeTone, "playCommandNs" to m.commandNs,
                    "captureOnsetEstimateNs" to m.onsetNs, "captureReadEndNs" to readEndNs,
                    "playbackTimestampNs" to outputStamp, "playbackTimestampFrame" to outputFrame,
                    "toneFirstPlaybackFrame" to m.firstPlaybackFrame, "tonePlaybackEstimateNs" to outputNs,
                    "commandToCaptureMs" to (m.onsetNs - m.commandNs) / 1e6,
                    "outputToCaptureEstimateMs" to outputNs?.let { (m.onsetNs - it) / 1e6 },
                    "firstToneWrittenNs" to m.firstWrittenNs,
                    "underrunDelta" to underruns, "volumeStable" to volumeStable,
                    "playbackStable" to playbackStable,
                    "invalidReason" to invalidReasons.joinToString(", "),
                    "measurementValid" to (measurement["stable"] == true && underruns == 0 && volumeStable && playbackStable),
                    "playbackBefore" to m.outputBefore, "playbackAfter" to outputAfter)) }
            }
        }
    }

    /** API-verified mixer/route plus volume and effect availability diagnostics. */
    private fun outputDiagnostics(includeEffectCatalogue: Boolean = false): Map<String, Any> {
        val manager = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val t = track ?: return emptyMap()
        val volume = manager.getStreamVolume(AudioManager.STREAM_MUSIC)
        val db = if (Build.VERSION.SDK_INT >= 28 && output != null)
            runCatching { manager.getStreamVolumeDb(AudioManager.STREAM_MUSIC, volume, output!!.type).toDouble() }.getOrNull() else null
        return mapOf("sampleRate" to t.sampleRate, "encoding" to t.audioFormat,
            "channels" to t.channelCount, "bufferFrames" to t.bufferSizeInFrames,
            "sessionId" to t.audioSessionId, "routedDeviceId" to (t.routedDevice?.id ?: -1),
            "generatorPeakDbfs" to -20.0, "generatorRmsDbfs" to (-20.0 - 10 * log10(2.0)),
            "pcmScaling" to "0.1 peak; encoding ${t.audioFormat}; integer PCM quantized to full scale",
            "trackGain" to 1.0, "auxSend" to 0.0, "appVolumeShaper" to false,
            "mediaStreamVolume" to volume, "mediaStreamMax" to manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
            "mediaStreamMuted" to manager.isStreamMute(AudioManager.STREAM_MUSIC),
            "mediaStreamDb" to (db?.takeIf { it.isFinite() } ?: "unavailable"),
            "underrunCount" to t.underrunCount) + (playbackOutput?.diagnostics(t, includeEffectCatalogue) ?: emptyMap())
    }

    /** Stop/flush/release is the synchronous playback barrier before MIDI restore. */
    fun stop(): String? {
        synchronized(lock) {
            generation++
            measuring?.let { m -> main.post { m.result.error("cancelled", "Abgebrochen", null) } }
            if (measuring != null || toneQueued()) lastToneEnd = System.nanoTime()
            measuring = null; tonePending = false
            var cleanupError: String? = null
            try {
                track?.let {
                    try { it.pause(); it.flush(); it.stop() } finally { it.release() }
                }
            } catch (e: Exception) { cleanupError = e.message ?: "USB-Wiedergabe nicht freigegeben" }
            try {
                val manager = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                if (playbackOutput != null) playbackOutput!!.clear() else AnalyzerSelfTestPlayback.clearStale(manager, activity)
                playbackOutput = null
            } catch (e: Exception) { cleanupError = e.message ?: "USB-Mixer nicht freigegeben" }
            track = null; playbackStamp = null; playbackStampFrame = null; writtenFrames = 0L; lastToneQueuedFrame = 0L; quiet = null; lastSamplesNs = 0
            ready?.countDown(); ready = null
            capture.endSelfTest()
            return cleanupError
        }
    }
    fun dispose() { stop(); channel.setMethodCallHandler(null); worker.shutdownNow(); io.shutdown() }
}
