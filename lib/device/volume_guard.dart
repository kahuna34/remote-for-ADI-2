// Schutz für die Lautstärke: Lauter wird nur langsam (Rampe), und je lauter
// es schon ist, desto langsamer. Leiser geht sofort. Eine einstellbare
// Obergrenze wird nie überschritten. Werte in 0,1-dB-Schritten (Rohwerte wie
// im Protokoll, -1145 .. 60).

import 'dart:math' as math;

const int volMinRaw = -1145;
const int volMaxRaw = 60;

/// Takt der Rampe in Millisekunden.
const int volTickMs = 50;

/// Erlaubte Anstiegsgeschwindigkeit in dB pro Sekunde bei aktuellem Pegel
/// [db]. Logarithmisch fallend: leise ~20 dB/s, -20 dB ~11,6 dB/s,
/// -10 dB ~5,4 dB/s, 0 dB 2,5 dB/s, +6 dB ~1,6 dB/s.
double riseRateDbPerSec(double db) =>
    (2.5 * math.pow(10, -db / 30)).clamp(1.5, 20.0).toDouble();

class VolumeGuard {
  VolumeGuard({this.rate = riseRateDbPerSec});

  /// Anstiegsgeschwindigkeit in dB/s abhängig vom aktuellen Pegel.
  double Function(double db) rate;

  final Map<int, int> _target = {};
  final Map<int, int> _limits = {};
  final Map<int, double> _carry = {}; // Nachkommaanteil der Rampe

  int limitFor(int address) => _limits[address] ?? volMaxRaw;

  void setLimit(int address, int raw) =>
      _limits[address] = raw.clamp(volMinRaw, volMaxRaw);

  void clearLimits() => _limits.clear();

  /// Gewünschter Zielwert (wird auf die Obergrenze begrenzt).
  /// Gibt true zurück, wenn der Wunsch an der Obergrenze abgeschnitten wurde.
  bool request(int address, int raw) {
    _target[address] = raw.clamp(volMinRaw, limitFor(address));
    return raw > limitFor(address);
  }

  int? target(int address) => _target[address];

  bool get isIdle => _target.isEmpty;

  void cancel(int address) {
    _target.remove(address);
    _carry.remove(address);
  }

  void cancelAll() {
    _target.clear();
    _carry.clear();
  }

  /// Liefert die Werte, die in diesem Takt gesendet werden sollen.
  /// [current] gibt den zuletzt bekannten Wert eines Ausgangs zurück.
  Map<int, int> tick(int? Function(int address) current) {
    final out = <int, int>{};
    for (final addr in _target.keys.toList()) {
      final target = _target[addr]!;
      final cur = current(addr);
      if (cur == null) {
        // Ausgangswert unbekannt: nichts blind senden.
        cancel(addr);
        continue;
      }
      int next;
      if (target <= cur) {
        next = target; // leiser: sofort
        _carry.remove(addr);
      } else {
        // Schrittweite in 0,1 dB für diesen Takt, abhängig vom Pegel.
        final step =
            rate(cur / 10) * 10 * volTickMs / 1000 + (_carry[addr] ?? 0);
        final whole = step.floor();
        _carry[addr] = step - whole;
        next = math.min(target, cur + whole);
      }
      if (next == target) cancel(addr);
      if (next != cur) out[addr] = next;
    }
    return out;
  }
}
