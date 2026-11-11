package de.markus.adi2_remote

import android.content.ComponentName
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.hardware.usb.UsbManager
import android.net.Uri
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Build
import android.os.Looper
import android.provider.Settings
import android.view.WindowInsets
import android.view.WindowInsetsController
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.Future

/**
 * Player-Leiste: liest die aktive Medien-Sitzung (Titel, Interpret, Cover,
 * Status) und steuert sie (Play/Pause, Weiter, Zurück, Stop).
 */
class MainActivity : FlutterActivity() {
    private var analyzer: AnalyzerCapture? = null
    private var analyzerSelfTest: AnalyzerSelfTest? = null
    private var eqFullscreen = false
    private var hostMulticastLock: android.net.wifi.WifiManager.MulticastLock? = null

    private fun applyEqFullscreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.let { insets ->
                if (eqFullscreen) {
                    insets.systemBarsBehavior =
                        WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                    insets.hide(WindowInsets.Type.systemBars())
                } else {
                    insets.show(WindowInsets.Type.systemBars())
                }
            }
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && eqFullscreen) applyEqFullscreen()
    }

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var manager: MediaSessionManager? = null
    private var controller: MediaController? = null
    private data class TrackKey(val pkg: String, val title: String?, val artist: String?, val album: String?)
    private data class ArtSource(val bitmap: Bitmap?, val uris: List<String>)
    // Alle Zustandsänderungen erfolgen auf dem Main-Thread, Dekodierung nur im Worker.
    private val artworkWorker = Executors.newSingleThreadExecutor()
    private var artworkTask: Future<*>? = null
    private var artworkGeneration = 0L
    private var artworkKey: TrackKey? = null
    private var pendingSource: ArtSource? = null
    private var loadedSource: ArtSource? = null
    private val artworkCache = object : LinkedHashMap<TrackKey, ByteArray>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<TrackKey, ByteArray>?) = size > 8
    }

    private fun invalidateArtwork() {
        artworkGeneration++
        artworkTask?.cancel(true)
        artworkTask = null
        artworkKey = null
        pendingSource = null
        loadedSource = null
    }

    private val listenerComponent by lazy {
        ComponentName(this, MediaListenerService::class.java)
    }

    private val sessionsListener =
        MediaSessionManager.OnActiveSessionsChangedListener { list ->
            main.post { pickController(list ?: emptyList()) }
        }

    private val callback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) = emit()
        override fun onPlaybackStateChanged(state: PlaybackState?) = emit()
        override fun onSessionDestroyed() {
            invalidateArtwork()
            controller?.unregisterCallback(this)
            controller = null
            refresh()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "de.markus.adi2_remote/host_network").setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticast" -> {
                    if (hostMulticastLock == null) {
                        val wifi = applicationContext.getSystemService(WIFI_SERVICE) as android.net.wifi.WifiManager
                        hostMulticastLock = wifi.createMulticastLock("adi2-host-discovery").apply {
                            setReferenceCounted(false)
                            acquire()
                        }
                    }
                    result.success(null)
                }
                "releaseMulticast" -> {
                    hostMulticastLock?.let { if (it.isHeld) it.release() }
                    hostMulticastLock = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        analyzer = AnalyzerCapture(this, messenger)
        analyzerSelfTest = AnalyzerSelfTest(this, messenger, analyzer!!)

        MethodChannel(messenger, "adi2/usb").setMethodCallHandler { call, result ->
            if (call.method == "ccMode") result.success(readUsbCcMode())
            else result.notImplemented()
        }

        MethodChannel(messenger, "adi2/display").setMethodCallHandler { call, result ->
            if (call.method == "setFullscreen") {
                eqFullscreen = call.arguments == true
                // Nach Flutters eigener System-UI-Aktualisierung anwenden.
                window.decorView.post { applyEqFullscreen() }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(messenger, "adi2/media").setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAccess" -> result.success(hasAccess())
                "openAccessSettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }
                "command" -> {
                    val c = controller?.transportControls
                    when (call.arguments as? String) {
                        "play" -> c?.play()
                        "pause" -> c?.pause()
                        "next" -> c?.skipToNext()
                        "previous" -> c?.skipToPrevious()
                        "stop" -> c?.stop()
                    }
                    result.success(c != null)
                }
                "openPlayer" -> result.success(openPlayer())
                "refresh" -> {
                    refresh()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "adi2/media/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    refresh()
                }

                override fun onCancel(args: Any?) {
                    sink = null
                    detach()
                }
            })
    }

    private fun readUsbCcMode(): String = try {
        val usb = getSystemService(USB_SERVICE) as UsbManager
        val devices = usb.deviceList.values.filter { it.vendorId == 0x2A39 }
        // Avoid attributing another RME device's descriptors to this connection.
        val device = devices.singleOrNull()
        if (device == null || !usb.hasPermission(device)) {
            "unknown"
        } else {
            val connection = usb.openDevice(device)
            if (connection == null) "unknown" else try {
                parseUsbCcMode(connection.rawDescriptors ?: byteArrayOf())
            } finally {
                connection.close()
            }
        }
    } catch (_: Exception) {
        // No requestPermission: MIDI access does not necessarily grant USB access.
        "unknown"
    }

    override fun onResume() {
        super.onResume()
        // Nach Rückkehr aus den Einstellungen: Freigabe erneut prüfen.
        refresh()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == AnalyzerCapture.PERMISSION) analyzer?.permissionResult(grantResults)
    }

    override fun onPause() {
        analyzer?.stopForBackground()
        analyzerSelfTest?.stop()
        super.onPause()
    }

    override fun onStop() {
        analyzer?.stopForBackground()
        analyzerSelfTest?.stop()
        super.onStop()
    }

    override fun onDestroy() {
        hostMulticastLock?.let { if (it.isHeld) it.release() }
        hostMulticastLock = null
        analyzerSelfTest?.dispose()
        analyzer?.dispose()
        detach()
        artworkWorker.shutdownNow()
        super.onDestroy()
    }

    /** Öffnet die Player-App, möglichst direkt bei der laufenden Wiedergabe. */
    private fun openPlayer(): Boolean {
        val c = controller ?: return false
        try {
            val pi = c.sessionActivity
            if (pi != null) {
                pi.send()
                return true
            }
        } catch (_: Exception) {
        }
        val launch = packageManager.getLaunchIntentForPackage(c.packageName) ?: return false
        startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        return true
    }

    private fun hasAccess(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
            ?: return false
        return flat.split(":").any {
            ComponentName.unflattenFromString(it)?.packageName == packageName
        }
    }

    private fun refresh() {
        if (sink == null) return
        if (!hasAccess()) {
            detach()
            sink?.success(mapOf("access" to false))
            return
        }
        try {
            if (manager == null) {
                manager = getSystemService(MEDIA_SESSION_SERVICE) as MediaSessionManager
                manager?.addOnActiveSessionsChangedListener(sessionsListener, listenerComponent)
            }
            pickController(manager?.getActiveSessions(listenerComponent) ?: emptyList())
        } catch (e: SecurityException) {
            detach()
            sink?.success(mapOf("access" to false))
        }
    }

    /** Spielende Sitzung bevorzugen, sonst die zuletzt aktive. */
    private fun pickController(list: List<MediaController>) {
        val best = list.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
            ?: list.firstOrNull()
        if (best?.sessionToken != controller?.sessionToken) {
            controller?.unregisterCallback(callback)
            invalidateArtwork()
            controller = best
            controller?.registerCallback(callback, main)
        }
        emit()
    }

    private fun detach() {
        invalidateArtwork()
        controller?.unregisterCallback(callback)
        controller = null
        try {
            manager?.removeOnActiveSessionsChangedListener(sessionsListener)
        } catch (_: Exception) {
        }
        manager = null
    }

    private fun emit() {
        val s = sink ?: return
        val c = controller
        if (c == null) {
            s.success(mapOf("access" to true))
            return
        }
        val md = c.metadata
        val title = md?.getString(MediaMetadata.METADATA_KEY_TITLE)
            ?: md?.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE)
        val artist = md?.getString(MediaMetadata.METADATA_KEY_ARTIST)
            ?: md?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
            ?: md?.getString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE)
        val app = try {
            packageManager.getApplicationLabel(
                packageManager.getApplicationInfo(c.packageName, 0)
            ).toString()
        } catch (_: Exception) {
            c.packageName
        }
        val playing = c.playbackState?.state == PlaybackState.STATE_PLAYING
        s.success(
            mapOf(
                "access" to true,
                "title" to title,
                "artist" to artist,
                "app" to app,
                "playing" to playing,
                "art" to art(md, TrackKey(c.packageName, title, artist,
                    md?.getString(MediaMetadata.METADATA_KEY_ALBUM))),
            )
        )
    }

    /** Späte Metadaten ergänzen das Cover; fehlende Bilder löschen es nur beim Titelwechsel. */
    private fun art(md: MediaMetadata?, key: TrackKey): ByteArray? {
        if (key != artworkKey) {
            invalidateArtwork()
            artworkKey = key
        }
        val bitmap = listOf(
            MediaMetadata.METADATA_KEY_ALBUM_ART,
            MediaMetadata.METADATA_KEY_ART,
            MediaMetadata.METADATA_KEY_DISPLAY_ICON,
        ).firstNotNullOfOrNull { name ->
            try { md?.getBitmap(name)?.takeUnless { it.isRecycled } } catch (_: Exception) { null }
        }
        val uris = listOf(
            MediaMetadata.METADATA_KEY_ALBUM_ART_URI,
            MediaMetadata.METADATA_KEY_ART_URI,
            MediaMetadata.METADATA_KEY_DISPLAY_ICON_URI,
        ).mapNotNull { name ->
            try { md?.getString(name)?.takeIf { it.isNotBlank() } } catch (_: Exception) { null }
        }.distinct()
        val source = ArtSource(bitmap, uris)
        if ((bitmap != null || uris.isNotEmpty()) && source != pendingSource && source != loadedSource) {
            artworkTask?.cancel(true)
            val generation = ++artworkGeneration
            pendingSource = source
            artworkTask = artworkWorker.submit {
                val bytes = bitmap?.let { encodeArtwork(it) }
                    ?: uris.firstNotNullOfOrNull { uri -> loadArtwork(uri) }
                main.post {
                    // Ein alter Download darf weder neue Titel noch neue Sessions überschreiben.
                    if (generation == artworkGeneration && key == artworkKey && sink != null) {
                        pendingSource = null
                        if (bytes != null) {
                            loadedSource = source
                            artworkCache[key] = bytes
                            emit()
                        }
                    }
                }
            }
        }
        return artworkCache[key]
    }

    private fun encodeArtwork(bitmap: Bitmap): ByteArray? {
        var scaled: Bitmap? = null
        return try {
            if (bitmap.isRecycled) return null
            val ratio = minOf(1.0, 200.0 / maxOf(bitmap.width, bitmap.height))
            scaled = Bitmap.createScaledBitmap(bitmap,
                maxOf(1, (bitmap.width * ratio).toInt()),
                maxOf(1, (bitmap.height * ratio).toInt()), true)
            ByteArrayOutputStream().use { out ->
                if (scaled.compress(Bitmap.CompressFormat.JPEG, 85, out)) out.toByteArray() else null
            }
        } catch (_: Exception) {
            null
        } catch (_: OutOfMemoryError) {
            null
        } finally {
            // Von der MediaSession gelieferte Bitmaps gehören dem Player.
            if (scaled !== bitmap) scaled?.recycle()
        }
    }

    private fun loadArtwork(value: String): ByteArray? {
        if (Thread.currentThread().isInterrupted) return null
        var connection: HttpURLConnection? = null
        var decoded: Bitmap? = null
        return try {
            val uri = Uri.parse(value)
            val stream = when (uri.scheme?.lowercase()) {
                "content", "android.resource" -> contentResolver.openInputStream(uri)
                "http", "https" -> {
                    connection = (URL(value).openConnection() as HttpURLConnection).apply {
                        connectTimeout = 4000
                        readTimeout = 4000
                    }
                    connection.inputStream
                }
                else -> null
            } ?: return null
            // Begrenzen, damit fehlerhafte Quellen keinen unbeschränkten Speicher belegen.
            val data = stream.use { input ->
                ByteArrayOutputStream().use { out ->
                    val buffer = ByteArray(8192)
                    while (true) {
                        if (Thread.currentThread().isInterrupted) return null
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (out.size() + count > 12 * 1024 * 1024) return null
                        out.write(buffer, 0, count)
                    }
                    out.toByteArray()
                }
            }
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(data, 0, data.size, options)
            if (options.outWidth <= 0 || options.outHeight <= 0) return null
            options.inSampleSize = 1
            while (maxOf(options.outWidth, options.outHeight) / options.inSampleSize > 400) {
                options.inSampleSize *= 2
            }
            options.inJustDecodeBounds = false
            decoded = BitmapFactory.decodeByteArray(data, 0, data.size, options)
            decoded?.let { encodeArtwork(it) }
        } catch (_: Exception) {
            null
        } catch (_: OutOfMemoryError) {
            null
        } finally {
            decoded?.recycle()
            connection?.disconnect()
        }
    }
}
