import 'dart:async';
import 'dart:convert';

import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/backup.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Midi implements MidiCommand {
  final packets = StreamController<MidiPacket>.broadcast(sync: true);
  final device = MidiDevice('pro', 'ADI-2 Pro', MidiDeviceType.serial, true);
  final writes = <Adi2Param>[];

  @override
  Future<List<MidiDevice>> get devices async => [];
  @override
  Stream<MidiPacket> get onMidiPacketReceived => packets.stream;
  @override
  void sendData(Uint8List data, {String? deviceId, int? timestamp}) {
    final message = parseSysex(data);
    if (message is Adi2ParamsMessage) writes.addAll(message.params);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  const address = Adi2Addr.line;
  const volumeKey = address << 8 | OutIdx.volume;
  const refKey = address << 8 | OutIdx.refLevel;

  for (final backup in [false, true]) {
    for (final limit in [false, true]) {
      testWidgets(
        '${backup ? 'Backup' : 'Offline'} Ref +4 → +24, Limit $limit',
        (tester) async {
          final saved = {volumeKey: -150, refKey: 3};
          SharedPreferences.setMockInitialValues({
            'offline_pro': jsonEncode({
              for (final e in saved.entries) '${e.key}': e.value,
            }),
          });
          final midi = _Midi();
          final c = Adi2Controller(midi: midi);
          await c.start();
          c.device = midi.device;
          c.model = Adi2Model.pro;
          c.state = ConnState.connected;
          for (final packet in buildSetParams(Adi2Model.pro.id, [
            const Adi2Param(address, OutIdx.refLevel, 0),
            const Adi2Param(address, OutIdx.volume, -100),
          ])) {
            midi.packets.add(MidiPacket(packet, 0, midi.device));
          }
          if (limit) await c.setLimitDbu(address, 0);
          midi.writes.clear();
          if (backup) {
            await c.restoreBackup(
              Adi2Backup(
                variant: 'pro',
                label: 'ADI-2 Pro',
                created: DateTime(2026),
                values: saved,
                presets: [],
                setupNames: {},
              ),
            );
          } else {
            await c.transferOffline();
          }
          final volumes = midi.writes.where((p) => p.index == OutIdx.volume);
          expect(volumes, isNotEmpty);
          if (limit) {
            expect(
              volumes.map((p) => p.value),
              everyElement(lessThanOrEqualTo(-240)),
            );
            expect(c.volGuard.limitFor(address), -240);
          } else {
            expect(volumes.map((p) => p.value), [-150]);
          }
          final ref = midi.writes.indexWhere((p) => p.index == OutIdx.refLevel);
          expect(ref, greaterThanOrEqualTo(0));
          expect(midi.writes[ref].value, 3);
          // The protective lowering may precede Ref Level. The transferred
          // volume in the final batch must follow it and stay below the limit.
          expect(midi.writes.last.index, OutIdx.volume);
          expect(midi.writes.last.value, limit ? -240 : -150);
          expect(ref, lessThan(midi.writes.length - 1));
          await tester.pump(const Duration(seconds: 1));
          c.dispose();
          midi.device.dispose();
          await midi.packets.close();
        },
      );
    }
  }
}
