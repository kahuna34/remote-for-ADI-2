import 'dart:async';

import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/backup.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Simulierter ADI-2 Pro: Schaltet Dual Phones ein, wird Phones 1/2 mit dem
/// im Gerät gespeicherten Pegel aktiv (hier −2 dB).
class _Midi implements MidiCommand {
  _Midi();
  final packets = StreamController<MidiPacket>.broadcast(sync: true);
  final device = MidiDevice('pro', 'ADI-2 Pro', MidiDeviceType.serial, true);
  final writes = <Adi2Param>[];
  final state = <int, int>{
    Adi2Addr.device << 8 | 8: 0,
    Adi2Addr.ph12 << 8 | OutIdx.volume: -20,
    Adi2Addr.ph12 << 8 | OutIdx.mute: 0,
    Adi2Addr.ph12 << 8 | OutIdx.refLevel: 3,
    Adi2Addr.ph34 << 8 | OutIdx.volume: -355,
    Adi2Addr.ph34 << 8 | OutIdx.autoRef: 1,
  };

  void _answer() {
    for (final packet in buildSetParams(Adi2Model.pro.id, [
      for (final e in state.entries)
        Adi2Param(e.key >> 8, e.key & 0xFF, e.value),
    ])) {
      packets.add(MidiPacket(packet, 0, device));
    }
  }

  @override
  Future<List<MidiDevice>> get devices async => [];
  @override
  Stream<MidiPacket> get onMidiPacketReceived => packets.stream;
  @override
  void sendData(Uint8List data, {String? deviceId, int? timestamp}) {
    if (data.length > 6 && data[5] == Adi2Cmd.request) {
      scheduleMicrotask(_answer);
      return;
    }
    final message = parseSysex(data);
    if (message is Adi2ParamsMessage) {
      writes.addAll(message.params);
      for (final p in message.params) {
        state[p.key] = p.value;
        // Wie am ADI-2 Pro gemessen: Auto Ref aus hebt die Lautstärke an.
        if (p.address == Adi2Addr.ph34 &&
            p.index == OutIdx.autoRef &&
            p.value == 0) {
          state[Adi2Addr.ph34 << 8 | OutIdx.volume] = -205;
        }
      }
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const dual = Adi2Param(Adi2Addr.device, 8, 1);
  const muteOn = Adi2Param(Adi2Addr.ph12, OutIdx.mute, 1);
  const muteOff = Adi2Param(Adi2Addr.ph12, OutIdx.mute, 0);

  Future<(Adi2Controller, _Midi)> connect() async {
    SharedPreferences.setMockInitialValues({});
    final midi = _Midi();
    final c = Adi2Controller(midi: midi);
    await c.start();
    c.device = midi.device;
    c.model = Adi2Model.pro;
    c.state = ConnState.connected;
    // Gerät meldet Dual Phones aus; Phones 1/2 ist inaktiv, die App kennt
    // nur einen alten Wert.
    for (final packet in buildSetParams(Adi2Model.pro.id, const [
      Adi2Param(Adi2Addr.device, 8, 0),
      Adi2Param(Adi2Addr.ph12, OutIdx.volume, -220),
    ])) {
      midi.packets.add(MidiPacket(packet, 0, midi.device));
    }
    midi.writes.clear();
    return (c, midi);
  }

  void expectMutedActivation(List<Adi2Param> writes) {
    final i = writes.indexOf(dual);
    expect(i, greaterThan(0), reason: 'Dual Phones wird eingeschaltet');
    expect(writes[i - 1], muteOn, reason: 'davor stumm');
    expect(writes[i + 1], muteOn, reason: 'danach sofort wieder stumm');
    expect(
      writes.indexOf(muteOff),
      anyOf(-1, greaterThan(i + 1)),
      reason: 'Stummschaltung erst nach dem Zurücklesen aufheben',
    );
  }

  test(
    'Backup mit Dual Phones: erst stumm, dann höchstens Zielpegel',
    () async {
      final (c, midi) = await connect();
      addTearDown(c.dispose);
      final b = Adi2Backup(
        variant: 'pro',
        label: 'ADI-2 Pro',
        created: DateTime(2026),
        values: const {
          Adi2Addr.device << 8 | 8: 1,
          Adi2Addr.ph12 << 8 | OutIdx.volume: -100,
          Adi2Addr.ph12 << 8 | OutIdx.refLevel: 1,
          Adi2Addr.ph12 << 8 | OutIdx.mute: 0,
        },
        presets: const [],
        setupNames: const {},
      );
      await c.restoreBackup(b);
      expectMutedActivation(midi.writes);
      // Gerät hatte −2 dB gespeichert, Ziel ist −10 dB: leiser stellen, dann
      // Stummschaltung aufheben.
      final vol = midi.writes.lastWhere(
        (p) => p.address == Adi2Addr.ph12 && p.index == OutIdx.volume,
      );
      expect(vol.value, -100);
      expect(
        midi.writes.indexOf(vol),
        lessThan(midi.writes.lastIndexOf(muteOff)),
      );
      expect(midi.state[Adi2Addr.ph12 << 8 | OutIdx.volume], -100);
      expect(midi.state[Adi2Addr.ph12 << 8 | OutIdx.refLevel], 1);
      expect(midi.state[Adi2Addr.ph12 << 8 | OutIdx.mute], 0);
    },
  );

  test(
    'Ziel lauter als Gerät: Pegel bleibt beim leiseren Gerätewert',
    () async {
      final (c, midi) = await connect();
      addTearDown(c.dispose);
      final b = Adi2Backup(
        variant: 'pro',
        label: 'ADI-2 Pro',
        created: DateTime(2026),
        values: const {
          Adi2Addr.device << 8 | 8: 1,
          Adi2Addr.ph12 << 8 | OutIdx.volume: 0,
          Adi2Addr.ph12 << 8 | OutIdx.mute: 0,
        },
        presets: const [],
        setupNames: const {},
      );
      await c.restoreBackup(b);
      expectMutedActivation(midi.writes);
      expect(midi.state[Adi2Addr.ph12 << 8 | OutIdx.volume], -20);
      expect(
        midi.writes.where(
          (p) => p.address == Adi2Addr.ph12 && p.index == OutIdx.volume,
        ),
        isEmpty,
      );
    },
  );

  test(
    'Schalter in der App: Phones 1/2 bleibt nach dem Einschalten stumm',
    () async {
      final (c, midi) = await connect();
      addTearDown(c.dispose);
      c.set(Adi2Addr.device, 8, 1);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expectMutedActivation(midi.writes);
      expect(midi.writes, isNot(contains(muteOff)));
      expect(midi.state[Adi2Addr.ph12 << 8 | OutIdx.mute], 1);
      expect(midi.state[Adi2Addr.device << 8 | 8], 1);
    },
  );
  test(
    'Gerät hebt Lautstärke beim Schreiben selbst an: App senkt zurück',
    () async {
      final (c, midi) = await connect();
      addTearDown(c.dispose);
      for (final packet in buildSetParams(Adi2Model.pro.id, const [
        Adi2Param(Adi2Addr.ph34, OutIdx.volume, -355),
        Adi2Param(Adi2Addr.ph34, OutIdx.autoRef, 1),
      ])) {
        midi.packets.add(MidiPacket(packet, 0, midi.device));
      }
      midi.writes.clear();
      final b = Adi2Backup(
        variant: 'pro',
        label: 'ADI-2 Pro',
        created: DateTime(2026),
        values: const {
          Adi2Addr.ph34 << 8 | OutIdx.autoRef: 0,
          Adi2Addr.ph34 << 8 | OutIdx.volume: -355,
        },
        presets: const [],
        setupNames: const {},
      );
      await c.restoreBackup(b);
      // Die Nachkontrolle läuft im Hintergrund.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(midi.state[Adi2Addr.ph34 << 8 | OutIdx.volume], -355);
      expect(
        midi.writes.last,
        const Adi2Param(Adi2Addr.ph34, OutIdx.volume, -355),
      );
    },
  );
}
