import 'package:adi2_remote/device/volume_options.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Obergrenze in dBu', () {
    test('Hi-Power (+19 dBu), Grenze +10 dBu -> max. −9,0 dB', () {
      final t = refTable(Adi2Variant.pro, Adi2Addr.ph34);
      expect(
        maxVolumeRaw(10, refDbu(Adi2Variant.pro, Adi2Addr.ph34, 1), t),
        -90,
      );
    });

    test('Umschalten Lo -> Hi senkt die erlaubte Lautstärke um 12 dB', () {
      final t = refTable(Adi2Variant.pro, Adi2Addr.ph34);
      final lo = maxVolumeRaw(10, refDbu(Adi2Variant.pro, Adi2Addr.ph34, 0), t);
      final hi = maxVolumeRaw(10, refDbu(Adi2Variant.pro, Adi2Addr.ph34, 1), t);
      expect(lo - hi, 120);
    });

    test('Unbekannter Ref-Level: höchster möglicher wird angenommen', () {
      final t = refTable(Adi2Variant.pro4se, Adi2Addr.line); // max +24
      expect(maxVolumeRaw(10, null, t), -140);
    });

    test('Keine Grenze -> +6 dB erlaubt', () {
      expect(maxVolumeRaw(null, 19, const [7, 19]), 60);
    });

    test('Ergebnis liegt im 0,5-dB-Raster und rundet ab', () {
      // 10,3 - 7 = 3,3 dB -> 3,0 dB
      expect(maxVolumeRaw(10.3, 7, const [7, 19]), 30);
    });

    test('Ref-Tabellen passen zu den Optionen der Geräte', () {
      expect(
        refTable(Adi2Variant.dac, Adi2Addr.line).length,
        outputParams(
          Adi2Variant.dac,
          phones: false,
        ).firstWhere((d) => d.index == OutIdx.refLevel).options!.length,
      );
      expect(
        refTable(Adi2Variant.pro4ex, Adi2Addr.ph34).length,
        outputParams(
          Adi2Variant.pro4ex,
          phones: true,
        ).firstWhere((d) => d.index == OutIdx.refLevel).options!.length,
      );
      expect(
        refTable(Adi2Variant.pro, Adi2Addr.ph12).length,
        outputParams(
          Adi2Variant.pro,
          phones: true,
        ).firstWhere((d) => d.index == OutIdx.refLevel).options!.length,
      );
    });
  });

  test('DAC-IEM: fester Pegel −3 dBu, Grenze 0 dBu -> max. +3,0 dB', () {
    expect(refDbu(Adi2Variant.dac, Adi2Addr.ph34, null), -3);
    expect(
      maxVolumeRaw(
        0,
        refDbu(Adi2Variant.dac, Adi2Addr.ph34, null),
        refTable(Adi2Variant.dac, Adi2Addr.ph34),
      ),
      30,
    );
  });

  test('Optionen speichern und laden', () {
    final o = VolumeOptions()
      ..rise = RiseMode.db10
      ..linked.addAll([6, 9]);
    o.of(9).limitDbu = 4.5;
    o.of(9).recallRaw = -300;
    final back = VolumeOptions.decode(o.encode());
    expect(back.rise, RiseMode.db10);
    expect(back.linked, {6, 9});
    expect(back.of(9).limitDbu, 4.5);
    expect(back.of(9).recallRaw, -300);
  });

  test('Beschädigte gespeicherte Daten ergeben sichere Standardwerte', () {
    final o = VolumeOptions.decode('{kaputt');
    expect(o.rise, RiseMode.adaptive);
    expect(o.linked, isEmpty);
  });

  test('Feste Stufen liefern konstante Raten', () {
    expect(RiseMode.db5.rate(0), 5);
    expect(RiseMode.db20.rate(-60), 20);
  });
}
