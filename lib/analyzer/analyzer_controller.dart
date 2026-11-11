import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'analyzer_dsp.dart';
import 'analyzer_calibration.dart';
import '../dev/analyzer_selftest_diagnostics.dart';
import '../app_settings.dart';

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
  AnalyzerController() {
    AppSettings.instance.addListener(_settingsChanged);
    analyzerDeveloperMode.addListener(_diagnosticsChanged);
    _applyBallistics(AppSettings.instance.analyzerBallistics);
  }
  AnalyzerBandResolution _bandResolution =
      AppSettings.instance.analyzerBandResolution;
  AnalyzerBandResolution get bandResolution => _bandResolution;

  void _settingsChanged() {
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
          octaveBandDb(f, next).map((v) => v + calibrationOffset).toList(),
          f.seconds,
        );
      }
    }
    _notify();
  }

  Future<void> setBandResolution(AnalyzerBandResolution value) =>
      AppSettings.instance.setAnalyzerBandResolution(value);

  Future<void> _configureBands(AnalyzerBandResolution next) async {
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
    if (_running) {
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
    if (!canCalibrate || _measurement != null || _toneRunning) {
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
      await hold(2000);
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
    unawaited(AppSettings.instance.setAnalyzerBars(value));
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

  /// Für Anzeigen, die sich einen Controller teilen: Aufgenommen wird, solange
  /// mindestens eine von ihnen aktiv ist.
  Future<void> setActiveFor(Object owner, bool active) {
    if (active) {
      _activeOwners.add(owner);
    } else {
      _activeOwners.remove(owner);
    }
    return setActive(_activeOwners.isNotEmpty);
  }

  Future<void> setActive(bool active) {
    _desired = active;
    _operations = _operations.then((_) => _reconcile());
    return _operations;
  }

  Future<void> _reconcile() async {
    if (_disposed || !_desired) {
      await _stop();
      return;
    }
    if (_running) return;
    inputRejected = false;
    inputErrorCode = null;
    diagnostics = {};
    status = AnalyzerStatus.starting;
    _notify();
    try {
      final allowed = await _method.invokeMethod<bool>('permission') ?? false;
      if (!_desired || _disposed) return;
      if (!allowed) {
        status = AnalyzerStatus.permissionRequired;
        _notify();
        return;
      }
      _subscription = _events.receiveBroadcastStream().listen(
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
        if ((status == AnalyzerStatus.starting ||
                status == AnalyzerStatus.running ||
                status == AnalyzerStatus.silent) &&
            _frameAge.elapsed.inSeconds >= 4) {
          _calibrationGeneration++;
          status = AnalyzerStatus.captureFailed;
          _notify();
        }
      });
      await _method.invokeMethod<void>('start', {
        'bandsPerOctave': bandResolution.bandsPerOctave,
        if (analyzerDeveloperMode.value) 'diagnostics': true,
      });
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
      inputRejected = true;
      inputErrorCode = code;
      device = null;
      status = switch (code) {
        'permissionDenied' => AnalyzerStatus.permissionRequired,
        'usbUnavailable' || 'routeMismatch' => AnalyzerStatus.usbUnavailable,
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
    if (data['pcm'] case final List pcm) {
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
    _updateAnalysis(next);
    _notify();
  }

  void _updateAnalysis(AnalyzerFrame raw) {
    // Apply the same dB correction once, before every envelope and peak hold.
    // Convert spectra before adding gain to preserve FFT floor/scalloping rules.
    List<double> calibrated(List<double> db) =>
        db.map((v) => v + calibrationOffset).toList();
    frame = raw.calibrated(calibrationOffset);
    spectrum.update(calibrated(analyzerLineDb(raw.spectrum)), raw.seconds);
    bassSpectrum.update(
      calibrated(analyzerLineDb(raw.bassSpectrum)),
      raw.seconds,
    );
    bands.update(calibrated(octaveBandDb(raw, bandResolution)), raw.seconds);
  }

  Future<void> _stop() async {
    _watchdog?.cancel();
    _watchdog = null;
    _frameAge
      ..stop()
      ..reset();
    if (_running) {
      _running = false;
      try {
        await _method.invokeMethod<void>('stop');
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
    AppSettings.instance.removeListener(_settingsChanged);
    analyzerDeveloperMode.removeListener(_diagnosticsChanged);
    _disposed = true;
    _desired = false;
    _operations = _operations.then((_) => _stop());
    super.dispose();
  }
}
