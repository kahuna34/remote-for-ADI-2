import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';

import 'analyzer_dsp.dart';
import 'analyzer_calibration.dart';
import '../dev/analyzer_selftest_diagnostics.dart';
import '../app_settings.dart';
import '../host/host_client.dart';
import '../host/host_analyzer_protocol.dart';

enum AnalyzerStatus {
  idle,
  starting,
  permissionRequired,
  usbUnavailable,
  captureFailed,
  running,
  silent,
}

class AnalyzerController extends ChangeNotifier {
  AnalyzerController({HostClient? host}) : _host = host, _requestedHost = host {
    _hostReady = host?.connected == true && host?.analyzerAvailable == true;
    _host?.addListener(_hostChanged);
    AppSettings.instance.addListener(_settingsChanged);
    analyzerDeveloperMode.addListener(_diagnosticsChanged);
    _applyBallistics(AppSettings.instance.analyzerBallistics);
    _applyPeakHoldDuration();
  }
  HostClient? _host, _requestedHost;
  bool _hostReady = false, _hostSuspended = false;
  bool get viaHost => _host != null;
  String? get hostPlatform => _host?.analyzerPlatform;

  Future<void> setHostSource(HostClient? host) {
    if (_disposed) return _operations;
    if (identical(_requestedHost, host)) return _operations;
    _requestedHost = host;
    // Source changes are capture barriers: stop the old source before assigning
    // the new one. Never leave a direct USB recording alive behind a host view.
    _operations = _operations.then((_) async {
      await _stop();
      if (_disposed) return;
      _host?.removeListener(_hostChanged);
      _host = host;
      _hostReady = host?.connected == true && host?.analyzerAvailable == true;
      _hostSuspended = false;
      host?.addListener(_hostChanged);
      await _reconcile();
    });
    return _operations;
  }

  void _hostChanged() {
    if (_disposed) return;
    final host = _host;
    if (host == null) return;
    if (host.reconnecting) {
      _hostSuspended = true;
      _cancelHostDisplay();
      _frameAge.reset();
      _calibrationGeneration++;
      return;
    }
    final ready = host.connected && host.analyzerAvailable;
    final changed = ready != _hostReady;
    _hostReady = ready;
    if (_hostSuspended) {
      _hostSuspended = false;
      if (_running && _desired && ready) {
        _hostMetadata = {};
        _frameAge.reset();
        host.send('analyzer_start', _hostRequest);
        return;
      }
      unawaited(retry());
    } else if (changed) {
      unawaited(retry());
    }
  }

  void _hostEvent(Map<String, dynamic> data) {
    if (_disposed || !_desired || !_running || _host?.reconnecting == true) {
      return;
    }
    if (data['type'] == 'analyzer_error') {
      _event({'status': data['code']});
      return;
    }
    if (data['type'] == 'analyzer_metadata') {
      _hostMetadata = Map.of(data);
      return;
    }
    try {
      var next = decodeHostAnalyzerFrame({..._hostMetadata, ...data});
      final pending = _pendingHostEvent;
      if (data['v'] == 2 &&
          pending != null &&
          pending['device'] == _hostMetadata['device'] &&
          mapEquals(
            pending['calibrationIdentity'] as Map?,
            _hostMetadata['calibrationIdentity'] as Map?,
          )) {
        next = coalesceAnalyzerFrames(
          pending['hostFrame'] as AnalyzerFrame,
          next,
        );
      }
      // Reuse route/identity handling, then the same _accept path as native.
      final event = <String, dynamic>{
        'hostFrame': next,
        'routeVerified': true,
        'device': data['v'] == 2 ? _hostMetadata['device'] : data['device'],
        'calibrationIdentity': data['v'] == 2
            ? _hostMetadata['calibrationIdentity']
            : data['calibrationIdentity'],
      };
      if (data['v'] == 2) {
        // One latest frame, 20 ms playout delay. Never accumulate a WLAN backlog.
        _pendingHostEvent = event;
        _hostPlayout ??= Timer(const Duration(milliseconds: 20), () {
          _hostPlayout = null;
          final pending = _pendingHostEvent;
          _pendingHostEvent = null;
          if (pending != null) _event(pending);
        });
      } else {
        _event(event);
      }
    } on FormatException {
      _event({'status': 'analyzer_no_input'});
    }
  }

  Map<String, dynamic> _hostMetadata = {};
  Map<String, dynamic>? _pendingHostEvent;
  Timer? _hostPlayout;
  int? _displayCallback;
  Duration? _displayTime;
  Duration _displayUntil = Duration.zero;
  bool _displayFresh = false;

  void _cancelHostDisplay() {
    _hostPlayout?.cancel();
    _hostPlayout = null;
    _pendingHostEvent = null;
    if (_displayCallback != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(_displayCallback!);
    }
    _displayCallback = null;
    _displayTime = null;
  }

  void _animateHost() {
    if (_displayCallback != null) return;
    _displayCallback = SchedulerBinding.instance.scheduleFrameCallback((time) {
      _displayCallback = null;
      if (_disposed || !_running || rawFrame == null || inputRejected) return;
      if (_displayFresh) {
        _displayUntil = time + const Duration(milliseconds: 80);
        _displayFresh = false;
      }
      final dt = _displayTime == null
          ? 1 / 60
          : ((time - _displayTime!).inMicroseconds / 1e6).clamp(0.0, .04);
      _displayTime = time;
      _updateAnalysis(rawFrame!, seconds: dt, smoothMeters: true);
      _notify();
      // Keep rendering between arrivals; a stalled stream stops scheduling.
      if (time < _displayUntil) _animateHost();
    });
  }

  Map<String, dynamic> get _hostRequest => {
    'bandResolution': bandResolution.bandsPerOctave,
    if ((_host?.analyzerVersion ?? 0) >= 2) ...{
      'analyzerVersion': 2,
      'bars': bars,
    },
  };

  AnalyzerBandResolution _bandResolution =
      AppSettings.instance.analyzerBandResolution;
  AnalyzerBandResolution get bandResolution => _bandResolution;

  void _applyPeakHoldDuration() {
    final seconds = AppSettings.instance.analyzerPeakHoldSeconds;
    for (final envelope in [spectrum, bassSpectrum, bands]) {
      envelope.holdSeconds = seconds == 0
          ? double.infinity
          : seconds.toDouble();
    }
  }

  void _settingsChanged() {
    _applyPeakHoldDuration();
    final next = AppSettings.instance.analyzerBandResolution;
    final offset = AppSettings.instance.analyzerCalibration(
      calibrationIdentity?.key,
    );
    final offsetChanged = offset != calibrationOffset;
    if (next == _bandResolution && !offsetChanged) return;
    final bandsChanged = next != _bandResolution;
    _bandResolution = next;
    calibrationOffset = offset;
    if (offsetChanged) {
      spectrum.reset();
      bassSpectrum.reset();
    }
    bands.reset();
    if (_pcmDsp != null) _pcmDsp!.bandResolution = next;
    if (_running && bandsChanged) unawaited(_configureBands(next));
    if (rawFrame case final f?) {
      if (offsetChanged) {
        _updateAnalysis(f);
      } else {
        bands.update(
          (f.logSpectrum
                  ? (f.bandResolution == next ? f.bandLevels : <double>[])
                  : octaveBandDb(f, next))
              .map((v) => v + calibrationOffset)
              .toList(),
          f.seconds,
        );
      }
    }
    _notify();
  }

  Future<void> setBandResolution(AnalyzerBandResolution value) =>
      AppSettings.instance.setAnalyzerBandResolution(value);

  Future<void> _configureBands(AnalyzerBandResolution next) async {
    if (_host case final host?) {
      if (host.reconnecting || !host.connected) return;
      host.send('analyzer_start', _hostRequest);
      return;
    }
    try {
      await _method.invokeMethod<void>('setBandResolution', {
        'bandsPerOctave': next.bandsPerOctave,
      });
    } on PlatformException {
      /* Older embedding keeps reference FFT fallback. */
    } on MissingPluginException {
      /* Reference PCM path configures locally. */
    }
  }

  Future<void> _diagnosticsChanged() async {
    if (_running && !viaHost) {
      try {
        await _method.invokeMethod<void>('setDiagnostics', {
          'enabled': analyzerDeveloperMode.value,
        });
      } on PlatformException {
        // Older platform implementation has no developer diagnostics.
      } on MissingPluginException {
        // iOS has no Android routing diagnostics.
      }
    }
    _notify();
  }

  static const _method = MethodChannel('adi2/analyzer');
  static const _events = EventChannel('adi2/analyzer/events');
  StreamSubscription<dynamic>? _subscription;
  Future<void> _operations = Future.value();
  bool _desired = false, _running = false, _disposed = false;
  Timer? _watchdog;
  final _frameAge = Stopwatch();
  double _silence = 0;
  int? _rate;
  AnalyzerDsp? _pcmDsp;
  AnalyzerStatus status = AnalyzerStatus.idle;
  AnalyzerFrame? frame;
  AnalyzerFrame? rawFrame;
  AnalyzerCalibrationIdentity? calibrationIdentity;
  double calibrationOffset = 0;
  int? mediaVolume, mediaVolumeMax;
  List<String> availableEffects = const [];
  bool get mediaVolumeBelowMaximum =>
      mediaVolume != null &&
      mediaVolumeMax != null &&
      mediaVolumeMax! > 0 &&
      mediaVolume! < mediaVolumeMax!;
  int _calibrationGeneration = 0;
  AnalyzerCalibrationMeasurement? _measurement;
  bool get canCalibrate =>
      !_disposed &&
      _desired &&
      _running &&
      calibrationIdentity != null &&
      rawFrame != null &&
      _frameAge.isRunning &&
      _frameAge.elapsed.inSeconds < 1 &&
      (status == AnalyzerStatus.running || status == AnalyzerStatus.silent);

  bool _toneRunning = false;

  /// With [useTestTone] the app plays the tone itself. [toneAllowed] is polled
  /// while it runs; the tone is stopped as soon as it returns false.
  Future<AnalyzerCalibrationProposal> measureCalibration({
    bool useTestTone = false,
    bool Function()? toneAllowed,
  }) async {
    if ((useTestTone && viaHost) ||
        !canCalibrate ||
        _measurement != null ||
        _toneRunning) {
      throw AnalyzerCalibrationError.unavailable;
    }
    final key = calibrationIdentity!.key;
    final generation = _calibrationGeneration;
    void guard() {
      if (!canCalibrate || generation != _calibrationGeneration) {
        throw AnalyzerCalibrationError.unavailable;
      }
      if (useTestTone && toneAllowed?.call() != true) {
        throw AnalyzerCalibrationError.toneInterrupted;
      }
    }

    Future<void> hold(int milliseconds) async {
      if (!useTestTone) {
        await Future<void>.delayed(Duration(milliseconds: milliseconds));
        return;
      }
      for (var waited = 0; waited < milliseconds; waited += 50) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        guard();
      }
    }

    _toneRunning = useTestTone;
    try {
      if (useTestTone) {
        guard();
        try {
          await _method.invokeMethod<void>('startCalibrationTone');
        } on PlatformException {
          throw AnalyzerCalibrationError.toneUnavailable;
        } on MissingPluginException {
          throw AnalyzerCalibrationError.toneUnavailable;
        }
        await hold(500);
      }
      final measurement = AnalyzerCalibrationMeasurement();
      _measurement = measurement;
      await hold(viaHost ? 3000 : 2000);
      if (!canCalibrate || generation != _calibrationGeneration) {
        throw AnalyzerCalibrationError.unavailable;
      }
      return AnalyzerCalibrationProposal(key, generation, measurement.finish());
    } finally {
      _measurement = null;
      if (useTestTone) {
        _toneRunning = false;
        try {
          await _method.invokeMethod<void>('stopCalibrationTone');
        } on PlatformException {
          /* Native stop is idempotent; the buffer also ends by itself. */
        } on MissingPluginException {
          /* Unsupported embedding. */
        }
      }
    }
  }

  Future<void> saveCalibration(AnalyzerCalibrationProposal proposal) {
    if (!canCalibrate ||
        proposal.key != calibrationIdentity?.key ||
        proposal.generation != _calibrationGeneration) {
      throw AnalyzerCalibrationError.unavailable;
    }
    return AppSettings.instance.setAnalyzerCalibration(
      proposal.key,
      proposal.offset,
    );
  }

  AnalyzerCalibrationProposal calibrationProposal(double offset) {
    if (!canCalibrate) throw AnalyzerCalibrationError.unavailable;
    return AnalyzerCalibrationProposal(
      calibrationIdentity!.key,
      _calibrationGeneration,
      (offset.clamp(-40, 40) * 10).round() / 10,
    );
  }

  void _clearCalibrationRoute() {
    _calibrationGeneration++;
    rawFrame = null;
    calibrationIdentity = null;
    mediaVolume = mediaVolumeMax = null;
    availableEffects = const [];
    calibrationOffset = 0;
  }

  String? device;
  Map<String, dynamic> diagnostics = {};
  bool inputRejected = false;
  String? inputErrorCode;
  bool get phoneMicrophone =>
      (diagnostics['routedDevice'] as Map?)?['phoneMicrophone'] == true;
  String get diagnosticText =>
      diagnostics.isEmpty ? '' : analyzerDiagnosticText(diagnostics);
  AnalyzerView view = AnalyzerView.spectrum;
  bool bars = AppSettings.instance.analyzerBars,
      peakHold = AppSettings.instance.analyzerPeakHold;
  final spectrum = AnalyzerEnvelope(),
      bassSpectrum = AnalyzerEnvelope(),
      bands = AnalyzerEnvelope();
  AnalyzerBallistics get ballistics => spectrum.ballistics;

  void _applyBallistics(AnalyzerBallistics value) {
    spectrum.ballistics = value;
    bands.ballistics = value;
    bassSpectrum.ballistics = value;
  }

  void setBallistics(AnalyzerBallistics value) {
    _applyBallistics(value);
    unawaited(AppSettings.instance.setAnalyzerBallistics(value));
    _notify();
  }

  void setView(AnalyzerView value) {
    view = value;
    _notify();
  }

  void setBars(bool value) {
    bars = value;
    if (_running &&
        _host?.connected == true &&
        _host?.reconnecting == false &&
        (_host?.analyzerVersion ?? 0) >= 2) {
      _host!.send('analyzer_start', _hostRequest);
    }
    unawaited(AppSettings.instance.setAnalyzerBars(value));
    _notify();
  }

  /// Setzt die Peak-Marken aller Darstellungen sofort zurück.
  void resetPeaks() {
    for (final envelope in [spectrum, bassSpectrum, bands]) {
      envelope.resetHeld();
    }
    _notify();
  }

  void setPeakHold(bool value) {
    peakHold = value;
    unawaited(AppSettings.instance.setAnalyzerPeakHold(value));
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  final _activeOwners = <Object>{};
  Timer? _visibilityStop;

  /// Für Anzeigen, die sich einen Controller teilen: Aufgenommen wird, solange
  /// mindestens eine von ihnen aktiv ist. Ein Layout-Umbau darf die letzte
  /// Anzeige kurz entfernen, ohne Aufnahme, Playout und Hüllkurven zu löschen.
  Future<void> setActiveFor(Object owner, bool active) {
    if (_disposed) return _operations;
    if (active) {
      _activeOwners.add(owner);
    } else {
      _activeOwners.remove(owner);
    }
    if (_activeOwners.isNotEmpty) return setActive(true);
    if (_desired) {
      _visibilityStop ??= Timer(const Duration(milliseconds: 500), () {
        _visibilityStop = null;
        if (!_disposed && _activeOwners.isEmpty) unawaited(setActive(false));
      });
    }
    return _operations;
  }

  /// Explicit capture barriers (including shutdown) remain immediate.
  Future<void> setActive(bool active) {
    _visibilityStop?.cancel();
    _visibilityStop = null;
    if (_disposed) return _operations;
    _desired = active;
    _operations = _operations.then((_) => _reconcile());
    return _operations;
  }

  Future<void> _reconcile() async {
    if (_disposed || !_desired) {
      await _stop();
      return;
    }
    if (_host?.reconnecting == true || _running) return;
    inputRejected = false;
    inputErrorCode = null;
    diagnostics = {};
    status = AnalyzerStatus.starting;
    _notify();
    try {
      final host = _host;
      if (host != null && (!host.connected || !host.analyzerAvailable)) {
        inputErrorCode = host.connected
            ? 'analyzer_unsupported'
            : 'analyzer_disconnected';
        status = AnalyzerStatus.usbUnavailable;
        _notify();
        return;
      }
      final allowed =
          host != null ||
          (await _method.invokeMethod<bool>('permission') ?? false);
      if (!_desired || _disposed) return;
      if (!allowed) {
        status = AnalyzerStatus.permissionRequired;
        _notify();
        return;
      }
      _subscription = host != null
          ? host.analyzerEvents.stream.listen(_hostEvent)
          : _events.receiveBroadcastStream().listen(
              _event,
              onError: (_) {
                _calibrationGeneration++;
                status = AnalyzerStatus.captureFailed;
                _notify();
              },
              onDone: () {
                _calibrationGeneration++;
                status = AnalyzerStatus.captureFailed;
                _notify();
              },
            );
      _running = true;
      _frameAge
        ..reset()
        ..start();
      _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_host?.reconnecting == true ||
            _host?.awaitingSilenceTimeout == true) {
          _frameAge.reset();
          return;
        }
        if ((status == AnalyzerStatus.starting ||
                status == AnalyzerStatus.running ||
                status == AnalyzerStatus.silent) &&
            _frameAge.elapsed.inSeconds >= 4) {
          _calibrationGeneration++;
          status = AnalyzerStatus.captureFailed;
          _notify();
        }
      });
      if (host != null) {
        host.send('analyzer_start', _hostRequest);
      } else {
        await _method.invokeMethod<void>('start', {
          'bandsPerOctave': bandResolution.bandsPerOctave,
          if (analyzerDeveloperMode.value) 'diagnostics': true,
        });
      }
      if (!_desired || _disposed) await _stop();
    } on PlatformException {
      await _failed();
    } on MissingPluginException {
      await _failed();
    }
  }

  Future<void> _failed() async {
    await _stop();
    status = AnalyzerStatus.usbUnavailable;
    _notify();
  }

  Future<void> requestPermission() async {
    if (viaHost) {
      await retry();
      return;
    }
    try {
      await _method.invokeMethod<bool>('requestPermission');
    } on PlatformException {
      /* State is refreshed below. */
    } on MissingPluginException {
      status = AnalyzerStatus.usbUnavailable;
      _notify();
      return;
    }
    await retry();
  }

  Future<void> retry() async {
    if (_host?.reconnecting == true) return _operations;
    _operations = _operations.then((_) async {
      await _stop();
      await _reconcile();
    });
    await _operations;
  }

  void _event(dynamic data) {
    if (_disposed || !_desired || !_running || data is! Map) return;
    if (data['diagnostics'] case final Map info) {
      diagnostics = Map<String, dynamic>.from(info);
    }
    if (data['status'] case final String code) {
      _cancelHostDisplay();
      inputRejected = true;
      inputErrorCode = code;
      device = null;
      status = switch (code) {
        'permissionDenied' ||
        'analyzer_permission' => AnalyzerStatus.permissionRequired,
        'usbUnavailable' ||
        'routeMismatch' ||
        'analyzer_no_input' => AnalyzerStatus.usbUnavailable,
        _ => AnalyzerStatus.captureFailed,
      };
      frame = null;
      _clearCalibrationRoute();
      spectrum.reset();
      bassSpectrum.reset();
      bands.reset();
      _notify();
      return;
    }
    // Native reconnect starts a fresh verified stream. Reject stale frames after
    // a failure unless they carry an explicitly verified ADI-2 route.
    if (inputRejected && data['routeVerified'] != true) return;
    inputRejected = false;
    inputErrorCode = null;
    device = data['device'] as String?;
    mediaVolume = data['mediaStreamVolume'] as int?;
    mediaVolumeMax = data['mediaStreamMax'] as int?;
    availableEffects =
        (data['availableEffects'] as List?)?.whereType<String>().toList() ??
        const [];
    final identity = AnalyzerCalibrationIdentity.fromMap(
      data['calibrationIdentity'],
    );
    if (identity?.key != calibrationIdentity?.key) {
      _calibrationGeneration++;
      calibrationIdentity = identity;
      calibrationOffset = AppSettings.instance.analyzerCalibration(
        identity?.key,
      );
      spectrum.reset();
      bassSpectrum.reset();
      bands.reset();
    }
    // iOS and macOS send continuous stereo PCM to the same DSP. Android
    // keeps its native analysis event path.
    if (data['hostFrame'] case final AnalyzerFrame f) {
      _accept(f);
    } else if (data['pcm'] case final List pcm) {
      final rate = data['sampleRate'] as int;
      if (_rate != rate) {
        _pcmDsp = AnalyzerDsp()..bandResolution = bandResolution;
      }
      _rate = rate;
      for (final f in _pcmDsp!.add(
        pcm.cast<num>().map((v) => v.toDouble()).toList(),
        rate,
      )) {
        _accept(f);
      }
    } else {
      _accept(AnalyzerFrame.fromMap(data));
    }
  }

  void _accept(AnalyzerFrame next) {
    if (frame?.sampleRate != next.sampleRate) {
      _calibrationGeneration++;
      spectrum.reset();
      bassSpectrum.reset();
      bands.reset();
    }
    rawFrame = next;
    _measurement?.add(next);
    _frameAge
      ..reset()
      ..start();
    _silence = next.peak.every((v) => v < -95) ? _silence + next.seconds : 0;
    status = _silence > 1.5 ? AnalyzerStatus.silent : AnalyzerStatus.running;
    if (viaHost && (_host?.analyzerVersion ?? 0) >= 2) {
      if (frame == null ||
          frame!.logSpectrum != next.logSpectrum ||
          spectrum.values.length != next.spectrum.length ||
          bands.values.length != next.bandLevels.length ||
          frame!.sampleRate != next.sampleRate) {
        _updateAnalysis(next, seconds: 1 / 60);
      }
      _displayFresh = true;
      _animateHost();
    } else {
      _updateAnalysis(next);
    }
    _notify();
  }

  void _updateAnalysis(
    AnalyzerFrame raw, {
    double? seconds,
    bool smoothMeters = false,
  }) {
    // Apply the same dB correction once, before every envelope and peak hold.
    // Convert spectra before adding gain to preserve FFT floor/scalloping rules.
    List<double> calibrated(List<double> db) =>
        db.map((v) => v + calibrationOffset).toList();
    final target = raw.calibrated(calibrationOffset);
    final dt = seconds ?? raw.seconds;
    final previous = frame;
    if (smoothMeters && previous != null) {
      final blend = 1 - math.exp(-dt / .02);
      List<double> mix(List<double> a, List<double> b) =>
          List.generate(2, (i) => a[i] + (b[i] - a[i]) * blend);
      frame = AnalyzerFrame(
        sampleRate: target.sampleRate,
        spectrum: target.spectrum,
        logSpectrum: target.logSpectrum,
        spectrumBinHz: target.spectrumBinHz,
        bassSpectrum: target.bassSpectrum,
        bassBinHz: target.bassBinHz,
        bandLevels: target.bandLevels,
        bandResolution: target.bandResolution,
        peak: target.peak,
        rms: target.rms,
        meterPeak: mix(previous.displayPeak, target.displayPeak),
        meterRms: mix(previous.displayRms, target.displayRms),
        clipped: target.clipped,
        seconds: target.seconds,
      );
    } else {
      frame = target;
    }
    spectrum.update(
      calibrated(
        raw.logSpectrum
            ? raw.spectrum.map(amplitudeDb).toList()
            : analyzerLineDb(raw.spectrum),
      ),
      dt,
    );
    bassSpectrum.update(calibrated(analyzerLineDb(raw.bassSpectrum)), dt);
    bands.update(
      calibrated(
        raw.logSpectrum ? raw.bandLevels : octaveBandDb(raw, bandResolution),
      ),
      dt,
    );
  }

  Future<void> _stop() async {
    _cancelHostDisplay();
    _hostMetadata = {};
    _watchdog?.cancel();
    _watchdog = null;
    _frameAge
      ..stop()
      ..reset();
    if (_running) {
      _running = false;
      try {
        if (_host case final host?) {
          host.send('analyzer_stop');
        } else {
          await _method.invokeMethod<void>('stop');
        }
      } on PlatformException {
        /* Platform already stopped. */
      } on MissingPluginException {
        /* Unsupported embedding. */
      }
    }
    // Native stop above is the capture barrier. EventChannel's broadcast
    // onCancel is void; its returned subscription future is not a native ack.
    unawaited(_subscription?.cancel());
    _subscription = null;
    _pcmDsp = null;
    _rate = null;
    _silence = 0;
    frame = null;
    _clearCalibrationRoute();
    device = null;
    diagnostics = {};
    inputRejected = false;
    inputErrorCode = null;
    spectrum.reset();
    bassSpectrum.reset();
    bands.reset();
    status = AnalyzerStatus.idle;
    _notify();
  }

  @override
  void dispose() {
    _visibilityStop?.cancel();
    _visibilityStop = null;
    _activeOwners.clear();
    _host?.removeListener(_hostChanged);
    AppSettings.instance.removeListener(_settingsChanged);
    analyzerDeveloperMode.removeListener(_diagnosticsChanged);
    _cancelHostDisplay();
    _disposed = true;
    _desired = false;
    _operations = _operations.then((_) => _stop());
    super.dispose();
  }
}
