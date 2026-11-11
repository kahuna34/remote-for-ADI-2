package de.markus.adi2_remote

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.*
import android.media.audiofx.*
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.*
import java.util.concurrent.Executors

/** USB-only delivery. Unverified routing probes are discarded before DSP or self-test. */
internal class AnalyzerCapture(private val activity: Activity, messenger: BinaryMessenger) : EventChannel.StreamHandler {
    companion object { const val PERMISSION = 8472 }
    private val main = Handler(Looper.getMainLooper())
    private val manager = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val worker = Executors.newSingleThreadExecutor()
    private var sink: EventChannel.EventSink? = null
    @Volatile private var recorder: AudioRecord? = null
    @Volatile private var generation = 0
    private var permissionResult: MethodChannel.Result? = null
    private val method = MethodChannel(messenger, "adi2/analyzer")
    private val events = EventChannel(messenger, "adi2/analyzer/events")
    private val deliveryLock = Any()
    private var deliveryPending = false
    private var latestEvent: Map<String, Any>? = null
    @Volatile private var bandsPerOctave = 3
    @Volatile private var diagnosticsEnabled = false
    @Volatile private var selfTestSamples: ((FloatArray, Int, Int, AudioDeviceInfo, Long, Map<String, Any>) -> Unit)? = null
    @Volatile private var selfTestOwned = false
    @Volatile private var selfTestGeneration = -1
    private var normalDesired = false
    @Volatile private var selfTestFailure: ((String, Map<String, Any>) -> Unit)? = null
    private val toneLock = Any()
    private var toneTrack: AudioTrack? = null
    private var toneOutputId: Int? = null

    fun beginSelfTest(callback: (FloatArray, Int, Int, AudioDeviceInfo, Long, Map<String, Any>) -> Unit, failure: (String, Map<String, Any>) -> Unit) {
        check(!selfTestOwned)
        stopCalibrationTone()
        selfTestOwned = true
        selfTestSamples = callback
        selfTestFailure = failure
        start()
        selfTestGeneration = generation
    }
    fun endSelfTest() {
        if (!selfTestOwned) return
        selfTestFailure = null; selfTestSamples = null; selfTestGeneration = -1; selfTestOwned = false
        stop()
        main.post { if (!selfTestOwned && normalDesired && sink != null) start() }
    }
    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(devices: Array<out AudioDeviceInfo>) {
            // Rebuild after a USB reconnect; an old AudioRecord keeps its old port.
            if (!selfTestOwned && normalDesired && devices.any { it.isSource && isAdi2(it) }) start()
        }
        override fun onAudioDevicesRemoved(devices: Array<out AudioDeviceInfo>) {
            if (devices.any { it.id == synchronized(toneLock) { toneOutputId } }) stopCalibrationTone()
            if (devices.any { it.id == recorder?.preferredDevice?.id }) {
                stop()
                failure(generation, "usbUnavailable", mapOf("message" to "ADI-2 getrennt"))
            }
        }
    }

    init {
        events.setStreamHandler(this)
        manager.registerAudioDeviceCallback(deviceCallback, main)
        method.setMethodCallHandler { call, result ->
            when (call.method) {
                "permission" -> result.success(activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
                "requestPermission" -> {
                    if (permissionResult != null) result.error("busy", "Permission pending", null)
                    else if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) result.success(true)
                    else {
                        permissionResult = result
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION)
                    }
                }
                "start" -> {
                    if (selfTestOwned) { result.error("busy", "Developer self-test active", null); return@setMethodCallHandler }
                    normalDesired = true
                    diagnosticsEnabled = call.argument<Boolean>("diagnostics") == true
                    bandsPerOctave = call.argument<Int>("bandsPerOctave")?.takeIf { it in listOf(3, 6, 12) } ?: 3
                    start(); result.success(null)
                }
                "setDiagnostics" -> { diagnosticsEnabled = call.argument<Boolean>("enabled") == true; result.success(null) }
                "setBandResolution" -> {
                    bandsPerOctave = call.argument<Int>("bandsPerOctave")?.takeIf { it in listOf(3, 6, 12) } ?: 3
                    result.success(null)
                }
                "stop" -> { normalDesired = false; if (!selfTestOwned) stop(); result.success(null) }
                "startCalibrationTone" -> startCalibrationTone { error ->
                    if (error == null) result.success(null) else result.error(error, "Calibration tone unavailable", null)
                }
                "stopCalibrationTone" -> { stopCalibrationTone(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    fun permissionResult(grants: IntArray) {
        permissionResult?.success(grants.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        permissionResult = null
    }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
    override fun onCancel(arguments: Any?) { normalDesired = false; if (!selfTestOwned) stop(); sink = null }

    private fun isAdi2(device: AudioDeviceInfo) = AnalyzerInputPolicy.isAdi2(
        device.type in listOf(AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET), device.productName.toString())

    private fun deviceInfo(device: AudioDeviceInfo?): Map<String, Any> = if (device == null)
        mapOf("name" to "unbekannt", "type" to -1, "id" to -1) else mapOf(
        "name" to device.productName.toString(), "type" to device.type, "id" to device.id,
        "address" to device.address, "phoneMicrophone" to (device.type == AudioDeviceInfo.TYPE_BUILTIN_MIC))

    /** Stable model identity, with the USB serial only when already accessible.
     * Audio port IDs and card addresses change after reconnecting. */
    private fun calibrationIdentity(device: AudioDeviceInfo): Map<String, Any> {
        val usbManager = activity.getSystemService(Context.USB_SERVICE) as UsbManager
        val candidates = usbManager.deviceList.values.filter {
            AnalyzerInputPolicy.isAdi2(true, it.productName.orEmpty())
        }
        val usb = candidates.singleOrNull { it.deviceName == device.address }
            ?: candidates.singleOrNull { it.productName == device.productName.toString() }
            ?: candidates.singleOrNull()
        val serial = try {
            if (usb != null && usbManager.hasPermission(usb)) usb.serialNumber else null
        } catch (_: SecurityException) { null }
        return buildMap {
            put("androidManufacturer", Build.MANUFACTURER)
            put("androidModel", Build.MODEL)
            put("usbName", device.productName.toString())
            usb?.let { put("usbVendorId", it.vendorId); put("usbProductId", it.productId) }
            serial?.takeIf { it.isNotBlank() }?.let { put("usbSerial", it) }
        }
    }

    private fun formatInfo(format: AudioFormat): Map<String, Any> = mapOf(
        "sampleRate" to format.sampleRate, "channels" to format.channelCount, "encoding" to format.encoding)

    private fun diagnostics(record: AudioRecord, requested: AudioFormat, expected: AudioDeviceInfo,
                            communication: String): Map<String, Any> {
        val config = manager.activeRecordingConfigurations.firstOrNull { it.clientAudioSessionId == record.audioSessionId }
        return mapOf("requestedDevice" to deviceInfo(expected), "routedDevice" to deviceInfo(record.routedDevice),
            "requestedFormat" to formatInfo(requested), "actualFormat" to formatInfo(record.format),
            "hardwareFormat" to (config?.let { formatInfo(it.format) } ?: emptyMap<String, Any>()),
            "audioSource" to record.audioSource, "bufferFrames" to record.bufferSizeInFrames,
            "pcmScaling" to if (record.audioFormat == AudioFormat.ENCODING_PCM_16BIT) "PCM16 / 32768" else "PCM_FLOAT [-1,1]",
            "communicationRouting" to communication)
    }

    /** Android may briefly report its default input while USB routing settles.
     * Drain and discard all probe PCM, including any buffered microphone data. */
    private fun awaitUsbRoute(record: AudioRecord, device: AudioDeviceInfo, token: Int): Boolean {
        val floats = FloatArray(maxOf(2, record.bufferSizeInFrames * 2))
        val shorts = ShortArray(floats.size)
        val deadline = System.nanoTime() + 500_000_000L
        var usbSince = 0L
        while (generation == token && System.nanoTime() < deadline) {
            val length = if (record.audioFormat == AudioFormat.ENCODING_PCM_FLOAT)
                record.read(floats, 0, floats.size, AudioRecord.READ_NON_BLOCKING)
            else record.read(shorts, 0, shorts.size, AudioRecord.READ_NON_BLOCKING)
            check(length >= 0) { "USB-Routenprüfung: AudioRecord.read fehlgeschlagen ($length)" }
            val routed = record.routedDevice
            val matches = routed != null && AnalyzerInputPolicy.accepts(device.id, routed.id,
                routed.type in listOf(AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET), routed.productName.toString())
            val now = System.nanoTime()
            if (!matches) usbSince = 0L
            else if (usbSince == 0L) usbSince = now
            else if (now - usbSince >= 100_000_000L) return true
            Thread.sleep(10)
        }
        return false
    }

    private fun failure(token: Int, code: String, details: Map<String, Any>) {
        main.post {
            if (generation == token) {
                sink?.success(mapOf("status" to code, "diagnostics" to details))
                selfTestFailure?.invoke(code, details)
            }
        }
    }

    private fun start() {
        stop()
        val token = generation
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            failure(token, "permissionDenied", emptyMap()); return
        }
        val device = manager.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { isAdi2(it) }
        if (device == null) { failure(token, "usbUnavailable", mapOf("message" to "Kein ADI-2-USB-Eingang verfügbar")); return }
        worker.execute {
            var owned: AudioRecord? = null
            var effects = emptyList<AudioEffect>()
            var requested: AudioFormat? = null
            var lastDetails = mapOf<String, Any>("requestedDevice" to deviceInfo(device))
            var failureCode = "usbUnavailable"
            var routeFailureDetails: Map<String, Any>? = null
            var communication = "nicht benötigt"
            var communicationDevice: AudioDeviceInfo? = null
            var previousCommunication: AudioDeviceInfo? = null
            fun status(code: String, details: Map<String, Any> = lastDetails) = failure(token, code, details)
            try {
                val rates = (listOf(48000) + device.sampleRates.filter { it in 44100..192000 }.sortedDescending()).distinct()
                val sources = buildList {
                    if (manager.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true")
                        add(MediaRecorder.AudioSource.UNPROCESSED)
                    add(MediaRecorder.AudioSource.VOICE_RECOGNITION)
                    add(MediaRecorder.AudioSource.MIC)
                }
                // First try normal recording; only then try a matching communication
                // sink on Android 12+. Never select the speaker or change audio mode.
                routeLoop@ for (attempt in 0..1) {
                    if (attempt == 1) {
                        if (Build.VERSION.SDK_INT < 31) break
                        val sink = manager.availableCommunicationDevices.singleOrNull {
                            isAdi2(it) && it.address == device.address && it.productName.toString() == device.productName.toString()
                        }
                        if (sink == null) { communication = "ADI-2 nicht als Kommunikationsgerät verfügbar"; break }
                        previousCommunication = manager.communicationDevice
                        if (!manager.setCommunicationDevice(sink)) { communication = "setCommunicationDevice abgelehnt"; break }
                        communicationDevice = sink
                        communication = "setCommunicationDevice + AudioRecord neu aufgebaut"
                    }
                    val negotiationDeadline = System.nanoTime() + 1_400_000_000L
                    for (source in sources) for (rate in rates) {
                        for (encoding in listOf(AudioFormat.ENCODING_PCM_FLOAT, AudioFormat.ENCODING_PCM_16BIT)) {
                            if (generation != token) return@execute
                            if (System.nanoTime() >= negotiationDeadline) continue@routeLoop
                            val minimum = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_STEREO, encoding)
                            if (minimum <= 0) continue
                            var candidate: AudioRecord? = null
                            var candidateEffects = emptyList<AudioEffect>()
                            var candidateFormat: AudioFormat? = null
                            try {
                                val format = AudioFormat.Builder().setSampleRate(rate)
                                    .setChannelMask(AudioFormat.CHANNEL_IN_STEREO).setEncoding(encoding).build()
                                candidateFormat = format
                                candidate = AudioRecord.Builder().setAudioSource(source).setAudioFormat(format)
                                    .setBufferSizeInBytes(maxOf(minimum, (rate / 60) * 2 *
                                        (if (encoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2) * 2)).build()
                                check(candidate.state == AudioRecord.STATE_INITIALIZED)
                                check(candidate.channelCount == 2 && candidate.audioFormat == encoding && candidate.sampleRate == rate) {
                                    "Aufnahmeformat entspricht nicht dem verlangten PCM-Format"
                                }
                                check(candidate.setPreferredDevice(device)) { "USB-Eingang als bevorzugtes Gerät abgelehnt" }
                                candidateEffects = disablePreprocessing(candidate.audioSessionId)
                                synchronized(this) {
                                    check(generation == token)
                                    recorder = candidate
                                    candidate.startRecording()
                                    check(candidate.recordingState == AudioRecord.RECORDSTATE_RECORDING)
                                }
                                // getRoutedDevice is valid only after startRecording.
                                // Until the USB route is verified, no PCM reaches a consumer.
                                val routeReady = awaitUsbRoute(candidate, device, token)
                                lastDetails = diagnostics(candidate, format, device, communication)
                                if (!routeReady) {
                                    failureCode = "routeMismatch"
                                    routeFailureDetails = lastDetails
                                    error("Aufnahme läuft über ${candidate.routedDevice?.productName ?: "unbekanntes Gerät"} statt über den ADI-2")
                                }
                                effects = candidateEffects; owned = candidate; requested = format
                                break@routeLoop
                            } catch (e: Exception) {
                                if (candidate != null && candidateFormat != null) lastDetails =
                                    runCatching { diagnostics(candidate, candidateFormat, device, communication) }.getOrDefault(lastDetails) +
                                    mapOf("message" to (e.message ?: e.toString()))
                                synchronized(this) { if (recorder === candidate) recorder = null }
                                try { candidate?.stop() } catch (_: Exception) {}
                                candidateEffects.forEach { it.release() }; candidate?.release()
                            }
                        }
                    }
                }
                val record = owned ?: run { status(failureCode, (routeFailureDetails ?: lastDetails) + mapOf("communicationRouting" to communication)); return@execute }
                val dsp = AnalyzerDsp(record.sampleRate, bandsPerOctave)
                val calibrationIdentity = calibrationIdentity(device)
                val availableEffects = runCatching {
                    AudioEffect.queryEffects()?.map { "${it.name} (${it.implementor})" }?.distinct() ?: emptyList<String>()
                }.getOrDefault(emptyList())
                val signal = AnalyzerSelfTestQuiet(record.sampleRate)
                var signalDetails = emptyMap<String, Any>()
                var signalStamp = 0L
                val blockSamples = (record.sampleRate / 60.0).toInt() * 2
                val floats = FloatArray(blockSamples)
                val shorts = ShortArray(blockSamples)
                while (generation == token) {
                    val length = if (record.audioFormat == AudioFormat.ENCODING_PCM_FLOAT)
                        record.read(floats, 0, floats.size, AudioRecord.READ_BLOCKING)
                    else record.read(shorts, 0, shorts.size, AudioRecord.READ_BLOCKING)
                    val readEndNs = System.nanoTime()
                    if (generation != token) break
                    lastDetails = diagnostics(record, requested!!, device, communication)
                    val routed = record.routedDevice
                    if (routed == null || !AnalyzerInputPolicy.accepts(device.id, routed.id,
                            routed.type in listOf(AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET), routed.productName.toString())) {
                        status("routeMismatch", lastDetails + mapOf("message" to "Aufnahmeroute geändert; USB-Aufnahme gestoppt")); break
                    }
                    if (length == 0) continue
                    if (length < 0) { status("captureFailed"); break }
                    if (record.audioFormat == AudioFormat.ENCODING_PCM_16BIT)
                        for (i in 0 until length) floats[i] = AnalyzerInputPolicy.pcm16(shorts[i])
                    if (!AnalyzerInputPolicy.validPcm(floats, length)) {
                        status("captureFailed", lastDetails + mapOf("message" to "Ungültiges PCM: Format/Skalierung oder ungerade Stereo-Länge")); break
                    }
                    if (selfTestGeneration == token) {
                        selfTestSamples?.invoke(floats, length, record.sampleRate, routed, readEndNs, lastDetails)
                        // Self-test owns capture: avoid a second filter bank and two
                        // unused FFTs competing with the AudioTrack writer.
                        continue
                    }
                    if (diagnosticsEnabled && !selfTestOwned) {
                        for (i in 0 until length step 2) signal.add(floats[i].toDouble(), floats[i + 1].toDouble())
                        if (readEndNs - signalStamp >= 500_000_000L) {
                            signalDetails = signal.details(); signalStamp = readEndNs
                        }
                        lastDetails = lastDetails + mapOf("signal" to signalDetails)
                    }
                    dsp.resolution = bandsPerOctave
                    dsp.add(floats, length) { frame ->
                        deliverLatest(token, frame + mapOf("device" to routed.productName.toString(),
                            "calibrationIdentity" to calibrationIdentity,
                            "mediaStreamVolume" to manager.getStreamVolume(AudioManager.STREAM_MUSIC),
                            "mediaStreamMax" to manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
                            "availableEffects" to availableEffects,
                            "diagnostics" to lastDetails, "routeVerified" to true, "blockFrames" to length / 2, "processingDisabled" to true))
                    }
                }
            } catch (_: SecurityException) { status("permissionDenied") }
            catch (e: Exception) { status("captureFailed", lastDetails + mapOf("message" to (e.message ?: e.toString()))) }
            finally {
                synchronized(this) { if (recorder === owned) recorder = null }
                try { owned?.stop() } catch (_: Exception) {}
                effects.forEach { it.release() }; owned?.release()
                if (Build.VERSION.SDK_INT >= 31 && communicationDevice != null && manager.communicationDevice?.id == communicationDevice.id) {
                    val previous = previousCommunication
                    if (previous != null && manager.availableCommunicationDevices.any { it.id == previous.id }) manager.setCommunicationDevice(previous)
                    else manager.clearCommunicationDevice()
                }
            }
        }
    }

    /** Retain handles until recording ends; reject an effect that refuses bypass. */
    private fun disablePreprocessing(session: Int): List<AudioEffect> {
        val effects = mutableListOf<AudioEffect>()
        try {
            if (AutomaticGainControl.isAvailable()) AutomaticGainControl.create(session)?.let { effects.add(it) }
            if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(session)?.let { effects.add(it) }
            if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(session)?.let { effects.add(it) }
            effects.forEach {
                check(it.setEnabled(false) == AudioEffect.SUCCESS && !it.enabled) { "Audio preprocessing cannot be disabled" }
            }
            return effects
        } catch (error: Exception) {
            effects.forEach { it.release() }
            throw error
        }
    }

    /** One main-thread message, replace queued stale spectra; retain time/clip/peaks. */
    private fun deliverLatest(token: Int, frame: Map<String, Any>) {
        synchronized(deliveryLock) {
            if (generation != token) return
            val previous = latestEvent
            latestEvent = if (previous == null) frame else frame + mapOf(
                "seconds" to (previous["seconds"] as Double) + (frame["seconds"] as Double),
                "peak" to DoubleArray(2) { maxOf((previous["peak"] as DoubleArray)[it], (frame["peak"] as DoubleArray)[it]) },
                "clipped" to List(2) { (previous["clipped"] as List<*>)[it] == true || (frame["clipped"] as List<*>)[it] == true })
            if (deliveryPending) return
            deliveryPending = true
            main.post {
                val event = synchronized(deliveryLock) {
                    if (generation != token) return@post
                    val next = latestEvent
                    latestEvent = null; deliveryPending = false
                    next
                }
                if (event != null && generation == token) sink?.success(event)
            }
        }
    }

    fun stopForBackground() { normalDesired = false; stop() }

    private fun startCalibrationTone(done: (String?) -> Unit) {
        Thread {
            val error = try { playCalibrationTone() } catch (_: Exception) { stopCalibrationTone(); "toneFailed" }
            main.post { done(error) }
        }.start()
    }

    /**
     * 1 kHz at 0 dBFS. The static buffer ends by itself after 3.6 s, even if Dart stops
     * responding. Its leading silence covers the check that the track really uses USB.
     */
    private fun playCalibrationTone(): String? {
        stopCalibrationTone()
        if (selfTestOwned) return "busy"
        val output = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { it.isSink && isAdi2(it) }
            ?: return "noUsbOutput"
        val rate = 48000
        val lead = rate / 4
        val fade = rate / 50
        val total = rate * 36 / 10
        val pcm = ShortArray(total * 2)
        for (frame in lead until total) {
            val gain = minOf(1.0, (frame - lead).toDouble() / fade, (total - 1 - frame).toDouble() / fade)
            val sample = (32767.0 * gain * Math.sin(2.0 * Math.PI * (frame - lead) / 48.0)).toInt().toShort()
            pcm[frame * 2] = sample
            pcm[frame * 2 + 1] = sample
        }
        val track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(rate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setBufferSizeInBytes(pcm.size * 2)
            .build()
        synchronized(toneLock) { toneTrack = track; toneOutputId = output.id }
        check(track.write(pcm, 0, pcm.size) == pcm.size) { "Testton nicht geschrieben" }
        check(track.setPreferredDevice(output)) { "USB-Ausgang abgelehnt" }
        track.play()
        var verified = false
        for (attempt in 0 until 20) {
            if (track.routedDevice?.id == output.id) { verified = true; break }
            Thread.sleep(10)
        }
        if (!verified) { stopCalibrationTone(); return "noUsbRoute" }
        // Android falls back to the speaker when USB goes away: stop instead.
        track.addOnRoutingChangedListener(AudioRouting.OnRoutingChangedListener { routing ->
            if (routing.routedDevice?.id != output.id) stopCalibrationTone()
        }, main)
        return null
    }

    fun stopCalibrationTone() {
        val track = synchronized(toneLock) {
            val current = toneTrack
            toneTrack = null
            toneOutputId = null
            current
        } ?: return
        try { track.stop() } catch (_: Exception) {}
        track.release()
    }

    @Synchronized fun stop() {
        stopCalibrationTone()
        generation++
        synchronized(deliveryLock) { latestEvent = null; deliveryPending = false }
        try { recorder?.stop() } catch (_: Exception) {}
        // The worker owns release, after the blocking read has returned.
        recorder = null
    }
    fun dispose() {
        stop()
        permissionResult?.success(false); permissionResult = null
        manager.unregisterAudioDeviceCallback(deviceCallback)
        events.setStreamHandler(null); method.setMethodCallHandler(null)
        sink = null
        worker.shutdown()
    }
}
