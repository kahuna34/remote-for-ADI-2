import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Pro offline: Loopback nur an Line und Phones 3/4', () {
    final m = offlineDefaults(Adi2Variant.pro);
    expect(m.containsKey(Adi2Addr.line << 8 | OutIdx.loopback), isTrue);
    expect(m.containsKey(Adi2Addr.ph12 << 8 | OutIdx.loopback), isFalse);
    expect(m.containsKey(Adi2Addr.ph34 << 8 | OutIdx.loopback), isTrue);
  });

  test('Jede Auswahl hat genau so viele Optionen wie Werte', () {
    final bad = <String>[];
    for (final v in Adi2Variant.values) {
      for (final d in [
        ...inputParams(v),
        ...outputParams(v, phones: false),
        ...outputParams(v, phones: true),
        ...deviceParams(v),
      ]) {
        final o = d.options;
        if (o != null && o.length != d.max - d.min + 1) {
          bad.add(
            '${v.name} ${d.index} ${d.name}: ${o.length} Optionen, '
            'Bereich ${d.min}..${d.max}',
          );
        }
      }
    }
    expect(bad, isEmpty);
  });
}
