import Flutter
import MediaPlayer
import UIKit

/// iOS exposes Apple Music's system player, not other apps' media sessions.
final class NowPlayingBridge: NSObject, FlutterStreamHandler {
  private let method: FlutterMethodChannel
  private let events: FlutterEventChannel
  private let player = MPMusicPlayerController.systemMusicPlayer
  private var sink: FlutterEventSink?
  private var observers: [NSObjectProtocol] = []
  private var generating = false
  private var foregroundObserver: NSObjectProtocol?

  init(messenger: FlutterBinaryMessenger) {
    method = FlutterMethodChannel(name: "adi2/media", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "adi2/media/events", binaryMessenger: messenger)
    super.init()
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.refresh() }
    events.setStreamHandler(self)
    method.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(false); return }
      switch call.method {
      case "hasAccess": result(self.hasAccess)
      case "restricted": result(false)
      case "openAccessSettings":
        if MPMediaLibrary.authorizationStatus() == .notDetermined {
          MPMediaLibrary.requestAuthorization { [weak self] _ in
            DispatchQueue.main.async { self?.refresh(); result(nil) }
          }
        } else { self.openSettings(); result(nil) }
      case "openAppDetails": self.openSettings(); result(nil)
      case "openPlayer":
        UIApplication.shared.open(URL(string: "music://")!, options: [:]) { result($0) }
      case "refresh": self.refresh(); result(nil)
      case "command":
        guard self.hasAccess else { result(false); return }
        switch call.arguments as? String {
        case "play": self.player.play()
        case "pause": self.player.pause()
        case "toggle":
          if self.player.playbackState == .playing { self.player.pause() }
          else { self.player.play() }
        case "next": self.player.skipToNextItem()
        case "previous": self.player.skipToPreviousItem()
        case "stop": self.player.stop()
        default: result(false); return
        }
        self.emit(); result(true)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private var hasAccess: Bool { MPMediaLibrary.authorizationStatus() == .authorized }

  private func openSettings() {
    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:])
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    refresh()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    detach()
    return nil
  }

  private func refresh() {
    guard sink != nil else { return }
    if hasAccess && !generating {
      generating = true
      let center = NotificationCenter.default
      for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
                   Notification.Name.MPMusicPlayerControllerPlaybackStateDidChange] {
        observers.append(center.addObserver(forName: name, object: player, queue: .main) {
          [weak self] _ in self?.emit()
        })
      }
      player.beginGeneratingPlaybackNotifications()
    } else if !hasAccess { detach() }
    emit()
  }

  private func emit() {
    guard let sink = sink else { return }
    guard hasAccess else { sink(["access": false]); return }
    guard let item = player.nowPlayingItem else { sink(["access": true]); return }
    var info: [String: Any] = ["access": true, "app": "Music",
      "playing": player.playbackState == .playing]
    info["title"] = item.title
    info["artist"] = item.artist
    if let image = item.artwork?.image(at: CGSize(width: 160, height: 160)) {
      // Render at scale 1: Retina scale must not turn 160 points into 480 px.
      let format = UIGraphicsImageRendererFormat(); format.scale = 1
      let size = CGSize(width: 160, height: 160)
      let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
      }
      for quality in [CGFloat(0.8), 0.6, 0.4, 0.2] {
        if let data = thumbnail.jpegData(compressionQuality: quality), data.count <= 30 * 1024 {
          info["art"] = FlutterStandardTypedData(bytes: data); break
        }
      }
    }
    sink(info)
  }

  private func detach() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    if generating { player.endGeneratingPlaybackNotifications() }
    generating = false
  }

  deinit {
    detach()
    if let observer = foregroundObserver { NotificationCenter.default.removeObserver(observer) }
  }
}
