import 'dart:async';

import 'package:adi2_host/host_analyzer.dart';
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/host/host_analyzer_protocol.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'analyzer_capture_fake.dart';

void main() {
  for (final fps in [30, 60]) {
    test(
      '$fps fps local client and unchanged 50 fps phone preserve transients',
      () {
        fakeAsync((clock) {
          final capture = FakeAnalyzerCapture();
          final host = HostAnalyzer(capture: capture, now: () => clock.elapsed);
          final local = <Map<String, dynamic>>[],
              phone = <Map<String, dynamic>>[];
          final times = <Duration>[];
          unawaited(
            host.start(
              'local',
              AnalyzerBandResolution.third,
              (type, data) {
                if (type == 'analyzer_frame') {
                  local.add(data);
                  times.add(clock.elapsed);
                }
              },
              version: 2,
              fps: fps,
              bars: true,
            ),
          );
          unawaited(
            host.start(
              'phone',
              AnalyzerBandResolution.third,
              (type, data) {
                if (type == 'analyzer_frame') phone.add(data);
              },
              version: 2,
              bars: true,
            ),
          );
          clock.flushMicrotasks();
          // 30 fps uses its own half-rate analysis; 60 fps shares the phone's.
          expect(host.analysisCount, fps <= 30 ? 2 : 1);
          for (var i = 0; i < 60; i++) {
            capture.input.add({
              'sampleRate': 48000,
              'pcm': List<double>.filled(1600, i == 1 ? 1 : .1),
            });
            clock.elapse(const Duration(microseconds: 16667));
          }
          expect(local.length, inInclusiveRange(fps - 1, fps + 1));
          expect(phone.length, inInclusiveRange(49, 51));
          for (var i = 1; i < times.length; i++) {
            expect(
              (times[i] - times[i - 1]).inMicroseconds,
              greaterThanOrEqualTo((1000000 / fps).ceil()),
            );
          }
          expect(local.any((m) => m['c'] == 3), true);
          final decoded = local.map(
            (m) => decodeHostAnalyzerFrame({'sampleRate': 48000, ...m}),
          );
          expect(
            decoded.fold<double>(0, (sum, f) => sum + f.seconds),
            closeTo(1, .06),
          );
          unawaited(host.dispose());
          clock.flushMicrotasks();
          expect(clock.nonPeriodicTimerCount, 0);
          unawaited(capture.input.close());
          clock.flushMicrotasks();
        });
      },
    );
  }

  test('Meter-only DSP matches spectral meters while emitting no spectrum or bands', () {
    final full = AnalyzerDsp(), meters = AnalyzerDsp(spectrumAnalysis: false);
    final pcm = List<double>.generate(1600, (i) => i % 3 == 0 ? 1 : .1);
    for (var i = 0; i < 6; i++) {
      final a = full.add(pcm, 48000).single;
      final b = meters.add(pcm, 48000).single;
      expect(b.peak, a.peak);
      expect(b.rms, a.rms);
      expect(b.meterPeak, a.meterPeak);
      expect(b.meterRms, a.meterRms);
      expect(b.clipped, a.clipped);
      expect(b.spectrum, isEmpty);
      expect(b.bassSpectrum, isEmpty);
      expect(b.bandLevels, isEmpty);
      final encoded = encodeHostAnalyzerFrameV2(b, levelsOnly: true);
      final decoded = decodeHostAnalyzerFrame({
        'sampleRate': 48000,
        ...encoded,
      });
      expect(decoded.spectrum, isEmpty);
      expect(decoded.peak.first, closeTo(b.peak.first, .5));
    }
  });
}
