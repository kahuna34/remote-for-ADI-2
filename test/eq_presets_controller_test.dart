import 'dart:async';

import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/eq/eq_editor_apply.dart';
import 'package:adi2_remote/eq/eq_editor_buffer.dart';
import 'package:adi2_remote/eq/eq_model.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';

class _Midi implements MidiCommand {
  final packets = StreamController<MidiPacket>.broadcast(sync: true);
  final sent = <Uint8List>[];
  final device = MidiDevice(
    'eq-test',
    'ADI-2 Pro',
    MidiDeviceType.serial,
    true,
  );
  bool answer = true;
  int requests = 0;

  @override
  Future<List<MidiDevice>> get devices async => [];
  @override
  Stream<MidiPacket> get onMidiPacketReceived => packets.stream;

  @override
  void sendData(Uint8List data, {String? deviceId, int? timestamp}) {
    sent.add(data);
    for (var n = 0; n < 20; n++) {
      if (!listEquals(data, buildRequestEqPreset(Adi2Model.pro.id, n))) {
        continue;
      }
      requests++;
      if (!answer) return;
      packets.add(
        MidiPacket(
          buildSendName(Adi2Model.pro.id, n + 1, 'Slot ${n + 1}'),
          0,
          device,
        ),
      );
      for (final message in buildSetParams(Adi2Model.pro.id, [
        Adi2Param(
          Adi2Addr.presetEqL,
          EqIdx2.presetFlags,
          (n << 4) | (n == 19 ? 15 : 1),
        ),
        if (n != 19) ...[
          Adi2Param(Adi2Addr.presetEqL, 4, n + 1),
          Adi2Param(Adi2Addr.presetEqR, 4, -n - 1),
        ],
      ])) {
        packets.add(MidiPacket(message, 0, device));
      }
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late _Midi midi;
  late Adi2Controller controller;

  setUp(() async {
    midi = _Midi();
    controller = Adi2Controller(midi: midi);
    await controller.start();
    controller.device = midi.device;
    controller.model = Adi2Model.pro;
    controller.state = ConnState.connected;
  });

  tearDown(() async {
    controller.dispose();
    midi.device.dispose();
    await midi.packets.close();
  });

  test('Factory sendet Codec-Befehl und fragt nach 400 ms neu ab', () async {
    controller.loadFactory();
    expect(midi.sent, hasLength(1));
    expect(midi.sent.single, orderedEquals(buildLoadFactory(Adi2Model.pro.id)));
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(midi.sent, hasLength(2));
    expect(midi.sent.last, orderedEquals(buildRequestAll(Adi2Model.pro.id)));
    controller.state = ConnState.offline;
    controller.loadFactory();
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(midi.sent, hasLength(2));
  });

  test('Setup-Namen verwenden Codec, Slot und normalisierten Cache', () {
    var notifications = 0;
    controller.addListener(() => notifications++);
    controller.renameSetup(9, 'A very long setup name');
    expect(
      midi.sent.single,
      orderedEquals(
        buildSendName(Adi2Model.pro.id, 0x29, 'A very long setup name'),
      ),
    );
    expect(controller.names[0x29], 'A very long se');
    expect(notifications, 1);
    controller.renameSetup(0, 'Invalid');
    controller.state = ConnState.offline;
    controller.renameSetup(1, 'Offline');
    expect(midi.sent, hasLength(1));
    expect(controller.names[0x21], isNull);
  });

  test(
    'Parallele Leser teilen 20 Abfragen, Cache enthält Daten und leere Slots',
    () async {
      final progress = <double>[];
      final first = controller.readEqPresets(progress: progress.add);
      final second = controller.readEqPresets();
      final result = await first;
      expect(await second, same(result));
      expect(midi.requests, 20);
      expect(progress, [for (var n = 1; n <= 20; n++) n / 20]);
      expect(result.first.name, 'Slot 1');
      expect(result.first.left[4], 1);
      expect(result.first.right[4], -1);
      expect(result.first.dual, isTrue);
      expect(result.last.empty, isTrue);
      expect(result.last.dual, isFalse);
      expect(controller.eqPresets, same(result));
      expect(controller.eqPresetReadProgress, isNull);

      midi.answer = false;
      await expectLater(
        controller.readEqPresets(),
        throwsA(isA<TimeoutException>()),
      );
      expect(controller.eqPresets, same(result));
      expect(controller.eqPresetReadProgress, isNull);
    },
  );

  test(
    'Backup liest über dieselbe Methode und speichert alle 20 Presets',
    () async {
      final backup = await controller.createBackup();
      expect(backup!.presets, same(controller.eqPresets));
      expect(backup.presets.length, 20);
      expect(midi.requests, 20);
      expect(
        backup.values.keys.where((key) => [13, 14].contains(key >> 8)),
        isEmpty,
      );
    },
  );

  test('Store und Lesen verwenden den Geräte-Puffer nacheinander', () async {
    final store = controller.storeEqPresetData(
      19,
      {4: 8, 20: 1, 27: 1},
      {4: -4},
      true,
      'Stored',
    );
    final read = controller.readEqPresets();
    await store;
    expect(controller.eqPresets!.single.name, 'Stored');
    expect(controller.eqPresets!.single.left, {4: 8});
    final presets = await read;
    expect(presets.length, 20);
    // Eine Store-Nachfrage, danach die vollständige Abfrage in Slot-Reihenfolge.
    expect(midi.requests, 21);
    final queries = [
      for (final message in midi.sent)
        for (var n = 0; n < 20; n++)
          if (listEquals(message, buildRequestEqPreset(Adi2Model.pro.id, n))) n,
    ];
    expect(queries, [19, for (var n = 0; n < 20; n++) n]);
  });

  test('Verbindungsabbruch verwirft laufende Daten und erlaubt einen neuen Leseversuch', () async {
    midi.answer = false;
    final read = controller.readEqPresets();
    final failure = expectLater(read, throwsStateError);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    controller.disconnect();
    await failure;
    expect(controller.eqPresets, isNull);
    expect(controller.eqPresetReadProgress, isNull);
  });

  List<Adi2Param> sentParams() => [
    for (final m in midi.sent)
      if (parseSysex(m) case Adi2ParamsMessage(:final params)) ...params,
  ];

  test(
    'Speichern nimmt die angezeigte Kurve, auch wenn Gain noch hochfährt',
    () async {
      const left = Adi2Addr.lineEqL, right = Adi2Addr.lineEqR;
      controller.setMany([
        const Adi2Param(left, 4, 0),
        const Adi2Param(left, EqIdx2.presetSelect, 0),
      ]);
      // +6 dB: läuft gebremst (0,5 dB je Takt), der Gerätewert hängt hinterher.
      controller.setEq(left, 4, 12);
      expect(controller.value(left, 4), 0);
      midi.sent.clear();
      await controller.storeEqPreset(left, right, 2, 'Lib', false);
      final stored = sentParams().where(
        (p) => p.address == Adi2Addr.presetEqL && p.index == 4,
      );
      expect(stored.map((p) => p.value), [12]);
      // Keine offenen Schritte mehr, die das geladene Preset verändern.
      expect(controller.eqValue(left, 4), controller.value(left, 4));
      expect(controller.value(left, EqIdx2.presetSelect), 4);
    },
  );

  test(
    'Speichern in das gewählte Preset wählt erst Manual, dann das Preset',
    () async {
      const left = Adi2Addr.lineEqL, right = Adi2Addr.lineEqR;
      controller.setMany([const Adi2Param(left, EqIdx2.presetSelect, 4)]);
      midi.sent.clear();
      await controller.storeEqPreset(left, right, 2, 'Same', false);
      final selects = sentParams()
          .where((p) => p.address == left && p.index == EqIdx2.presetSelect)
          .map((p) => p.value);
      expect(selects, [0, 4]);
    },
  );

  test('Preset aus Temp heraus laden wählt erst Manual', () async {
    const left = Adi2Addr.lineEqL;
    controller.setMany([const Adi2Param(left, EqIdx2.presetSelect, 1)]);
    midi.sent.clear();
    await controller.loadEqPreset(left, 4);
    final selects = sentParams()
        .where((p) => p.address == left && p.index == EqIdx2.presetSelect)
        .map((p) => p.value);
    expect(selects, [0, 4]);
  });

  test('Editor ohne Dual EQ schreibt den rechten Kanal nicht', () {
    final editor = EqEditorBuffer()
      ..set(Adi2Addr.presetEqL, 4, -10)
      ..set(Adi2Addr.presetEqR, 3, 1);
    applyEqEditor(controller, Adi2Addr.line, editor);
    expect(controller.eqValue(Adi2Addr.lineEqL, 4), -10);
    expect(controller.eqValue(Adi2Addr.lineEqR, 3), isNull);
    editor.dual = true;
    applyEqEditor(controller, Adi2Addr.line, editor);
    expect(controller.eqValue(Adi2Addr.lineEqR, 3), 1);
  });
}
