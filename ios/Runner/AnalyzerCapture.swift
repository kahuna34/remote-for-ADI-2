import AVFoundation
import Flutter
import MediaPlayer
import UIKit

/// iOS groundwork: USB-only input, mixed session, no file or speaker monitoring.
/// Sends continuous PCM blocks to the shared Dart DSP; Android analyzes natively.
final class AnalyzerCapture: NSObject, FlutterStreamHandler {
  private let session = AVAudioSession.sharedInstance()
  private var engine: AVAudioEngine?
  private var sink: FlutterEventSink?
  private var generation = 0
  private var previousCategory: AVAudioSession.Category?
  private var previousMode: AVAudioSession.Mode?
  private var previousOptions: AVAudioSession.CategoryOptions?
  private var previousRate: Double?
  private var previousInput: AVAudioSessionPortDescription?
  private let method: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var observers: [NSObjectProtocol] = []
  var usesSession: Bool { previousCategory != nil }
  var beforeSessionStart: (() -> Void)?
  var afterSessionStop: (() -> Void)?

  init(messenger: FlutterBinaryMessenger) {
    method = FlutterMethodChannel(name: "adi2/analyzer", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "adi2/analyzer/events", binaryMessenger: messenger)
    super.init()
    events.setStreamHandler(self)
    method.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(false); return }
      switch call.method {
      case "permission": result(self.session.recordPermission == .granted)
      case "requestPermission":
        self.session.requestRecordPermission { allowed in DispatchQueue.main.async { result(allowed) } }
      case "start": self.start(); result(nil)
      case "stop": self.stop(); result(nil)
      case "startCalibrationTone":
        if let error = self.startCalibrationTone() {
          result(FlutterError(code: error, message: "Calibration tone unavailable", details: nil))
        } else { result(nil) }
      case "stopCalibrationTone": self.stopCalibrationTone(); result(nil)
      case "setMediaVolumeMax":
        if self.setMediaVolumeMax() { result(nil) }
        else { result(FlutterError(code: "noSlider", message: nil, details: nil)) }
      default: result(FlutterMethodNotImplemented)
      }
    }
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
      self?.stop(); self?.sink?(["status": "captureFailed"])
    })
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self = self, self.engine != nil else { return }
      if !self.validRoute() { self.stop(); self.sink?(["status": "usbUnavailable"]); return }
      self.updateFixedOutputVolume()
    })
  }
  private func isAdi(_ input: AVAudioSessionPortDescription) -> Bool {
    // iOS meldet den ADI-2 je nach Version als USB-Audio oder als kabelgebundenes
    // Mikrofon (iPhone 15, iOS 27: MicrophoneWired). Entscheidend ist der Name.
    input.portType != .builtInMic &&
      (input.portName.localizedCaseInsensitiveContains("ADI-2") || input.portName.localizedCaseInsensitiveContains("RME"))
  }
  private func validRoute() -> Bool { session.currentRoute.inputs.contains(where: isAdi) }

  /// Kurze Diagnose für „USB nicht verfügbar“: was das iPhone an Eingängen sieht.
  private func routeDetail(_ reason: String, channels: AVAudioChannelCount? = nil, rate: Double? = nil) -> String {
    func port(_ p: AVAudioSessionPortDescription) -> String {
      // Seriennummer in Klammern nicht anzeigen.
      let name = p.portName.replacingOccurrences(of: #"\s*\(\d+\)"#, with: "", options: .regularExpression)
      return "\(name) [\(p.portType.rawValue), \(p.channels?.count ?? 0) ch]"
    }
    var parts = [reason]
    let available = session.availableInputs ?? []
    parts.append("inputs: " + (available.isEmpty ? "-" : available.map(port).joined(separator: "; ")))
    let route = session.currentRoute.inputs
    parts.append("route: " + (route.isEmpty ? "-" : route.map(port).joined(separator: "; ")))
    if let c = channels { parts.append("format: \(c) ch, \(Int(rate ?? 0)) Hz") }
    return parts.joined(separator: " | ")
  }

  /// Gleiche Bausteine wie Android/Host: Hersteller, Gerätemodell, USB-Name.
  /// Die Kalibrierung gilt damit nur für dieses Telefon mit diesem ADI-2-Modell.
  private func calibrationIdentity(_ usbName: String) -> [String: Any] {
    var info = utsname()
    uname(&info)
    let model = withUnsafeBytes(of: &info.machine) { raw in
      String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return ["hostManufacturer": "Apple", "hostModel": model.isEmpty ? "iPhone" : model, "usbName": usbName]
  }

  private var tonePlayer: AVAudioPlayerNode?

  /// true, wenn der aktuelle Ausgang keine Systemlautstärke hat (MPVolumeView
  /// zeigt dann nur den Gerätenamen, keinen Regler). Am ADI-2 per USB gibt
  /// iOS das Signal dort mit voller Aussteuerung aus.
  private var fixedOutputVolume = false

  private func updateFixedOutputVolume() {
    guard let window = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow }) else { return }
    let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 160, height: 40))
    view.alpha = 0.01
    window.addSubview(view)
    view.layoutIfNeeded()
    fixedOutputVolume = findSlider(view) == nil
    view.removeFromSuperview()
  }

  private func findSlider(_ v: UIView) -> UISlider? {
    if let s = v as? UISlider { return s }
    for sub in v.subviews { if let s = findSlider(sub) { return s } }
    return nil
  }

  /// Systemlautstärke über den (unsichtbaren) Regler von MPVolumeView auf 100 %.
  /// Nur auf ausdrücklichen Knopfdruck in der Kalibrierung.
  private func setMediaVolumeMax() -> Bool {
    guard let window = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow }) else { return false }
    let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 160, height: 40))
    view.alpha = 0.01
    window.addSubview(view)
    view.layoutIfNeeded()
    guard let slider = findSlider(view) else { view.removeFromSuperview(); return false }
    slider.setValue(1, animated: false)
    slider.sendActions(for: .valueChanged)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { view.removeFromSuperview() }
    return true
  }

  /// 1 kHz bei 0 dBFS wie unter Android: 0,25 s Stille, weiche Flanken, endet
  /// nach 3,6 s von selbst, auch wenn Dart nicht mehr antwortet. Nur bei
  /// laufender Aufnahme und nur über den USB-Ausgang des ADI-2.
  private func startCalibrationTone() -> String? {
    stopCalibrationTone()
    guard engine != nil else { return "busy" }
    guard session.currentRoute.outputs.contains(where: isAdi) else { return "noUsbOutput" }
    let rate = 48000.0
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return "toneFailed" }
    let total = Int(rate * 3.6), lead = Int(rate / 4), fade = Int(rate / 50)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
      let data = buffer.floatChannelData else { return "toneFailed" }
    buffer.frameLength = AVAudioFrameCount(total)
    for frame in 0..<total {
      var sample: Float = 0
      if frame >= lead {
        let gain = min(1.0, Double(frame - lead) / Double(fade), Double(total - 1 - frame) / Double(fade))
        sample = Float(gain * sin(2.0 * Double.pi * Double(frame - lead) / 48.0))
      }
      data[0][frame] = sample; data[1][frame] = sample
    }
    // Eigene Engine nur für den Ton: Ein Knoten, der an die laufende
    // Aufnahme-Engine gehängt wird, stoppt diese, und play() bricht ab.
    let toneEngine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    toneEngine.attach(player)
    toneEngine.connect(player, to: toneEngine.mainMixerNode, format: format)
    toneEngine.mainMixerNode.outputVolume = 1
    do {
      toneEngine.prepare()
      try toneEngine.start()
    } catch { return "toneFailed" }
    guard toneEngine.isRunning else { return "toneFailed" }
    tonePlayer = player
    self.toneEngine = toneEngine
    player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
      DispatchQueue.main.async { if self?.tonePlayer === player { self?.stopCalibrationTone() } }
    }
    player.play()
    return nil
  }

  private var toneEngine: AVAudioEngine?

  func stopCalibrationTone() {
    tonePlayer?.stop()
    tonePlayer = nil
    toneEngine?.stop()
    toneEngine = nil
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events; return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stop(); sink = nil; return nil
  }
  private func start() {
    stop()
    guard session.recordPermission == .granted else { sink?(["status": "permissionDenied"]); return }
    beforeSessionStart?()
    previousCategory = session.category; previousMode = session.mode
    previousOptions = session.categoryOptions; previousInput = session.preferredInput
    previousRate = session.preferredSampleRate
    do {
      try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers])
      // Preserve a running player's clock whenever it is usable.
      let rate = session.sampleRate
      try session.setPreferredSampleRate((44100...192000).contains(rate) ? rate : 48000)
      try session.setActive(true)
      guard let usb = session.availableInputs?.first(where: isAdi) else {
        let detail = routeDetail("no ADI-2 USB input")
        stop(); sink?(["status": "usbUnavailable", "detail": detail]); return
      }
      try session.setPreferredInput(usb)
      updateFixedOutputVolume()
      let audioEngine = AVAudioEngine()
      let input = audioEngine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard validRoute(), format.channelCount >= 2, format.sampleRate > 0 else {
        let detail = routeDetail(validRoute() ? "input format" : "route not on ADI-2",
                                 channels: format.channelCount, rate: format.sampleRate)
        stop(); sink?(["status": "usbUnavailable", "detail": detail]); return
      }
      let token = generation
      let name = usb.portName
      // One queued UI delivery. Never skip PCM: IIR states and elapsed time
      // require a continuous stream. Bound a blocked UI to 250 ms; report a
      // capture failure instead of silently splicing disconnected audio.
      let gate = NSLock()
      var pending = false
      var queued = [Double]()
      var overflow = false
      let maxQueuedSamples = Int(format.sampleRate / 4) * 2
      let blockFrames = AVAudioFrameCount(max(1, (format.sampleRate / 60).rounded()))
      input.installTap(onBus: 0, bufferSize: blockFrames, format: format) { [weak self] buffer, _ in
        guard buffer.format.channelCount >= 2, let channels = buffer.floatChannelData else { return }
        var stereo = [Double]()
        stereo.reserveCapacity(Int(buffer.frameLength) * 2)
        for i in 0..<Int(buffer.frameLength) {
          if buffer.format.isInterleaved {
            let stride = Int(buffer.format.channelCount)
            stereo.append(Double(channels[0][i * stride]))
            stereo.append(Double(channels[0][i * stride + 1]))
          } else {
            stereo.append(Double(channels[0][i])); stereo.append(Double(channels[1][i]))
          }
        }
        gate.lock()
        if queued.count + stereo.count > maxQueuedSamples {
          overflow = true
          queued.removeAll(keepingCapacity: true)
        } else if !overflow {
          queued.append(contentsOf: stereo)
        }
        if pending { gate.unlock(); return }
        pending = true; gate.unlock()
        DispatchQueue.main.async { [weak self] in
          gate.lock()
          let pcm = queued
          let failed = overflow
          queued = []
          pending = false
          gate.unlock()
          guard let self = self, self.generation == token else { return }
          guard self.validRoute() else { self.stop(); self.sink?(["status": "usbUnavailable"]); return }
          if failed { self.stop(); self.sink?(["status": "captureFailed"]); return }
          self.sink?(["pcm": pcm, "sampleRate": Int(format.sampleRate), "device": name,
                      "calibrationIdentity": self.calibrationIdentity(name),
                      // Systemlautstärke in Prozent; am ADI-2 per USB meist fest 100.
                      "mediaStreamVolume": self.fixedOutputVolume
                        ? 100 : Int((self.session.outputVolume * 100).rounded()),
                      "mediaStreamMax": 100])
        }
      }
      engine = audioEngine
      audioEngine.prepare()
      try audioEngine.start()
    } catch {
      let detail = routeDetail("error: \(error.localizedDescription)")
      stop(); sink?(["status": "captureFailed", "detail": detail])
    }
  }
  func stop() {
    stopCalibrationTone()
    generation += 1
    if let engine = engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
    engine = nil
    if let category = previousCategory, let mode = previousMode, let options = previousOptions {
      try? session.setPreferredInput(previousInput)
      if let rate = previousRate { try? session.setPreferredSampleRate(rate) }
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      try? session.setCategory(category, mode: mode, options: options)
    }
    previousCategory = nil; previousMode = nil; previousOptions = nil; previousInput = nil; previousRate = nil
    afterSessionStop?()
  }
  deinit {
    stop()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }
}
