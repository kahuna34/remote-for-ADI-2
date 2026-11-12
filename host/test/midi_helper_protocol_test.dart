import 'package:adi2_host/midi_helper_protocol.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hex preserves all byte values, leading zeros and upper case', () {
    final bytes = List.generate(256, (i) => i);
    final line = encodeMidiLine(bytes);
    expect(line.length, 512);
    expect(decodeMidiLine(line.toUpperCase()), bytes);
    expect(encodeMidiLine([0, 0xf0, 0x0a, 0xf7]), '00f00af7');
  });
  test('rejects malformed or oversized frames', () {
    for (final text in [
      '',
      'a',
      'zz',
      '0x12',
      '90 001',
      'f0\nf7',
      '00' * 4097,
    ]) {
      expect(() => decodeMidiLine(text), throwsFormatException);
    }
    for (final bytes in [
      <int>[],
      [-1],
      [256],
      List.filled(4097, 0),
    ]) {
      expect(() => encodeMidiLine(bytes), throwsFormatException);
    }
  });
  test('shared pure Dart assembler splits and joins multiple SysEx', () {
    final assembler = SysexAssembler();
    expect(assembler.add([0xf0, 0, 0x20]), isEmpty);
    final messages = assembler.add([0x0d, 0xf7, 0xf0, 1, 0xf8, 2, 0xf7]);
    expect(messages.map(encodeMidiLine), ['f000200df7', 'f00102f7']);
    expect(messages.map(encodeMidiLine).map(decodeMidiLine), messages);
  });
  test('short messages have their actual length without trailing zeros', () {
    for (final entry in {
      0x7f3c90: [0x90, 0x3c, 0x7f],
      0x05c0: [0xc0, 5],
      0x06d0: [0xd0, 6],
      0x0201f2: [0xf2, 1, 2],
      0x07f1: [0xf1, 7],
      0xf8: [0xf8],
      0xfa: [0xfa],
    }.entries) {
      expect(unpackShortMidi(entry.key), entry.value);
      expect(
        decodeMidiLine(encodeMidiLine(unpackShortMidi(entry.key))),
        entry.value,
      );
    }
    expect(() => unpackShortMidi(0x3c), throwsFormatException);
  });
  test('list JSON preserves names and selects only paired ADI-2 ports', () {
    const ports = MidiHelperPorts(
      [
        MidiHelperPort(0, 'Babyface'),
        MidiHelperPort(1, 'adi-2 DAC Midi Port 1'),
        MidiHelperPort(2, 'ADI-2 Pro'),
      ],
      [MidiHelperPort(0, 'adi-2 DAC Midi Port 1')],
    );
    final decoded = MidiHelperPorts.parse(ports.encode());
    expect(decoded.candidates, ['adi-2 DAC Midi Port 1']);
    expect(decoded.inputs.last.id, 2);
    expect(decoded.inputs.last.name, 'ADI-2 Pro');
  });
}
