import AVFoundation
import Flutter

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
      default: result(FlutterMethodNotImplemented)
      }
    }
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
      self?.stop(); self?.sink?(["status": "captureFailed"])
    })
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self = self, self.engine != nil else { return }
      if !self.validRoute() { self.stop(); self.sink?(["status": "usbUnavailable"]) }
    })
  }
  private func isAdi(_ input: AVAudioSessionPortDescription) -> Bool {
    input.portType == .usbAudio && (input.portName.localizedCaseInsensitiveContains("ADI-2") || input.portName.localizedCaseInsensitiveContains("RME"))
  }
  private func validRoute() -> Bool { session.currentRoute.inputs.contains(where: isAdi) }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events; return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stop(); sink = nil; return nil
  }
  private func start() {
    stop()
    guard session.recordPermission == .granted else { sink?(["status": "permissionDenied"]); return }
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
        stop(); sink?(["status": "usbUnavailable"]); return
      }
      try session.setPreferredInput(usb)
      let audioEngine = AVAudioEngine()
      let input = audioEngine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard validRoute(), format.channelCount >= 2, format.sampleRate > 0 else {
        stop(); sink?(["status": "usbUnavailable"]); return
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
          self.sink?(["pcm": pcm, "sampleRate": Int(format.sampleRate), "device": name])
        }
      }
      engine = audioEngine
      audioEngine.prepare()
      try audioEngine.start()
    } catch { stop(); sink?(["status": "captureFailed"]) }
  }
  func stop() {
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
  }
  deinit {
    stop()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }
}
