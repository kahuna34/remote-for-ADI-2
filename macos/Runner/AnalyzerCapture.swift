import AVFoundation
import CoreAudio
import FlutterMacOS

/// USB-only capture. Neither the system default devices nor their settings are
/// changed. Only PCM is delivered to Dart; there is no monitoring or file output.
final class AnalyzerCapture: NSObject, FlutterStreamHandler {
  private let method: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var sink: FlutterEventSink?
  private var engine: AVAudioEngine?
  private var tapInstalled = false
  private var inputDevice: AudioDeviceID?
  private var inputRate: Double = 0
  private var generation = 0
  private var tone: CalibrationTone?
  private var configurationObserver: NSObjectProtocol?
  private var terminationObserver: NSObjectProtocol?
  private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

  init(messenger: FlutterBinaryMessenger) {
    method = FlutterMethodChannel(name: "adi2/analyzer", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "adi2/analyzer/events", binaryMessenger: messenger)
    super.init()
    events.setStreamHandler(self)
    method.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(false); return }
      switch call.method {
      case "permission":
        result(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
      case "requestPermission":
        AVCaptureDevice.requestAccess(for: .audio) { allowed in
          DispatchQueue.main.async { result(allowed) }
        }
      case "start": self.start(); result(nil)
      case "stop": self.stop(); result(nil)
      // Band resolution lives in Dart; Android routing diagnostics do not apply.
      case "setDiagnostics", "setBandResolution": result(nil)
      case "startCalibrationTone":
        self.stopTone()
        guard let device = self.inputDevice, self.validInput(),
              AdiAudio.channels(device, scope: kAudioDevicePropertyScopeOutput) >= 2 else {
          result(FlutterError(code: "noUsbOutput", message: "ADI-2 USB output unavailable", details: nil)); return
        }
        do {
          let playback = try CalibrationTone(device: device) { [weak self] in
            self?.fail("usbUnavailable")
          }
          self.tone = playback
          try playback.start()
          result(nil)
        } catch {
          self.stopTone()
          result(FlutterError(code: "toneFailed", message: "ADI-2 USB output unavailable", details: nil))
        }
      case "stopCalibrationTone": self.stopTone(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.stop() }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events; return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stop(); sink = nil; return nil
  }

  private func validInput() -> Bool {
    guard let device = inputDevice, let engine = engine,
          let unit = engine.inputNode.audioUnit else { return false }
    return AdiAudio.isAdi(device) && AdiAudio.currentDevice(unit) == device &&
      AdiAudio.channels(device, scope: kAudioDevicePropertyScopeInput) >= 2 &&
      engine.inputNode.outputFormat(forBus: 0).sampleRate == inputRate
  }

  private func fail(_ status: String) {
    stop(); sink?(["status": status])
  }

  private func watch(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws {
    var address = AdiAudio.address(selector)
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self = self, self.engine != nil else { return }
      if !self.validInput() || self.tone?.validRoute() == false { self.fail("usbUnavailable") }
    }
    try AdiAudio.check(AudioObjectAddPropertyListenerBlock(object, &address, .main, listener))
    deviceListeners.append((object, address, listener))
  }

  private func start() {
    stop()
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      sink?(["status": "permissionDenied"]); return
    }
    let candidates = AdiAudio.devices().filter {
      AdiAudio.isAdi($0) && AdiAudio.channels($0, scope: kAudioDevicePropertyScopeInput) >= 2
    }
    // A name alone cannot distinguish multiple ADI-2 units. Do not choose an
    // arbitrary capture/tone target while another unit may be controlled by MIDI.
    guard candidates.count == 1, let device = candidates.first else {
      sink?(["status": "usbUnavailable"]); return
    }
    do {
      let audioEngine = AVAudioEngine()
      let input = audioEngine.inputNode
      guard let unit = input.audioUnit else { fail("usbUnavailable"); return }
      var selected = device
      try AdiAudio.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                            kAudioUnitScope_Global, 0, &selected,
                                            UInt32(MemoryLayout<AudioDeviceID>.size)))
      // AVAudioEngine keeps the previous default input's client format after
      // the device changes; the hardware side already reports the ADI-2.
      var clientFormat = input.inputFormat(forBus: 0).streamDescription.pointee
      try AdiAudio.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                                            1, &clientFormat,
                                            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
      let format = input.outputFormat(forBus: 0)
      engine = audioEngine; inputDevice = device; inputRate = format.sampleRate
      guard validInput(), format.channelCount >= 2, format.sampleRate >= 44100,
            format.commonFormat == .pcmFormatFloat32 else { fail("usbUnavailable"); return }
      let token = generation
      let name = AdiAudio.string(device, kAudioObjectPropertyName) ?? "ADI-2"
      let identity = AdiAudio.identity(device, name: name)
      // Preserve continuous IIR state. A UI stall over 250 ms is an explicit
      // failure, never a splice of disconnected pieces of audio.
      let gate = NSLock()
      var queued = [Double]()
      var pending = false
      var overflow = false
      let maxQueuedSamples = Int(format.sampleRate / 4) * 2
      input.installTap(onBus: 0, bufferSize: AVAudioFrameCount((format.sampleRate / 60).rounded()),
                       format: format) { [weak self] buffer, _ in
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
          overflow = true; queued.removeAll(keepingCapacity: true)
        } else if !overflow { queued.append(contentsOf: stereo) }
        if pending { gate.unlock(); return }
        pending = true; gate.unlock()
        DispatchQueue.main.async { [weak self] in
          gate.lock()
          let pcm = queued; let failed = overflow
          queued = []; pending = false
          gate.unlock()
          guard let self = self, self.generation == token else { return }
          guard self.validInput() else { self.fail("usbUnavailable"); return }
          if failed { self.fail("captureFailed"); return }
          self.sink?(["pcm": pcm, "sampleRate": Int(format.sampleRate), "device": name,
                      "calibrationIdentity": identity, "routeVerified": true])
        }
      }
      tapInstalled = true
      // No connections from input to a mixer or output: capture only.
      audioEngine.prepare()
      try audioEngine.start()
      guard validInput() else { fail("usbUnavailable"); return }
      try watch(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
      try watch(device, kAudioDevicePropertyDeviceIsAlive)
      try watch(device, kAudioDevicePropertyNominalSampleRate)
      configurationObserver = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
      ) { [weak self] _ in
        guard let self = self, self.generation == token, self.engine != nil else { return }
        guard self.validInput() else { self.fail("usbUnavailable"); return }
        // Selecting the ADI-2 and its format also reports a change: the same
        // device and format may simply continue.
        if audioEngine.isRunning { return }
        do { try audioEngine.start() } catch { self.fail("captureFailed") }
      }
    } catch { fail("captureFailed") }
  }

  private func stopTone() { tone?.stop(); tone = nil }

  func stop() {
    generation += 1
    stopTone()
    if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
    configurationObserver = nil
    for (object, var address, listener) in deviceListeners {
      AudioObjectRemovePropertyListenerBlock(object, &address, .main, listener)
    }
    deviceListeners.removeAll()
    if let engine = engine {
      if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
      engine.stop()
    }
    tapInstalled = false
    engine = nil; inputDevice = nil; inputRate = 0
  }

  deinit {
    stop()
    if let observer = terminationObserver { NotificationCenter.default.removeObserver(observer) }
  }
}

private enum AdiAudio {
  static func address(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }
  static func check(_ status: OSStatus) throws {
    if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
  }
  static func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var property = address(selector), value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr ? value : nil
  }
  static func sampleRate(_ device: AudioDeviceID) -> Double? {
    var property = address(kAudioDevicePropertyNominalSampleRate)
    var rate: Double = 0, size = UInt32(MemoryLayout<Double>.size)
    return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &rate) == noErr ? rate : nil
  }
  static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var property = address(selector)
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
    let text = value as String
    return text.isEmpty ? nil : text
  }
  static func devices() -> [AudioDeviceID] {
    var property = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr, size > 0 else { return [] }
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    let status = devices.withUnsafeMutableBytes {
      AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, $0.baseAddress!)
    }
    return status == noErr ? devices : []
  }
  static func channels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32 {
    var property = address(kAudioDevicePropertyStreamConfiguration, scope: scope), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { storage.deallocate() }
    guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, storage) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
      .reduce(0) { $0 + $1.mNumberChannels }
  }
  static func isAdi(_ device: AudioDeviceID) -> Bool {
    uint(device, kAudioDevicePropertyDeviceIsAlive) == 1 &&
      uint(device, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeUSB &&
      string(device, kAudioObjectPropertyName)?.localizedCaseInsensitiveContains("ADI-2") == true
  }
  static func currentDevice(_ unit: AudioUnit) -> AudioDeviceID? {
    var device: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
    return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                0, &device, &size) == noErr ? device : nil
  }
  static func identity(_ device: AudioDeviceID, name: String) -> [String: Any] {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: max(1, size))
    _ = model.withUnsafeMutableBufferPointer { sysctlbyname("hw.model", $0.baseAddress, &size, nil, 0) }
    var result: [String: Any] = [
      "hostManufacturer": "macOS", "hostModel": "\(String(cString: model)) · \(ProcessInfo.processInfo.hostName)",
      "usbName": name
    ]
    if let serial = string(device, kAudioObjectPropertySerialNumber) { result["usbSerial"] = serial }
    return result
  }
}

/// A device-bound HAL unit never follows the default output. A fixed buffer
/// ends even if Dart/main is blocked. Every render verifies the selected device
/// before returning any audible samples, including after the 250 ms lead-in.
private final class CalibrationTone {
  private var unit: AudioUnit?
  private let device: AudioDeviceID
  private let sampleRate: Double
  private let pcm: [Float]
  private var position = 0 // Only the render thread writes this.
  private var interrupted = false // Latched by render; no recovery/fallback.
  private let onRouteFailure: () -> Void
  private var expiry: DispatchWorkItem?

  init(device: AudioDeviceID, onRouteFailure: @escaping () -> Void) throws {
    self.device = device; self.onRouteFailure = onRouteFailure
    var property = AdiAudio.address(kAudioDevicePropertyNominalSampleRate)
    var rate: Double = 0, size = UInt32(MemoryLayout<Double>.size)
    try AdiAudio.check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &rate))
    guard (44100...192000).contains(rate) else { throw NSError(domain: "AnalyzerTone", code: 1) }
    sampleRate = rate
    let lead = Int(rate * 0.25), fade = Int(rate * 0.02), total = Int(rate * 3.6)
    pcm = (0..<total).map { frame in
      guard frame >= lead else { return 0 }
      let gain = min(1, Double(frame - lead) / Double(fade), Double(total - 1 - frame) / Double(fade))
      return Float(gain * sin(2 * .pi * 1000 * Double(frame - lead) / rate))
    }
    var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0, componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &description) else { throw NSError(domain: "AnalyzerTone", code: 2) }
    var created: AudioUnit?
    try AdiAudio.check(AudioComponentInstanceNew(component, &created))
    unit = created
    do {
      guard let unit = unit else { throw NSError(domain: "AnalyzerTone", code: 3) }
      var enabled: UInt32 = 1, disabled: UInt32 = 0, selected = device
      try AdiAudio.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                                            0, &enabled, UInt32(MemoryLayout<UInt32>.size)))
      try AdiAudio.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                                            1, &disabled, UInt32(MemoryLayout<UInt32>.size)))
      try AdiAudio.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                            0, &selected, UInt32(MemoryLayout<AudioDeviceID>.size)))
      var format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
        mBitsPerChannel: 32, mReserved: 0)
      try AdiAudio.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                                            0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
      var channelMap = [Int32](repeating: -1, count: Int(AdiAudio.channels(device, scope: kAudioDevicePropertyScopeOutput)))
      guard channelMap.count >= 2 else { throw NSError(domain: "AnalyzerTone", code: 6) }
      channelMap[0] = 0; channelMap[1] = 1
      try channelMap.withUnsafeMutableBytes { bytes in
        try AdiAudio.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Input,
                                              0, bytes.baseAddress!, UInt32(bytes.count)))
      }
      var callback = AURenderCallbackStruct(inputProc: { context, _, _, _, frames, data in
        guard let data = data else { return noErr }
        let playback = Unmanaged<CalibrationTone>.fromOpaque(context).takeUnretainedValue()
        playback.render(frames: Int(frames), data: data)
        return noErr
      }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
      try AdiAudio.check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                                            0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
      try AdiAudio.check(AudioUnitInitialize(unit))
      guard validRoute() else { throw NSError(domain: "AnalyzerTone", code: 4) }
    } catch { stop(); throw error }
  }

  func validRoute() -> Bool {
    guard let unit = unit else { return false }
    return AdiAudio.currentDevice(unit) == device && AdiAudio.isAdi(device) &&
      AdiAudio.sampleRate(device) == sampleRate
  }
  func start() throws {
    guard let unit = unit, validRoute() else { throw NSError(domain: "AnalyzerTone", code: 5) }
    try AdiAudio.check(AudioOutputUnitStart(unit))
    let work = DispatchWorkItem { [weak self] in self?.stop() }
    expiry = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.6, execute: work)
  }
  private func render(frames: Int, data: UnsafeMutablePointer<AudioBufferList>) {
    let routeOK = validRoute()
    if !routeOK && !interrupted {
      interrupted = true
      DispatchQueue.main.async { [weak self] in self?.onRouteFailure() }
    }
    for buffer in UnsafeMutableAudioBufferListPointer(data) {
      guard let bytes = buffer.mData else { continue }
      let samples = bytes.assumingMemoryBound(to: Float.self)
      let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
      for i in 0..<count {
        let index = position + i
        samples[i] = !interrupted && routeOK && index < pcm.count ? pcm[index] : 0
      }
    }
    position = min(pcm.count, position + frames)
  }
  func stop() {
    expiry?.cancel(); expiry = nil
    if let unit = unit {
      AudioOutputUnitStop(unit)
      AudioUnitUninitialize(unit)
      AudioComponentInstanceDispose(unit)
    }
    unit = nil
  }
  deinit { stop() }
}
