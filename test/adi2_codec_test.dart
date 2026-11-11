import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_status.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> hex(String s) =>
    s.trim().split(RegExp(r'\s+')).map((h) => int.parse(h, radix: 16)).toList();

void main() {
  group('Beispiele aus RME MIDI-Protokoll v1.2', () {
    test('Request all settings', () {
      expect(buildRequestAll(0x73), hex('F0 00 20 0D 73 03 09 F7'));
    });

    test('Phones 3/4 Volume -10 dB', () {
      final msgs = buildSetParams(0x73, [const Adi2Param(9, 12, -100)]);
      expect(msgs.single, hex('F0 00 20 0D 73 02 4B 1F 1C F7'));
    });

    test('Input Ref Level 13 dBu', () {
      final msgs = buildSetParams(0x73, [const Adi2Param(0, 1, 2)]);
      expect(msgs.single, hex('F0 00 20 0D 73 02 00 20 02 F7'));
    });

    test('Request EQ-Preset 2', () {
      expect(buildRequestEqPreset(0x73, 1), hex('F0 00 20 0D 73 03 0B F7'));
    });

    test('Dekodieren: Frequenzen, Faktor 10, negative Werte', () {
      expect(decodeParam(0x09, 0x20, 0x64), const Adi2Param(1, 5, 100));
      expect(decodeParam(0x0A, 0x03, 0x74), const Adi2Param(1, 8, 500));
      expect(decodeParam(0x0A, 0x67, 0x68), const Adi2Param(1, 11, 1000));
      expect(decodeParam(0x0B, 0x53, 0x74), const Adi2Param(1, 14, 5000));
      expect(decodeParam(0x0C, 0x57, 0x68), const Adi2Param(1, 18, 10000));
      expect(decodeParam(0x4B, 0x1F, 0x1C), const Adi2Param(9, 12, -100));
      // Loudness Low Vol Ref -30 dB = -60 Inkremente
      expect(decodeParam(0x1D, 0x7F, 0x44), const Adi2Param(3, 23, -60));
      // Geräteparameter Clock Source (Index 15)
      expect(decodeParam(0x61, 0x70, 0x01), const Adi2Param(12, 15, 1));
    });

    test('Kodieren und Dekodieren ergibt denselben Wert', () {
      for (final p in const [
        Adi2Param(3, 12, -1145),
        Adi2Param(6, 12, 60),
        Adi2Param(4, 14, 20000),
        Adi2Param(4, 5, 20),
        Adi2Param(4, 25, 6500),
        Adi2Param(12, 63, 0),
        Adi2Param(12, 33, 5),
        Adi2Param(7, 4, -24),
      ]) {
        final b = encodeParam(p);
        expect(decodeParam(b[0], b[1], b[2]), p, reason: '$p -> $b');
      }
    });

    test('Name-Nachricht vom Gerät', () {
      final m = parseSysex(
        hex(
          'F0 00 20 0D 73 05 02 20 20 20 20 50 72 6F 50 68 69 6C 65 20 38 00 00 F7',
        ),
      );
      expect(m, isA<Adi2NameMessage>());
      final n = m as Adi2NameMessage;
      expect(n.slot, 2);
      expect(n.name, 'ProPhile 8');
    });

    test('Statusmeldung', () {
      final m = parseSysex(
        hex('F0 00 20 0D 73 07 11 30 7E 08 00 00 00 02 04 01 11 00 F7'),
      );
      final s = Adi2Status((m as Adi2StatusMessage).data);
      expect(s.protocolRevision, 1);
      expect(s.eightChannelMode, isTrue);
      expect(s.clockSource, 0);
      expect(s.isEx, isFalse);
    });

    test('Großer Parameter-Block wird komplett gelesen', () {
      final m = parseSysex(
        hex('F0 00 20 0D 73 01 56 60 00 57 00 02 F7'),
      ) as Adi2ParamsMessage;
      expect(m.params.length, 2);
    });
  });

  test('Preset-Kennung kommt auf Adresse 13, Index 1 (RME-Beispieldaten)', () {
    // "Request EQ-Preset 2": Antwort beginnt mit 68 20 10 -> Preset 1, nicht leer
    expect(decodeParam(0x68, 0x20, 0x10), const Adi2Param(13, 1, 0x10));
    // "Request EQ-Preset 3" (leer): 68 20 2F -> Nummer 2, untere Bits alle 1
    final p = decodeParam(0x68, 0x20, 0x2F);
    expect(p.index, 1);
    expect(p.value >> 4, 2);
    expect(p.value & 0x0F, 0x0F);
  });

  test('Namen: 14 Zeichen rechtsbündig, dann 00 00 (wie vom Gerät)', () {
    expect(
      buildSendName(0x72, 20, 'EQ Preset 20'),
      hex(
        'F0 00 20 0D 72 06 14 20 20 45 51 20 50 72 65 73 65 74 20 32 30 00 00 F7',
      ),
    );
    expect(nameBytes('Ein sehr langer Presetname').length, 16);
  });

  test('Preset speichern: Daten, Name, Kennung auf Index 2 – nie 20/27', () {
    final msgs = buildStoreEqPreset(
      0x72,
      19,
      {3: 1, 10: 12, 20: 1, 21: 0, 27: 1},
      {10: 4},
      false,
      'Test',
    );
    final params = <Adi2Param>[];
    for (final m in msgs) {
      final p = parseSysex(m);
      if (p is Adi2ParamsMessage) params.addAll(p.params);
    }
    expect(params.any((p) => p.index == 20 || p.index == 27), isFalse);
    expect(
      params.any((p) => p.address == Adi2Addr.presetEqR),
      isFalse,
      reason: 'rechts nur bei Dual',
    );
    // Reihenfolge: zuletzt die Kennung, davor der Name
    final last = parseSysex(msgs.last) as Adi2ParamsMessage;
    expect(last.params.single, const Adi2Param(13, 2, 19 << 4));
    expect(parseSysex(msgs[msgs.length - 2]), isA<Adi2NameMessage>());
  });

  test('Dual-Preset: rechte Bänder werden mitgespeichert', () {
    final msgs = buildStoreEqPreset(0x72, 0, {4: 2}, {4: -2}, true, null);
    final first = parseSysex(msgs.first) as Adi2ParamsMessage;
    expect(first.params, contains(const Adi2Param(14, 4, -2)));
    final last = parseSysex(msgs.last) as Adi2ParamsMessage;
    expect(last.params.single.value & 1, 1);
  });

  test('SysEx-Zusammensetzung aus Stücken', () {
    final a = SysexAssembler();
    expect(a.add(hex('F0 00 20 0D')), isEmpty);
    final out = a.add(hex('73 03 09 F7 F0 00'));
    expect(out.single, hex('F0 00 20 0D 73 03 09 F7'));
  });

  test('Lange Parameterlisten werden auf 256 Bytes aufgeteilt', () {
    final ps = [for (var i = 0; i < 200; i++) Adi2Param(3, i % 24, i)];
    final msgs = buildSetParams(0x71, ps);
    expect(msgs.every((m) => m.length <= 256), isTrue);
    expect(msgs.fold<int>(0, (s, m) => s + (m.length - 7) ~/ 3), 200);
  });
}
