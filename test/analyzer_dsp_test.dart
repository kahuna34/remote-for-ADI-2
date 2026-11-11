import 'dart:math' as math;
import 'dart:typed_data';

import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/analyzer/analyzer_filter_bank.dart';
import 'package:flutter_test/flutter_test.dart';

List<double> tone(
  int n,
  double frequency, {
  double rightGain = 1,
  int rate = 48000,
  int offset = 0,
}) => List.generate(
  n * 2,
  (i) =>
      math.sin(2 * math.pi * frequency * (offset + i ~/ 2) / rate) *
      (i.isOdd ? rightGain : 1),
);

/// Periodic pink noise: equal expected power per octave, exact 1/f bin power,
/// independent random phases. Inverse radix-2 FFT avoids a flaky short random
/// recording in the narrowest bass bands; all bins remain present.
List<double> pinkPeriod([int n = 262144]) {
  final re = Float64List(n), im = Float64List(n);
  final random = math.Random(6512);
  for (var k = 1; k < n ~/ 2; k++) {
    final phase = random.nextDouble() * 2 * math.pi;
    final amplitude = 1 / math.sqrt(k);
    re[k] = re[n - k] = amplitude * math.cos(phase);
    im[k] = amplitude * math.sin(phase);
    im[n - k] = -im[k];
  }
  for (int i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final a = re[i];
      re[i] = re[j];
      re[j] = a;
      final b = im[i];
      im[i] = im[j];
      im[j] = b;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    for (var start = 0; start < n; start += len) {
      for (var j = 0; j < len ~/ 2; j++) {
        final w = 2 * math.pi * j / len, c = math.cos(w), s = math.sin(w);
        final a = start + j, b = a + len ~/ 2;
        final r = re[b] * c - im[b] * s, v = re[b] * s + im[b] * c;
        re[b] = re[a] - r;
        im[b] = im[a] - v;
        re[a] += r;
        im[a] += v;
      }
    }
  }
  return re.map((v) => v * .02).toList();
}

void main() {
  test('USB tap level remains absolute: post minus 6 dB lowers bands and meters by 6', () {
    final values = <List<double>>[];
    for (final db in [-12.0, -18.0]) {
      final gain = math.pow(10, db / 20).toDouble();
      final bank = AnalyzerFilterBank(48000, AnalyzerBandResolution.third);
      final meters = AnalyzerMeters(48000);
      for (var i = 0; i < 96000; i++) {
        final sample = gain * math.sin(2 * math.pi * 1000 * i / 48000);
        bank.process(sample, 0); // hard-panned source must keep its full level
        meters.process(sample, 0);
      }
      final reading = [bank.levels[16], meters.peak[0], meters.rms[0]];
      expect(reading[0], closeTo(db, .1));
      expect(reading[1], closeTo(db, .01));
      expect(reading[2], closeTo(db - 3.0103, .02));
      values.add(reading);
    }
    for (var i = 0; i < 3; i++) {
      expect(values[1][i] - values[0][i], closeTo(-6, 1e-8));
    }
  });
  test(
    'periodic Hann coherent gain, scalloping-corrected 1 kHz line and ENBW',
    () {
      final dsp = AnalyzerDsp(size: 4096);
      expect(dsp.window.reduce((a, b) => a + b), closeTo(2048, 1e-8));
      final exact = dsp.analyze(tone(4096, 1500), 48000);
      expect(amplitudeDb(exact.spectrum[128]), closeTo(0, 1e-7));
      expect(exact.spectrum[127], closeTo(.5, 1e-7));
      for (final size in [2048, 4096, 8192]) {
        final f = AnalyzerDsp(size: size).analyze(tone(size, 1000), 48000);
        expect(analyzerLineDb(f.spectrum).reduce(math.max), closeTo(0, .5));
        expect(thirdOctaveDb(f)[16], closeTo(0, .01));
      }
    },
  );
  test(
    'band integration sums two tone powers rather than amplitudes or averages',
    () {
      final pcm = List.generate(8192, (i) {
        final t = (i ~/ 2) / 48000;
        return .5 * math.sin(2 * math.pi * 960 * t) +
            .5 * math.sin(2 * math.pi * 1040 * t);
      });
      final frame = AnalyzerDsp(size: 4096).analyze(pcm, 48000);
      expect(thirdOctaveDb(frame)[16], closeTo(-3.0103, .03));
    },
  );
  test(
    'quadrature detector keeps bass steady without long RMS integration',
    () {
      for (final r in AnalyzerBandResolution.values) {
        for (final band in [0, 4 * r.bandsPerOctave ~/ 3]) {
          final bank = AnalyzerFilterBank(48000, r), hz = r.centre(band);
          final settle = (48000 * math.max(.4, 100 / hz)).round();
          var min = 12.0, max = -120.0;
          for (var i = 0; i < settle + 4800; i++) {
            final v = math.sin(2 * math.pi * hz * i / 48000);
            bank.process(v, -v);
            if (i >= settle && i % 800 == 0) {
              final db = bank.levels[band];
              min = math.min(min, db);
              max = math.max(max, db);
            }
          }
          expect(min, greaterThan(-.1));
          expect(max, lessThan(.1));
        }
      }
    },
  );
  test('full-scale sine peak 0, RMS -3.0103, L/R and Max-L/R independent', () {
    for (final gain in [0.0, .5, -1.0, 1.0]) {
      final f = AnalyzerDsp(size: 4096)
          .analyze(tone(4096, 1500, rightGain: gain), 48000);
      expect(f.peak[0], closeTo(0, 1e-9));
      expect(f.rms[0], closeTo(-3.0103, .001));
      expect(amplitudeDb(f.spectrum[128]), closeTo(0, 1e-7));
      expect(f.clipped, [true, gain.abs() == 1]);
      if (gain == .5) {
        expect(f.peak[1], closeTo(-6.0206, .001));
        expect(f.rms[1], closeTo(-9.0309, .001));
      }
    }
  });
  test('silence finite, unclipped; standalone FFT 75% overlap', () {
    final dsp = AnalyzerDsp(size: 2048, bassAnalysis: false);
    expect(dsp.add(List.filled(4094, 0), 48000), isEmpty);
    final frames = dsp.add(List.filled(2050, 0), 48000);
    expect(frames.length, 3);
    expect(frames.first.seconds, 512 / 48000);
    expect(frames.last.peak, [-120, -120]);
    expect(frames.last.clipped, [false, false]);
  });
  test('60 Hz bank/meter delivery before FFT, arbitrary blocks, rate/reset and resolution', () {
    final dsp = AnalyzerDsp();
    expect(dsp.add(tone(123, 1000), 48000), isEmpty);
    final first = dsp.add(tone(677, 1000, offset: 123), 48000).single;
    expect(first.seconds, 1 / 60);
    expect(first.bandLevels.length, 30);
    expect(first.bassSpectrum, isEmpty);
    expect(first.spectrum.length, 1025);
    final frames = dsp.add(tone(800 * 60, 1000, offset: 800), 48000);
    expect(frames.length, 60);
    expect(frames.last.bassBinHz, 48000 / 8192);
    expect(frames.last.bandLevels[16], closeTo(0, .1));
    dsp.bandResolution = AnalyzerBandResolution.twelfth;
    expect(dsp.add(tone(800, 1000), 48000).single.bandLevels.length, 117);
    final reset = dsp.add(List.filled(3200, 0), 96000).single;
    expect(reset.bandLevels, everyElement(-120));
    expect(reset.meterRms, [-120, -120]);
    expect(reset.spectrum.length, 2049);
  });
  for (final rate in [44100, 48000, 96000, 192000]) {
    for (final resolution in AnalyzerBandResolution.values) {
      test(
        'filter bank calibrated centres / separation / stereo at $rate $resolution',
        () {
          for (final hz in [
            25.118864315,
            63.095734448,
            251.188643151,
            1000.0,
            7943.28234724,
            19952.6231497,
          ]) {
            final index =
                List.generate(
                  resolution.count,
                  (i) => (math.log(resolution.centre(i) / hz)).abs(),
                ).indexOf(
                  List.generate(
                    resolution.count,
                    (i) => (math.log(resolution.centre(i) / hz)).abs(),
                  ).reduce(math.min),
                );
            final centre = resolution.centre(index);
            final filter = AnalyzerBandFilter(
              centre,
              resolution.edgeRatio,
              rate,
            );
            double power = 0;
            final settle = math.max(.4, 100 / centre);
            final n = (rate * (settle + .2)).round(),
                start = (rate * settle).round();
            for (var i = 0; i < n; i++) {
              final y = filter.process(
                math.sin(2 * math.pi * centre * i / rate),
                0,
              );
              if (i >= start) power += y * y;
            }
            expect(
              amplitudeDb(math.sqrt(2 * power / (n - start))),
              closeTo(0, .12),
              reason: '$centre Hz',
            );
          }
          final bank = AnalyzerFilterBank(rate, resolution);
          final sums = List.filled(resolution.count, 0.0);
          for (var i = 0; i < rate ~/ 4; i++) {
            final v = math.sin(2 * math.pi * 1000 * i / rate);
            bank.process(v, 0);
            if (i > rate ~/ 8 && i % 100 == 0) {
              final db = bank.levels;
              for (var j = 0; j < db.length; j++) {
                sums[j] += math.pow(10, db[j] / 10);
              }
            }
          }
          expect(
            sums.indexOf(sums.reduce(math.max)),
            16 * resolution.bandsPerOctave ~/ 3,
          );
          expect(
            bank.levels[16 * resolution.bandsPerOctave ~/ 3],
            closeTo(0, .1),
          );
        },
      );
    }
  }
  test(
    'Butterworth band edges are -3.01 dB, adjacent centres remain separated',
    () {
      for (final r in AnalyzerBandResolution.values) {
        for (final hz in [
          1000 / r.edgeRatio,
          1000 * r.edgeRatio,
          r.centre(16 * r.bandsPerOctave ~/ 3 + 1),
        ]) {
          final f = AnalyzerBandFilter(1000, r.edgeRatio, 48000);
          double sum = 0;
          for (var i = 0; i < 48000; i++) {
            final v = f.process(math.sin(2 * math.pi * hz * i / 48000), 0);
            if (i >= 24000) sum += v * v;
          }
          final db = amplitudeDb(math.sqrt(2 * sum / 24000));
          expect(
            db,
            hz == r.centre(16 * r.bandsPerOctave ~/ 3 + 1)
                ? lessThan(-11)
                : closeTo(-3.0103, .02),
          );
        }
      }
    },
  );
  test('every centre has unity sine response, including 25 Hz and 20 kHz', () {
    for (final r in AnalyzerBandResolution.values) {
      for (var band = 0; band < r.count; band++) {
        final hz = r.centre(band),
            f = AnalyzerBandFilter(hz, r.edgeRatio, 48000);
        final settle = math.max(.15, 100 / hz);
        final n = (48000 * (settle + .2)).round(),
            start = (48000 * settle).round();
        double power = 0;
        for (var i = 0; i < n; i++) {
          final v = f.process(math.sin(2 * math.pi * hz * i / 48000), 0);
          if (i >= start) power += v * v;
        }
        expect(
          amplitudeDb(math.sqrt(2 * power / (n - start))),
          closeTo(0, .15),
          reason: '$r $hz',
        );
      }
    }
  });
  test('pink noise has flat power bands within 1 dB, all resolutions', () {
    final period = pinkPeriod();
    for (final r in AnalyzerBandResolution.values) {
      final bank = AnalyzerFilterBank(48000, r);
      final sums = List.filled(r.count, 0.0);
      // Settle once, then average exactly one periodic cycle.
      for (var i = 0; i < period.length * 2; i++) {
        final v = period[i % period.length];
        bank.process(v, v);
        if (i >= period.length && i % 64 == 0) {
          final levels = bank.levels;
          for (var j = 0; j < levels.length; j++) {
            sums[j] += math.pow(10, levels[j] / 10);
          }
        }
      }
      final db = sums.map((p) => 10 * math.log(p) / math.ln10).toList();
      final mean = db.reduce((a, b) => a + b) / db.length;
      final deviation = db.map((v) => (v - mean).abs()).reduce(math.max);
      // ignore: avoid_print
      print(
        'PINK ${r.bandsPerOctave} max deviation=${deviation.toStringAsFixed(3)} dB',
      );
      expect(deviation, lessThan(1));
    }
  });
  test('instant attack, fast/medium/slow decay 60/25/10 dB per second; time invariant', () {
    for (final b in AnalyzerBallistics.values) {
      final e = AnalyzerEnvelope()..ballistics = b;
      e.update([-10], 1 / 60);
      expect(e.values.single, -10);
      e.update([-120], .2);
      expect(e.values.single, closeTo(-10 - [60, 25, 10][b.index] * .2, 1e-9));
      final split = AnalyzerEnvelope()..ballistics = b;
      split.update([-10], .01);
      for (var i = 0; i < 20; i++) {
        split.update([-120], .01);
      }
      expect(split.values.single, closeTo(e.values.single, 1e-9));
    }
  });
  test('peak hold 1 second, then 12 dB/s, resets and re-triggers', () {
    final e = AnalyzerEnvelope();
    e.update([-10], .1);
    e.update([-80], .5);
    expect(e.held.single, -10);
    e.update([-80], 1);
    expect(e.held.single, closeTo(-16, 1e-9));
    e.update([-5], .1);
    expect(e.held.single, -5);
    e.reset();
    expect(e.held, isEmpty);
  });
  test('meter peak instant / 20 dB per 1.5s; RMS power 300ms integration', () {
    final meters = AnalyzerMeters(48000);
    meters.process(1, .5);
    expect(meters.peak[0], 0);
    expect(meters.peak[1], closeTo(-6.0206, .001));
    for (var i = 0; i < 72000; i++) {
      meters.process(0, 0);
    }
    expect(meters.peak[0], closeTo(-20, 1e-7));
    final rms = AnalyzerMeters(48000);
    for (var i = 0; i < 14400; i++) {
      rms.process(1, 0);
    }
    expect(
      rms.rms[0],
      closeTo(10 * math.log(1 - math.exp(-1)) / math.ln10, 1e-8),
    );
    expect(rms.rms[1], -120);
  });
  test('step response -3 dB at 63/250/1k/8k, all resolutions', () {
    for (final r in AnalyzerBandResolution.values) {
      for (final thirdBand in [4, 10, 16, 25]) {
        final band = thirdBand * r.bandsPerOctave ~/ 3, hz = r.centre(band);
        final dsp = AnalyzerDsp()..bandResolution = r;
        double? reached;
        for (var offset = 0; offset < 48000 ~/ 2; offset += 800) {
          final f = dsp.add(tone(800, hz, offset: offset), 48000).single;
          if (f.bandLevels[band] >= -3 && reached == null) {
            reached = (offset + 800) / 48;
          }
        }
        // ignore: avoid_print
        print('STEP ${r.bandsPerOctave} $hz ${reached}ms');
        expect(reached, isNotNull);
        expect(
          reached!,
          lessThanOrEqualTo(
            thirdBand == 4
                ? 350
                : thirdBand == 10
                ? 100
                : 50,
          ),
        );
      }
    }
  });
  test(
    'log line interpolates endpoints, preserves dense peaks and log mapping',
    () {
      expect(logFrequency(20), 0);
      expect(logFrequency(20000), 1);
      for (final f in [20.0, 55.0, 1000.0, 20000.0]) {
        expect(frequencyAt(logFrequency(f)), closeTo(f, 1e-8));
      }
      final bins = List.filled(2049, -100.0);
      bins[1] = -80;
      bins[2] = -20;
      bins[1600] = -1;
      final line = logSpectrumDb(bins, 48000 / 4096, 850);
      expect(line.first, closeTo(-80 + 60 * (20 / (48000 / 4096) - 1), 1e-10));
      expect(line.reduce(math.max), -1);
      expect(
        logSpectrumDb(List.filled(2049, -42), 48000 / 4096, 850),
        everyElement(-42),
      );
    },
  );
}
