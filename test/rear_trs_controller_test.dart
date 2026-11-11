import 'dart:async';

import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/backup.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Midi implements MidiCommand {
  _Midi(this.address);
  final int address;
  final packets = StreamController<MidiPacket>.broadcast(sync: true);
  final device = MidiDevice(
    'rear-trs',
    'ADI-2/4 Pro SE',
    MidiDeviceType.serial,
    true,
  );
  final writes = <Adi2Param>[];
  int raw = 1;

  @override
  Future<List<MidiDevice>> get devices async => [];
  @override
  Stream<MidiPacket> get onMidiPacketReceived => packets.stream;
  @override
  void sendData(Uint8List data, {String? deviceId, int? timestamp}) {
    if (listEquals(data, buildRequestAll(Adi2Model.pro4.id))) {
      for (final response in buildSetParams(Adi2Model.pro4.id, [
        Adi2Param(address, OutIdx.rearTrsSource, raw),
      ])) {
        packets.add(MidiPacket(response, 0, device));
      }
    } else {
      final message = parseSysex(data);
      if (message is Adi2ParamsMessage) writes.addAll(message.params);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Controller extends Adi2Controller {
  _Controller(MidiCommand midi) : super(midi: midi);
  @override
  Future<List<EqPresetData>> readEqPresets({
    void Function(double)? progress,
  }) async => [];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final address in [Adi2Addr.line, Adi2Addr.ph34]) {
    testWidgets(
      'RequestAll, Backup und Restore behalten Rear-TRS-Adresse $address',
      (tester) async {
        final midi = _Midi(address);
        final controller = _Controller(midi);
        await controller.start();
        controller.device = midi.device;
        controller.model = Adi2Model.pro4;
        controller.state = ConnState.connected;
        controller.requestAll();
        expect(controller.value(address, OutIdx.rearTrsSource), 1);
        expect(
          controller.outputParamAddress(Adi2Addr.ph34, OutIdx.rearTrsSource),
          address,
        );
        final pending = controller.createBackup();
        await tester.pump(const Duration(milliseconds: 700));
        final backup = Adi2Backup.decode((await pending)!.encode());
        expect(backup.values[address << 8 | OutIdx.rearTrsSource], 1);
        expect(
          backup.values.keys.where((k) => k & 255 == OutIdx.rearTrsSource),
          hasLength(1),
        );
        controller.set(address, OutIdx.rearTrsSource, 0);
        expect(await controller.restoreBackup(backup), 1);
        expect(controller.value(address, OutIdx.rearTrsSource), 1);
        expect(midi.writes.last.address, address);
        expect(midi.writes.last.index, OutIdx.rearTrsSource);
        expect(midi.writes.last.value, 1);
        await tester.pump(const Duration(milliseconds: 600));
        controller.dispose();
        midi.device.dispose();
        await midi.packets.close();
      },
    );
  }

  for (final v in [Adi2Variant.pro4se, Adi2Variant.pro4ex]) {
    testWidgets(
      'Offline Rear TRS wird einmalig gespeichert und erneut geladen: $v',
      (tester) async {
        final midi = _Midi(Adi2Addr.line);
        final controller = _Controller(midi);
        await controller.startOffline(v);
        final address = controller.outputParamAddress(
          Adi2Addr.ph34,
          OutIdx.rearTrsSource,
        );
        expect(address, Adi2Addr.line);
        controller.set(address, OutIdx.rearTrsSource, 1);
        await tester.pump(const Duration(milliseconds: 600));
        await controller.startOffline(v);
        expect(controller.value(address, OutIdx.rearTrsSource), 1);
        expect(controller.value(Adi2Addr.ph34, OutIdx.rearTrsSource), isNull);
        controller.dispose();
        midi.device.dispose();
        await midi.packets.close();
      },
    );
  }
}
