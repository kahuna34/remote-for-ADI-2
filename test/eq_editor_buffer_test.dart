import 'package:adi2_remote/device/backup.dart';
import 'package:adi2_remote/eq/eq_editor_buffer.dart';
import 'package:adi2_remote/eq/eq_library.dart';
import 'package:adi2_remote/eq/eq_model.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const left = Adi2Addr.presetEqL, right = Adi2Addr.presetEqR;

  test('Clear stellt alle Bänder auf lineare Werkseinstellungen', () {
    final buffer = EqEditorBuffer()
      ..name = 'Changed'
      ..dual = true
      ..set(left, 4, 12)
      ..set(right, 16, 2)
      ..clear();
    expect(buffer.name, isEmpty);
    expect(buffer.dual, isFalse);
    for (final band in eqBands) {
      expect(buffer.value(left, band.gainIdx), 0);
      expect(buffer.value(left, band.freqIdx), band.defF);
      expect(buffer.value(left, band.qIdx), (band.defQ * 10).round());
      if (band.typeIdx != null) expect(buffer.value(left, band.typeIdx!), 1);
      if (!band.isBassTreble) {
        expect(buffer.value(right, band.gainIdx), 0);
        expect(buffer.value(right, band.freqIdx), band.defF);
      }
    }
    expect(buffer.value(right, 21), isNull);
    expect(buffer.left.keys, isNot(contains(20)));
    expect(buffer.left.keys, isNot(contains(27)));
  });

  test('Geräte-Preset und App-Preset werden mit unabhängigen Maps geladen', () {
    final preset = EqPresetData(
      number: 19,
      name: 'Device',
      empty: false,
      dual: true,
      left: {4: 8, 5: 120, 20: 1, 27: 1},
      right: {4: -6},
    );
    final buffer = EqEditorBuffer()..loadDevicePreset(preset);
    expect(buffer.name, 'Device');
    expect(buffer.dual, isTrue);
    expect(buffer.value(left, 4), 8);
    expect(buffer.value(right, 4), -6);
    final exported = buffer.toAppPreset();
    buffer.set(left, 4, 2);
    expect(exported.left[4], 8);
    expect(preset.left[4], 8);
    expect(exported.left.keys, isNot(contains(20)));
    expect(exported.left.keys, isNot(contains(27)));
    final restored = EqEditorBuffer()
      ..loadAppPreset(AppEqPreset.decode(exported.encode()));
    expect(restored.left, exported.left);
    expect(restored.right, exported.right);
    expect(restored.name, 'Device');
    expect(restored.dual, isTrue);
  });

  test('Kopieren und Einfügen erhalten unabhängige Schnappschüsse', () {
    final source = EqEditorBuffer()
      ..name = 'Copy'
      ..dual = true
      ..set(right, 4, -8);
    final clipboard = source.copy();
    source.clear();
    final destination = EqEditorBuffer()..paste(clipboard);
    destination.set(right, 4, 10);
    expect(clipboard.value(right, 4), -8);
    expect(source.value(right, 4), 0);
    expect(destination.name, 'Copy');
    expect(destination.dual, isTrue);
  });

  test(
    'Ältere unvollständige Dateien ergänzen Defaults und begrenzen Rohwerte',
    () {
      final buffer = EqEditorBuffer()
        ..loadAppPreset(
          AppEqPreset(
            name: 'Old',
            dual: false,
            left: {4: 100, 5: 1, 6: 0, 16: 99, 25: 6612},
            right: {4: -100, 22: 100},
          ),
        );
      expect(buffer.value(left, 4), eqGainMaxRaw);
      expect(buffer.value(right, 4), eqGainMinRaw);
      expect(buffer.value(left, 5), eqBands[0].minF);
      expect(buffer.value(left, 6), 5);
      expect(buffer.value(left, 16), 2);
      expect(buffer.value(left, 25), 6600);
      expect(buffer.value(right, 22), isNull);
      expect(buffer.value(left, 14), eqBands[3].defF);
    },
  );

  test('Leerer Geräteslot lädt lineare Defaults und behält seinen Namen', () {
    final buffer = EqEditorBuffer()
      ..set(left, 4, 8)
      ..loadDevicePreset(
        EqPresetData(
          number: 0,
          name: 'Empty',
          empty: true,
          dual: true,
          left: {4: 20},
        ),
      );
    expect(buffer.value(left, 4), 0);
    expect(buffer.dual, isFalse);
    expect(buffer.name, 'Empty');
  });
}
