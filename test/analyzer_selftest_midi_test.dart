import 'dart:async';

import 'package:adi2_remote/analyzer/analyzer_routing.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/dev/analyzer_selftest.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/protocol/adi2_status.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'analyzer_selftest_test.dart' show TestSelfTestAudio;

class _Midi implements MidiCommand {
  final packets = StreamController<MidiPacket>.broadcast(sync: true);
  final device = MidiDevice(
    'selftest-midi',
    'ADI-2 Pro',
    MidiDeviceType.serial,
    true,
  );
  final actual = <int, int>{
    for (final a in [3, 6, 9])
      for (final i in [
        OutIdx.mute,
        OutIdx.volume,
        OutIdx.loopback,
        OutIdx.source,
      ])
        if (a != Adi2Addr.ph12 || i != OutIdx.loopback)
          a << 8 | i: i == OutIdx.volume ? -250 : 0,
  };
  bool answer = true;
  final writes = <Adi2Param>[];
  void emit(Iterable<Adi2Param> params) {
    for (final message in buildSetParams(Adi2Model.pro.id, params.toList())) {
      packets.add(MidiPacket(message, 0, device));
    }
  }

  void emitStatus() {
    packets.add(
      MidiPacket(
        Uint8List.fromList([
          0xf0,
          ...rmeVendor,
          Adi2Model.pro.id,
          Adi2Cmd.status,
          ...List.filled(13, 0),
          0xf7,
        ]),
        0,
        device,
      ),
    );
  }

  @override
  Future<List<MidiDevice>> get devices async => [];
  @override
  Stream<MidiPacket> get onMidiPacketReceived => packets.stream;
  @override
  void sendData(Uint8List data, {String? deviceId, int? timestamp}) {
    if (listEquals(data, buildRequestAll(Adi2Model.pro.id))) {
      if (answer) {
        emit(
          actual.entries.map(
            (e) => Adi2Param(e.key >> 8, e.key & 255, e.value),
          ),
        );
      }
    } else {
      final message = parseSysex(data);
      if (message is Adi2ParamsMessage) {
        writes.addAll(message.params);
        for (final p in message.params) {
          actual[p.key] = p.value;
        }
      }
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

// Simulates a transport which supplies a hardware serial after MIDI status.
class _SerialMidiDevice extends MidiSelfTestDevice {
  _SerialMidiDevice(super.ctrl);
  String? serial;
  @override
  SelfTestIdentity get recoveryIdentity => SelfTestIdentity(
    model: super.recoveryIdentity.model,
    variant: super.recoveryIdentity.variant,
    serial: serial,
    connection: identity,
  );
}

void main() {
  late _Midi midi;
  late Adi2Controller ctrl;
  late MidiSelfTestDevice device;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
    midi = _Midi();
    ctrl = Adi2Controller(midi: midi);
    await ctrl.start();
    ctrl.device = midi.device;
    ctrl.model = Adi2Model.pro;
    ctrl.state = ConnState.connected;
    device = MidiSelfTestDevice(ctrl);
  });
  tearDown(() async {
    ctrl.dispose();
    midi.device.dispose();
    await midi.packets.close();
  });
  test(
    'recovery after restart waits for status then restores via actual MIDI RX',
    () async {
      final original = Map.of(midi.actual);
      final audio = TestSelfTestAudio([]);
      audio.journal = {
        'device': 'old-android-endpoint/${Adi2Model.pro.id}',
        'values': {for (final e in original.entries) '${e.key}': e.value},
      };
      midi.actual.updateAll(
        (key, value) => switch (key & 255) {
          OutIdx.mute => 1,
          OutIdx.volume => -1000,
          OutIdx.source => 4,
          OutIdx.loopback => 1,
          _ => value,
        },
      );
      final session = AnalyzerSelfTest(device, audio);
      addTearDown(session.dispose);
      await session.loadRecovery();
      final pending = session.retryRestore();
      await Future<void>.delayed(Duration.zero);
      expect(midi.writes, isEmpty);
      expect(audio.journal, isNotNull);
      expect(session.running, isTrue);
      midi.emitStatus();
      await pending;
      expect(session.restored, isTrue);
      expect(midi.actual, original);
      expect(audio.journal, isNull);
      expect(ctrl.analyzerSelfTestActive, isFalse);
    },
  );

  test(
    'MIDI readiness waits for a required serial delivered after status',
    () async {
      final serialDevice = _SerialMidiDevice(ctrl);
      var ready = false;
      final pending = serialDevice
          .waitUntilReady(requireSerial: true)
          .then((_) => ready = true);
      midi.emitStatus();
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse);
      expect(midi.writes, isEmpty);
      serialDevice.serial = ' AB-1234 ';
      midi.emitStatus();
      await pending;
      expect(ready, isTrue);
      expect(
        SelfTestIdentity.normalizedSerial(serialDevice.recoveryIdentity.serial),
        'AB1234',
      );
    },
  );

  test('Pro self-test never writes Loopback to Phones 1/2', () async {
    midi.emitStatus();
    final snapshot = await device.read();
    expect(device.loopbackOutputs, [Adi2Addr.line, Adi2Addr.ph34]);
    expect(snapshot, isNot(contains(Adi2Addr.ph12 << 8 | OutIdx.loopback)));
    final session = AnalyzerSelfTest(
      device,
      TestSelfTestAudio([]),
      silence: Duration.zero,
    );
    addTearDown(session.dispose);
    await session.run(Adi2Addr.ph34);
    expect(session.error, isNull);
    expect(session.restored, isTrue);
    await session.resetTestState();
    expect(session.error, isNull);
    expect(midi.writes.where((p) => p.index == OutIdx.loopback), isNotEmpty);
    expect(
      midi.writes.where(
        (p) => p.address == Adi2Addr.ph12 && p.index == OutIdx.loopback,
      ),
      isEmpty,
    );
  });

  test('emergency reset keeps loopback off after automatic analyzer routing resumes', () async {
    midi.emitStatus();
    await device.read();
    await AppSettings.instance.confirmAnalyzerLoopback();
    await AppSettings.instance.setAnalyzerRouting(output: 3, tap: 1);
    final routing = AnalyzerRouting(ctrl);
    addTearDown(routing.dispose);
    routing.setActive(true);
    await routing.configure(output: 3, tap: 1);
    expect(midi.actual[3 << 8 | OutIdx.loopback], 1);
    final protectedValues = {
      for (final e in midi.actual.entries)
        if ((e.key & 255) == OutIdx.mute || (e.key & 255) == OutIdx.volume)
          e.key: e.value,
    };
    final session = AnalyzerSelfTest(device, TestSelfTestAudio([]));
    addTearDown(session.dispose);
    await session.resetTestState();
    expect(session.error, isNull);
    expect(AppSettings.instance.analyzerLoopbackTap, 0);
    midi.emitStatus();
    await Future<void>.delayed(Duration.zero);
    for (final output in device.outputs) {
      expect(
        midi.actual[output << 8 | OutIdx.loopback],
        device.loopbackOutputs.contains(output) ? 0 : isNull,
      );
      expect(midi.actual[output << 8 | OutIdx.source], 0);
    }
    for (final e in protectedValues.entries) {
      expect(midi.actual[e.key], e.value);
    }
  });

  test(
    'new journal stores model and status variant without volatile MIDI ID',
    () async {
      midi.emitStatus();
      await device.waitUntilReady();
      final encoded = device.recoveryIdentity.toJson() as Map;
      expect(encoded['model'], Adi2Model.pro.id);
      expect(encoded['variant'], 'pro');
      expect(encoded['serial'], isNull);
      expect(encoded.toString(), isNot(contains(midi.device.id)));
      expect(device.defaultSource(3), 0);
    },
  );

  test(
    'missing status gives a specific error without any restoration writes',
    () async {
      final audio = TestSelfTestAudio([]);
      audio.journal = {
        'device': 'old-endpoint/${Adi2Model.pro.id}',
        'values': {for (final e in midi.actual.entries) '${e.key}': e.value},
      };
      final session = AnalyzerSelfTest(device, audio);
      addTearDown(session.dispose);
      await session.loadRecovery();
      await session.retryRestore();
      expect(session.restored, isFalse);
      expect(session.restoreError, contains('Statusdaten fehlen'));
      expect(midi.writes, isEmpty);
      expect(audio.journal, isNotNull);
    },
  );

  test('snapshot comes from fresh device RX and contains all 11 supported Pro parameters', () async {
    final snapshot = await device.read();
    expect(snapshot, midi.actual);
    expect(snapshot.length, 11);
    expect(device.usbSource, 4);
    ctrl.model = Adi2Model.dac;
    expect(device.usbSource, 3);
  });
  test('USB option and source labels come from every variant definition', () {
    for (final model in Adi2Model.values) {
      ctrl.model = model;
      final options = outputParams(
        ctrl.variant!,
        phones: false,
      ).firstWhere((p) => p.index == OutIdx.source).options!;
      expect(
        options[device.usbSource],
        model == Adi2Model.dac ? 'USB' : 'USB 1/2',
      );
      expect(device.sourceLabel(3, 0), 'Auto');
    }
    ctrl.model = Adi2Model.pro4;
    ctrl.status = Adi2Status([4]);
    expect(ctrl.variant, Adi2Variant.pro4ex);
    expect(device.usbSource, 4);
    expect(device.sourceLabel(9, 4), 'USB 1/2');
    ctrl.model = Adi2Model.dac;
    expect(device.sourceLabel(3, 2), 'SPDIF optical');
  });
  test('source change waits for matching received MIDI value', () async {
    midi.answer = false;
    var completed = false;
    final pending = device
        .write({3 << 8 | OutIdx.source: device.usbSource})
        .then((_) => completed = true);
    midi.emit([const Adi2Param(3, OutIdx.source, 0)]);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    midi.emit([const Adi2Param(3, OutIdx.source, 4)]);
    await pending;
    expect(completed, isTrue);
  });
  test(
    'optimistic Mute is insufficient; genuine MIDI RX resolves safety barrier',
    () async {
      await device.read();
      midi.answer = false;
      var completed = false;
      final pending = device.write({3 << 8 | OutIdx.mute: 1}).then((_) {
        completed = true;
      });
      expect(ctrl.value(3, OutIdx.mute), 1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(completed, isFalse);
      midi.emit([const Adi2Param(3, OutIdx.mute, 1)]);
      await pending;
      expect(completed, isTrue);
    },
  );
  test(
    'wrong MIDI value cannot confirm; absent correct readback times out',
    () async {
      await device.read();
      midi.answer = false;
      final pending = device.write({3 << 8 | OutIdx.mute: 1});
      final check = expectLater(pending, throwsA(isA<TimeoutException>()));
      midi.emit([const Adi2Param(3, OutIdx.mute, 0)]);
      await Future<void>.delayed(const Duration(seconds: 3));
      await check;
    },
  );
  test(
    'confirmed loopback changes only on MIDI readback, never on optimistic set',
    () async {
      expect(ctrl.confirmedValue(3, OutIdx.loopback), isNull);
      await device.read();
      expect(ctrl.confirmedValue(3, OutIdx.loopback), 0);
      ctrl.set(3, OutIdx.loopback, 2);
      expect(ctrl.value(3, OutIdx.loopback), 2);
      expect(ctrl.confirmedValue(3, OutIdx.loopback), 0);
      midi.emit([const Adi2Param(3, OutIdx.loopback, 2)]);
      expect(ctrl.confirmedValue(3, OutIdx.loopback), 2);
      await ctrl.startOffline(Adi2Variant.pro);
      expect(ctrl.confirmedValue(3, OutIdx.loopback), isNull);
    },
  );

  test(
    'lease blocks automatic routing and rejects an active volume ramp',
    () async {
      await device.read();
      ctrl.volGuard.request(3, -200);
      expect(device.acquire, throwsStateError);
      ctrl.volGuard.cancelAll();
      device.acquire();
      routeAnalyzerLoopback(ctrl, Adi2Addr.ph34, 1);
      expect(midi.writes, isEmpty);
      expect(device.acquire, throwsStateError);
      device.release();
      routeAnalyzerLoopback(ctrl, Adi2Addr.ph34, 1);
      expect(midi.writes.single.index, OutIdx.loopback);
    },
  );
}
