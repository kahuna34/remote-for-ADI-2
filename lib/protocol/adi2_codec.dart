// Kodierung/Dekodierung des ADI-2 SysEx-Protokolls (RME MIDI-Protokoll v1.2).

import 'dart:typed_data';

/// Geräte-IDs laut Protokoll.
enum Adi2Model {
  dac(0x71, 'ADI-2 DAC'),
  pro(0x72, 'ADI-2 Pro'),
  pro4(0x73, 'ADI-2/4 Pro');

  const Adi2Model(this.id, this.label);
  final int id;
  final String label;

  static Adi2Model? fromId(int id) {
    for (final m in values) {
      if (m.id == id) return m;
    }
    return null;
  }
}

/// Kommando-IDs.
abstract final class Adi2Cmd {
  static const paramsToRemote = 0x01;
  static const paramsToDevice = 0x02;
  static const request = 0x03;
  static const presetRequest = 0x04;
  static const nameToRemote = 0x05;
  static const nameToDevice = 0x06;
  static const status = 0x07;
}

/// Adressen (4 Bit) der 3-Byte-Container.
abstract final class Adi2Addr {
  static const input = 0;
  static const inputEqL = 1;
  static const inputEqR = 2;
  static const line = 3;
  static const lineEqL = 4;
  static const lineEqR = 5;
  static const ph12 = 6;
  static const ph12EqL = 7;
  static const ph12EqR = 8;
  static const ph34 = 9;
  static const ph34EqL = 10;
  static const ph34EqR = 11;
  static const device = 12;
  static const presetEqL = 13;
  static const presetEqR = 14;
}

const List<int> rmeVendor = [0x00, 0x20, 0x0D];

/// Ein Parameter-Wert, so wie er übertragen wird (in Inkrementen).
class Adi2Param {
  const Adi2Param(this.address, this.index, this.value);
  final int address;
  final int index;

  /// Rohwert in Inkrementen (z. B. -3 für -1,5 dB EQ-Gain,
  /// -100 für -10,0 dB Volume). Frequenzen in Hz.
  final int value;

  int get key => address << 8 | index;

  @override
  String toString() => 'P(a$address,i$index=$value)';

  @override
  bool operator ==(Object other) =>
      other is Adi2Param &&
      other.address == address &&
      other.index == index &&
      other.value == value;

  @override
  int get hashCode => Object.hash(address, index, value);
}

/// Parameter-Indizes, die Frequenzen sind (Faktor-10-Flag möglich).
/// Gilt für EQ-Adressen (1,2,4,5,7,8,10,11,13,14).
const Set<int> eqFrequencyIndices = {5, 8, 11, 14, 18, 22, 25};

bool isEqAddress(int a) =>
    a == 1 ||
    a == 2 ||
    a == 4 ||
    a == 5 ||
    a == 7 ||
    a == 8 ||
    a == 10 ||
    a == 11 ||
    a == 13 ||
    a == 14;

bool isFrequencyParam(int address, int index) =>
    isEqAddress(address) && eqFrequencyIndices.contains(index);

/// Kodiert einen Parameter in einen 3-Byte-Container.
List<int> encodeParam(Adi2Param p) {
  if (p.address == Adi2Addr.device) {
    final v = p.value.clamp(0, 2047);
    return [
      (12 << 3) | ((p.index >> 3) & 0x07),
      ((p.index & 0x07) << 4) | ((v >> 7) & 0x0F),
      v & 0x7F,
    ];
  }
  final b1 = ((p.address & 0x0F) << 3) | ((p.index >> 2) & 0x07);
  var b2 = (p.index & 0x03) << 5;
  int raw;
  if (isFrequencyParam(p.address, p.index) && p.value > 2047) {
    b2 |= 0x10; // Faktor 10
    raw = (p.value / 10).round().clamp(0, 2047);
  } else if (isFrequencyParam(p.address, p.index)) {
    raw = p.value.clamp(0, 2047);
  } else {
    raw = p.value.clamp(-2048, 2047) & 0x0FFF; // 12 Bit Zweierkomplement
    if (raw & 0x800 != 0) b2 |= 0x10;
  }
  b2 |= (raw >> 7) & 0x0F;
  return [b1, b2, raw & 0x7F];
}

/// Dekodiert einen 3-Byte-Container.
Adi2Param decodeParam(int b1, int b2, int b3) {
  final address = (b1 >> 3) & 0x0F;
  if (address == Adi2Addr.device) {
    final index = ((b1 & 0x07) << 3) | ((b2 >> 4) & 0x07);
    final value = ((b2 & 0x0F) << 7) | (b3 & 0x7F);
    return Adi2Param(address, index, value);
  }
  final index = ((b1 & 0x07) << 2) | ((b2 >> 5) & 0x03);
  final low11 = ((b2 & 0x0F) << 7) | (b3 & 0x7F);
  final flag = (b2 & 0x10) != 0;
  int value;
  if (isFrequencyParam(address, index)) {
    value = flag ? low11 * 10 : low11;
  } else {
    value = flag ? low11 - 2048 : low11; // Bit 11 = Vorzeichen
  }
  return Adi2Param(address, index, value);
}

Uint8List _sysex(int deviceId, int cmd, List<int> body) =>
    Uint8List.fromList([0xF0, ...rmeVendor, deviceId, cmd, ...body, 0xF7]);

/// Maximal 256 Bytes pro SysEx -> Parameter in Blöcke aufteilen.
List<Uint8List> buildSetParams(int deviceId, List<Adi2Param> params) {
  const maxPerBlock = (256 - 8) ~/ 3;
  final out = <Uint8List>[];
  for (var i = 0; i < params.length; i += maxPerBlock) {
    final chunk = params.skip(i).take(maxPerBlock);
    out.add(
      _sysex(deviceId, Adi2Cmd.paramsToDevice, [
        for (final p in chunk) ...encodeParam(p),
      ]),
    );
  }
  return out;
}

Uint8List buildRequestAll(int deviceId) =>
    _sysex(deviceId, Adi2Cmd.request, [0x09]);

/// presetIndex 0..19
Uint8List buildRequestEqPreset(int deviceId, int presetIndex) =>
    _sysex(deviceId, Adi2Cmd.request, [0x0A + presetIndex]);

/// setup 1..9
Uint8List buildLoadSetup(int deviceId, int setup) =>
    _sysex(deviceId, Adi2Cmd.presetRequest, [setup]);

/// setup 1..9
Uint8List buildSaveSetup(int deviceId, int setup) =>
    _sysex(deviceId, Adi2Cmd.presetRequest, [0x09 + setup]);

Uint8List buildLoadFactory(int deviceId) =>
    _sysex(deviceId, Adi2Cmd.presetRequest, [0x13]);

/// Name an das Gerät senden. slot: 0x01..0x14 EQ-Preset, 0x21..0x29 Setup.
/// Format wie vom Gerät gesendet: 14 Zeichen rechtsbündig, dann 00 00.
Uint8List buildSendName(int deviceId, int slot, String name) =>
    _sysex(deviceId, Adi2Cmd.nameToDevice, [slot, ...nameBytes(name)]);

const int nameLength = 14;

List<int> nameBytes(String name) {
  final clean = String.fromCharCodes(
    name.codeUnits.where((c) => c >= 0x20 && c <= 0x7E),
  ).trim();
  final cut = clean.length > nameLength
      ? clean.substring(0, nameLength)
      : clean;
  return [...cut.padLeft(nameLength).codeUnits, 0x00, 0x00];
}

/// Preset-Kennung: beim Lesen (Gerät -> App) auf Index 1, beim Speichern
/// (App -> Gerät) auf Index 2. Das RME-Dokument nennt nur Index 2; das
/// Gerät sendet 1 (Beispieldaten). Getestet am ADI-2 Pro, 2026-11-05.
const int presetFlagReadIdx = 1;
const int presetFlagStoreIdx = 2;

/// Indizes, die ein gespeichertes Preset enthalten darf. Nie 20 (B/T an)
/// oder 27 (B/T mit Preset laden): enthält ein Speichervorgang diese, schaltet
/// der ADI-2 Pro (EX) MIDI Control ab.
bool isPresetStoreIndex(int index, {required bool left}) =>
    (index >= 3 && index <= 19) || (left && index >= 21 && index <= 26);

/// Nachrichten zum Speichern eines EQ-Presets [n] (0..19), in dieser
/// Reihenfolge: Daten (13/14) -> Name -> Kennung (schreibt alles fest).
/// [left]/[right]: EQ-Index -> Rohwert.
List<Uint8List> buildStoreEqPreset(
  int deviceId,
  int n,
  Map<int, int> left,
  Map<int, int> right,
  bool dual,
  String? name,
) {
  final ps = <Adi2Param>[
    for (final e in left.entries)
      if (isPresetStoreIndex(e.key, left: true))
        Adi2Param(Adi2Addr.presetEqL, e.key, e.value),
    if (dual)
      for (final e in right.entries)
        if (isPresetStoreIndex(e.key, left: false))
          Adi2Param(Adi2Addr.presetEqR, e.key, e.value),
  ];
  return [
    ...buildSetParams(deviceId, ps),
    if (name != null) buildSendName(deviceId, n + 1, name),
    ...buildSetParams(deviceId, [
      Adi2Param(
        Adi2Addr.presetEqL,
        presetFlagStoreIdx,
        ((n & 0x1F) << 4) | (dual ? 1 : 0),
      ),
    ]),
  ];
}

// ---------------------------------------------------------------------------
// Eingehende Nachrichten

sealed class Adi2Message {
  const Adi2Message(this.deviceId);
  final int deviceId;
}

class Adi2ParamsMessage extends Adi2Message {
  const Adi2ParamsMessage(super.deviceId, this.params);
  final List<Adi2Param> params;
}

class Adi2NameMessage extends Adi2Message {
  const Adi2NameMessage(super.deviceId, this.slot, this.name);
  final int slot;
  final String name;
}

class Adi2StatusMessage extends Adi2Message {
  const Adi2StatusMessage(super.deviceId, this.data);

  /// Bytes 6..n der Statusmeldung (ohne Header, ohne F7).
  final List<int> data;
}

/// Parst eine komplette SysEx-Nachricht (F0 ... F7). Gibt null zurück, wenn
/// sie nicht von einem ADI-2 stammt.
Adi2Message? parseSysex(List<int> msg) {
  if (msg.length < 7 || msg.first != 0xF0 || msg.last != 0xF7) return null;
  if (msg[1] != 0x00 || msg[2] != 0x20 || msg[3] != 0x0D) return null;
  final dev = msg[4];
  if (Adi2Model.fromId(dev) == null) return null;
  final cmd = msg[5];
  final body = msg.sublist(6, msg.length - 1);
  switch (cmd) {
    case Adi2Cmd.paramsToRemote:
    case Adi2Cmd.paramsToDevice:
      final ps = <Adi2Param>[];
      for (var i = 0; i + 2 < body.length; i += 3) {
        ps.add(decodeParam(body[i], body[i + 1], body[i + 2]));
      }
      return Adi2ParamsMessage(dev, ps);
    case Adi2Cmd.nameToRemote:
    case Adi2Cmd.nameToDevice:
      if (body.isEmpty) return null;
      final chars = <int>[];
      for (final c in body.skip(1)) {
        if (c == 0) break;
        chars.add(c);
      }
      return Adi2NameMessage(dev, body[0], String.fromCharCodes(chars).trim());
    case Adi2Cmd.status:
      return Adi2StatusMessage(dev, body);
    default:
      return null;
  }
}

/// Setzt SysEx-Nachrichten aus beliebig gestückelten MIDI-Paketen zusammen.
class SysexAssembler {
  final List<int> _buf = [];
  bool _inside = false;

  List<List<int>> add(List<int> data) {
    final done = <List<int>>[];
    for (final b in data) {
      if (b == 0xF0) {
        _buf
          ..clear()
          ..add(b);
        _inside = true;
      } else if (_inside) {
        if (b == 0xF7) {
          _buf.add(b);
          done.add(List.of(_buf));
          _buf.clear();
          _inside = false;
        } else if (b >= 0xF8) {
          // Realtime-Bytes dürfen in SysEx stehen -> ignorieren
        } else if (b & 0x80 != 0) {
          _buf.clear();
          _inside = false; // abgebrochen
        } else {
          _buf.add(b);
          if (_buf.length > 1024) {
            _buf.clear();
            _inside = false;
          }
        }
      }
    }
    return done;
  }
}
