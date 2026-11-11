import 'package:adi2_remote/eq/eq_library.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('EQ-Preset: speichern und wieder lesen', () {
    final p = AppEqPreset(
      name: 'HD 800',
      dual: true,
      left: {3: 1, 4: -6, 5: 120, 26: 2},
      right: {4: 3, 5: 900},
    );
    final q = AppEqPreset.decode(p.encode());
    expect(q.name, 'HD 800');
    expect(q.dual, isTrue);
    expect(q.left, p.left);
    expect(q.right, p.right);
  });

  test('Liste überspringt fehlerhafte Einträge', () {
    final good = AppEqPreset(name: 'A', dual: false, left: {4: 2}, right: {});
    final s = EqLibrary.encodeList([good]).replaceFirst(']', ',{"x":1}]');
    final l = EqLibrary.decodeList(s);
    expect(l.length, 1);
    expect(l.first.name, 'A');
  });

  test('Fremde Datei wird abgelehnt, unzulässige Indizes entfernt', () {
    expect(
      () => AppEqPreset.decode('{"type":"backup"}'),
      throwsFormatException,
    );
    final p = AppEqPreset.fromJson({
      'type': AppEqPreset.fileType,
      'name': '',
      'l': {'4': 2, '99': 5, '1': 3},
      'r': {'4': 1, '22': 7},
    });
    expect(p.name, 'EQ');
    expect(p.left, {4: 2});
    expect(p.right, {4: 1});
  });
}
