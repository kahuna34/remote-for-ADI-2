import 'dart:async';

import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/backup.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/analyzer_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A DAC that applies writes but, like the real one, does not echo them.
class _SilentDac implements MidiCommand {
  final packets = StreamController<MidiPacket>.broadcast(sync: true);
  final device = MidiDevice('dac', 'ADI-2 DAC', MidiDeviceType.serial, true);
  final state = <int, Adi2Param>{};
  bool ignoreWrites = false;
  bool answers = true;
  final omittedKeys = <int>{};
  int requests = 0;

  void store(int address, int index, int value) =>
      state[address << 8 | index] = Adi2Param(address, index, value);

  @override
  Future<List<MidiDevice>> get devices async => [];
  @override
  Stream<MidiPacket> get onMidiPacketReceived => packets.stream;
  @override
  void sendData(Uint8List data, {String? deviceId, int? timestamp}) {
    if (listEquals(data, buildRequestAll(Adi2Model.dac.id))) {
      requests++;
      if (!answers) return;
      for (final response in buildSetParams(
        Adi2Model.dac.id,
        state.values.where((p) => !omittedKeys.contains(p.key)).toList(),
      )) {
        packets.add(MidiPacket(response, 0, device));
      }
      return;
    }
    final message = parseSysex(data);
    if (message is Adi2ParamsMessage && !ignoreWrites) {
      for (final p in message.params) {
        store(p.address, p.index, p.value);
      }
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The fake device has no EQ presets to read after connecting.
class _Controller extends Adi2Controller {
  _Controller(MidiCommand midi) : super(midi: midi);
  @override
  Future<List<EqPresetData>> readEqPresets({
    void Function(double)? progress,
  }) async => [];
}

void main() {
  const outputs = [Adi2Addr.line, Adi2Addr.ph12, Adi2Addr.ph34];
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(Adi2Controller, _SilentDac)> connect(WidgetTester tester) async {
    final midi = _SilentDac();
    for (final a in outputs) {
      midi.store(a, OutIdx.volume, 0);
      midi.store(a, OutIdx.mute, 1);
    }
    final c = _Controller(midi);
    await c.start();
    c.device = midi.device;
    // The first device message connects it and starts the volume timer.
    for (final response in buildSetParams(Adi2Model.dac.id, [
      Adi2Param(Adi2Addr.line, OutIdx.mute, 1),
    ])) {
      midi.packets.add(MidiPacket(response, 0, midi.device));
    }
    await tester.pump(const Duration(milliseconds: 700));
    final read = c.refreshConfirmedValues();
    await tester.pump(const Duration(milliseconds: 300));
    expect(await read, isTrue);
    return (c, midi);
  }

  Future<void> finish(WidgetTester tester, Adi2Controller c) async {
    await tester.pump(const Duration(seconds: 1));
    c.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('Stilles Gerät: Absenkung wird durch Abfrage bestätigt', (
    tester,
  ) async {
    final (c, midi) = await connect(tester);
    final result = ensureOutputsQuiet(c);
    await tester.pump(const Duration(seconds: 12));
    expect(await result, isTrue);
    for (final a in outputs) {
      expect(midi.state[a << 8 | OutIdx.volume]!.value, -300);
    }
    await finish(tester, c);
  });

  testWidgets('Gerät übernimmt die Absenkung nicht: Prüfung schlägt fehl', (
    tester,
  ) async {
    final (c, midi) = await connect(tester);
    midi.ignoreWrites = true;
    final result = ensureOutputsQuiet(c);
    await tester.pump(const Duration(seconds: 12));
    expect(await result, isFalse);
    await finish(tester, c);
  });

  testWidgets('Keine Antwort des Geräts: Prüfung schlägt fehl', (tester) async {
    final (c, midi) = await connect(tester);
    midi.answers = false;
    final result = ensureOutputsQuiet(c);
    await tester.pump(const Duration(seconds: 12));
    expect(await result, isFalse);
    await finish(tester, c);
  });

  testWidgets(
    'Anzeige folgt dem Gerät, wenn es eine Änderung nicht übernimmt',
    (tester) async {
      final (c, midi) = await connect(tester);
      midi.ignoreWrites = true;
      c.set(Adi2Addr.line, OutIdx.mute, 0);
      expect(c.value(Adi2Addr.line, OutIdx.mute), 0);
      await tester.pump(const Duration(seconds: 1));
      expect(c.value(Adi2Addr.line, OutIdx.mute), 1);
      await finish(tester, c);
    },
  );

  testWidgets('Während einer Rampe wird nicht zurückgelesen', (tester) async {
    final (c, midi) = await connect(tester);
    midi.store(Adi2Addr.line, OutIdx.volume, -600);
    final read = c.refreshConfirmedValues();
    await tester.pump(const Duration(milliseconds: 300));
    await read;
    final before = midi.requests;
    c.setVolume(Adi2Addr.line, -300, followLink: false);
    await tester.pump(const Duration(milliseconds: 900));
    expect(c.volumeTarget(Adi2Addr.line), isNotNull);
    expect(midi.requests, before);
    await tester.pump(const Duration(seconds: 30));
    expect(c.volumeTarget(Adi2Addr.line), isNull);
    expect(midi.requests, greaterThan(before));
    expect(midi.state[Adi2Addr.line << 8 | OutIdx.volume]!.value, -300);
    await finish(tester, c);
  });

  testWidgets('Entstummen am Gerät zeigt die frische Abfrage', (tester) async {
    final (c, midi) = await connect(tester);
    expect(calibrationOutputsMuted(c), isTrue);
    midi.store(Adi2Addr.ph12, OutIdx.mute, 0);
    final read = c.refreshConfirmedValues();
    await tester.pump(const Duration(milliseconds: 300));
    expect(await read, isTrue);
    expect(calibrationOutputsMuted(c), isFalse);
    await finish(tester, c);
  });

  for (final index in [OutIdx.mute, OutIdx.volume]) {
    testWidgets('Frische Bestätigung fehlt für Ausgangsparameter $index', (
      tester,
    ) async {
      final (c, midi) = await connect(tester);
      final requiredKeys = [
        for (final address in outputs) ...[
          address << 8 | OutIdx.mute,
          address << 8 | OutIdx.volume,
        ],
      ];
      midi.omittedKeys.add(Adi2Addr.ph34 << 8 | index);
      // Cached values and replies from the other outputs are insufficient.
      final missing = c.refreshConfirmedValues(requiredKeys: requiredKeys);
      await tester.pump(const Duration(seconds: 3));
      expect(await missing, isFalse);
      final quiet = ensureOutputsQuiet(c);
      await tester.pump(const Duration(seconds: 12));
      expect(await quiet, isFalse);
      expect(calibrationOutputsMuted(c), isTrue);
      // Callers without required keys retain the message-based behaviour.
      final legacy = c.refreshConfirmedValues();
      await tester.pump(const Duration(milliseconds: 300));
      expect(await legacy, isTrue);
      midi.omittedKeys.clear();
      final complete = c.refreshConfirmedValues(requiredKeys: requiredKeys);
      await tester.pump(const Duration(milliseconds: 300));
      expect(await complete, isTrue);
      final confirmedQuiet = ensureOutputsQuiet(c);
      await tester.pump(const Duration(seconds: 3));
      expect(await confirmedQuiet, isTrue);
      await finish(tester, c);
    });
  }
}
