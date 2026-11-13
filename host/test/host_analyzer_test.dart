import 'dart:async';
import 'dart:math' as math;

import 'package:adi2_host/host_analyzer.dart';
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/host/host_analyzer_protocol.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';

import 'analyzer_capture_fake.dart';

void main() {
  late FakeAnalyzerCapture capture;
  late HostAnalyzer analyzer;
  late Duration now;
  final frames = <Map<String, dynamic>>[], errors = <String>[];
  void send(String type, Map<String, dynamic> data) {
    if (type == 'analyzer_frame') frames.add(data);
    if (type == 'analyzer_error') errors.add(data['code'] as String);
  }

  Map<String, dynamic> pcm({double amplitude = 0.2, int rate = 48000}) => {
    'sampleRate': rate,
    'pcm': List.generate(
      (rate / 60).round() * 2,
      (i) => amplitude * math.sin(2 * math.pi * 1000 * (i ~/ 2) / rate),
    ),
    'device': 'ADI-2 DAC',
  };
  setUp(() {
    capture = FakeAnalyzerCapture();
    now = Duration.zero;
    analyzer = HostAnalyzer(capture: capture, now: () => now);
    frames.clear();
    errors.clear();
  });
  tearDown(() async {
    await analyzer.dispose();
    await capture.input.close();
  });

  test('Capture starts only on demand, DSP shared per resolution, stops at last owner', () async {
    expect(capture.starts, 0);
    await analyzer.start('a', AnalyzerBandResolution.third, send);
    await analyzer.start('b', AnalyzerBandResolution.third, send);
    final fine = <Map<String, dynamic>>[];
    await analyzer.start('c', AnalyzerBandResolution.twelfth, (type, data) {
      if (type == 'analyzer_frame') fine.add(data);
    });
    expect(capture.starts, 1);
    expect(analyzer.analysisCount, 2);
    capture.input.add(pcm());
    expect(frames, hasLength(2));
    expect(fine, hasLength(1));
    expect(
      decodeHostAnalyzerFrame(frames.first).bandResolution,
      AnalyzerBandResolution.third,
    );
    expect(decodeHostAnalyzerFrame(fine.first).bandLevels, hasLength(117));
    await analyzer.start('b', AnalyzerBandResolution.sixth, send);
    expect(analyzer.analysisCount, 3);
    await analyzer.stop('a');
    expect(analyzer.analysisCount, 2);
    await analyzer.stop('b');
    expect(analyzer.analysisCount, 1);
    expect(capture.stops, 0);
    await analyzer.stop('c');
    expect(capture.stops, 1);
    expect(analyzer.analysisCount, 0);
    capture.input.add(pcm());
    expect(frames, hasLength(2));
    await analyzer.stop('c');
    expect(capture.stops, 1);
  });

  test(
    'v2 holds frames while the app lags behind and coalesces them',
    () async {
      final sent = <Map<String, dynamic>>[];
      void receive(String type, Map<String, dynamic> data) {
        if (type == 'analyzer_frame') sent.add(data);
      }

      await analyzer.start(
        'slow',
        AnalyzerBandResolution.third,
        receive,
        version: 2,
      );
      analyzer.acknowledge('slow', 0);
      for (var i = 0; i < 40; i++) {
        capture.input.add(pcm());
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      // Ohne Bestätigung höchstens maxInFlight + 1 Bilder unterwegs.
      expect(sent.length, hostAnalyzerMaxInFlight + 1);
      analyzer.acknowledge('slow', sent.length);
      capture.input.add(pcm());
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(sent.length, greaterThan(hostAnalyzerMaxInFlight + 1));
    },
  );

  test('Rate cap has no burst and retains elapsed seconds, transient peaks and clipping', () async {
    await analyzer.start('a', AnalyzerBandResolution.third, send);
    capture.input.add(pcm());
    expect(frames, hasLength(1));
    capture.input.add(pcm(amplitude: 1.1));
    for (var i = 0; i < 5; i++) {
      capture.input.add(pcm(amplitude: 0.01));
    }
    expect(frames, hasLength(1));
    now = hostAnalyzerLegacyInterval;
    capture.input.add(pcm(amplitude: 0.01));
    expect(frames, hasLength(2));
    final f = decodeHostAnalyzerFrame(frames.last);
    expect(f.clipped, [true, true]);
    expect(f.peak.first, greaterThan(0));
    expect(f.seconds, closeTo(7 / 60, 0.0001));
    now += const Duration(seconds: 2);
    capture.input.add({
      'sampleRate': 48000,
      'pcm': List<double>.filled(24000, 0),
    });
    expect(
      frames,
      hasLength(3),
    ); // A large block never produces a network burst.
    now += hostAnalyzerLegacyInterval;
    capture.input.add(pcm());
    expect(frames, hasLength(4));
    expect(decodeHostAnalyzerFrame(frames.last).seconds, closeTo(0.25, 0.0001));
  });

  test(
    'v2 sends metadata once per client and only on route or rate changes',
    () async {
      final messages = <(String, Map<String, dynamic>)>[];
      void receive(String type, Map<String, dynamic> data) =>
          messages.add((type, data));
      await analyzer.start(
        'v2',
        AnalyzerBandResolution.twelfth,
        receive,
        version: 2,
      );
      final input = {
        ...pcm(),
        'calibrationIdentity': {'hostModel': 'PC', 'usbSerial': '123'},
      };
      capture.input.add(input);
      expect(messages.map((v) => v.$1), [
        'analyzer_metadata',
        'analyzer_frame',
      ]);
      expect(messages.first.$2['sampleRate'], 48000);
      expect(messages.last.$2.containsKey('device'), isFalse);
      expect(messages.last.$2.containsKey('sampleRate'), isFalse);
      now += hostAnalyzerInterval;
      capture.input.add(input);
      expect(messages.where((v) => v.$1 == 'analyzer_metadata'), hasLength(1));
      await analyzer.start(
        'v2',
        AnalyzerBandResolution.sixth,
        receive,
        version: 2,
        bars: true,
      );
      now += hostAnalyzerInterval;
      capture.input.add(input);
      expect(messages.where((v) => v.$1 == 'analyzer_metadata'), hasLength(1));
      expect(messages.last.$2.containsKey('b'), isTrue);
      expect(messages.last.$2.containsKey('s'), isFalse);
      now += hostAnalyzerInterval;
      capture.input.add({
        ...input,
        'calibrationIdentity': {'hostModel': 'PC', 'usbSerial': '456'},
      });
      expect(messages.where((v) => v.$1 == 'analyzer_metadata'), hasLength(2));
      now += hostAnalyzerInterval;
      capture.input.add({...pcm(rate: 96000), 'device': 'ADI-2 Pro'});
      expect(messages.where((v) => v.$1 == 'analyzer_metadata'), hasLength(3));
      expect(messages[messages.length - 2].$2['sampleRate'], 96000);
      await analyzer.start(
        'new',
        AnalyzerBandResolution.sixth,
        receive,
        version: 2,
      );
      now += hostAnalyzerInterval;
      capture.input.add({...pcm(rate: 96000), 'device': 'ADI-2 Pro'});
      expect(messages.where((v) => v.$1 == 'analyzer_metadata'), hasLength(4));
      await analyzer.stop('v2');
      await analyzer.start(
        'v2',
        AnalyzerBandResolution.sixth,
        receive,
        version: 2,
      );
      now += hostAnalyzerInterval;
      capture.input.add({...pcm(rate: 96000), 'device': 'ADI-2 Pro'});
      expect(messages.where((v) => v.$1 == 'analyzer_metadata'), hasLength(5));
    },
  );

  test(
    '20 ms timer yields exactly 50 fps from 60 Hz PCM without catch-up bursts',
    () {
      fakeAsync((clock) {
        final input = FakeAnalyzerCapture();
        final times = <Duration>[];
        final host = HostAnalyzer(capture: input, now: () => clock.elapsed);
        unawaited(
          host.start('a', AnalyzerBandResolution.third, (type, data) {
            if (type == 'analyzer_frame') times.add(clock.elapsed);
          }, version: 2),
        );
        clock.flushMicrotasks();
        input.input.add(pcm());
        for (var i = 1; i < 60; i++) {
          clock.elapse(const Duration(microseconds: 16667));
          input.input.add(pcm());
        }
        expect(times, hasLength(50));
        for (var i = 1; i < times.length; i++) {
          expect(times[i] - times[i - 1], hostAnalyzerInterval);
        }
        clock.elapse(const Duration(seconds: 2));
        final afterStall = times.length;
        input.input.add(pcm());
        expect(times.length - afterStall, 1);
        unawaited(host.stop('a'));
        clock.flushMicrotasks();
        final stopped = times.length;
        clock.elapse(const Duration(seconds: 1));
        expect(times, hasLength(stopped));
        expect(clock.nonPeriodicTimerCount, 0);
        unawaited(host.dispose());
        unawaited(input.input.close());
        clock.flushMicrotasks();
      });
    },
  );

  test('Permission/start/stream/device errors reach every requester, stop capture and allow retry', () async {
    capture.failure = PlatformException(code: 'analyzer_permission');
    await analyzer.start('a', AnalyzerBandResolution.third, send);
    await Future<void>.delayed(Duration.zero);
    expect(errors, ['analyzer_permission']);
    expect(capture.stops, 1);
    capture.failure = null;
    await analyzer.start('a', AnalyzerBandResolution.third, send);
    await analyzer.start('b', AnalyzerBandResolution.sixth, send);
    capture.input.add({'status': 'usbUnavailable'});
    await Future<void>.delayed(Duration.zero);
    expect(errors, [
      'analyzer_permission',
      'analyzer_no_input',
      'analyzer_no_input',
    ]);
    expect(capture.stops, 2);
    expect(analyzer.analysisCount, 0);
    await analyzer.start('a', AnalyzerBandResolution.third, send);
    capture.input.addError(PlatformException(code: 'analyzer_permission'));
    await Future<void>.delayed(Duration.zero);
    expect(errors.last, 'analyzer_permission');
    expect(capture.stops, 3);
    await analyzer.start('a', AnalyzerBandResolution.third, send);
    capture.input.add({
      'sampleRate': 0,
      'pcm': [0.0, 0.0],
    });
    await Future<void>.delayed(Duration.zero);
    expect(errors.last, 'analyzer_no_input');
    expect(capture.stops, 4);
  });

  test(
    'Last stop during asynchronous native start leaves no capture alive',
    () async {
      capture.starting = Completer<void>();
      final start = analyzer.start('a', AnalyzerBandResolution.third, send);
      await Future<void>.delayed(Duration.zero);
      final stop = analyzer.stop('a');
      capture.input.add(pcm());
      expect(frames, isEmpty);
      capture.starting!.complete();
      await start;
      await stop;
      expect(capture.starts, 1);
      expect(capture.stops, 1);
    },
  );

  test('Sample rate changes preserve frequency spacing and discard old aggregate meters', () async {
    await analyzer.start('a', AnalyzerBandResolution.third, send);
    capture.input.add(pcm(amplitude: 1.1));
    capture.input.add(pcm(amplitude: 1.1));
    now += hostAnalyzerLegacyInterval;
    capture.input.add(pcm(rate: 96000, amplitude: 0.01));
    final f = decodeHostAnalyzerFrame(frames.last);
    expect(f.sampleRate, 96000);
    expect(f.binHz, 96000 / analyzerFastSize(96000));
    expect(f.peak.first, closeTo(-40, 0.1));
    expect(f.clipped, [false, false]);
  });
  test('Immediate stop/start and error/retry replace the stale native subscription', () async {
    await analyzer.start('a', AnalyzerBandResolution.third, send);
    final stopping = analyzer.stop('a');
    final starting = analyzer.start('a', AnalyzerBandResolution.sixth, send);
    await stopping;
    await starting;
    expect(capture.starts, 2);
    expect(capture.stops, 1);
    capture.input.add(pcm());
    expect(frames, hasLength(1));
    capture.input.add({'status': 'usbUnavailable'});
    await analyzer.start('a', AnalyzerBandResolution.twelfth, send);
    expect(capture.starts, 3);
    expect(capture.stops, 2);
    capture.input.add(pcm());
    expect(frames, hasLength(2));
    expect(
      decodeHostAnalyzerFrame(frames.last).bandResolution,
      AnalyzerBandResolution.twelfth,
    );
  });
}
