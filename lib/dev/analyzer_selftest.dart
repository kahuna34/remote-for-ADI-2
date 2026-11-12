// Temporary developer calibration tool. Remove together with the hidden entry.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../analyzer/analyzer_dsp.dart';
import '../app_settings.dart';
import '../l10n/l10n.dart';
import 'analyzer_selftest_diagnostics.dart';
import '../device/adi2_controller.dart';
import '../device/loopback.dart';
import '../protocol/adi2_codec.dart';
import '../protocol/adi2_params.dart';

typedef SelfTestValues = Map<int, int>;

/// Persistent hardware identity; a MIDI endpoint ID is only a connection token.
class SelfTestIdentity {
  const SelfTestIdentity({
    this.model,
    this.variant,
    this.serial,
    this.connection,
  });
  final int? model;
  final String? variant, serial, connection;

  static String? normalizedSerial(String? value) {
    final normalized = value?.toUpperCase().replaceAll(RegExp(r'[\s\-:]'), '');
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  factory SelfTestIdentity.fromJson(dynamic data) {
    if (data is String && data.isNotEmpty) {
      // Migrate journals written before stable hardware identities were stored.
      final slash = data.lastIndexOf('/');
      final model = slash < 0 ? null : int.tryParse(data.substring(slash + 1));
      return SelfTestIdentity(
        model: model != null && Adi2Model.fromId(model) != null ? model : null,
        connection: data,
      );
    }
    if (data is! Map ||
        data['model'] is! int ||
        Adi2Model.fromId(data['model'] as int) == null) {
      throw const FormatException('Gerätekennung fehlt oder ist ungültig');
    }
    return SelfTestIdentity(
      model: data['model'] as int,
      variant: data['variant'] as String?,
      serial: normalizedSerial(data['serial'] as String?),
    );
  }

  dynamic toJson() => model == null
      ? connection
      : {
          'model': model,
          'variant': variant,
          'serial': normalizedSerial(serial),
        };

  void check(SelfTestIdentity actual) {
    if (model == null) {
      if (connection != actual.connection) {
        throw StateError(
          'Originalgerät verbinden: Gerätekennung stimmt nicht überein',
        );
      }
      return;
    }
    if (model != actual.model) {
      throw StateError(
        'Originalgerät verbinden: Modell stimmt nicht überein (erwartet $model, empfangen ${actual.model})',
      );
    }
    if (variant != null && variant != actual.variant) {
      throw StateError(
        'Originalgerät verbinden: Variante stimmt nicht überein (erwartet $variant, empfangen ${actual.variant ?? 'noch nicht verfügbar'})',
      );
    }
    final expectedSerial = normalizedSerial(serial);
    if (expectedSerial != null &&
        expectedSerial != normalizedSerial(actual.serial)) {
      throw StateError(
        normalizedSerial(actual.serial) == null
            ? 'Seriennummer des Originalgeräts noch nicht verfügbar; erneut versuchen'
            : 'Originalgerät verbinden: Seriennummer stimmt nicht überein',
      );
    }
  }
}

abstract class SelfTestDevice {
  bool get connected;
  String get identity;
  SelfTestIdentity get recoveryIdentity =>
      SelfTestIdentity(connection: identity);
  Future<void> waitUntilReady({bool requireSerial = false}) async {
    if (!connected) {
      throw StateError('Originalgerät verbinden: keine MIDI-Verbindung');
    }
  }

  Future<void> disableAutomaticLoopback() async {}
  int defaultSource(int output) => 0;
  List<int> get outputs;
  List<int> get loopbackOutputs => outputs;
  int get usbSource;
  String sourceLabel(int output, int value) => 'Wert $value';
  bool get hasInput;
  Future<SelfTestValues> read();
  Future<void> write(SelfTestValues values);
  void acquire();
  void release();
}

/// Read only actual incoming MIDI, never optimistic controller values.
class MidiSelfTestDevice extends SelfTestDevice {
  MidiSelfTestDevice(this.ctrl);
  final Adi2Controller ctrl;
  @override
  bool get connected => ctrl.state == ConnState.connected;
  @override
  String get identity => '${ctrl.device?.id}/${ctrl.model?.id}';
  @override
  SelfTestIdentity get recoveryIdentity => SelfTestIdentity(
    model: ctrl.model?.id,
    variant: ctrl.status == null ? null : ctrl.variant?.name,
    // The supported MIDI status contains no hardware serial number.
    connection: identity,
  );

  @override
  Future<void> waitUntilReady({bool requireSerial = false}) async {
    if (!connected) {
      throw StateError('Originalgerät verbinden: keine MIDI-Verbindung');
    }
    final endpoint = ctrl.device?.id;
    final ready = Completer<void>();
    void changed() {
      if (ready.isCompleted) return;
      if (!connected || ctrl.device?.id != endpoint) {
        ready.completeError(
          StateError(
            'MIDI-Verbindung während der Geräteerkennung getrennt oder gewechselt',
          ),
        );
      } else if (ctrl.model != null &&
          ctrl.status?.raw.isNotEmpty == true &&
          ctrl.variant != null &&
          (!requireSerial ||
              SelfTestIdentity.normalizedSerial(recoveryIdentity.serial) !=
                  null)) {
        ready.complete();
      }
    }

    ctrl.addListener(changed);
    try {
      changed();
      if (!ready.isCompleted) ctrl.requestAll();
      await ready.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw StateError(
            requireSerial
                ? 'Seriennummer des Originalgeräts nicht verfügbar; Gerätezustand manuell prüfen'
                : 'Statusdaten fehlen (Modell/Variante); auf Geräteverbindung warten und erneut versuchen',
          );
        },
      );
    } finally {
      ctrl.removeListener(changed);
    }
  }

  @override
  Future<void> disableAutomaticLoopback() =>
      AppSettings.instance.setAnalyzerRouting(
        output: AppSettings.instance.analyzerLoopbackOutput,
        tap: 0,
      );

  @override
  int defaultSource(int output) {
    final options = _source(output).options!;
    final auto = options.indexOf('Auto');
    return auto >= 0 ? auto : usbSource;
  }

  @override
  List<int> get outputs => Adi2Controller.volumeAddresses;
  @override
  List<int> get loopbackOutputs => [
    for (final a in outputs)
      if (hasOwnLoopback(ctrl.variant!, a)) a,
  ];
  ParamDef _source(int output) => outputParams(
    ctrl.variant!,
    phones: output != Adi2Addr.line,
    ph34: output == Adi2Addr.ph34,
  ).firstWhere((p) => p.index == OutIdx.source);
  @override
  int get usbSource {
    final options = _source(Adi2Addr.line).options!;
    final index = options.indexWhere((o) => o == 'USB' || o == 'USB 1/2');
    if (index < 0) throw StateError('Keine feste USB-Quelle verfügbar');
    return index;
  }

  @override
  String sourceLabel(int output, int value) {
    final options = _source(output).options!;
    if (value < 0 || value >= options.length) return 'Unbekannt ($value)';
    return options[value] == 'Optical' ? 'SPDIF optical' : options[value];
  }

  @override
  bool get hasInput => ctrl.variant!.hasInput;
  @override
  void acquire() {
    if (!connected || ctrl.variant == null || ctrl.analyzerSelfTestActive) {
      throw StateError('Kein freies, verbundenes ADI-2');
    }
    if (!ctrl.volGuard.isIdle) {
      throw StateError('Lautstärkerampe zuerst beenden lassen');
    }
    ctrl.analyzerSelfTestActive = true;
  }

  @override
  void release() {
    ctrl.analyzerSelfTestActive = false;
  }

  Future<SelfTestValues> _confirmed(
    Set<int> keys, {
    SelfTestValues? expected,
  }) async {
    if (!connected) throw StateError('Gerät getrennt');
    final id = identity;
    final result = Completer<SelfTestValues>();
    final received = <int, int>{};
    final subscription = ctrl.analyzerSelfTestReadbacks.stream.listen((params) {
      if (!connected || identity != id) return;
      for (final p in params) {
        if (keys.contains(p.key) &&
            (expected == null || expected[p.key] == p.value)) {
          received[p.key] = p.value;
        } else if (keys.contains(p.key)) {
          received.remove(p.key);
        }
      }
      if (received.length == keys.length && !result.isCompleted) {
        result.complete(received);
      }
    });
    try {
      if (expected != null) {
        ctrl.setMany([
          for (final e in expected.entries)
            Adi2Param(e.key >> 8, e.key & 255, e.value),
        ]);
      }
      ctrl.requestAll();
      return await result.future.timeout(const Duration(seconds: 3));
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<SelfTestValues> read() => _confirmed({
    for (final a in outputs)
      for (final i in [
        OutIdx.mute,
        OutIdx.volume,
        OutIdx.loopback,
        OutIdx.source,
      ])
        if (i != OutIdx.loopback || loopbackOutputs.contains(a)) a << 8 | i,
  });
  @override
  Future<void> write(SelfTestValues values) async {
    if (values.isEmpty) return;
    await _confirmed(values.keys.toSet(), expected: values);
  }
}

// Only bounded diagnostic summaries may be retained or exported. In particular,
// arrays of samples, spectra, levels and response traces never enter a report.
Map<String, dynamic> _selfTestMetadata(Map data, [int depth = 0]) {
  if (depth > 5) return {};
  const scalars = {
    'sampleRate',
    'input',
    'output',
    'inputId',
    'outputId',
    'mediaStreamVolume',
    'mediaStreamMax',
    'mediaStreamMuted',
    'preFxProbeDbfs',
    'postFxProbeDbfs',
    'name',
    'type',
    'id',
    'address',
    'phoneMicrophone',
    'channels',
    'encoding',
    'audioSource',
    'bufferFrames',
    'pcmScaling',
    'communicationRouting',
    'message',
    'peakDbfs',
    'maximumDbfs',
    'rmsDbfs',
    'peakPercentile',
    'windowMs',
    'interpretation',
    'dc',
    'dominantHz',
    'binHz',
    'shape',
    'tonalPowerFraction',
    'quietStartNs',
    'quietEndNs',
    'firstToneCommandNs',
    'firstToneWrittenNs',
    'testPlaybackActive',
    'lastToneQueuedFrame',
    'measuredLatencyMs',
    'quietAfterNs',
    'drainMs',
    'outputPlaybackHeadFrame',
    'beforeFirstTestTone',
    'quietEndToFirstToneMs',
    'generatorPeakDbfs',
    'generatorRmsDbfs',
    'trackGain',
    'auxSend',
    'appVolumeShaper',
    'outputEffects',
    'availableEffects',
    'effectsQueryScope',
    'bitPerfect',
    'mixerPreferenceSet',
    'playbackMode',
    'bitPerfectVerification',
    'mixerFallbackReason',
    'mediaStreamDb',
    'sessionId',
    'routedDeviceId',
    'underrunCount',
    'preFxProbeRmsDbfs',
    'postFxProbeRmsDbfs',
    'bandDriftDb',
    'broadbandDriftDb',
    'bandSpanDb',
    'invalidReason',
    'dropout',
    'stabilityLimitDb',
    'playbackStable',
    'stable',
    'clipped',
    'settlingSeconds',
    'stableWindowSeconds',
    'measurementSeconds',
    'measurementValid',
    'volumeStable',
    'underrunDelta',
    'bandMinusBroadbandSineDb',
    'playCommandNs',
    'captureOnsetEstimateNs',
    'captureReadEndNs',
    'playbackTimestampNs',
    'playbackTimestampFrame',
    'toneFirstPlaybackFrame',
    'tonePlaybackEstimateNs',
    'commandToCaptureMs',
    'outputToCaptureEstimateMs',
  };
  const objects = {
    'diagnostics',
    'capture',
    'quiet',
    'signal',
    'timing',
    'requestedDevice',
    'routedDevice',
    'requestedFormat',
    'actualFormat',
    'hardwareFormat',
    'preFxProbeQuiet',
    'postFxProbeQuiet',
    'playback',
    'playbackBefore',
    'playbackAfter',
  };
  final result = <String, dynamic>{};
  for (final key in scalars) {
    if (!data.containsKey(key)) continue;
    final value = data[key];
    if (value == null || value is bool || (value is num && value.isFinite)) {
      result[key] = value;
    } else if (value is String) {
      result[key] = value.length > 512 ? value.substring(0, 512) : value;
    }
  }
  for (final key in objects) {
    if (data[key] is Map) {
      result[key] = _selfTestMetadata(data[key] as Map, depth + 1);
    }
  }
  final channels = data['channels'];
  if (channels is List) {
    result['channels'] = [
      for (final channel in channels.take(2))
        if (channel is Map) _selfTestMetadata(channel, depth + 1),
    ];
  }
  return result;
}

class SelfTestAudio {
  static const channel = MethodChannel('adi2/analyzer_selftest');
  static const writeLimit = 1000000, readLimit = 2000000;
  String? lastResultNotice;
  Future<Map<String, dynamic>> prepare() async => Map<String, dynamic>.from(
    (await channel.invokeMapMethod<String, dynamic>('prepare'))!,
  );
  Future<Map<String, dynamic>> tone(
    AnalyzerBandResolution resolution,
    int index,
  ) async => Map<String, dynamic>.from(
    (await channel.invokeMapMethod<String, dynamic>('tone', {
      'bandsPerOctave': resolution.bandsPerOctave,
      'index': index,
    }))!,
  );
  Future<bool> permission() async {
    const capture = MethodChannel('adi2/analyzer');
    if (await capture.invokeMethod<bool>('permission') == true) return true;
    return await capture.invokeMethod<bool>('requestPermission') == true;
  }

  Future<void> stop() => channel.invokeMethod<void>('stop');
  Future<String> save(String name, Map<String, dynamic> data) async {
    final json = jsonEncode(data);
    final limit = name == 'analyzer_selftest_recovery.json'
        ? 64000
        : writeLimit;
    if (json.length >= limit || utf8.encode(json).length >= limit) {
      throw const FormatException('Selbsttest-Datei zu groß zum Speichern');
    }
    return (await channel.invokeMethod<String>('save', {
      'name': name,
      'json': json,
    }))!;
  }

  Map<String, dynamic> _decode(String text, int limit) {
    if (text.length > limit || utf8.encode(text).length > limit) {
      throw const FormatException('Selbsttest-Datei zu groß, verworfen');
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>?> recovery() async {
    final text = await channel.invokeMethod<String>('recovery');
    return text == null ? null : _decode(text, 64000);
  }

  Future<SelfTestLastResult?> lastResult() async {
    lastResultNotice = null;
    final data = await channel.invokeMapMethod<String, dynamic>('lastResult');
    lastResultNotice = data?['notice'] as String?;
    if (data == null || data['json'] == null) return null;
    return SelfTestLastResult(
      _decode(data['json'] as String, readLimit),
      data['path'] as String,
    );
  }

  Future<void> clearRecovery() => channel.invokeMethod<void>('clearRecovery');
}

/// Same conservative bandwidth/period rule as AnalyzerToneMeasurement in Kotlin.
double selfTestSettling(AnalyzerBandResolution resolution, int index) => [
  .8,
  (resolution.centre(index) < 40 ? 40 : 20) / resolution.centre(index),
  6 /
      (resolution.centre(index) *
          (math.pow(10, .3 / resolution.bandsPerOctave) - 1)),
].reduce(math.max);

double selfTestWindow(AnalyzerBandResolution resolution, int index) => math.max(
  .4,
  (resolution.centre(index) < 40 ? 40 : 20) / resolution.centre(index),
);

class SelfTestBandResult {
  SelfTestBandResult(
    this.resolution,
    this.index,
    Map<String, dynamic> measurement, {
    this.bitPerfect = true,
  }) {
    quietBeforeTone = measurement['quietBeforeTone'] is Map
        ? _selfTestMetadata(measurement['quietBeforeTone'] as Map)
        : null;
    final levels = (measurement['levels'] as List).cast<num>();
    if (levels.length != resolution.count || levels.any((v) => !v.isFinite)) {
      throw StateError('Ungültige Analyzer-Messung');
    }
    db = levels[index].toDouble();
    neighbours = [
      if (index > 0) levels[index - 1].toDouble(),
      if (index + 1 < levels.length) levels[index + 1].toDouble(),
    ];
    details = _selfTestMetadata(measurement);
    final rms = measurement['broadbandRmsDbfs'];
    if (rms != null) {
      if (rms is! List ||
          rms.length != 2 ||
          rms.any((v) => v is! num || !v.isFinite)) {
        throw StateError('Ungültiger Breitband-RMS');
      }
      broadbandRmsDbfs = rms.cast<num>().map((v) => v.toDouble()).toList();
    }
    final peaks = measurement['broadbandPeakDbfs'];
    if (peaks != null) {
      if (peaks is! List ||
          peaks.length != 2 ||
          peaks.any((v) => v is! num || !v.isFinite)) {
        throw StateError('Ungültiger Breitband-Peak');
      }
      details['broadbandPeakDbfs'] = peaks.cast<num>().toList();
    }
    final trace = (measurement['trace'] as List).cast<Map>();
    // Require >=50 ms continuously above final-3 dB; a short overshoot is
    // not a settled response. Time remains the first frame of that run.
    double? runStart;
    double? previous;
    for (final point in trace) {
      final seconds = (point['seconds'] as num).toDouble();
      final value = (point['db'] as num).toDouble();
      if (!seconds.isFinite || !value.isFinite || seconds <= (previous ?? 0)) {
        throw StateError('Ungültige Reaktionszeit-Messung');
      }
      if (value < db - 3 || (previous != null && seconds - previous > .025)) {
        runStart = null;
      }
      if (value >= db - 3) runStart ??= seconds;
      if (runStart != null && seconds - runStart >= .05 - 1e-6) {
        responseMs = runStart * 1000;
        break;
      }
      previous = seconds;
    }
  }
  final AnalyzerBandResolution resolution;
  final int index;
  bool bitPerfect;
  late final Map<String, dynamic>? quietBeforeTone;
  late final double db;
  late final List<double> neighbours;
  num? responseMs;
  List<double>? broadbandRmsDbfs;
  late final Map<String, dynamic> details;
  String get broadbandText => broadbandRmsDbfs == null
      ? ''
      : 'Breitband-RMS L/R ${broadbandRmsDbfs!.map((v) => v.toStringAsFixed(2)).join(' / ')} dBFS';
  bool get measurementValid =>
      details['measurementValid'] != false &&
      details['stable'] != false &&
      details['volumeStable'] != false &&
      details['clipped'] != true &&
      details['dropout'] != true &&
      details['playbackStable'] != false &&
      (details['underrunDelta'] as num? ?? 0) == 0;
  String get invalidReason =>
      (details['invalidReason'] as String?)?.isNotEmpty == true
      ? details['invalidReason'] as String
      : 'Stabilität / Clipping / Wiedergabe prüfen';
  double get absoluteDeviationDb => db + 20;
  // The analyzer combines channels by maximum power; use the same RMS channel.
  double? get relativeExpectedDbfs => broadbandRmsDbfs == null
      ? null
      : broadbandRmsDbfs!.reduce(math.max) + 10 * math.log(2) / math.ln10;
  double? get relativeDeviationDb =>
      relativeExpectedDbfs == null ? null : db - relativeExpectedDbfs!;
  bool get absoluteLevelOk => absoluteDeviationDb.abs() <= 1;
  bool get relativeLevelOk =>
      relativeDeviationDb != null && relativeDeviationDb!.abs() <= 1;
  bool get levelOk => bitPerfect ? absoluteLevelOk : relativeLevelOk;
  String get evaluationBasis => bitPerfect ? 'absolute' : 'relative';
  String get levelText =>
      '${db.toStringAsFixed(2)} dBFS; Δ absolut ${absoluteDeviationDb.toStringAsFixed(2)} dB; '
      'Δ relativ ${relativeDeviationDb?.toStringAsFixed(2) ?? '— (RMS fehlt)'} dB';
  bool get separationOk => neighbours.every((v) => db - v >= 9);
  bool get ok =>
      levelOk && separationOk && responseMs != null && measurementValid;
  Map<String, dynamic> toJson() => {
    'bandsPerOctave': resolution.bandsPerOctave,
    'index': index,
    'frequencyHz': resolution.centre(index),
    'expectedDbfs': -20,
    ...details,
    if (broadbandRmsDbfs != null) 'broadbandRmsDbfs': broadbandRmsDbfs,
    'measurementValid': measurementValid,
    'measuredDbfs': db,
    'deviationDb': absoluteDeviationDb,
    'relativeExpectedDbfs': relativeExpectedDbfs,
    'relativeDeviationDb': relativeDeviationDb,
    'absoluteLevelOk': absoluteLevelOk,
    'relativeLevelOk': relativeLevelOk,
    'evaluationBasis': evaluationBasis,
    'neighbourDbfs': neighbours,
    'responseMsFromCapturedOnset': responseMs,
    'levelOk': levelOk,
    'separationOk': separationOk,
    'ok': ok,
    'neighbourAttenuationDb': neighbours.map((v) => db - v).toList(),
  };
}

/// A historical report is display-only; recovery remains the sole safety journal.
class SelfTestLastResult {
  SelfTestLastResult(this.report, this.path) {
    if (report['schema'] != 2 ||
        DateTime.tryParse(report['started'] as String? ?? '') == null ||
        report['grade'] is! String ||
        report['summary'] is! List ||
        report['bands'] is! List) {
      throw const FormatException('Ungültiger Selbsttest-Bericht');
    }
    // Validate the display data before exposing a partially readable report.
    text;
  }
  final Map<String, dynamic> report;
  final String path;

  String get text {
    final date = DateTime.parse(report['started'] as String).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final timestamp =
        '${two(date.day)}.${two(date.month)}.${date.year} '
        '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
    final summary = (report['summary'] as List).cast<Map>();
    final deviations = (report['bands'] as List).cast<Map>().where(
      (r) => r['ok'] != true,
    );
    final metadata = report['metadata'];
    final diagnostics = metadata is Map ? metadata['diagnostics'] : null;
    final capture = diagnostics is Map
        ? diagnostics['capture'] ?? diagnostics
        : null;
    final routed = capture is Map ? capture['routedDevice'] : null;
    final format = capture is Map ? capture['actualFormat'] : null;
    String number(dynamic value) =>
        value is num ? value.toStringAsFixed(1) : '—';
    final encoding = format is Map
        ? switch (format['encoding']) {
            2 => 'PCM16',
            4 => 'PCM_FLOAT',
            final value => 'PCM $value',
          }
        : '—';
    return [
      'Letzter Test: $timestamp',
      'Status: ${report['grade']} · Wiederhergestellt: ${report['restored'] == true ? 'ja' : 'nein'}',
      if (report['playbackText'] is String) report['playbackText'] as String,
      if (report['captureCalibration'] == 'uncalibrated')
        tr('USB-Messwerte unkalibriert (Analyzer-Offset nicht angewendet)'),
      if (report['evaluationBasis'] is String)
        'Pegelbewertung: ${report['evaluationBasis'] == 'absolute' ? 'absolut (−20 dBFS)' : 'relativ (Breitband-RMS + 3,01 dB)'}',
      'Oktave   OK   Abw. Offen',
      for (final row in summary)
        '${'1/${row['bandsPerOctave']}'.padRight(8)}'
            '${(row['ok'] as int).toString().padLeft(3)}'
            '${(row['deviations'] as int).toString().padLeft(6)}'
            '${((row['expected'] as int) - (row['ok'] as int) - (row['deviations'] as int)).toString().padLeft(6)}',
      if (deviations.isEmpty) 'Abweichungen: keine gemessen',
      for (final band in deviations)
        '1/${band['bandsPerOctave']} ${number(band['frequencyHz'])} Hz: '
            '${number(band['measuredDbfs'])} dBFS, Δ absolut ${number(band['deviationDb'])} dB; '
            '${band.containsKey('relativeDeviationDb') ? 'Δ relativ ${number(band['relativeDeviationDb'])} dB; ' : ''}'
            'Nachb. ${(band['neighbourDbfs'] as List).map(number).join('/')} dBFS; '
            '${number(band['responseMsFromCapturedOnset'])} ms'
            '${band['broadbandRmsDbfs'] is List ? '; Breitband-RMS L/R ${(band['broadbandRmsDbfs'] as List).map(number).join('/')} dBFS' : ''}'
            '${band['measurementValid'] == false ? '; Messfenster ungültig (${band['invalidReason'] ?? 'Grund nicht aufgezeichnet'})' : ''}',
      for (final band in (report['bands'] as List).cast<Map>().where(
        (b) => b['ok'] == true && b['broadbandRmsDbfs'] is List,
      ))
        '1/${band['bandsPerOctave']} ${number(band['frequencyHz'])} Hz: OK; '
            '${band.containsKey('relativeDeviationDb') ? '${number(band['measuredDbfs'])} dBFS; Δ absolut ${number(band['deviationDb'])} dB; Δ relativ ${number(band['relativeDeviationDb'])} dB; ' : ''}'
            'Breitband-RMS L/R ${(band['broadbandRmsDbfs'] as List).map(number).join('/')} dBFS',
      'Diagnose: ${routed is Map ? routed['name'] : 'Route nicht gemeldet'}'
          '${format is Map ? ' · ${format['sampleRate']} Hz / ${format['channels']} Kanäle / $encoding' : ''}',
      if (metadata is Map && metadata['playback'] is Map)
        'Ausgangseffekte: ${(metadata['playback'] as Map)['outputEffects'] ?? 'unbekannt'}'
            '${(metadata['playback'] as Map)['availableEffects'] is String ? '; verfügbar (Aktivierung unbekannt): ${(metadata['playback'] as Map)['availableEffects']}' : ''}',
      if (report['tap'] != null)
        'Signalweg: ${(report['tap'] as String).startsWith('post FX') ? 'post FX / −100 dB' : 'pre FX / alle Ausgänge stumm'}',
      for (final warning in (report['warnings'] as List? ?? [])) '$warning',
      if (report['error'] != null) '${report['error']}',
      if (report['restoreError'] != null)
        'Wiederherstellung: ${report['restoreError']}',
    ].join('\n');
  }
}

class AnalyzerSelfTest extends ChangeNotifier {
  AnalyzerSelfTest(
    this.device,
    this.audio, {
    this.silence = const Duration(milliseconds: 500),
  });
  final SelfTestDevice device;
  final SelfTestAudio audio;
  final Duration silence;
  final results = <SelfTestBandResult>[];
  bool running = false, cancelled = false, fallback = false, restored = true;
  bool _leased = false, _disposed = false;
  String status = 'Bereit', path = '';
  String? error, restoreError;
  SelfTestValues? _snapshot;
  String? _identity;
  SelfTestIdentity? _recoveryIdentity;
  bool _recoveryPresent = false;
  bool get canResetTestState => !_recoveryPresent && _snapshot == null;
  String? _reportName;
  Future<void>? _operation;
  Map<String, dynamic> metadata = {};
  DateTime? started;
  SelfTestLastResult? lastResult;
  String? lastResultError;

  Future<void> loadLastResult() async {
    if (running) return;
    try {
      final saved = await audio.lastResult();
      if (_disposed || running) return;
      lastResult = saved;
      lastResultError = audio.lastResultNotice;
    } catch (e) {
      if (_disposed || running) return;
      lastResultError = 'Letztes Ergebnis nicht lesbar: $e';
    }
    _notify();
  }

  int get total => AnalyzerBandResolution.values.fold(0, (n, r) => n + r.count);
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _check() {
    if (cancelled) throw StateError('Abgebrochen');
    if (!device.connected || device.identity != _identity) {
      throw StateError('Gerät getrennt oder gewechselt');
    }
  }

  bool get bitPerfect =>
      metadata['playback'] is Map &&
      (metadata['playback'] as Map)['bitPerfect'] == true;
  String get playbackText =>
      'Wiedergabe: ${bitPerfect ? 'bit-perfect' : 'normal + Effekte'}';

  SelfTestBandResult _evaluate(
    AnalyzerBandResolution resolution,
    int index,
    Map<String, dynamic> measurement,
  ) {
    if (bitPerfect &&
        ['playbackBefore', 'playbackAfter'].any(
          (key) =>
              measurement[key] is! Map ||
              (measurement[key] as Map)['bitPerfect'] != true,
        )) {
      metadata['playback'] = {
        ...metadata['playback'] as Map,
        'bitPerfect': false,
        'playbackMode': 'normal + Effekte',
        'mixerFallbackReason':
            'Bit-Perfect während der Messung nicht durchgehend bestätigt',
        'outputEffects':
            'System-/Herstellereffekte möglich; Aktivierung unbekannt',
      };
      for (final result in results) {
        result.bitPerfect = false;
      }
    }
    return SelfTestBandResult(
      resolution,
      index,
      measurement,
      bitPerfect: bitPerfect,
    );
  }

  List<String> get warnings => [
    if (!bitPerfect) 'System-Klangeffekte können die Messung verfälschen',
    if (!bitPerfect &&
        metadata['playback'] is Map &&
        (metadata['playback'] as Map)['mixerFallbackReason'] is String)
      (metadata['playback'] as Map)['mixerFallbackReason'] as String,
    if (!bitPerfect &&
        metadata['mediaStreamVolume'] != null &&
        metadata['mediaStreamVolume'] != metadata['mediaStreamMax'])
      'Android-Medienlautstärke ${metadata['mediaStreamVolume']}/${metadata['mediaStreamMax']}: kann den digitalen Testpegel absenken.',
    if (!bitPerfect && metadata['mediaStreamMuted'] == true)
      'Android-Medienausgabe ist stummgeschaltet.',
    if (fallback) 'post FX: Geräteeffekte können den Testpegel verändern.',
  ];
  Map<String, dynamic> get report => {
    'schema': 2,
    'started': started?.toUtc().toIso8601String(),
    'device': _identity,
    'expectedDbfs': -20,
    'captureCalibration': 'uncalibrated',
    'toleranceDb': 1,
    'windowRule': 'after max(0.8 s, 20 periods, 6/bandwidth); below 40 Hz 40 periods; window >=0.4 s and >=20 periods (below 40 Hz 40); band span and band/RMS half drift <0.5 dB; no clipping/dropout/underrun or playback change',
    'minimumNeighbourAttenuationDb': 9,
    'bitPerfect': bitPerfect,
    'playbackText': playbackText,
    'evaluationBasis': bitPerfect ? 'absolute' : 'relative',
    'relativeReference':
        'max(channel broadband RMS) + 10*log10(2) dB, per tone',
    'responseReference': 'first captured sample >= -60 dBFS; final band -3 dB sustained 50 ms; 60 Hz quantization; capture timestamps estimated from read completion',
    'tap': fallback
        ? 'post FX, volume -100 dB, selected output unmuted'
        : 'pre FX, all outputs muted',
    'metadata': _selfTestMetadata(metadata),
    'diagnosticText': diagnosticText,
    'warnings': warnings,
    'cancelled': cancelled,
    'error': error,
    'restored': restored,
    'restoreError': restoreError,
    'grade': !restored
        ? 'Wiederherstellung ausstehend'
        : cancelled
        ? 'Abgebrochen'
        : error != null || results.length != total
        ? 'Unvollständig'
        : results.every((r) => r.ok)
        ? (fallback ? 'OK (post FX)' : 'OK')
        : 'Abweichung',
    'summary': [
      for (final resolution in AnalyzerBandResolution.values)
        {
          'bandsPerOctave': resolution.bandsPerOctave,
          'expected': resolution.count,
          'ok': results.where((r) => r.resolution == resolution && r.ok).length,
          'deviations': results
              .where((r) => r.resolution == resolution && !r.ok)
              .length,
        },
    ],
    'bands': results.map((r) => r.toJson()).toList(),
  };
  String get diagnosticText => metadata['diagnostics'] is Map
      ? analyzerDiagnosticText(metadata['diagnostics'] as Map)
      : '';
  String get text =>
      '${tr('USB-Messwerte unkalibriert (Analyzer-Offset nicht angewendet)')}\n'
      'Analyzer-Selbsttest: ${report['grade']}\n$playbackText\nPegelbewertung: ${bitPerfect ? 'absolut' : 'relativ (Breitband-RMS + 3,01 dB)'}\n${fallback ? 'post FX / -100 dB' : 'pre FX / alle Ausgänge stumm'}\n'
      '${results.where((r) => r.ok).length}/${results.length} OK, $total Bänder erwartet\n'
      '$diagnosticText\n${warnings.join('\n')}\nWiederhergestellt: $restored\n${error ?? ''}\n${restoreError ?? ''}\n'
      '${results.map((r) => '1/${r.resolution.bandsPerOctave}: ${r.resolution.centre(r.index).toStringAsFixed(2)} Hz: ${r.ok ? 'OK' : 'Abweichung'}; ${r.levelText}; Nachbarn ${r.neighbours.map((v) => v.toStringAsFixed(2)).join('/')} dBFS; ${r.responseMs?.toStringAsFixed(1) ?? '—'} ms; ${r.broadbandText}${r.measurementValid ? '' : '; Messfenster ungültig (${r.invalidReason})'}').join('\n')}';
  String get csv =>
      'bands_per_octave,frequency_hz,expected_dbfs,measured_dbfs,deviation_db,response_ms,broadband_rms_l_dbfs,broadband_rms_r_dbfs,measurement_valid,lower_neighbour_dbfs,upper_neighbour_dbfs,level_ok,separation_ok,ok,relative_expected_dbfs,relative_deviation_db,absolute_level_ok,relative_level_ok,evaluation_basis,invalid_reason\n${results.map((r) => '${r.resolution.bandsPerOctave},${r.resolution.centre(r.index)},-20,${r.db},${r.db + 20},${r.responseMs ?? ''},${r.broadbandRmsDbfs?[0] ?? ''},${r.broadbandRmsDbfs?[1] ?? ''},${r.measurementValid},${r.index > 0 ? r.neighbours.first : ''},${r.index + 1 < r.resolution.count ? r.neighbours.last : ''},${r.levelOk},${r.separationOk},${r.ok},${r.relativeExpectedDbfs ?? ''},${r.relativeDeviationDb ?? ''},${r.absoluteLevelOk},${r.relativeLevelOk},${r.evaluationBasis},"${(r.details['invalidReason'] as String? ?? '').replaceAll('"', '""')}"').join('\n')}\n';

  Future<void> run(int output) {
    if (running || !restored) {
      return Future.error(StateError('Test oder Wiederherstellung läuft'));
    }
    return _operation = _run(output);
  }

  Future<void> _run(int output) async {
    running = true;
    cancelled = false;
    fallback = false;
    error = null;
    restoreError = null;
    results.clear();
    path = '';
    started = DateTime.now();
    metadata = {};
    status = 'Gerätezustand sichern';
    _notify();
    try {
      device.acquire();
      _leased = true;
      await device.waitUntilReady();
      _identity = device.identity;
      _recoveryIdentity = device.recoveryIdentity;
      _snapshot = await device.read();
      _check();
      if (!device.loopbackOutputs.contains(output)) {
        throw StateError('Ungültiger Ausgang');
      }
      await audio.save('analyzer_selftest_recovery.json', {
        'device': _recoveryIdentity!.toJson(),
        'values': {for (final e in _snapshot!.entries) '${e.key}': e.value},
      });
      _check();
      _recoveryPresent = true;
      restored = false;
      // Muting is confirmed by incoming MIDI before any audio can start.
      await device.write({
        for (final a in device.outputs) a << 8 | OutIdx.mute: 1,
      });
      _check();
      await device.write({
        for (final a in device.loopbackOutputs) a << 8 | OutIdx.loopback: 0,
        output << 8 | OutIdx.source: device.usbSource,
      });
      _check();
      await device.write({
        output << 8 | OutIdx.loopback: encodeLoopback(
          tap: 1,
          pair: 0,
          hasInput: device.hasInput,
        ),
      });
      _check();
      status = 'USB-Aufnahme und Wiedergabe starten';
      _notify();
      metadata = _selfTestMetadata(await audio.prepare());
      _check();
      // A 1 kHz probe checks whether pre FX survives Mute, before the full sweep.
      final probeIndex = 16; // exact 1 kHz in the third-octave grid
      try {
        final probe = _evaluate(
          AnalyzerBandResolution.third,
          probeIndex,
          await audio.tone(AnalyzerBandResolution.third, probeIndex),
        );
        if (probe.db < -60) throw PlatformException(code: 'noSignal');
        metadata['preFxProbeDbfs'] = probe.db;
        metadata['preFxProbeRmsDbfs'] = probe.broadbandRmsDbfs?.reduce(
          math.max,
        );
        metadata['preFxProbeQuiet'] = probe.quietBeforeTone;
      } on PlatformException catch (e) {
        if (e.code != 'noSignal') rethrow;
        _check();
        await audio.stop();
        _check();
        fallback = true;
        status = 'Fallback: post FX, Ausgang -100 dB, übrige Ausgänge stumm';
        _notify();
        await device.write({
          output << 8 | OutIdx.volume: math.min(
            -1000,
            _snapshot![output << 8 | OutIdx.volume]!,
          ),
        });
        _check();
        await device.write({
          output << 8 | OutIdx.loopback: encodeLoopback(
            tap: 2,
            pair: 0,
            hasInput: device.hasInput,
          ),
        });
        _check();
        await device.write({output << 8 | OutIdx.mute: 0});
        _check();
        metadata = _selfTestMetadata(await audio.prepare());
        _check();
        final probe = _evaluate(
          AnalyzerBandResolution.third,
          probeIndex,
          await audio.tone(AnalyzerBandResolution.third, probeIndex),
        );
        metadata['postFxProbeDbfs'] = probe.db;
        metadata['postFxProbeRmsDbfs'] = probe.broadbandRmsDbfs?.reduce(
          math.max,
        );
        metadata['postFxProbeQuiet'] = probe.quietBeforeTone;
        if (!probe.levelOk) {
          throw StateError(
            bitPerfect
                ? 'post FX liefert keinen kalibrierbaren -20-dBFS-Testpegel'
                : 'post FX liefert keinen relativ zum Breitband-RMS kalibrierbaren Testpegel',
          );
        }
      }
      for (final resolution in AnalyzerBandResolution.values) {
        for (var i = 0; i < resolution.count; i++) {
          _check();
          status =
              '${results.length + 1}/$total: 1/${resolution.bandsPerOctave}, ${resolution.centre(i).toStringAsFixed(2)} Hz';
          _notify();
          await Future<void>.delayed(silence);
          _check();
          final measurement = await audio.tone(resolution, i);
          _check();
          if (measurement['sampleRate'] != metadata['sampleRate']) {
            throw StateError('Abtastrate geändert');
          }
          results.add(_evaluate(resolution, i, measurement));
          _notify();
        }
      }
    } catch (e) {
      error = await _errorMessage(e, output);
    } finally {
      status = 'Wiedergabe stoppen und Gerätezustand wiederherstellen';
      _notify();
      if (_leased) await _restore();
      _reportName =
          'analyzer_selftest_${started!.toUtc().toIso8601String().replaceAll(RegExp('[^0-9]'), '')}.json';
      await _saveReport();
      running = false;
      status = report['grade'] as String;
      _notify();
    }
  }

  Future<String> _errorMessage(Object error, int output) async {
    if (error is! PlatformException) {
      return error is StateError ? error.message.toString() : error.toString();
    }
    final failureDetails = error.details;
    if (failureDetails is Map && failureDetails['diagnostics'] is Map) {
      metadata['diagnostics'] = _selfTestMetadata(
        failureDetails['diagnostics'] as Map,
      );
    }
    if (error.code == 'routeMismatch') {
      final capture = (metadata['diagnostics'] as Map?)?['capture'];
      final routed = capture is Map ? capture['routedDevice'] : null;
      final name = routed is Map ? routed['name'] : 'unbekanntes Gerät';
      return 'Aufnahme läuft über $name statt über den ADI-2. USB-Verbindung prüfen und erneut versuchen.';
    }
    if (error.code == 'signalBusy') {
      final details = error.details;
      String level(String key) {
        final value = details is Map ? details[key] : null;
        return value is num && value.isFinite
            ? value.toStringAsFixed(1).replaceAll('-', '−')
            : 'unbekannt';
      }

      var source = 'unbekannt';
      if (device.connected && device.identity == _identity) {
        try {
          final values = await device.read();
          final value = values[output << 8 | OutIdx.source];
          if (value != null) source = device.sourceLabel(output, value);
        } catch (_) {
          // Restoration still runs if a fresh source readback fails.
        }
      }
      return 'Loopback-Pegel vor dem Test: ${level('peakDbfs')} dBFS Peak, '
          '${level('rmsDbfs')} dBFS RMS – Quelle des Ausgangs: $source. '
          'Der Loopback ist nicht ruhig genug (Peak < −60 dBFS und RMS < −70 dBFS). '
          'Andere Audiowiedergabe beenden und die Ausgangsquelle prüfen.';
    }
    return switch (error.code) {
      'noSignal' => 'Kein stabiles Loopback-Signal erkannt. USB-Verbindung und Loopback prüfen.',
      'cancelled' => 'Test abgebrochen.',
      'busy' => 'Audio ist noch nicht bereit. Den Test erneut starten.',
      _ => error.message ?? 'Selbsttest fehlgeschlagen (${error.code}).',
    };
  }

  Future<void> cancel() async {
    if (!running) return;
    cancelled = true;
    status = 'Abbruch: Wiederherstellung läuft';
    _notify();
    try {
      await audio.stop();
    } catch (_) {
      /* _restore retries the stop barrier */
    }
    await _operation;
  }

  Future<void> _saveReport() async {
    if (_reportName == null) return;
    try {
      final data = report;
      path = await audio.save(_reportName!, data);
      lastResult = SelfTestLastResult(data, path);
      lastResultError = null;
    } catch (e) {
      error = '${error ?? ''}\nJSON-Speichern fehlgeschlagen: $e';
    }
  }

  Future<void> _restore() async {
    try {
      // Stop our playback even when the original device is currently absent.
      if (_leased) await audio.stop();
      if (!restored && _snapshot == null) {
        throw StateError(
          'Keine gültige Sicherung; Gerätezustand manuell prüfen',
        );
      }
      if (!restored && _snapshot != null) {
        status = 'Auf Statusdaten des Originalgeräts warten';
        _notify();
        await device.waitUntilReady(
          requireSerial:
              SelfTestIdentity.normalizedSerial(_recoveryIdentity?.serial) !=
              null,
        );
        _recoveryIdentity!.check(device.recoveryIdentity);
        _identity = device.identity;
        if (!_leased) {
          device.acquire();
          _leased = true;
        }
        // Never restore an audible volume until native playback has stopped.
        await audio.stop();
        _checkRestoreDevice();
        await device.write({
          for (final a in device.outputs) a << 8 | OutIdx.mute: 1,
        });
        _checkRestoreDevice();
        await device.write({
          for (final e in _snapshot!.entries)
            if ((e.key & 255) != OutIdx.mute) e.key: e.value,
        });
        // Volume increases may clear Mute in hardware: original Mutes go last.
        _checkRestoreDevice();
        await device.write({
          for (final e in _snapshot!.entries)
            if ((e.key & 255) == OutIdx.mute) e.key: e.value,
        });
        _checkRestoreDevice();
        final actual = await device.read();
        _checkRestoreDevice();
        if (_snapshot!.entries.any((e) => actual[e.key] != e.value)) {
          throw StateError(
            'Geräterücklesung stimmt nicht mit Sicherung überein',
          );
        }
      }
      if (restored) await audio.stop();
      await audio.clearRecovery();
      _recoveryPresent = false;
      _snapshot = null;
      restored = true;
      restoreError = null;
      if (_leased) {
        device.release();
        _leased = false;
      }
    } catch (e) {
      restoreError = e is StateError ? e.message.toString() : e.toString();
    }
  }

  void _checkRestoreDevice() {
    if (!device.connected || device.identity != _identity) {
      throw StateError(
        'Originalgerät während der Wiederherstellung getrennt oder gewechselt',
      );
    }
    _recoveryIdentity!.check(device.recoveryIdentity);
  }

  Future<void> retryRestore() {
    if (running) return Future.value();
    return _operation = _retryRestore();
  }

  Future<void> _retryRestore() async {
    if (running) return;
    running = true;
    _notify();
    await _restore();
    await _saveReport();
    running = false;
    status = restored ? 'Wiederhergestellt' : 'Wiederherstellung ausstehend';
    _notify();
  }

  Future<void> loadRecovery() async {
    try {
      final data = await audio.recovery();
      if (data == null) return;
      _recoveryPresent = true;
      _recoveryIdentity = SelfTestIdentity.fromJson(data['device']);
      final snapshot = (data['values'] as Map).map(
        (k, v) => MapEntry(int.parse(k as String), v as int),
      );
      final expected = {
        for (final a in device.outputs)
          for (final i in [
            OutIdx.mute,
            OutIdx.volume,
            OutIdx.source,
            OutIdx.loopback,
          ])
            if (i != OutIdx.loopback || device.loopbackOutputs.contains(a))
              a << 8 | i,
      };
      if (snapshot.length != expected.length ||
          !snapshot.keys.every(expected.contains)) {
        throw const FormatException('Unvollständige Sicherung');
      }
      for (final entry in snapshot.entries) {
        final valid = switch (entry.key & 255) {
          OutIdx.mute => entry.value >= 0 && entry.value <= 1,
          OutIdx.volume => entry.value >= -1145 && entry.value <= 60,
          OutIdx.source => entry.value >= 0 && entry.value <= 6,
          OutIdx.loopback => entry.value >= 0 && entry.value <= 9,
          _ => false,
        };
        if (!valid) {
          throw const FormatException('Ungültiger Parameter in Sicherung');
        }
      }
      _snapshot = snapshot;
      restored = false;
      status = 'Wiederherstellung eines unterbrochenen Tests erforderlich';
      _notify();
    } catch (e) {
      _snapshot = null;
      _recoveryPresent = true;
      error = 'Wiederherstellungsdatei nicht lesbar: $e';
      restored = false;
      _notify();
    }
  }

  /// Emergency routing reset without a journal: never change Mute or volume.
  Future<void> resetTestState() {
    if (running || !canResetTestState) return Future.value();
    return _operation = _resetTestState();
  }

  Future<void> _resetTestState() async {
    running = true;
    status = 'Testzustand aufheben';
    _notify();
    try {
      // Recheck disk before writing: reports are never a substitute for a journal.
      if (await audio.recovery() != null) {
        _recoveryPresent = true;
        restored = false;
        await loadRecovery();
        throw StateError(
          'Wiederherstellungsdatei vorhanden; Wiederherstellung erneut starten',
        );
      }
      await device.waitUntilReady();
      device.acquire();
      _leased = true;
      _identity = device.identity;
      _recoveryIdentity = device.recoveryIdentity;
      await audio.stop();
      _checkRestoreDevice();
      // Prevent normal analyzer routing from re-enabling loopback on the next status.
      await device.disableAutomaticLoopback();
      _checkRestoreDevice();
      final defaults = <int, int>{
        for (final a in device.loopbackOutputs) a << 8 | OutIdx.loopback: 0,
        for (final a in device.outputs)
          a << 8 | OutIdx.source: device.defaultSource(a),
      };
      await device.write(defaults);
      _checkRestoreDevice();
      final actual = await device.read();
      _checkRestoreDevice();
      if (defaults.entries.any((e) => actual[e.key] != e.value)) {
        throw StateError('Quelle/Loopback vom Gerät nicht bestätigt');
      }
      status = 'Testzustand aufgehoben. Mute am Gerät prüfen';
      error = null;
    } catch (e) {
      error = e is StateError ? e.message.toString() : e.toString();
      status = 'Testzustand nicht aufgehoben. Mute am Gerät prüfen';
    } finally {
      if (_leased) {
        device.release();
        _leased = false;
      }
      running = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
