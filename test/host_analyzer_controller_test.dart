import 'package:adi2_remote/analyzer/analyzer_controller.dart';
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/host/host_analyzer_protocol.dart';
import 'package:adi2_remote/host/host_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:adi2_remote/ui/analyzer_controls.dart';
import 'package:adi2_remote/dev/analyzer_selftest.dart';
import 'package:adi2_remote/dev/analyzer_selftest_page.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'host_analyzer_protocol_test.dart' show transportFrame;

class AnalyzerTestHost extends HostClient {
  AnalyzerTestHost() {
    analyzerAvailable = true;
    analyzerPlatform = 'windows';
  }
  bool online = true;
  @override
  bool awaitingSilenceTimeout = false;
  final sent = <(String, Map<String, dynamic>)>[];
  @override
  bool get connected => online;
  @override
  void send(String type, [Map<String, dynamic> payload = const {}]) {
    sent.add((type, payload));
  }

  void changed() => notifyListeners();
}

class _HostDevice extends Adi2Controller {
  _HostDevice(HostClient host) : super(host: host) {
    state = ConnState.connected;
  }
  @override
  bool get viaHost => true;
  @override
  Adi2Variant get variant => Adi2Variant.dac;
  final values = offlineDefaults(Adi2Variant.dac);
  @override
  int? value(int address, int index) => values[address << 8 | index];
  @override
  int valueOr(int address, int index, int fallback) =>
      value(address, index) ?? fallback;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('adi2/analyzer'),
      (_) async => fail('Host source must not call native capture or tones'),
    );
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('adi2/analyzer'),
      null,
    );
  });

  testWidgets(
    'Host frames use calibration, envelopes and peak reset; ownership controls start/stop',
    (tester) async {
      final host = AnalyzerTestHost(), c = AnalyzerController();
      await c.setHostSource(host);
      final owner1 = Object(), owner2 = Object();
      await c.setActiveFor(owner1, true);
      await c.setActiveFor(owner2, true);
      expect(host.sent.map((m) => m.$1), ['analyzer_start']);
      host.analyzerEvents.add({
        'type': 'analyzer_frame',
        ...encodeHostAnalyzerFrame(transportFrame(48000, c.bandResolution)),
        'device': 'ADI-2 DAC',
        'calibrationIdentity': {
          'hostManufacturer': 'Windows',
          'hostModel': 'Studio PC',
          'usbName': 'ADI-2 DAC',
        },
      });
      expect(c.status, AnalyzerStatus.running);
      expect(c.canCalibrate, isTrue);
      expect(c.rawFrame?.peak.first, -0.1);
      final key = c.calibrationIdentity!.key;
      await AppSettings.instance.setAnalyzerCalibration(key, 2);
      expect(c.frame!.peak.first, closeTo(1.9, 0.001));
      c.spectrum.held[0] = 20;
      c.resetPeaks();
      expect(c.spectrum.held, c.spectrum.values);
      await c.setBandResolution(AnalyzerBandResolution.twelfth);
      await tester.pump();
      expect(host.sent.last.$1, 'analyzer_start');
      expect(host.sent.last.$2, {'bandResolution': 12});
      await expectLater(
        c.measureCalibration(useTestTone: true),
        throwsA(anything),
      );
      await c.setActiveFor(owner1, false);
      expect(host.sent.last.$1, 'analyzer_start');
      await c.setActiveFor(owner2, false);
      await tester.pump(const Duration(milliseconds: 500));
      expect(host.sent.last.$1, 'analyzer_stop');
      expect(c.frame, isNull);
      c.dispose();
      host.dispose();
    },
  );

  testWidgets(
    'v2 playout is bounded, envelopes and meters move between frames, stop cancels queued work',
    (tester) async {
      final host = AnalyzerTestHost()..analyzerVersion = 2;
      final c = AnalyzerController(host: host);
      await c.setActive(true);
      expect(host.sent.single.$2, {
        'bandResolution': c.bandResolution.bandsPerOctave,
        'analyzerVersion': 2,
        'bars': c.bars,
      });
      final source = transportFrame(48000, c.bandResolution);
      AnalyzerFrame level(double db) => AnalyzerFrame(
        sampleRate: 48000,
        spectrum: List.filled(source.spectrum.length, .1),
        bandResolution: c.bandResolution,
        bandLevels: List.filled(c.bandResolution.count, db),
        peak: [db, db],
        rms: [db, db],
        clipped: [false, false],
        seconds: .04,
      );
      void send(double db) => host.analyzerEvents.add({
        'type': 'analyzer_frame',
        ...encodeHostAnalyzerFrameV2(level(db), bars: true),
      });
      host.analyzerEvents.add({
        'type': 'analyzer_metadata',
        'v': 2,
        'sampleRate': 48000,
        'device': 'ADI-2 DAC',
        'calibrationIdentity': {
          'hostManufacturer': 'Windows',
          'hostModel': 'PC',
          'usbName': 'ADI-2 DAC',
        },
      });
      send(-10);
      expect(c.frame, isNull);
      await tester.pump(const Duration(milliseconds: 19));
      expect(c.frame, isNull);
      await tester.pump(const Duration(milliseconds: 1));
      expect(c.frame, isNotNull);
      expect(c.device, 'ADI-2 DAC');
      final key = c.calibrationIdentity!.key;
      send(-50);
      await tester.pump(const Duration(milliseconds: 20));
      final a = c.bands.values.first, meterA = c.frame!.displayPeak.first;
      await tester.pump(const Duration(milliseconds: 8));
      final b = c.bands.values.first, meterB = c.frame!.displayPeak.first;
      await tester.pump(const Duration(milliseconds: 8));
      final d = c.bands.values.first, meterD = c.frame!.displayPeak.first;
      expect(b, lessThan(a));
      expect(d, lessThan(b));
      expect(a - b, lessThan(1));
      expect(b - d, lessThan(1));
      expect(meterB, lessThan(meterA));
      expect(meterD, lessThan(meterB));
      expect(meterD, greaterThan(-50));
      expect(c.calibrationIdentity!.key, key);
      expect(c.device, 'ADI-2 DAC');
      // A short burst replaces the pending value; it cannot form a backlog.
      send(-30);
      await tester.pump(const Duration(milliseconds: 5));
      send(-20);
      await tester.pump(const Duration(milliseconds: 15));
      expect(c.rawFrame!.peak.first, -20);
      host.analyzerEvents.add({
        'type': 'analyzer_frame',
        ...encodeHostAnalyzerFrameV2(
          AnalyzerFrame(
            sampleRate: 48000,
            spectrum: source.spectrum,
            bandResolution: c.bandResolution,
            bandLevels: List.filled(c.bandResolution.count, 1),
            peak: [1, 1],
            rms: [-6, -6],
            clipped: [true, true],
            seconds: .04,
          ),
          bars: true,
        ),
      });
      send(-40);
      await tester.pump(const Duration(milliseconds: 20));
      expect(c.rawFrame!.peak, [1, 1]);
      expect(c.rawFrame!.clipped, [true, true]);
      expect(c.rawFrame!.bandLevels.first, -40);
      expect(c.rawFrame!.rms.first, closeTo(-9.0, .02));
      c.setBars(!c.bars);
      expect(host.sent.last.$2['bars'], c.bars);
      expect(host.sent.last.$2['analyzerVersion'], 2);
      send(-5);
      await c.setActive(false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(c.frame, isNull);
      expect(tester.binding.transientCallbackCount, 0);
      c.dispose();
      host.dispose();
    },
  );

  testWidgets(
    'Überbrückung friert Analyzer und Peak-hold ein und startet mit gleicher Auflösung weiter',
    (tester) async {
      final host = AnalyzerTestHost(), c = AnalyzerController(host: null);
      await c.setHostSource(host);
      await c.setBandResolution(AnalyzerBandResolution.twelfth);
      await c.setActive(true);
      void frame() => host.analyzerEvents.add({
        'type': 'analyzer_frame',
        ...encodeHostAnalyzerFrame(transportFrame(48000, c.bandResolution)),
        'device': 'ADI-2 DAC',
      });
      frame();
      c.spectrum.held[0] = 20;
      c.bands.held[0] = 30;
      final previous = c.frame;
      final starts = host.sent.where((m) => m.$1 == 'analyzer_start').length;
      host.changed(); // z. B. ein neuer Player-Status darf nicht neu starten.
      await tester.pump();
      expect(c.frame, same(previous));
      expect(
        host.sent.where((m) => m.$1 == 'analyzer_start'),
        hasLength(starts),
      );
      host.awaitingSilenceTimeout = true;
      await tester.pump(const Duration(seconds: 4));
      expect(c.status, AnalyzerStatus.running);
      expect(c.frame, same(previous));
      host.online = false;
      host.setReconnecting(true);
      await tester.pump(const Duration(seconds: 7));
      expect(c.status, AnalyzerStatus.running);
      expect(c.frame, same(previous));
      expect(c.spectrum.held[0], 20);
      expect(c.bands.held[0], 30);
      expect(c.inputErrorCode, isNull);
      host.online = true;
      host.changed(); // Authentifiziert, aber Geräteabgleich noch gesperrt.
      await tester.pump();
      expect(
        host.sent.where((m) => m.$1 == 'analyzer_start'),
        hasLength(starts),
      );
      host.setReconnecting(false);
      await tester.pump();
      expect(host.sent.last.$1, 'analyzer_start');
      expect(host.sent.last.$2, {'bandResolution': 12});
      expect(c.frame, same(previous));
      frame();
      expect(c.status, AnalyzerStatus.running);
      expect(c.spectrum.held[0], 20);
      expect(c.bands.held[0], 30);
      await c.setActive(false);
      c.dispose();
      host.dispose();
    },
  );

  test(
    'Host errors clear data, expose permission and recover on reconnect',
    () async {
      final host = AnalyzerTestHost(), c = AnalyzerController();
      await c.setHostSource(host);
      await c.setActive(true);
      host.analyzerEvents.add({
        'type': 'analyzer_error',
        'code': 'analyzer_permission',
      });
      expect(c.status, AnalyzerStatus.permissionRequired);
      expect(c.inputErrorCode, 'analyzer_permission');
      host.analyzerEvents.add({
        'type': 'analyzer_error',
        'code': 'analyzer_no_input',
      });
      expect(c.status, AnalyzerStatus.usbUnavailable);
      host.online = false;
      host.changed();
      await c.setActive(true);
      expect(c.inputErrorCode, 'analyzer_disconnected');
      host.online = true;
      host.changed();
      await c.setActive(true);
      expect(host.sent.last.$1, 'analyzer_start');
      await c.setActive(false);
      c.dispose();
      host.dispose();
    },
  );

  test(
    'Old host is left connected and receives no unsupported messages',
    () async {
      final host = AnalyzerTestHost()..analyzerAvailable = false;
      final c = AnalyzerController(host: host);
      await c.setActive(true);
      expect(c.inputErrorCode, 'analyzer_unsupported');
      expect(host.sent, isEmpty);
      expect(host.connected, isTrue);
      await c.setActive(false);
      c.dispose();
      host.dispose();
    },
  );
  testWidgets(
    'Host panel displays frames and OS permission help, with fullscreen available',
    (tester) async {
      final language = AppLang.instance.language;
      AppLang.instance.language = AppLanguage.de;
      final host = AnalyzerTestHost()..analyzerVersion = 2;
      final c = AnalyzerController();
      final device = _HostDevice(host);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: AnalyzerPanel(controller: c, deviceController: device),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      host.analyzerEvents.add({
        'type': 'analyzer_metadata',
        'v': 2,
        'sampleRate': 48000,
      });
      host.analyzerEvents.add({
        'type': 'analyzer_frame',
        ...encodeHostAnalyzerFrameV2(
          transportFrame(48000, c.bandResolution),
          bars: c.bars,
        ),
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('analyzer-spectrum')), findsOneWidget);
      await tester.tap(find.byTooltip('Vollbild'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('analyzer-spectrum')), findsOneWidget);
      expect(host.sent.where((m) => m.$1 == 'analyzer_start'), hasLength(1));
      host.analyzerEvents.add({
        'type': 'analyzer_error',
        'code': 'analyzer_permission',
      });
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Desktop-Apps Zugriff erlauben'),
        findsOneWidget,
      );
      host.analyzerPlatform = 'macos';
      c.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Remote for ADI-2 Host erlauben'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await c.setActive(false);
      c.dispose();
      device.dispose();
      AppLang.instance.language = language;
    },
  );

  testWidgets(
    'Host calibration hides tone switch and self-test entry cannot open',
    (tester) async {
      final host = AnalyzerTestHost(), c = AnalyzerController();
      final device = _HostDevice(host);
      await c.setHostSource(host);
      await c.setActive(true);
      host.analyzerEvents.add({
        'type': 'analyzer_frame',
        ...encodeHostAnalyzerFrame(transportFrame(48000, c.bandResolution)),
        'calibrationIdentity': {
          'hostManufacturer': 'Windows',
          'hostModel': 'PC',
          'usbName': 'ADI-2 DAC',
        },
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  AnalyzerSelfTestEntry(
                    ctrl: device,
                    child: const Text('version'),
                  ),
                  AnalyzerCalibrationSetting(
                    controller: c,
                    deviceController: device,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.text('version'));
      }
      await tester.pumpAndSettle();
      expect(find.byType(AnalyzerSelfTestPage), findsNothing);
      expect(MidiSelfTestDevice(device).connected, isFalse);
      await tester.tap(find.byKey(const ValueKey('analyzer-calibration-auto')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byKey(const ValueKey('calibration-test-tone')), findsNothing);
      expect(
        find.textContaining('only with a direct USB connection'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await c.setActive(false);
      c.dispose();
      device.dispose();
    },
  );
}
