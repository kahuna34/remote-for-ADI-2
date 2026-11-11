import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:flutter_test/flutter_test.dart';

// Stichproben gegen die Tabelle "Remap-Key Options" im RME-Protokoll v1.2.
void main() {
  test('ADI-2 DAC: 42 Funktionen, Positionen wie in der RME-Tabelle', () {
    expect(remapOptionsDac.length, 42);
    expect(remapOptionsDac[10], 'Mono');
    expect(remapOptionsDac[13], 'Loudness');
    expect(remapOptionsDac[19], 'AutoDark');
    expect(remapOptionsDac[20], 'Dim');
    expect(remapOptionsDac[32], 'DA SD LD (Brickwall)');
    expect(remapOptionsDac[41], 'EQ Preset 9');
  });

  test('ADI-2 Pro: 62 Funktionen', () {
    expect(remapOptionsPro.length, 62);
    expect(remapOptionsPro[38], 'DA NOS');
    expect(remapOptionsPro[41], 'DIM');
    expect(remapOptionsPro[47], 'Source AES');
    expect(remapOptionsPro[50], 'Source Analog');
    expect(remapOptionsPro[52], 'AutoDark');
    expect(remapOptionsPro[61], 'EQ Preset 9');
  });

  test('ADI-2/4 Pro: 66 Funktionen inkl. RIAA', () {
    expect(remapOptionsPro4.length, 66);
    expect(remapOptionsPro4[38], 'DA SD LD');
    expect(remapOptionsPro4[39], 'Brickwall');
    expect(remapOptionsPro4[42], 'DIM');
    expect(remapOptionsPro4[51], 'Source Analog');
    expect(remapOptionsPro4[53], 'AutoDark');
    expect(remapOptionsPro4[63], 'RIAA Mode +');
    expect(remapOptionsPro4[65], 'RIAA Mono Bass');
  });

  test('Werkseinstellungen zeigen auf die richtigen Funktionen', () {
    String name(Adi2Variant v, int idx) {
      final d = deviceParams(v).firstWhere((x) => x.index == idx);
      return d.options![d.def];
    }

    expect(name(Adi2Variant.dac, 26), 'Mono');
    expect(name(Adi2Variant.dac, 29), 'Dim');
    expect(name(Adi2Variant.pro, 26), 'Source Analog');
    expect(name(Adi2Variant.pro4se, 29), 'DIM');
  });

  test('DAC-Filterplatz 5: SD LD (AKM) bzw. Brickwall (ESS)', () {
    String f(bool ess) => outputParams(
      Adi2Variant.dac,
      phones: true,
      ess: ess,
    ).firstWhere((d) => d.index == OutIdx.daFilter).options![5];
    expect(f(false), 'SD LD');
    expect(f(true), 'Brickwall');
    expect(
      outputParams(
        Adi2Variant.dac,
        phones: true,
      ).firstWhere((d) => d.index == OutIdx.daFilter).options!.length,
      6,
    );
  });
}
