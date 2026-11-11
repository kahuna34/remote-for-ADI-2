import 'package:adi2_remote/device/backup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Adi2Backup sample() => Adi2Backup(
    variant: 'pro',
    label: 'ADI-2 Pro',
    created: DateTime(2026, 11, 5, 16, 12),
    values: {9 << 8 | 12: -230, 10 << 8 | 4: -6},
    presets: [
      EqPresetData(
        number: 2,
        name: 'LCD-2',
        empty: false,
        dual: true,
        left: {4: 3, 5: 120},
        right: {4: -2},
      ),
      EqPresetData(number: 3, name: '', empty: true, dual: false),
    ],
    setupNames: {1: 'Kopfhörer'},
  );

  test('Speichern und Laden ergibt denselben Inhalt', () {
    final b = Adi2Backup.decode(sample().encode());
    expect(b.variant, 'pro');
    expect(b.label, 'ADI-2 Pro');
    expect(b.created, DateTime(2026, 11, 5, 16, 12));
    expect(b.values[9 << 8 | 12], -230);
    expect(b.values[10 << 8 | 4], -6);
    expect(b.presets.first.name, 'LCD-2');
    expect(b.presets.first.dual, isTrue);
    expect(b.presets.first.left, {4: 3, 5: 120});
    expect(b.presets.first.right, {4: -2});
    expect(b.presets.last.empty, isTrue);
    expect(b.setupNames, {1: 'Kopfhörer'});
  });

  test('Fremde Dateien werden abgelehnt', () {
    expect(
      () => Adi2Backup.decode('{"format":"etwas anderes"}'),
      throwsFormatException,
    );
    expect(() => Adi2Backup.decode('[1,2,3]'), throwsFormatException);
  });

  test('Backups neuerer App-Versionen werden abgelehnt', () {
    final s = sample().encode().replaceFirst('"version": 1', '"version": 99');
    expect(() => Adi2Backup.decode(s), throwsFormatException);
  });

  test('Dateiname mit Modell und Zeitstempel', () {
    expect(sample().fileName, 'ADI-2_Pro_2026-11-05_1612.json');
  });
}
