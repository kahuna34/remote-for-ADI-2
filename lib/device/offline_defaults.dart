// Werkseinstellungen (Spalte "Default" im RME MIDI-Protokoll) für den
// Offline-Modus: alle Parameter eines Modells ohne angeschlossenes Gerät.

import '../eq/eq_model.dart';
import '../protocol/adi2_codec.dart';
import '../protocol/adi2_params.dart';
import 'loopback.dart';

Map<int, int> offlineDefaults(Adi2Variant v) {
  final m = <int, int>{};
  void put(int a, int i, int val) => m[a << 8 | i] = val;

  final channels = <(int, bool)>[
    if (v.hasInput) (Adi2Addr.input, false),
    (Adi2Addr.line, false),
    (Adi2Addr.ph12, true),
    if (v.hasPhones34) (Adi2Addr.ph34, true),
  ];
  for (final (a, phones) in channels) {
    // Rear TRS bleibt einmalig bei Line (3); Phones 3/4 verwendet im UI
    // dieselbe Adresse, solange das Gerät keinen eigenen Wert auf 9 meldet.
    final defs = a == Adi2Addr.input
        ? inputParams(v)
        : outputParams(v, phones: phones);
    for (final d in defs) {
      put(a, d.index, d.def);
    }
    // EQ links/rechts
    for (final eqA in [a + 1, a + 2]) {
      for (var bi = 0; bi < eqBands.length; bi++) {
        final b = eqBands[bi];
        if (b.isBassTreble && eqA != a + 1) continue;
        if (b.typeIdx != null) put(eqA, b.typeIdx!, 1); // Default: Shelf
        put(eqA, b.gainIdx, 0);
        put(eqA, b.freqIdx, b.defF);
        put(eqA, b.qIdx, (b.defQ * 10).round());
      }
    }
    put(a + 1, EqIdx2.enable, 0);
    put(a + 1, EqIdx2.btEnable, 1);
    put(a + 1, EqIdx2.loadBtWithPreset, 0);
    put(a + 1, EqIdx2.presetSelect, 0);
  }
  for (final d in deviceParams(v)) {
    put(Adi2Addr.device, d.index, d.def);
  }
  if (!hasOwnLoopback(v, Adi2Addr.ph12)) {
    m.remove(Adi2Addr.ph12 << 8 | OutIdx.loopback);
  }
  return m;
}

/// Geräte-ID (Protokoll) für eine Variante.
Adi2Model modelOf(Adi2Variant v) => switch (v) {
  Adi2Variant.dac => Adi2Model.dac,
  Adi2Variant.pro => Adi2Model.pro,
  _ => Adi2Model.pro4,
};

/// Parameter, die beim Übertragen nie gesendet werden: nur Anzeige oder
/// Aktion, oder (Lautstärke) nur wenn leiser als am Gerät.
bool isTransferExcluded(int address, int index) =>
    (address == Adi2Addr.device &&
        (index == DevIdx.sampleRate || index == DevIdx.doToggleOutputs)) ||
    (address == Adi2Addr.presetEqL || address == Adi2Addr.presetEqR) ||
    (index == EqIdx2.presetSelect && address % 3 == 1);
