import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:adi2_remote/analyzer/analyzer_calibration.dart';
import 'package:adi2_remote/analyzer/analyzer_controller.dart';
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/ui/analyzer_controls.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:adi2_remote/ui/outputs_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CalibrationDevice extends Adi2Controller {
  _CalibrationDevice() {
    state = ConnState.connected;
  }
  @override
  Adi2Variant get variant => Adi2Variant.dac;
  final values = offlineDefaults(Adi2Variant.dac);
  @override
  int? value(int address, int index) => values[address << 8 | index];
  @override
  int? confirmedValue(int address, int index) =>
      staleConfirmed[address << 8 | index] ?? value(address, index);
  @override
  int valueOr(int address, int index, int fallback) =>
      value(address, index) ?? fallback;
  bool stuckVolume = false;
  bool answers = true;
  final omittedKeys = <int>{};
  final confirmationRequests = <List<int>?>[];
  final staleConfirmed = <int, int>{};
  @override
  Future<bool> refreshConfirmedValues({List<int>? requiredKeys}) async {
    confirmationRequests.add(requiredKeys);
    return answers &&
        (requiredKeys == null ||
            requiredKeys.every((key) => !omittedKeys.contains(key)));
  }

  bool autoMuteLine = false;
  @override
  bool autoMuted(int address) => autoMuteLine && address == Adi2Addr.line;
  @override
  void setVolume(int address, int raw, {bool followLink = true}) {
    if (!stuckVolume) set(address, OutIdx.volume, raw);
  }

  @override
  void set(int address, int index, int value) {
    values[address << 8 | index] = value;
    notifyListeners();
  }
}

Map<String, Object> identity({
  String host = 'Tablet',
  String usb = 'ADI-2/4 Pro SE',
  String? serial = '123',
}) => {
  'androidManufacturer': 'Test',
  'androidModel': host,
  'usbName': usb,
  'usbVendorId': 1,
  'usbProductId': 2,
  'usbSerial': ?serial,
};

AnalyzerFrame rawFrame({
  double left = -20,
  double? right,
  double seconds = 1 / 60,
}) => AnalyzerFrame(
  sampleRate: 48000,
  spectrum: List.filled(1025, .1),
  bassSpectrum: List.filled(4097, .1),
  bassBinHz: 48000 / 8192,
  bandLevels: List.filled(30, -20),
  peak: [left, right ?? left],
  rms: [left - 3, (right ?? left) - 3],
  clipped: [false, false],
  seconds: seconds,
  meterPeak: [left - 1, (right ?? left) - 1],
  meterRms: [left - 4, (right ?? left) - 4],
);

Map<String, dynamic> capture({
  Map<String, Object>? route,
  double peak = -20,
  double? right,
  bool nativeBands = true,
}) => {
  'calibrationIdentity': route ?? identity(),
  'device': 'ADI-2/4 Pro SE',
  'sampleRate': 48000,
  'spectrum': List.filled(1025, .1),
  'bassSpectrum': List.filled(4097, .1),
  'bassBinHz': 48000 / 8192,
  if (nativeBands) 'bandLevels': List.filled(30, -20.0),
  'peak': [peak, right ?? peak],
  'rms': [peak - 3, (right ?? peak) - 3],
  'meterPeak': [peak - 1, (right ?? peak) - 1],
  'meterRms': [peak - 4, (right ?? peak) - 4],
  'clipped': [false, false],
  'seconds': 1 / 60,
  'routeVerified': true,
};

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final settings = AppSettings.instance;
  const method = MethodChannel('adi2/analyzer');
  const events = MethodChannel('adi2/analyzer/events');
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
    AppLang.instance.language = AppLanguage.de;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      method,
      (call) async => call.method == 'permission' ? true : null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      events,
      (_) async => null,
    );
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(method, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null);
  });
  Future<void> send(WidgetTester tester, Map<String, dynamic> data) async {
    await tester.runAsync(() async {
      binding.channelBuffers.push(
        'adi2/analyzer/events',
        const StandardMethodCodec().encodeSuccessEnvelope(data),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
    });
  }

  Future<void> settle(WidgetTester tester) async {
    // Platform and serialized preference futures cross the fake/real zones.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
      await tester.pumpAndSettle();
    }
  }

  Future<void> active(
    WidgetTester tester,
    AnalyzerController c,
    bool enabled,
  ) async {
    await tester.runAsync(() => c.setActive(enabled));
    await tester.pump();
  }

  Future<void> save(
    WidgetTester tester,
    AnalyzerController c,
    double offset,
  ) async {
    await tester.runAsync(
      () => c.saveCalibration(c.calibrationProposal(offset)),
    );
    await tester.pump();
  }

  Future<void> signal(
    WidgetTester tester, {
    double peak = -20,
    double? right,
    bool unstable = false,
  }) async {
    for (var i = 0; i < 120; i++) {
      await send(
        tester,
        capture(peak: unstable && i.isEven ? peak - 2 : peak, right: right),
      );
      await tester.pump(const Duration(milliseconds: 17));
    }
  }

  test(
    'identity isolates host, USB model and available serial, ignoring port IDs',
    () {
      final key = AnalyzerCalibrationIdentity.fromMap(identity())!.key;
      expect(
        AnalyzerCalibrationIdentity.fromMap({
          ...identity(),
          'id': 99,
          'address': 'new',
        })!.key,
        key,
      );
      for (final other in [
        identity(host: 'Phone'),
        identity(usb: 'ADI-2 DAC'),
        identity(serial: '456'),
        identity(serial: null),
      ]) {
        expect(AnalyzerCalibrationIdentity.fromMap(other)!.key, isNot(key));
      }
      expect(AnalyzerCalibrationIdentity.fromMap({'usbName': 'ADI-2'}), isNull);
      expect(AnalyzerCalibrationIdentity.fromMap(null), isNull);
    },
  );

  test('Mac identity separates hosts, USB models and serials; Android keys stay compatible', () {
    final android = identity();
    expect(
      AnalyzerCalibrationIdentity.fromMap(android)!.key,
      jsonEncode(['Test', 'Tablet', 'ADI-2/4 Pro SE', 1, 2, '123']),
    );
    final mac = <String, Object>{
      'hostManufacturer': 'macOS',
      'hostModel': 'MacBook test host',
      'usbName': 'ADI-2 DAC',
      'usbSerial': '123',
    };
    final first = AnalyzerCalibrationIdentity.fromMap(mac)!;
    expect(first.label, contains('MacBook test host · ADI-2 DAC · 123'));
    for (final other in [
      {...mac, 'hostModel': 'Other Mac'},
      {...mac, 'usbName': 'ADI-2 Pro'},
      {...mac, 'usbSerial': '456'},
      {...mac}..remove('usbSerial'),
    ]) {
      expect(AnalyzerCalibrationIdentity.fromMap(other)!.key, isNot(first.key));
    }
    expect(
      AnalyzerCalibrationIdentity.fromMap({...mac, 'id': 999})!.key,
      first.key,
    );
  });

  test(
    'per-combination persistence, concurrent writes, reset and validation',
    () async {
      final a = AnalyzerCalibrationIdentity.fromMap(identity())!.key;
      final b = AnalyzerCalibrationIdentity.fromMap(identity(host: 'Phone'))!
          .key;
      expect(settings.analyzerCalibration(a), 0);
      await Future.wait([
        settings.setAnalyzerCalibration(a, 20),
        settings.setAnalyzerCalibration(b, -1.1),
      ]);
      await settings.load();
      expect(settings.analyzerCalibration(a), 20);
      expect(settings.analyzerCalibration(b), -1.1);
      expect(settings.analyzerCalibration('unknown'), 0);
      expect(settings.analyzerCalibration(null), 0);
      for (final invalid in [-40.1, 40.1, double.nan, double.infinity]) {
        expect(
          () => settings.setAnalyzerCalibration(a, invalid),
          throwsArgumentError,
        );
      }
      await settings.setAnalyzerCalibration(a, 0);
      await settings.load();
      expect(settings.analyzerCalibration(a), 0);
      expect(settings.analyzerCalibration(b), -1.1);
      final saved = jsonDecode(
        (await SharedPreferences.getInstance()).getString(
          'analyzer_calibrations',
        )!,
      ) as Map;
      expect(saved.containsKey(a), isFalse);
    },
  );

  test('old settings and malformed calibration use zero', () async {
    for (final stored in ['broken', '[]', '{"a":99,"b":"20"}']) {
      SharedPreferences.setMockInitialValues({'analyzer_calibrations': stored});
      await settings.load();
      expect(settings.analyzerCalibration('a'), 0);
      expect(settings.analyzerCalibration('b'), 0);
    }
  });

  test('measurement averages raw L/R, tolerates specified limits and rounds to 0.1 dB', () {
    final measurement = AnalyzerCalibrationMeasurement();
    for (var i = 0; i < 120; i++) {
      measurement.add(rawFrame(left: i.isEven ? -20.5 : -19.5));
    }
    expect(measurement.finish(), 20);
    final stereo = AnalyzerCalibrationMeasurement();
    for (var i = 0; i < 120; i++) {
      stereo.add(rawFrame(left: -20, right: -19));
    }
    expect(stereo.finish(), 19.5);
  });

  for (final entry in <String, (double, double, AnalyzerCalibrationError)>{
    'too quiet': (-60, -60, AnalyzerCalibrationError.tooQuiet),
    'unbalanced': (-20, -21.01, AnalyzerCalibrationError.unbalanced),
    'out of range': (-41, -41, AnalyzerCalibrationError.outOfRange),
    'invalid': (double.nan, -20, AnalyzerCalibrationError.unstable),
  }.entries) {
    test('measurement rejects ${entry.key}', () {
      final m = AnalyzerCalibrationMeasurement();
      for (var i = 0; i < 120; i++) {
        m.add(rawFrame(left: entry.value.$1, right: entry.value.$2));
      }
      expect(m.finish, throwsA(entry.value.$3));
    });
  }
  test('measurement rejects unstable, missing and coalesced observations', () {
    final m = AnalyzerCalibrationMeasurement();
    for (var i = 0; i < 120; i++) {
      m.add(rawFrame(left: i.isEven ? -20 : -21.1));
    }
    expect(m.finish, throwsA(AnalyzerCalibrationError.unstable));
    expect(
      AnalyzerCalibrationMeasurement().finish,
      throwsA(AnalyzerCalibrationError.unavailable),
    );
    final coalesced = AnalyzerCalibrationMeasurement()
      ..add(rawFrame(seconds: 2));
    expect(coalesced.finish, throwsA(AnalyzerCalibrationError.unavailable));
  });

  testWidgets(
    'offset applies centrally to line/bass/bands/hold, stereo meters and clipping',
    (tester) async {
      final c = AnalyzerController();
      addTearDown(c.dispose);
      await active(tester, c, true);
      await send(tester, capture());
      await tester.pump();
      final line = List.of(c.spectrum.values),
          bass = List.of(c.bassSpectrum.values);
      await save(tester, c, 20);
      expect(c.rawFrame!.peak, [-20, -20]);
      expect(c.rawFrame!.displayPeak, [-21, -21]);
      expect(c.frame!.peak, [0, 0]);
      expect(c.frame!.rms, [-3, -3]);
      expect(c.frame!.displayPeak, [-1, -1]);
      expect(c.frame!.displayRms, [-4, -4]);
      expect(c.frame!.clipped, [true, true]);
      expect(c.frame!.spectrum.first, closeTo(1, 1e-12));
      expect(c.bands.values, everyElement(0));
      expect(c.bands.held, everyElement(0));
      expect(c.spectrum.values.first, closeTo(line.first + 20, 1e-12));
      expect(c.spectrum.held.first, closeTo(line.first + 20, 1e-12));
      expect(c.bassSpectrum.values.first, closeTo(bass.first + 20, 1e-12));
      // Changing gain clears old peak holds, including when lowering the offset.
      await save(tester, c, -40);
      expect(c.spectrum.held.first, closeTo(line.first - 40, 1e-12));
      expect(c.frame!.clipped, [false, false]);
      await save(tester, c, 40);
      expect(c.spectrum.values.first, closeTo(line.first + 40, 1e-12));
      expect(c.frame!.peak, [20, 20]);
      await active(tester, c, false);
    },
  );

  testWidgets(
    'FFT band fallback and band-resolution changes retain the same offset',
    (tester) async {
      final c = AnalyzerController();
      addTearDown(c.dispose);
      await active(tester, c, true);
      await send(tester, capture(nativeBands: false));
      await tester.pump();
      final raw = octaveBandDb(c.rawFrame!, c.bandResolution);
      await save(tester, c, 20);
      for (var i = 0; i < raw.length; i++) {
        expect(c.bands.values[i], closeTo(raw[i] + 20, 1e-9));
      }
      await tester.runAsync(
        () => c.setBandResolution(AnalyzerBandResolution.twelfth),
      );
      await tester.pump();
      final finer = octaveBandDb(c.rawFrame!, c.bandResolution);
      expect(c.bands.values.length, 117);
      for (var i = 0; i < finer.length; i++) {
        expect(c.bands.values[i], closeTo(finer[i] + 20, 1e-9));
      }
      await active(tester, c, false);
    },
  );

  testWidgets(
    'switching combinations resets gain and holds and reconnect restores only matching gain',
    (tester) async {
      final c = AnalyzerController();
      addTearDown(c.dispose);
      await active(tester, c, true);
      await send(tester, capture());
      await tester.pump();
      await save(tester, c, 20);
      final stale = c.calibrationProposal(21);
      await send(tester, capture(route: identity(serial: 'other')));
      await tester.pump();
      expect(c.calibrationOffset, 0);
      expect(c.bands.values, everyElement(-20));
      expect(c.bands.held, everyElement(-20));
      expect(
        () => c.saveCalibration(stale),
        throwsA(AnalyzerCalibrationError.unavailable),
      );
      await active(tester, c, false);
      await active(tester, c, true);
      await send(tester, capture());
      await tester.pump();
      expect(c.calibrationOffset, 20);
      expect(
        () => c.saveCalibration(stale),
        throwsA(AnalyzerCalibrationError.unavailable),
      );
      await send(tester, {...capture(), 'calibrationIdentity': null});
      await tester.pump();
      expect(c.calibrationOffset, 0);
      expect(c.canCalibrate, isFalse);
      await active(tester, c, false);
    },
  );

  testWidgets(
    'two-second measurement uses raw peaks and requires an explicit save',
    (tester) async {
      final c = AnalyzerController();
      addTearDown(c.dispose);
      await active(tester, c, true);
      await send(tester, capture());
      await tester.pump();
      await save(tester, c, 4);
      final measuring = c.measureCalibration();
      await signal(tester);
      final proposal = await measuring;
      expect(proposal.offset, 20);
      expect(c.calibrationOffset, 4);
      await tester.runAsync(() => c.saveCalibration(proposal));
      await tester.pump();
      expect(c.calibrationOffset, 20);
      await active(tester, c, false);
    },
  );

  testWidgets('capture interruption invalidates a measurement without saving', (
    tester,
  ) async {
    final c = AnalyzerController();
    addTearDown(c.dispose);
    await active(tester, c, true);
    await send(tester, capture());
    await tester.pump();
    final measured = expectLater(
      c.measureCalibration(),
      throwsA(AnalyzerCalibrationError.unavailable),
    );
    await send(tester, {'status': 'usbUnavailable'});
    await tester.pump(const Duration(seconds: 2));
    await measured;
    expect(c.calibrationOffset, 0);
    await active(tester, c, false);
  });

  Future<Timer> controls(WidgetTester tester, AnalyzerController c) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AnalyzerCalibrationSetting(controller: c),
          ),
        ),
      ),
    );
    await active(tester, c, true);
    await send(tester, capture());
    await tester.pump();
    final stream = Timer.periodic(const Duration(milliseconds: 17), (_) {
      binding.channelBuffers.push(
        'adi2/analyzer/events',
        const StandardMethodCodec().encodeSuccessEnvelope(capture()),
        (_) {},
      );
    });
    addTearDown(stream.cancel);
    return stream;
  }

  Future<Adi2Controller> connectedDevice() async {
    final d = _CalibrationDevice();
    d.set(Adi2Addr.line, OutIdx.loopback, 2);
    d.set(Adi2Addr.line, OutIdx.source, 3);
    addTearDown(d.dispose);
    return d;
  }

  Map<String, dynamic> mediaCapture({
    int volume = 9,
    String host = 'Tablet',
  }) => {
    ...capture(route: identity(host: host)),
    'mediaStreamVolume': volume,
    'mediaStreamMax': 15,
    'availableEffects': ['Raumklang (Hersteller)', 'Klangprofil (Hersteller)'],
  };

  List<String> recordNativeCalls() {
    final calls = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(method, (
      call,
    ) async {
      calls.add(call.method);
      return call.method == 'permission' ? true : null;
    });
    return calls;
  }

  Future<void> streamFrames(WidgetTester tester, int frames) async {
    for (var i = 0; i < frames; i++) {
      await send(tester, capture());
      await tester.pump(const Duration(milliseconds: 17));
    }
  }

  testWidgets('Testton startet vor und stoppt nach der Messung', (
    tester,
  ) async {
    final calls = recordNativeCalls();
    final c = AnalyzerController();
    addTearDown(c.dispose);
    await active(tester, c, true);
    await send(tester, capture());
    await tester.pump();
    final measuring = c.measureCalibration(
      useTestTone: true,
      toneAllowed: () => true,
    );
    await streamFrames(tester, 190);
    expect((await measuring).offset, 20);
    expect(
      calls.indexOf('startCalibrationTone'),
      lessThan(calls.indexOf('stopCalibrationTone')),
    );
  });

  testWidgets('Entstummen stoppt den Testton ohne Vorschlag', (tester) async {
    final calls = recordNativeCalls();
    final c = AnalyzerController();
    addTearDown(c.dispose);
    await active(tester, c, true);
    await send(tester, capture());
    await tester.pump();
    var allowed = true;
    Object? error;
    final measuring = c
        .measureCalibration(useTestTone: true, toneAllowed: () => allowed)
        .catchError((Object e) {
          error = e;
          return AnalyzerCalibrationProposal('', 0, 0);
        });
    await streamFrames(tester, 40);
    allowed = false;
    await streamFrames(tester, 10);
    await measuring;
    expect(error, AnalyzerCalibrationError.toneInterrupted);
    expect(calls, contains('stopCalibrationTone'));
  });

  testWidgets('Fehlender USB-Ausgang startet keine Messung', (tester) async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(method, (
      call,
    ) async {
      if (call.method == 'permission') return true;
      if (call.method == 'startCalibrationTone') {
        throw PlatformException(code: 'noUsbOutput');
      }
      return null;
    });
    final c = AnalyzerController();
    addTearDown(c.dispose);
    await active(tester, c, true);
    await send(tester, capture());
    await tester.pump();
    Object? error;
    await tester.runAsync(() async {
      try {
        await c.measureCalibration(useTestTone: true, toneAllowed: () => true);
      } catch (e) {
        error = e;
      }
    });
    expect(error, AnalyzerCalibrationError.toneUnavailable);
  });

  testWidgets('Messprotokoll sperrt den Testton bis alles passt', (
    tester,
  ) async {
    final c = AnalyzerController();
    addTearDown(c.dispose);
    final d = await connectedDevice();
    await active(tester, c, true);
    await send(tester, mediaCapture(volume: 15));
    await tester.pump();
    expect(
      calibrationToneBlockers(d, c),
      contains('Nicht alle Ausgänge sind stumm'),
    );

    muteCalibrationOutputs(d);
    for (final o in outputsFor(Adi2Variant.dac)) {
      expect(d.value(o.address, OutIdx.mute), 1);
    }
    d.set(Adi2Addr.line, OutIdx.daFilter, 0);
    expect(calibrationToneBlockers(d, c), isEmpty);

    d.set(Adi2Addr.line, OutIdx.daFilter, 2);
    expect(
      calibrationToneBlockers(d, c),
      contains('DA-Filter auf SD Sharp stellen'),
    );
    d.set(Adi2Addr.line, OutIdx.daFilter, 0);

    d.set(Adi2Addr.line, OutIdx.loopback, 1);
    expect(
      calibrationToneBlockers(d, c),
      contains('Loopback auf post FX und USB 1/2 stellen'),
    );
    d.set(Adi2Addr.line, OutIdx.loopback, 2);

    d.set(Adi2Addr.line, OutIdx.source, 2);
    expect(
      calibrationToneBlockers(d, c),
      contains('Quelle des gemessenen Ausgangs auf USB stellen'),
    );
    d.set(Adi2Addr.line, OutIdx.source, 3);

    d.set(Adi2Addr.line, OutIdx.crossfeed, 1);
    expect(
      calibrationToneBlockers(d, c),
      contains('EQ, Bass/Treble, Loudness und Crossfeed ausschalten'),
    );
    d.set(Adi2Addr.line, OutIdx.crossfeed, 0);

    await send(tester, mediaCapture(volume: 9));
    await tester.pump();
    expect(
      calibrationToneBlockers(d, c),
      contains('Medienlautstärke auf Maximum stellen'),
    );

    d.set(Adi2Addr.ph12, OutIdx.mute, 0);
    expect(
      calibrationToneBlockers(d, c),
      contains('Nicht alle Ausgänge sind stumm'),
    );
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets(
      '$platform checklist keeps all device checks and only Mac skips media volume',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final c = AnalyzerController();
          addTearDown(c.dispose);
          final d = await connectedDevice();
          muteCalibrationOutputs(d);
          d.set(Adi2Addr.line, OutIdx.daFilter, 0);
          // No Android media-volume information, as with native Mac PCM events.
          expect(
            calibrationToneBlockers(d, c),
            platform == TargetPlatform.macOS
                ? isEmpty
                : contains('Medienlautstärke auf Maximum stellen'),
          );
          c.mediaVolume = 3;
          c.mediaVolumeMax = 15;
          expect(
            calibrationToneBlockers(d, c),
            platform == TargetPlatform.macOS
                ? isEmpty
                : contains('Medienlautstärke auf Maximum stellen'),
          );
          c.mediaVolume = 15;
          expect(calibrationToneBlockers(d, c), isEmpty);
          d.set(Adi2Addr.ph12, OutIdx.mute, 0);
          d.set(Adi2Addr.line, OutIdx.loopback, 1);
          d.set(Adi2Addr.line, OutIdx.daFilter, 2);
          d.set(Adi2Addr.line, OutIdx.source, 2);
          d.set(Adi2Addr.line, OutIdx.crossfeed, 1);
          expect(
            calibrationToneBlockers(d, c),
            containsAll([
              'Nicht alle Ausgänge sind stumm',
              'Loopback auf post FX und USB 1/2 stellen',
              'DA-Filter auf SD Sharp stellen',
              'Quelle des gemessenen Ausgangs auf USB stellen',
              'EQ, Bass/Treble, Loudness und Crossfeed ausschalten',
            ]),
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
    testWidgets('$platform calibration dialog offers tone on Android and Mac', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        final c = AnalyzerController();
        addTearDown(c.dispose);
        final d = await connectedDevice();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AnalyzerCalibrationSetting(
                  controller: c,
                  deviceController: d,
                ),
              ),
            ),
          ),
        );
        await active(tester, c, true);
        await send(tester, capture());
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(const ValueKey('analyzer-calibration-auto')),
        );
        await tester.tap(
          find.byKey(const ValueKey('analyzer-calibration-auto')),
        );
        await settle(tester);
        final toggle = find.byKey(const ValueKey('calibration-test-tone'));
        expect(
          toggle,
          platform == TargetPlatform.iOS ? findsNothing : findsOneWidget,
        );
        if (platform == TargetPlatform.macOS) {
          muteCalibrationOutputs(d);
          d.set(Adi2Addr.line, OutIdx.daFilter, 0);
          await tester.tap(toggle);
          await tester.pump();
          expect(
            find.text('Medienlautstärke auf Maximum stellen'),
            findsNothing,
          );
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Messung starten'),
                )
                .onPressed,
            isNotNull,
          );
          d.set(Adi2Addr.ph12, OutIdx.mute, 0);
          await tester.pump();
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Messung starten'),
                )
                .onPressed,
            isNull,
          );
        }
        await tester.tap(find.text('Abbrechen'));
        await settle(tester);
        await active(tester, c, false);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  for (final missingKey in <int?>[
    null,
    Adi2Addr.ph34 << 8 | OutIdx.mute,
    Adi2Addr.ph34 << 8 | OutIdx.volume,
    Adi2Addr.line << 8 | OutIdx.mute,
  ]) {
    testWidgets('Testton-Freigabe verlangt jeden Ausgang, fehlt $missingKey', (
      tester,
    ) async {
      final calls = recordNativeCalls();
      final c = AnalyzerController();
      addTearDown(c.dispose);
      final d = await connectedDevice() as _CalibrationDevice;
      muteCalibrationOutputs(d);
      d.set(Adi2Addr.line, OutIdx.daFilter, 0);
      // Automatic Line mute still counts, but its parameter must be fresh too.
      d.autoMuteLine = true;
      d.set(Adi2Addr.line, OutIdx.mute, 0);
      if (missingKey != null) d.omittedKeys.add(missingKey);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AnalyzerCalibrationSetting(
                controller: c,
                deviceController: d,
              ),
            ),
          ),
        ),
      );
      await active(tester, c, true);
      await send(tester, mediaCapture(volume: 15));
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('analyzer-calibration-auto')),
      );
      await tester.tap(find.byKey(const ValueKey('analyzer-calibration-auto')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('calibration-test-tone')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Messung starten'));
      await settle(tester);
      expect(
        calls.where((call) => call == 'startCalibrationTone'),
        missingKey == null ? hasLength(1) : isEmpty,
      );
      final keys = [
        for (final address in Adi2Controller.volumeAddresses) ...[
          address << 8 | OutIdx.mute,
          address << 8 | OutIdx.volume,
        ],
      ];
      expect(d.confirmationRequests, isNotEmpty);
      for (final request in d.confirmationRequests) {
        expect(request, unorderedEquals(keys));
      }
      expect(calibrationOutputsMuted(d), isTrue);
      if (missingKey == null) {
        for (var i = 0; i < 190; i++) {
          await send(tester, mediaCapture(volume: 15));
          await tester.pump(const Duration(milliseconds: 17));
        }
        await tester.pump(const Duration(seconds: 2));
        await settle(tester);
        // The result dialog only remains open when the measurement failed.
        final cancel = find.text('Abbrechen');
        if (cancel.evaluate().isNotEmpty) {
          await tester.tap(cancel.first);
          await settle(tester);
        }
      }
      await active(tester, c, false);
    });
  }

  testWidgets('Automatisch stummer Line Out zählt wie in der Anzeige', (
    tester,
  ) async {
    final d = await connectedDevice() as _CalibrationDevice;
    muteCalibrationOutputs(d);
    d.set(Adi2Addr.line, OutIdx.mute, 0);
    expect(calibrationOutputsMuted(d), isFalse);
    d.autoMuteLine = true;
    expect(calibrationOutputsMuted(d), isTrue);
    d.set(Adi2Addr.ph12, OutIdx.mute, 0);
    expect(calibrationOutputsMuted(d), isFalse);
  });

  testWidgets('Veralteter Mute-Wert gibt den Testton nie frei', (tester) async {
    final d = await connectedDevice() as _CalibrationDevice;
    muteCalibrationOutputs(d);
    expect(calibrationOutputsMuted(d), isTrue);
    d.set(Adi2Addr.ph12, OutIdx.mute, 0);
    d.staleConfirmed[Adi2Addr.ph12 << 8 | OutIdx.mute] = 1;
    expect(calibrationOutputsMuted(d), isFalse);
  });

  testWidgets('Ohne Antwort des Geräts gilt die Lautstärke nicht als sicher', (
    tester,
  ) async {
    final d = await connectedDevice() as _CalibrationDevice;
    d.answers = false;
    d.set(Adi2Addr.line, OutIdx.volume, -500);
    final result = ensureOutputsQuiet(d);
    await tester.pump(const Duration(seconds: 5));
    expect(await result, isFalse);
  });

  testWidgets('Veralteter Lautstärkewert besteht die Prüfung nicht', (
    tester,
  ) async {
    final d = await connectedDevice() as _CalibrationDevice;
    d.set(Adi2Addr.line, OutIdx.volume, 0);
    d.staleConfirmed[Adi2Addr.line << 8 | OutIdx.volume] = 0;
    final result = ensureOutputsQuiet(d);
    await tester.pump(const Duration(seconds: 5));
    expect(await result, isFalse);
  });

  testWidgets('Nach dem Testton nur zu laute Ausgänge absenken', (
    tester,
  ) async {
    final d = await connectedDevice();
    d.set(Adi2Addr.line, OutIdx.volume, 0);
    d.set(Adi2Addr.ph12, OutIdx.volume, -240);
    d.set(Adi2Addr.ph34, OutIdx.volume, -500);
    lowerOutputsAfterCalibration(d);
    expect(calibrationSafeVolumeRaw, -300);
    expect(d.value(Adi2Addr.line, OutIdx.volume), -300);
    expect(d.value(Adi2Addr.ph12, OutIdx.volume), -300);
    expect(d.value(Adi2Addr.ph34, OutIdx.volume), -500);
  });

  testWidgets('Doppelte Prüfung braucht die Bestätigung des Geräts', (
    tester,
  ) async {
    final ok = await connectedDevice() as _CalibrationDevice;
    ok.set(Adi2Addr.line, OutIdx.volume, 0);
    final passed = ensureOutputsQuiet(ok);
    await tester.pump(const Duration(seconds: 2));
    expect(await passed, isTrue);

    final stuck = await connectedDevice() as _CalibrationDevice;
    stuck.stuckVolume = true;
    stuck.set(Adi2Addr.line, OutIdx.volume, 0);
    final failed = ensureOutputsQuiet(stuck);
    await tester.pump(const Duration(seconds: 5));
    expect(await failed, isFalse);
  });

  testWidgets('Testton-Abbruch senkt die Lautstärke trotzdem ab', (
    tester,
  ) async {
    final c = AnalyzerController();
    addTearDown(c.dispose);
    final d = await connectedDevice();
    muteCalibrationOutputs(d);
    d.set(Adi2Addr.line, OutIdx.daFilter, 0);
    d.set(Adi2Addr.line, OutIdx.volume, 0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AnalyzerCalibrationSetting(
              controller: c,
              deviceController: d,
            ),
          ),
        ),
      ),
    );
    await active(tester, c, true);
    await send(tester, mediaCapture(volume: 15));
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey('analyzer-calibration-auto')),
    );
    await tester.tap(find.byKey(const ValueKey('analyzer-calibration-auto')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('calibration-test-tone')));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Messung starten'));
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await send(tester, mediaCapture(volume: 15));
      await tester.pump(const Duration(milliseconds: 17));
    }
    d.set(Adi2Addr.ph12, OutIdx.mute, 0);
    for (var i = 0; i < 30; i++) {
      await send(tester, mediaCapture(volume: 15));
      await tester.pump(const Duration(milliseconds: 17));
    }
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(d.value(Adi2Addr.line, OutIdx.volume), -300);
    expect(find.textContaining('Testton abgebrochen'), findsOneWidget);
  });

  testWidgets('Dialog sperrt den Testton und schaltet alle Ausgänge stumm', (
    tester,
  ) async {
    final c = AnalyzerController();
    addTearDown(c.dispose);
    final d = await connectedDevice();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AnalyzerCalibrationSetting(
              controller: c,
              deviceController: d,
            ),
          ),
        ),
      ),
    );
    await active(tester, c, true);
    await send(tester, mediaCapture(volume: 15));
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey('analyzer-calibration-auto')),
    );
    await tester.tap(find.byKey(const ValueKey('analyzer-calibration-auto')));
    await settle(tester);
    FilledButton start() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Messung starten'),
    );
    expect(start().onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('calibration-test-tone')));
    await tester.pump();
    expect(start().onPressed, isNull);
    final mute = find.byKey(const ValueKey('calibration-mute-all'));
    await tester.ensureVisible(mute);
    await tester.tap(mute);
    await tester.pump(const Duration(milliseconds: 300));
    expect(d.value(Adi2Addr.line, OutIdx.mute), 1);
    expect(mute, findsNothing);
  });

  testWidgets(
    'USB volume gate is live, explicit, and external sources stay free',
    (tester) async {
      final c = AnalyzerController();
      addTearDown(c.dispose);
      final d = await connectedDevice();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AnalyzerCalibrationSetting(
                controller: c,
                deviceController: d,
              ),
            ),
          ),
        ),
      );
      await active(tester, c, true);
      await send(tester, mediaCapture());
      await tester.pump();
      expect(
        find.byKey(const ValueKey('calibration-hint-red')),
        findsOneWidget,
      );
      expect(find.text('Medienlautstärke: 9/15'), findsOneWidget);
      expect(find.textContaining('Raumklang (Hersteller)'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey('analyzer-calibration-auto')),
      );
      await tester.tap(find.byKey(const ValueKey('analyzer-calibration-auto')));
      await settle(tester);
      FilledButton start() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Messung starten'),
      );
      expect(start().onPressed, isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('calibration-volume-confirm')),
      );
      await tester.tap(
        find.byKey(const ValueKey('calibration-volume-confirm')),
      );
      await tester.pump();
      expect(start().onPressed, isNotNull);
      await send(tester, mediaCapture(volume: 8));
      await tester.pump();
      expect(
        start().onPressed,
        isNull,
        reason: 'A changed volume needs a new acknowledgement',
      );
      await send(tester, mediaCapture(volume: 15));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('calibration-volume-confirm')),
        findsNothing,
      );
      expect(start().onPressed, isNotNull);
      await send(tester, mediaCapture());
      d.set(Adi2Addr.line, OutIdx.source, 2);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('calibration-volume-confirm')),
        findsNothing,
      );
      expect(start().onPressed, isNotNull);
      expect(find.byKey(const ValueKey('calibration-hint-red')), findsNothing);
      await tester.tap(find.text('Abbrechen'));
      await settle(tester);
      await active(tester, c, false);
    },
  );

  testWidgets(
    'source check uses DAC fallback or assigned Pro loopback output',
    (tester) async {
      for (final variant in Adi2Variant.values) {
        final d = Adi2Controller();
        await d.startOffline(variant);
        d.state = ConnState.connected;
        for (final output in analyzerOutputs(d)) {
          d.set(output.address, OutIdx.loopback, 0);
        }
        d.set(Adi2Addr.ph34, OutIdx.loopback, 2);
        d.set(Adi2Addr.line, OutIdx.source, variant.isDac ? 3 : 4);
        d.selectedOutput = Adi2Addr.line;
        final sourceAddress = variant.isDac ? Adi2Addr.line : Adi2Addr.ph34;
        final definition = outputParams(
          variant,
          phones: true,
          ph34: true,
        ).firstWhere((p) => p.index == OutIdx.source);
        for (var source = 0; source < definition.options!.length; source++) {
          d.set(sourceAddress, OutIdx.source, source);
          expect(
            analyzerCalibrationUsesUsb(d),
            source == 0 || definition.options![source].startsWith('USB'),
          );
        }
        if (!variant.isDac) {
          d.set(Adi2Addr.ph34, OutIdx.source, 0);
          d.set(Adi2Addr.device, 6, 3);
          expect(analyzerCalibrationUsesUsb(d), isFalse);
          d.set(Adi2Addr.device, 6, 2);
          expect(analyzerCalibrationUsesUsb(d), isTrue);
        }
        d.dispose();
      }
    },
  );

  for (final answer in [false, true]) {
    testWidgets(
      'first visible use asks once per identity with answer $answer',
      (tester) async {
        final c = AnalyzerController();
        addTearDown(c.dispose);
        final d = await connectedDevice();
        Future<void> panel() async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: AnalyzerPanel(
                  controller: c,
                  deviceController: d,
                  expanded: true,
                ),
              ),
            ),
          );
          await settle(tester);
          await send(tester, mediaCapture());
          await tester.pump();
          await settle(tester);
        }

        // An active capture alone (no visible analyzer) must not show a prompt.
        await active(tester, c, true);
        await send(tester, mediaCapture());
        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
        await tester.pump();
        expect(find.text('Analyzer kalibrieren?'), findsNothing);
        await panel();
        expect(find.text('Analyzer kalibrieren?'), findsOneWidget);
        expect(find.textContaining('Android-Klangeffekte'), findsOneWidget);
        await tester.tap(find.text(answer ? 'Ja' : 'Nein'));
        await settle(tester);
        if (answer) {
          expect(find.text('Messung starten'), findsOneWidget);
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Messung starten'),
                )
                .onPressed,
            isNull,
          );
          await tester.tap(find.text('Abbrechen'));
          await settle(tester);
          await tester.tap(find.text('Schließen'));
          await settle(tester);
        }
        expect(c.calibrationOffset, 0);
        final prefs = await tester.runAsync(SharedPreferences.getInstance);
        expect(
          jsonDecode(
            prefs!.getString('analyzer_calibration_answers')!,
          )[c.calibrationIdentity!.key],
          answer,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await settle(tester);
        await tester.runAsync(settings.load);
        await panel();
        expect(find.text('Analyzer kalibrieren?'), findsNothing);
        await send(tester, mediaCapture(host: 'Other phone'));
        await tester.pump();
        await settle(tester);
        expect(find.text('Analyzer kalibrieren?'), findsOneWidget);
        await tester.tap(find.text('Nein'));
        await settle(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await settle(tester);
        await active(tester, c, false);
      },
    );
  }

  for (final suppressed in ['offline', 'selftest', 'hidden']) {
    testWidgets('first use prompt suppressed while $suppressed', (
      tester,
    ) async {
      final c = AnalyzerController();
      addTearDown(c.dispose);
      final d = await connectedDevice();
      if (suppressed == 'offline') d.state = ConnState.offline;
      if (suppressed == 'selftest') d.analyzerSelfTestActive = true;
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: AnalyzerPanel(
              controller: c,
              deviceController: d,
              expanded: true,
            ),
          ),
        ),
      );
      await settle(tester);
      if (suppressed == 'hidden') {
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Other page')),
            ),
          ),
        );
        await settle(tester);
      }
      await send(tester, mediaCapture());
      await tester.pump();
      await settle(tester);
      expect(find.text('Analyzer kalibrieren?'), findsNothing);
      if (suppressed == 'hidden') {
        navigator.currentState!.pop();
      } else {
        d.state = ConnState.connected;
        d.analyzerSelfTestActive = false;
        d.notifyListeners();
      }
      await settle(tester);
      await send(tester, mediaCapture());
      await tester.pump();
      await settle(tester);
      expect(find.text('Analyzer kalibrieren?'), findsOneWidget);
      await tester.tap(find.text('Nein'));
      await settle(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      await active(tester, c, false);
    });
  }

  testWidgets('manual steps, limits and reset confirmation', (tester) async {
    final c = AnalyzerController();
    addTearDown(c.dispose);
    final stream = await controls(tester, c);
    for (final step in [1.0, .1, -.1, -1.0]) {
      final previous = c.calibrationOffset;
      await tester.ensureVisible(
        find.byKey(ValueKey('analyzer-calibration-step-$step')),
      );
      await tester.tap(find.byKey(ValueKey('analyzer-calibration-step-$step')));
      await settle(tester);
      expect(c.calibrationOffset, closeTo(previous + step, 1e-9));
    }
    await save(tester, c, 40);
    await tester.pump();
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('analyzer-calibration-step-0.1')),
          )
          .onPressed,
      isNull,
    );
    await save(tester, c, -40);
    await tester.pump();
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('analyzer-calibration-step--1.0')),
          )
          .onPressed,
      isNull,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('analyzer-calibration-reset')),
    );
    await tester.tap(find.byKey(const ValueKey('analyzer-calibration-reset')));
    await settle(tester);
    await tester.tap(find.text('Abbrechen'));
    await settle(tester);
    expect(c.calibrationOffset, -40);
    await tester.ensureVisible(
      find.byKey(const ValueKey('analyzer-calibration-reset')),
    );
    await tester.tap(find.byKey(const ValueKey('analyzer-calibration-reset')));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Zurücksetzen'));
    await settle(tester);
    expect(c.calibrationOffset, 0);
    expect(find.text('Aktueller Offset 0,0 dB'), findsOneWidget);
    stream.cancel();
    await active(tester, c, false);
  });

  testWidgets(
    'automatic UI shows instructions and preview, supports cancel and save',
    (tester) async {
      final c = AnalyzerController();
      addTearDown(c.dispose);
      final stream = await controls(tester, c);
      for (final save in [false, true]) {
        await tester.ensureVisible(
          find.byKey(const ValueKey('analyzer-calibration-auto')),
        );
        await tester.tap(
          find.byKey(const ValueKey('analyzer-calibration-auto')),
        );
        await settle(tester);
        expect(find.textContaining('Loopback-Quelle post FX'), findsOneWidget);
        await tester.tap(find.text('Messung starten'));
        await tester.pump();
        await signal(tester);
        await settle(tester);
        expect(find.text('Offset +20,0 dB speichern?'), findsOneWidget);
        expect(c.calibrationOffset, 0);
        await tester.tap(find.text(save ? 'Speichern' : 'Abbrechen'));
        await settle(tester);
        expect(
          c.calibrationOffset,
          save ? 20 : 0,
          reason: tester
              .widgetList<Text>(find.byType(Text))
              .map((w) => w.data)
              .join(' | '),
        );
      }
      expect(
        find.text('Unkalibrierter Peak · L -20,0 / R -20,0 dBFS'),
        findsOneWidget,
      );
      expect(find.text('Aktueller Offset +20,0 dB'), findsOneWidget);
      stream.cancel();
      await active(tester, c, false);
    },
  );

  for (final invalid in ['unstable', 'quiet', 'unbalanced']) {
    testWidgets('automatic UI explains $invalid and keeps stored gain', (
      tester,
    ) async {
      final c = AnalyzerController();
      addTearDown(c.dispose);
      final stream = await controls(tester, c);
      await save(tester, c, 3);
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('analyzer-calibration-auto')),
      );
      await tester.tap(find.byKey(const ValueKey('analyzer-calibration-auto')));
      await settle(tester);
      await tester.tap(find.text('Messung starten'));
      await tester.pump();
      await signal(
        tester,
        peak: invalid == 'quiet' ? -70 : -20,
        unstable: invalid == 'unstable',
        right: invalid == 'unbalanced' ? -23 : null,
      );
      await settle(tester);
      expect(find.textContaining('Nichts gespeichert.'), findsOneWidget);
      expect(find.textContaining('speichern?'), findsNothing);
      expect(c.calibrationOffset, 3);
      stream.cancel();
      await active(tester, c, false);
    });
  }

  testWidgets(
    'compact and fullscreen share calibrated levels and a single info line',
    (tester) async {
      final c = AnalyzerController();
      addTearDown(c.dispose);
      await active(tester, c, true);
      await send(tester, capture());
      await tester.pump();
      await save(tester, c, 20);
      for (final compact in [true, false]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: compact ? 112 : 500,
                child: AnalyzerDisplay(controller: c, compact: compact),
              ),
            ),
          ),
        );
        await tester.pump();
        if (compact) {
          expect(find.textContaining('kalibriert +20,0 dB'), findsNothing);
          await tester.tap(find.byKey(const ValueKey('analyzer-info-toggle')));
          await tester.pump();
        }
        expect(find.textContaining('kalibriert +20,0 dB'), findsOneWidget);
        expect(find.byType(AnalyzerLevelBar), findsNWidgets(2));
        for (final bar in tester.widgetList<AnalyzerLevelBar>(
          find.byType(AnalyzerLevelBar),
        )) {
          expect(bar.peak, -1);
          expect(bar.rms, -4);
          expect(bar.clipped, isTrue);
        }
        expect(tester.takeException(), isNull);
      }
      await save(tester, c, 0);
      await tester.pump();
      expect(find.textContaining('kalibriert'), findsNothing);
      await active(tester, c, false);
    },
  );

  for (final language in AppLanguage.values) {
    testWidgets(
      'calibration settings and instructions fit narrow enlarged text in $language',
      (tester) async {
        AppLang.instance.language = language;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 800);
        addTearDown(tester.view.reset);
        final c = AnalyzerController();
        addTearDown(c.dispose);
        await active(tester, c, true);
        await send(tester, capture());
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  key: const ValueKey('open-settings'),
                  onPressed: () => showAnalyzerSettings(context, c, null),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('open-settings')));
        await settle(tester);
        await tester.ensureVisible(
          find.byKey(const ValueKey('analyzer-calibration-auto')),
        );
        await send(tester, capture());
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(const ValueKey('analyzer-calibration-auto')),
        );
        await tester.tap(
          find.byKey(const ValueKey('analyzer-calibration-auto')),
        );
        await settle(tester);
        expect(find.text(tr('Messung starten')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text(tr('Abbrechen')));
        await tester.tap(find.text(tr('Abbrechen')));
        await settle(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await active(tester, c, false);
      },
    );
  }

  test(
    'calibrated frame preserves raw DSP and permits positive/negative offsets',
    () {
      final raw = rawFrame();
      for (final offset in [-40.0, 20.0, 40.0]) {
        final calibrated = raw.calibrated(offset);
        expect(calibrated.peak[0], -20 + offset);
        expect(
          calibrated.spectrum[0],
          closeTo(.1 * math.pow(10, offset / 20), 1e-9),
        );
        expect(calibrated.bandLevels[0], -20 + offset);
        expect(raw.peak, [-20, -20]);
        expect(raw.bandLevels[0], -20);
      }
    },
  );
}
