import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/analyzer/analyzer_filter_bank.dart';
import 'package:adi2_remote/analyzer/test_signal.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

List<double> samples(Uint8List bytes, [int channel = 0]) {
  final data = ByteData.sublistView(bytes);
  return List.generate(
    bytes.length ~/ 8,
    (i) => data.getFloat32(i * 8 + channel * 4, Endian.little),
  );
}

void main() {
  for (final rate in [44100, 48000, 96000, 192000]) {
    for (final dbfs in [0.0, -6.0, -20.0, -60.0]) {
      test('sine peak/RMS/frequency $rate Hz $dbfs dBFS', () {
        final synth = TestSignalSynth(TestSignalSettings(dbfs: dbfs), rate);
        final signal = samples(synth.render(rate + rate ~/ 10))
            .sublist(rate ~/ 10);
        final peak = signal.map((v) => v.abs()).reduce(math.max);
        final rms = math.sqrt(
          signal.fold(0.0, (s, v) => s + v * v) / signal.length,
        );
        expect(20 * math.log(peak) / math.ln10, closeTo(dbfs, .01));
        expect(20 * math.log(rms) / math.ln10, closeTo(dbfs - 3.0103, .001));
        var crossings = 0;
        for (var i = 1; i < signal.length; i++) {
          if (signal[i - 1] <= 0 && signal[i] > 0) crossings++;
        }
        expect(crossings, inInclusiveRange(999, 1001));
      });
    }
  }

  test('all channel routes including exact opposite polarity', () {
    for (final channel in TestSignalChannel.values) {
      final synth = TestSignalSynth(
        TestSignalSettings(channel: channel),
        48000,
      );
      final data = synth.render(12000), l = samples(data), r = samples(data, 1);
      if (channel == TestSignalChannel.left) {
        expect(r, everyElement(0));
      }
      if (channel == TestSignalChannel.right) {
        expect(l, everyElement(0));
      }
      if (channel == TestSignalChannel.both) {
        expect(l, r);
      }
      if (channel == TestSignalChannel.opposite) {
        for (var i = 0; i < l.length; i++) {
          expect(l[i] + r[i], 0);
        }
      }
    }
  });

  test('20 ms start/stop envelope and chunk invariance', () {
    final settings = TestSignalSettings(frequency: 1234, dbfs: 0);
    final a = TestSignalSynth(settings, 48000),
        b = TestSignalSynth(settings, 48000);
    final whole = samples(a.render(6000));
    expect([...samples(b.render(137)), ...samples(b.render(5863))], whole);
    for (var i = 0; i < 960; i++) {
      expect(whole[i].abs(), lessThanOrEqualTo(i / 960 + 1e-7));
    }
    a.fadeOut();
    final tail = samples(a.render(48000));
    expect(tail.length, 960);
    expect(tail.last, 0);
    expect(a.finished, isTrue);
    for (var i = 0; i < tail.length; i++) {
      expect(tail[i].abs(), lessThanOrEqualTo((959 - i) / 960 + 1e-7));
    }
    expect(a.render(100), isEmpty);
  });

  test('third and level schedules follow fake time, stop exactly, never skip a band', () {
    for (final seconds in [1, 2, 5]) {
      final settings = TestSignalSettings(
        signal: TestSignal.thirds,
        stepSeconds: seconds,
      );
      fakeAsync((clock) {
        var current = settings.position(clock.elapsed);
        final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
          current = settings.position(clock.elapsed);
        });
        for (final frequency in testSignalThirds) {
          expect(current.frequency, frequency);
          clock.elapse(Duration(seconds: seconds));
        }
        expect(current.finished, isTrue);
        expect(current.progress, 1);
        timer.cancel();
      });
    }
    final settings = TestSignalSettings(signal: TestSignal.levels);
    final synth = TestSignalSynth(settings, 48000);
    for (final level in testSignalLevels) {
      final signal = samples(synth.render(3 * 48000));
      expect(signal.first, 0);
      expect(signal.last, 0);
      expect(
        amplitudeDb(signal.map((v) => v.abs()).reduce(math.max)),
        closeTo(level, .001),
      );
    }
    expect(synth.finished, isTrue);
    expect(synth.elapsed, const Duration(seconds: 15));
  });

  test(
    'log sweep integrates actual frequency and repeat resets with fades',
    () {
      const rate = 48000, seconds = 10;
      final settings = TestSignalSettings(
        signal: TestSignal.sweep,
        sweepSeconds: seconds,
        dbfs: 0,
      );
      final synth = TestSignalSynth(settings, rate);
      final all = samples(synth.render(rate * seconds));
      final ratio = math.pow(1000, 1 / (seconds * rate));
      for (final n in [4800, 48000, 240000, 432000]) {
        final phase =
            2 * math.pi * 20 / rate * (math.pow(ratio, n) - 1) / (ratio - 1);
        expect(all[n], closeTo(math.sin(phase), .00001));
      }
      expect(all.last, 0);
      expect(synth.finished, isTrue);
      final loop = TestSignalSettings(
        signal: TestSignal.sweep,
        sweepSeconds: 10,
        repeat: true,
      );
      final looping = TestSignalSynth(loop, rate);
      looping.render(rate * 10);
      expect(looping.finished, isFalse);
      expect(samples(looping.render(1)).single, 0);
      expect(loop.position(const Duration(seconds: 10)).frequency, 20);
      expect(
        loop.position(const Duration(seconds: 15)).frequency,
        closeTo(math.sqrt(20 * 20000), .001),
      );
    },
  );

  test(
    'white noise is bounded, deterministic and has expected uniform RMS',
    () {
      final settings = TestSignalSettings(signal: TestSignal.white);
      final a = TestSignalSynth(settings, 48000),
          b = TestSignalSynth(settings, 48000);
      final signal = samples(a.render(480000)).sublist(4800);
      expect(samples(b.render(480000)).sublist(4800), signal);
      expect(
        signal.map((v) => v.abs()).reduce(math.max),
        lessThanOrEqualTo(.10000001),
      );
      final mean = signal.reduce((a, b) => a + b) / signal.length;
      final power = signal.fold(0.0, (a, b) => a + b * b) / signal.length;
      expect(mean, closeTo(0, .0003));
      expect(power, closeTo(.01 / 3, .00003));
    },
  );

  for (final rate in [44100, 48000, 96000]) {
    test('pink equal third-octave energy ±1 dB at $rate Hz', () {
      final period = testSignalPinkNoise(rate);
      expect(period.map((v) => v.abs()).reduce(math.max), closeTo(1, 1e-12));
      double binPower(int bin) {
        final coefficient = 2 * math.cos(2 * math.pi * bin / period.length);
        var a = 0.0, b = 0.0;
        for (final sample in period) {
          final next = sample + coefficient * a - b;
          b = a;
          a = next;
        }
        return a * a + b * b - coefficient * a * b;
      }

      final referenceBin = (1000 * period.length / rate).round();
      final reference = binPower(referenceBin) * referenceBin;
      // Independent Goertzel projections, including the 20 Hz and 20 kHz
      // endpoints, validate 1/f power without using the generator's FFT.
      for (final frequency in testSignalThirds) {
        final bin = (frequency * period.length / rate).round();
        final relativeDb =
            10 * math.log(binPower(bin) * bin / reference) / math.ln10;
        expect(relativeDb, closeTo(0, .001), reason: '$frequency Hz spectrum');
      }
      final bank = AnalyzerFilterBank(rate, AnalyzerBandResolution.third);
      final sums = List.filled(bank.filters.length, 0.0);
      for (var i = 0; i < period.length * 2; i++) {
        final value = period[i % period.length];
        bank.process(value, value);
        if (i >= period.length && i % 64 == 0) {
          final levels = bank.levels;
          for (var band = 0; band < sums.length; band++) {
            sums[band] += math.pow(10, levels[band] / 10);
          }
        }
      }
      final db = sums.map((p) => 10 * math.log(p) / math.ln10).toList();
      final mean = db.reduce((a, b) => a + b) / db.length;
      // The 20 kHz third extends above Nyquist at 44.1 kHz. Its full
      // energy cannot be measured by this warped bandpass there; check the
      // actual 20 kHz spectral density independently below instead.
      for (var i = 0; i < db.length - (rate == 44100 ? 1 : 0); i++) {
        expect(db[i], closeTo(mean, 1), reason: 'band $i at $rate Hz');
      }
    });
  }

  test(
    'reject invalid parameters; high-level approval includes fixed level steps',
    () {
      expect(
        () => TestSignalSettings(frequency: double.nan),
        throwsArgumentError,
      );
      expect(() => TestSignalSettings(frequency: 20001), throwsArgumentError);
      expect(() => TestSignalSettings(dbfs: 1), throwsArgumentError);
      expect(() => TestSignalSettings(dbfs: -61), throwsArgumentError);
      expect(() => TestSignalSettings(stepSeconds: 0), throwsArgumentError);
      expect(() => TestSignalSettings(sweepSeconds: 11), throwsArgumentError);
      expect(TestSignalSettings().requiresHighLevel, isFalse);
      expect(TestSignalSettings(dbfs: -6).requiresHighLevel, isFalse);
      expect(TestSignalSettings(dbfs: -5).requiresHighLevel, isTrue);
      expect(
        TestSignalSettings(signal: TestSignal.levels).requiresHighLevel,
        isTrue,
      );
    },
  );
}
