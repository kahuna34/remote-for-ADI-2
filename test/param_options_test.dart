import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
