import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/eq/eq_model.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:flutter_test/flutter_test.dart';

int k(int a, int i) => a << 8 | i;

void main() {
  test('Werkseinstellungen: Lautstärke −10 dB, EQ aus, Bass 85 Hz', () {
    final d = offlineDefaults(Adi2Variant.pro);
    expect(d[k(Adi2Addr.ph34, OutIdx.volume)], -100);
    expect(d[k(Adi2Addr.ph34 + 1, EqIdx2.enable)], 0);
    expect(d[k(Adi2Addr.ph34 + 1, 22)], 85); // Bass Freq
    expect(d[k(Adi2Addr.line + 1, 5)], 100); // Band 1 Freq
    expect(d[k(Adi2Addr.device, 2)], 0); // Auto-Standby aus
  });

  test('DAC hat keinen Eingang, aber IEM als dritten Ausgang', () {
    final d = offlineDefaults(Adi2Variant.dac);
    expect(d.keys.any((x) => x >> 8 == Adi2Addr.input), isFalse);
    expect(d.keys.any((x) => x >> 8 == Adi2Addr.ph34), isTrue);
  });

  test('Bass/Treble nur auf der linken EQ-Adresse', () {
    final d = offlineDefaults(Adi2Variant.pro4ex);
    expect(d.containsKey(k(Adi2Addr.ph34 + 1, 21)), isTrue);
    expect(d.containsKey(k(Adi2Addr.ph34 + 2, 21)), isFalse);
  });

  test('Übertragung lässt Anzeige-/Aktionswerte und Presetwahl aus', () {
    expect(isTransferExcluded(Adi2Addr.device, DevIdx.sampleRate), isTrue);
    expect(isTransferExcluded(Adi2Addr.device, DevIdx.doToggleOutputs), isTrue);
    expect(isTransferExcluded(Adi2Addr.ph34 + 1, EqIdx2.presetSelect), isTrue);
    expect(isTransferExcluded(Adi2Addr.ph34 + 1, 4), isFalse);
    expect(isTransferExcluded(Adi2Addr.ph34, OutIdx.mute), isFalse);
  });

  test('Rear TRS nur bei Pro4, einmalig auf Line, auch im Phones-Menü', () {
    for (final v in Adi2Variant.values) {
      final defaults = offlineDefaults(v);
      expect(
        defaults[k(Adi2Addr.line, OutIdx.rearTrsSource)],
        v.isPro4 ? 0 : null,
      );
      for (final a in [Adi2Addr.ph12, Adi2Addr.ph34]) {
        expect(defaults.containsKey(k(a, OutIdx.rearTrsSource)), isFalse);
      }
      bool hasRear(bool phones, bool ph34) => outputParams(
        v,
        phones: phones,
        ph34: ph34,
      ).any((d) => d.index == OutIdx.rearTrsSource);
      expect(hasRear(false, false), v.isPro4);
      expect(hasRear(true, false), isFalse);
      expect(hasRear(true, true), v.isPro4);
    }
  });

  test('Modell-IDs der Varianten', () {
    expect(modelOf(Adi2Variant.pro4ex), Adi2Model.pro4);
    expect(modelOf(Adi2Variant.dac).id, 0x71);
  });
}
