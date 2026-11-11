import 'package:adi2_remote/device/volume_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Simuliert Takte, bis nichts mehr gesendet wird. Gibt die gesendeten
  /// Werte zurück.
  List<int> run(
    VolumeGuard g,
    Map<int, int> device,
    int addr, {
    int maxTicks = 1000,
  }) {
    final sent = <int>[];
    for (var i = 0; i < maxTicks && !g.isIdle; i++) {
      final out = g.tick((a) => device[a]);
      if (out.containsKey(addr)) {
        device[addr] = out[addr]!;
        sent.add(out[addr]!);
      }
    }
    return sent;
  }

  test('Lauter nur langsam – je lauter, desto langsamer', () {
    final g = VolumeGuard();
    final dev = {3: -500};
    g.request(3, 60); // Regler von -50 dB auf +6 dB gerissen
    var prev = -500;
    var ticks = 0;
    final ticksPerDb = <int, int>{}; // Takte je 10-dB-Bereich
    while (!g.isIdle && ticks < 100000) {
      final out = g.tick((a) => dev[a]);
      ticks++;
      final bucket = (prev / 100).floor();
      ticksPerDb[bucket] = (ticksPerDb[bucket] ?? 0) + 1;
      if (out.containsKey(3)) {
        final v = out[3]!;
        // Nie mehr als die erlaubte Rate (+1 Rohwert Rundung) pro Takt.
        final allowed = riseRateDbPerSec(prev / 10) * 10 * volTickMs / 1000;
        expect(v - prev, lessThanOrEqualTo(allowed.ceil()));
        dev[3] = v;
        prev = v;
      }
    }
    expect(dev[3], 60);
    // Im lauten Bereich (-10..0 dB) deutlich mehr Takte als im leisen
    // (-50..-40 dB).
    expect(ticksPerDb[-1]!, greaterThan(ticksPerDb[-5]! * 3));
    // Gesamtdauer -50 -> +6 dB: rund 8,7 Sekunden.
    expect(ticks * volTickMs, greaterThan(8000));
  });

  test('Anstiegsrate: Werte der Kurve', () {
    expect(riseRateDbPerSec(-60), 20);
    expect(riseRateDbPerSec(0), closeTo(2.5, 0.01));
    expect(riseRateDbPerSec(6), closeTo(1.58, 0.01));
    expect(riseRateDbPerSec(-10), closeTo(5.39, 0.01));
  });

  test('Leiser sofort in einem Schritt', () {
    final g = VolumeGuard();
    final dev = {6: -100};
    g.request(6, -800);
    expect(g.tick((a) => dev[a]), {6: -800});
    expect(g.isIdle, isTrue);
  });

  test('Obergrenze wird nie überschritten', () {
    final g = VolumeGuard()..setLimit(9, -200);
    final dev = {9: -400};
    g.request(9, 60);
    run(g, dev, 9);
    expect(dev[9], -200);
  });

  test('Nur der neueste Zielwert zählt (kein Rückstau)', () {
    final g = VolumeGuard();
    final dev = {3: -300};
    for (var v = -300; v <= -100; v += 5) {
      g.request(3, v); // viele Regler-Ereignisse vor dem nächsten Takt
    }
    g.request(3, -350); // Nutzer zieht zurück
    expect(g.tick((a) => dev[a]), {3: -350});
    expect(g.isIdle, isTrue);
  });

  test('Ohne bekannten Ist-Wert wird nichts gesendet', () {
    final g = VolumeGuard();
    g.request(3, 0);
    expect(g.tick((a) => null), isEmpty);
    expect(g.isIdle, isTrue);
  });
}
