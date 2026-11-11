/// Abgriff 0 = Aus, 1 = pre FX, 2 = post FX, 3 = post −6 dB.
/// Bei Aus ist das USB-Paar im Rohwert nicht gespeichert und wird als 0 gelesen.
({int tap, int pair}) decodeLoopback(int raw, {required bool hasInput}) {
  RangeError.checkValueInInterval(raw, 0, hasInput ? 9 : 3, 'raw');
  if (raw == 0 || !hasInput) return (tap: raw, pair: 0);
  return (tap: 1 + (raw - 1) % 3, pair: (raw - 1) ~/ 3);
}

/// Rechnet die Bedienauswahl in den bestehenden Ausgangsparameter 17 um.
int encodeLoopback({
  required int tap,
  required int pair,
  required bool hasInput,
}) {
  RangeError.checkValueInInterval(tap, 0, 3, 'tap');
  RangeError.checkValueInInterval(pair, 0, hasInput ? 2 : 0, 'pair');
  if (tap == 0 || !hasInput) return tap;
  return 3 * pair + tap;
}
