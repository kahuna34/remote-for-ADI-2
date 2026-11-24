import 'dart:math' as math;
import 'dart:typed_data';

enum TestSignal { sine, thirds, sweep, pink, white, levels }

enum TestSignalChannel { left, right, both, opposite }

const testSignalThirds = <double>[
  20,
  25,
  31.5,
  40,
  50,
  63,
  80,
  100,
  125,
  160,
  200,
  250,
  315,
  400,
  500,
  630,
  800,
  1000,
  1250,
  1600,
  2000,
  2500,
  3150,
  4000,
  5000,
  6300,
  8000,
  10000,
  12500,
  16000,
  20000,
];
const testSignalLevels = <double>[0, -6, -12, -20, -40];

/// Immutable, validated before any playback process is started.
class TestSignalSettings {
  TestSignalSettings({
    this.signal = TestSignal.sine,
    this.frequency = 1000,
    this.dbfs = -20,
    this.channel = TestSignalChannel.both,
    this.stepSeconds = 2,
    this.sweepSeconds = 20,
    this.repeat = false,
  }) {
    if (!frequency.isFinite ||
        frequency < 20 ||
        frequency > 20000 ||
        !dbfs.isFinite ||
        dbfs < -60 ||
        dbfs > 0 ||
        stepSeconds < 1 ||
        stepSeconds > 5 ||
        ![10, 20, 30].contains(sweepSeconds)) {
      throw ArgumentError('Invalid test signal settings');
    }
  }
  final TestSignal signal;
  final double frequency, dbfs;
  final TestSignalChannel channel;
  final int stepSeconds, sweepSeconds;
  final bool repeat;

  bool get requiresHighLevel => signal == TestSignal.levels || dbfs > -6;
  Duration? get duration => switch (signal) {
    TestSignal.thirds => Duration(
      seconds: testSignalThirds.length * stepSeconds,
    ),
    TestSignal.sweep when !repeat => Duration(seconds: sweepSeconds),
    TestSignal.levels => const Duration(seconds: 15),
    _ => null,
  };

  TestSignalPosition position(Duration elapsed) {
    final seconds = math.max(0.0, elapsed.inMicroseconds / 1e6);
    final total = duration?.inMicroseconds;
    final finished = total != null && elapsed.inMicroseconds >= total;
    final progress = total == null
        ? (signal == TestSignal.sweep
              ? seconds % sweepSeconds / sweepSeconds
              : null)
        : (elapsed.inMicroseconds / total).clamp(0.0, 1.0);
    return TestSignalPosition(
      frequency: switch (signal) {
        TestSignal.thirds =>
          testSignalThirds[(seconds / stepSeconds).floor().clamp(
            0,
            testSignalThirds.length - 1,
          )],
        TestSignal.sweep =>
          (20 *
                  math.pow(
                    1000,
                    (repeat
                            ? seconds % sweepSeconds
                            : math.min(seconds, sweepSeconds)) /
                        sweepSeconds,
                  ))
              .toDouble(),
        TestSignal.levels => 1000,
        TestSignal.sine => frequency,
        _ => null,
      },
      dbfs: signal == TestSignal.levels
          ? testSignalLevels[(seconds / 3).floor().clamp(0, 4)]
          : dbfs,
      progress: progress,
      finished: finished,
    );
  }
}

class TestSignalPosition {
  const TestSignalPosition({
    required this.frequency,
    required this.dbfs,
    this.progress,
    this.finished = false,
  });
  final double? frequency, progress;
  final double dbfs;
  final bool finished;
}

/// A deterministic sample clock: chunk boundaries and wall-clock jitter cannot
/// change frequency, sweep integration, steps, noise or the 20 ms envelopes.
class TestSignalSynth {
  TestSignalSynth(this.settings, this.rate, {int seed = 0xad12})
    : _random = math.Random(seed) {
    if (rate < 44100 || rate > 768000) throw ArgumentError.value(rate, 'rate');
    _fade = (rate * .02).round();
    _total = settings.duration == null
        ? null
        : settings.duration!.inMicroseconds * rate ~/ 1000000;
    _segment = switch (settings.signal) {
      TestSignal.thirds => settings.stepSeconds * rate,
      TestSignal.levels => 3 * rate,
      TestSignal.sweep => settings.sweepSeconds * rate,
      _ => null,
    };
    _amplitude = math.pow(10, settings.dbfs / 20).toDouble();
    _frequency = settings.frequency;
    _sweepRatio = math.pow(1000, 1 / (settings.sweepSeconds * rate)).toDouble();
    if (settings.signal == TestSignal.pink) {
      _pink = testSignalPinkNoise(rate, seed: seed);
    }
  }
  final TestSignalSettings settings;
  final int rate;
  final math.Random _random;
  late final int _fade;
  late final int? _total, _segment;
  Float64List? _pink;
  int frame = 0;
  int? _stopAt, _stopFrom;
  double _phase = 0;
  late double _frequency, _amplitude;
  late final double _sweepRatio;

  bool get finished => frame >= (_stopAt ?? _total ?? 0x7fffffffffffffff);
  Duration get elapsed => Duration(microseconds: frame * 1000000 ~/ rate);
  void fadeOut() {
    _stopFrom ??= frame;
    _stopAt ??= math.min(frame + _fade, _total ?? frame + _fade);
  }

  Uint8List render(int frames) {
    final remaining = (_stopAt ?? _total);
    if (remaining != null) frames = math.min(frames, remaining - frame);
    frames = math.max(0, frames);
    final data = ByteData(frames * 8);
    for (var i = 0; i < frames; i++, frame++) {
      final segment = _segment;
      final local = segment == null ? frame : frame % segment;
      if (segment != null && local == 0) {
        final step = frame ~/ segment;
        if (settings.signal == TestSignal.thirds) {
          _frequency = testSignalThirds[step];
        }
        if (settings.signal == TestSignal.levels) {
          _frequency = 1000;
          _amplitude = math.pow(10, testSignalLevels[step] / 20).toDouble();
        }
        if (settings.signal == TestSignal.sweep) _frequency = 20;
      }
      var envelope = math.min(1.0, frame / _fade);
      if (segment != null) {
        envelope = math.min(
          envelope,
          math.min(local / _fade, (segment - 1 - local) / _fade),
        );
      }
      if (_total != null) {
        envelope = math.min(envelope, (_total - 1 - frame) / _fade);
      }
      if (_stopFrom != null) {
        envelope = math.min(envelope, (_stopAt! - 1 - frame) / _fade);
      }
      final double raw;
      if (settings.signal == TestSignal.white) {
        raw = _random.nextDouble() * 2 - 1;
      } else if (_pink != null) {
        raw = _pink![frame % _pink!.length];
      } else {
        raw = math.sin(_phase);
        _phase = (_phase + 2 * math.pi * _frequency / rate) % (2 * math.pi);
      }
      if (settings.signal == TestSignal.sweep) _frequency *= _sweepRatio;
      final value = raw * _amplitude * envelope.clamp(0.0, 1.0);
      data.setFloat32(
        i * 8,
        settings.channel == TestSignalChannel.right ? 0 : value,
        Endian.little,
      );
      data.setFloat32(i * 8 + 4, switch (settings.channel) {
        TestSignalChannel.left => 0,
        TestSignalChannel.opposite => -value,
        _ => value,
      }, Endian.little);
    }
    return data.buffer.asUint8List();
  }
}

/// Periodic random-phase pink noise. Exact 1/f bin power at the actual sink
/// rate avoids sample-rate-dependent IIR coloration. A >=4 s tile has <=.25 Hz
/// bin spacing and a seamless periodic boundary. Normalize once to peak=1;
/// the level control is a peak ceiling for both kinds of noise, not RMS.
Float64List testSignalPinkNoise(int rate, {int seed = 0xad12}) {
  var n = 1;
  while (n < rate * 4) {
    n *= 2;
  }
  final re = Float64List(n), im = Float64List(n);
  final random = math.Random(seed);
  for (var k = 1; k < n ~/ 2; k++) {
    final magnitude = 1 / math.sqrt(k);
    final phase = random.nextDouble() * 2 * math.pi;
    re[k] = re[n - k] = magnitude * math.cos(phase);
    im[k] = magnitude * math.sin(phase);
    im[n - k] = -im[k];
  }
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final r = re[i], v = im[i];
      re[i] = re[j];
      im[i] = im[j];
      re[j] = r;
      im[j] = v;
    }
  }
  for (var length = 2; length <= n; length *= 2) {
    final angle = 2 * math.pi / length;
    final wr = math.cos(angle), wi = math.sin(angle);
    for (var start = 0; start < n; start += length) {
      var r = 1.0, v = 0.0;
      for (var k = 0; k < length ~/ 2; k++) {
        final a = start + k, b = a + length ~/ 2;
        final br = re[b] * r - im[b] * v;
        final bi = re[b] * v + im[b] * r;
        re[b] = re[a] - br;
        im[b] = im[a] - bi;
        re[a] += br;
        im[a] += bi;
        final next = r * wr - v * wi;
        v = r * wi + v * wr;
        r = next;
      }
    }
  }
  var peak = 0.0;
  for (final value in re) {
    peak = math.max(peak, value.abs());
  }
  for (var i = 0; i < n; i++) {
    re[i] /= peak;
  }
  return re;
}
