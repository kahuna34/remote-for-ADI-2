import 'dart:async';
import 'dart:math' as math;

import 'package:adi2_remote/analyzer/analyzer_controller.dart';
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('adi2/analyzer');
  const events = MethodChannel('adi2/analyzer/events');
  final calls = <String>[];
  var allowed = true;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
    calls.clear();
    allowed = true;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(method, (
      call,
    ) async {
      calls.add(call.method);
      if (call.method == 'permission') return allowed;
      if (call.method == 'requestPermission') {
        allowed = true;
        return true;
      }
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      events,
      (_) async => null,
    );
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(method, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null);
  });
  Future<void> event(Map<String, dynamic> data) async {
    binding.channelBuffers.push(
      'adi2/analyzer/events',
      const StandardMethodCodec().encodeSuccessEnvelope(data),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  Map<String, dynamic> frame({double peak = -6, int rate = 48000}) => {
    'sampleRate': rate,
    'spectrum': List.filled(2049, 0.1),
    'peak': [peak, peak],
    'rms': [peak - 3, peak - 3],
    'clipped': [false, false],
    'seconds': 0.5,
  };
  test(
    'route failure clears meters and preserves actual microphone diagnostics',
    () async {
      final c = AnalyzerController();
      await c.setActive(true);
      await event(frame());
      await event({
        'status': 'routeMismatch',
        'diagnostics': {
          'routedDevice': {
            'name': 'Built-in mic',
            'type': 15,
            'id': 8,
            'phoneMicrophone': true,
          },
          'requestedDevice': {'name': 'ADI-2 DAC', 'type': 11, 'id': 17},
        },
      });
      expect(c.status, AnalyzerStatus.usbUnavailable);
      expect(c.phoneMicrophone, isTrue);
      expect(c.device, isNull);
      expect(c.frame, isNull);
      expect(c.bands.values, isEmpty);
      expect(c.diagnosticText, contains('Built-in mic (Typ 15, ID 8)'));
      await event(frame()); // A queued, unverified frame cannot hide the error.
      expect(c.frame, isNull);
      await c.retry();
      await event({...frame(), 'routeVerified': true, 'device': 'ADI-2 DAC'});
      expect(c.status, AnalyzerStatus.running);
      expect(c.phoneMicrophone, isFalse);
      await c.setActive(false);
      expect(c.diagnostics, isEmpty);
      c.dispose();
    },
  );

  test(
    'band changes rebuild envelopes and persist across controller lifetimes',
    () async {
      final c = AnalyzerController();
      await c.setActive(true);
      await event(frame());
      expect(c.bands.values.length, 30);
      for (final resolution in AnalyzerBandResolution.values) {
        await c.setBandResolution(resolution);
        expect(c.bands.values.length, resolution.count);
        expect(c.bands.held.length, resolution.count);
      }
      expect(
        (await SharedPreferences.getInstance()).getInt(
          'analyzer_bands_per_octave',
        ),
        12,
      );
      await c.setActive(false);
      expect(c.bands.values, isEmpty);
      c.dispose();
      final fresh = AnalyzerController();
      expect(fresh.bandResolution, AnalyzerBandResolution.twelfth);
      fresh.dispose();
    },
  );
  test('native band levels and integrated meters survive the event channel; resolution updates without restart', () async {
    final messages = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(method, (
      call,
    ) async {
      messages.add(call);
      return call.method == 'permission' ? true : null;
    });
    final c = AnalyzerController();
    await c.setActive(true);
    expect(messages.firstWhere((m) => m.method == 'start').arguments, {
      'bandsPerOctave': 3,
    });
    await event({
      ...frame(),
      'spectrum': List.filled(1025, 0),
      'bandLevels': List.filled(30, -12.0),
      'bandsPerOctave': 3,
      'meterPeak': [-2.0, -4.0],
      'meterRms': [-9.0, -11.0],
    });
    expect(c.bands.values, everyElement(-12));
    expect(c.frame!.displayPeak, [-2, -4]);
    expect(c.frame!.displayRms, [-9, -11]);
    await c.setBandResolution(AnalyzerBandResolution.twelfth);
    expect(messages.last.method, 'setBandResolution');
    expect(messages.last.arguments, {'bandsPerOctave': 12});
    await event({
      ...frame(),
      'bandLevels': List.filled(117, -6.0),
      'bandsPerOctave': 12,
    });
    expect(c.bands.values, everyElement(-6));
    expect(messages.where((m) => m.method == 'start').length, 1);
    await c.setActive(false);
    expect(c.bassSpectrum.values, isEmpty);
    c.dispose();
  });
  test('continuous batched PCM uses the filter bank, meters and actual rate, then resets on rate change', () async {
    final c = AnalyzerController();
    await c.setActive(true);
    await c.setBandResolution(AnalyzerBandResolution.twelfth);
    final pcm = List.generate(
      9600,
      (i) =>
          math.sin(2 * math.pi * 1000 * (i ~/ 2) / 48000) * (i.isOdd ? .5 : 1),
    );
    await event({'pcm': pcm, 'sampleRate': 48000, 'device': 'ADI-2'});
    expect(c.frame!.seconds, 1 / 60);
    expect(c.frame!.bandLevels.length, 117);
    expect(c.bands.values[64], closeTo(0, .1));
    expect(c.frame!.displayPeak[1], closeTo(-6.0206, .03));
    expect(c.frame!.displayRms[0], lessThan(c.frame!.rms[0]));
    await event({'pcm': List.filled(3200, 0.0), 'sampleRate': 96000});
    expect(c.frame!.sampleRate, 96000);
    expect(c.frame!.meterRms, [-120, -120]);
    expect(c.bands.values, everyElement(-120));
    await c.setActive(false);
    c.dispose();
  });
  for (final platform in [TargetPlatform.macOS, TargetPlatform.iOS]) {
    test(
      '$platform PCM uses shared DSP at every resolution and clears on hide',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final c = AnalyzerController();
        final route = {
          'hostManufacturer': 'macOS',
          'hostModel': 'Mac test host',
          'usbName': 'ADI-2 DAC',
          'usbSerial': '123',
        };
        await c.setActive(true);
        final pcm = List.generate(
          19200,
          (i) => math.sin(2 * math.pi * 1000 * (i ~/ 2) / 48000) * .5,
        );
        for (final resolution in AnalyzerBandResolution.values) {
          await c.setBandResolution(resolution);
          await event({
            'pcm': pcm,
            'sampleRate': 48000,
            'device': 'ADI-2 DAC',
            'calibrationIdentity': route,
            'routeVerified': true,
          });
          expect(c.status, AnalyzerStatus.running);
          expect(c.rawFrame!.bandLevels.length, resolution.count);
          expect(c.rawFrame!.bandResolution, resolution);
          expect(c.rawFrame!.peak[0], closeTo(-6.0206, .03));
          expect(
            c.rawFrame!.bandLevels[16 * resolution.bandsPerOctave ~/ 3],
            closeTo(-6.0206, .1),
          );
          expect(c.canCalibrate, isTrue);
        }
        await c.saveCalibration(c.calibrationProposal(6));
        expect(c.frame!.peak[0], closeTo(0, .04));
        await event({'status': 'usbUnavailable'});
        expect(c.frame, isNull);
        expect(c.calibrationIdentity, isNull);
        expect(c.canCalibrate, isFalse);
        await c.setActive(false);
        await c.setActive(true);
        await event({
          'pcm': List.filled(19200, 0.0),
          'sampleRate': 48000,
          'calibrationIdentity': route,
        });
        expect(c.calibrationOffset, 6);
        expect(c.rawFrame!.bandLevels, everyElement(-120));
        await c.setActive(false);
        expect(c.frame, isNull);
        expect(c.calibrationIdentity, isNull);
        expect(c.bands.values, isEmpty);
        c.dispose();
      },
    );
  }
  test(
    'permission is requested only explicitly, start/stop are idempotent',
    () async {
      final c = AnalyzerController();
      allowed = false;
      await c.setActive(true);
      expect(c.status, AnalyzerStatus.permissionRequired);
      expect(calls, ['permission']);
      await c.requestPermission();
      expect(calls.where((v) => v == 'start').length, 1);
      await c.setActive(true);
      expect(calls.where((v) => v == 'start').length, 1);
      await c.setActive(false);
      await c.setActive(false);
      expect(calls.where((v) => v == 'stop').length, 1);
      c.dispose();
    },
  );
  test(
    'frames report silence, recover, and clear on disconnect and stop',
    () async {
      final c = AnalyzerController();
      await c.setActive(true);
      await event(frame());
      expect(c.status, AnalyzerStatus.running);
      for (var i = 0; i < 4; i++) {
        await event(frame(peak: -120));
      }
      expect(c.status, AnalyzerStatus.silent);
      await event(frame());
      expect(c.status, AnalyzerStatus.running);
      await event({'status': 'usbUnavailable'});
      expect(c.status, AnalyzerStatus.usbUnavailable);
      expect(c.frame, isNull);
      await c.retry();
      await event(frame(rate: 96000));
      expect(c.frame!.sampleRate, 96000);
      await c.setActive(false);
      expect(c.frame, isNull);
      expect(c.spectrum.values, isEmpty);
      c.dispose();
    },
  );
  test(
    'hide during in-flight start releases capture when start completes',
    () async {
      final start = Completer<void>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(method, (
        call,
      ) async {
        calls.add(call.method);
        if (call.method == 'permission') return true;
        if (call.method == 'start') await start.future;
        return null;
      });
      final c = AnalyzerController();
      final starting = c.setActive(true);
      await Future<void>.delayed(Duration.zero);
      final stopping = c.setActive(false);
      start.complete();
      await starting;
      await stopping;
      expect(calls, ['permission', 'start', 'stop']);
      expect(c.status, AnalyzerStatus.idle);
      c.dispose();
    },
  );
}
