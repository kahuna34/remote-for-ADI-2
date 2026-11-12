import 'dart:convert';
import 'dart:typed_data';

/// One complete MIDI message per line; control lines never contain hex alone.
String encodeMidiLine(List<int> bytes) {
  if (bytes.isEmpty ||
      bytes.length > 4096 ||
      bytes.any((b) => b < 0 || b > 255)) {
    throw const FormatException('Invalid MIDI bytes');
  }
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

Uint8List decodeMidiLine(String line) {
  if (line.isEmpty ||
      line.length > 8192 ||
      line.length.isOdd ||
      !RegExp(r'^[0-9a-fA-F]+$').hasMatch(line)) {
    throw const FormatException('Invalid MIDI hex line');
  }
  return Uint8List.fromList([
    for (var i = 0; i < line.length; i += 2)
      int.parse(line.substring(i, i + 2), radix: 16),
  ]);
}

/// WinMM packs short messages little endian, including unused high bytes.
Uint8List unpackShortMidi(int packed) {
  final status = packed & 255;
  final length = switch (status) {
    >= 0x80 && < 0xc0 => 3,
    >= 0xc0 && < 0xe0 => 2,
    >= 0xe0 && < 0xf0 => 3,
    0xf1 || 0xf3 => 2,
    0xf2 => 3,
    >= 0xf6 => 1,
    _ => throw const FormatException('Invalid short MIDI status'),
  };
  return Uint8List.fromList([
    for (var i = 0; i < length; i++) (packed >> (8 * i)) & 255,
  ]);
}

class MidiHelperPort {
  const MidiHelperPort(this.id, this.name);
  final int id;
  final String name;
  Map<String, Object> toJson() => {'id': id, 'name': name};
}

class MidiHelperPorts {
  const MidiHelperPorts(this.inputs, this.outputs);
  final List<MidiHelperPort> inputs, outputs;

  factory MidiHelperPorts.parse(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    List<MidiHelperPort> ports(String key) => [
      for (final row in json[key] as List)
        MidiHelperPort(row['id'] as int, row['name'] as String),
    ];
    return MidiHelperPorts(ports('inputs'), ports('outputs'));
  }

  String encode() => jsonEncode({
    'inputs': inputs.map((p) => p.toJson()).toList(),
    'outputs': outputs.map((p) => p.toJson()).toList(),
  });

  // Same Windows name rule as Adi2Controller.autoConnectCandidates. Both
  // directions are required; never pick an unrelated generic MIDI port.
  List<String> get candidates => inputs
      .where((p) {
        final name = p.name.toLowerCase();
        return name.contains('adi-2') ||
            name.contains('adi2') ||
            name.contains('adi 2');
      })
      .where((p) => outputs.any((out) => out.name == p.name))
      .map((p) => p.name)
      .toSet()
      .toList();
}
