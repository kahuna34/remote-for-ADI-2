import AVFoundation
import Flutter
import MediaPlayer
import UIKit

/// Public outputVolume observation; the phone's volume is restored after a step.
final class VolumeKeys: NSObject {
  private let channel: FlutterMethodChannel
  private let session = AVAudioSession.sharedInstance()
  private let analyzerUsesSession: () -> Bool
  private var observation: NSKeyValueObservation?
  private var backgroundObserver: NSObjectProtocol?
  private var routeObserver: NSObjectProtocol?
  /// Nach einem Wechsel des Audio-Ausgangs (z. B. Bluetooth) stellt iOS eine
  /// andere Lautstärke ein. Das ist kein Tastendruck und wird ignoriert.
  private var ignoreUntil = Date.distantPast
  /// Zuletzt gemeldete Systemlautstärke. Die Richtung eines Tastendrucks
  /// ergibt sich nur aus der Änderung gegenüber diesem Wert.
  private var lastSeen: Float = 0

  /// Ausgangswert mit Abstand zu den Anschlägen, sonst meldet iOS am Rand
  /// keine Tastendrücke mehr.
  private func baselineFor(_ volume: Float) -> Float { min(max(volume, 0.2), 0.8) }
  private var volumeView: MPVolumeView?
  private weak var slider: UISlider?
  private var enabled = false
  private var resetting = false
  private var originalVolume: Float = 0
  private var baseline: Float = 0
  private var previousCategory: AVAudioSession.Category?
  private var previousMode: AVAudioSession.Mode?
  private var previousOptions: AVAudioSession.CategoryOptions?

  init(messenger: FlutterBinaryMessenger, analyzerUsesSession: @escaping () -> Bool) {
    channel = FlutterMethodChannel(name: "adi2/volume_keys", binaryMessenger: messenger)
    self.analyzerUsesSession = analyzerUsesSession
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      if call.method == "setEnabled" {
        self.setEnabled(call.arguments as? Bool == true)
        result(nil)
      } else { result(FlutterMethodNotImplemented) }
    }
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.setEnabled(false) }
    routeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.routeChanged() }
  }

  /// iPhone hängt per USB am ADI-2: iOS hat dort keine eigene Lautstärke, und
  /// eine eigene Audio-Sitzung stört die USB-Verbindung. Dann nichts tun.
  private var usbRoute: Bool {
    session.currentRoute.outputs.contains {
      $0.portType == .usbAudio || $0.portName.localizedCaseInsensitiveContains("ADI-2")
        || $0.portName.localizedCaseInsensitiveContains("RME")
    }
  }

  private func routeChanged() {
    guard enabled else { return }
    if usbRoute { setEnabled(false); return }
    ignoreUntil = Date().addingTimeInterval(1.0)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      guard let self = self, self.enabled else { return }
      // Neuer Ausgang: seine Lautstärke ist der Wert, der später zurückkommt.
      self.originalVolume = self.session.outputVolume
      self.baseline = self.baselineFor(self.originalVolume)
      self.setSystemVolume(self.baseline)
    }
  }

  private func setEnabled(_ value: Bool) {
    if !value {
      guard enabled else { return }
      enabled = false
      observation = nil
      setSystemVolume(originalVolume)
      volumeView?.removeFromSuperview()
      volumeView = nil; slider = nil
      yieldSession()
      return
    }
    guard !enabled, UIApplication.shared.applicationState == .active else { return }
    if usbRoute { return }
    guard let window = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow }) else { return }
    // Zuerst die Audio-Sitzung aktivieren: ohne aktive Sitzung zeigt
    // MPVolumeView nur „No Volume Available“ und hat keinen Regler.
    enabled = true
    ignoreUntil = Date().addingTimeInterval(1.0)
    resumeSession()
    let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 160, height: 40))
    view.alpha = 0.01
    view.showsRouteButton = false
    window.addSubview(view)
    volumeView = view
    originalVolume = session.outputVolume
    baseline = baselineFor(originalVolume)
    lastSeen = originalVolume
    observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
      guard let value = change.newValue else { return }
      DispatchQueue.main.async { self?.volumeChanged(value) }
    }
    // Wait until MPVolumeView is attached before touching its slider.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self = self, self.enabled else { return }
      self.setSystemVolume(self.baseline)
    }
  }

  private func volumeChanged(_ value: Float) {
    let delta = value - lastSeen
    lastSeen = value
    guard enabled, !resetting else { return }
    // Nach dem Einschalten oder einem Ausgangswechsel: nur neu ausrichten.
    guard Date() >= ignoreUntil else { return }
    // Rundung der eigenen Rücksetzung (z. B. 0,0625 → 0,05) ist kein Tastendruck.
    if abs(delta) < 0.02 { return }
    // Ein Tastendruck ändert um etwa 1/16; größere Sprünge kommen vom System
    // und dürfen nie die ADI-2-Lautstärke ändern.
    if abs(delta) <= 0.15 {
      channel.invokeMethod("step", arguments: delta > 0 ? 1 : -1)
    }
    setSystemVolume(baseline)
  }

  private func findSlider(_ view: UIView?) -> UISlider? {
    guard let view = view else { return nil }
    if let slider = view as? UISlider { return slider }
    for sub in view.subviews { if let s = findSlider(sub) { return s } }
    return nil
  }

  private func setSystemVolume(_ value: Float) {
    if slider == nil {
      volumeView?.layoutIfNeeded()
      slider = findSlider(volumeView)
    }
    resetting = true
    slider?.setValue(value, animated: false)
    slider?.sendActions(for: .valueChanged)
    if slider != nil { lastSeen = value }
    resetting = false
    // Asynchronous KVO echoes compare equal to baseline and are ignored too.
  }

  /// Analyzer calls this BEFORE snapshotting/changing its session category.
  func yieldSession() {
    guard let category = previousCategory, let mode = previousMode,
      let options = previousOptions else { return }
    try? session.setActive(false, options: .notifyOthersOnDeactivation)
    try? session.setCategory(category, mode: mode, options: options)
    previousCategory = nil; previousMode = nil; previousOptions = nil
  }

  /// Analyzer calls this AFTER restoring/releasing its session.
  func resumeSession() {
    guard enabled, !analyzerUsesSession(), previousCategory == nil else { return }
    previousCategory = session.category; previousMode = session.mode
    previousOptions = session.categoryOptions
    do {
      try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
    } catch { yieldSession() }
  }

  deinit {
    setEnabled(false)
    if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) }
    if let observer = routeObserver { NotificationCenter.default.removeObserver(observer) }
    channel.setMethodCallHandler(nil)
  }
}
