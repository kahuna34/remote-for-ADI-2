import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/eq/eq_model.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Midi implements MidiCommand {
  final sent = <Uint8List>[];
  @override
  void sendData(Uint8List data, {String? deviceId, int? timestamp}) =>
      sent.add(data);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Controller extends Adi2Controller {
  _Controller(MidiCommand midi) : super(midi: midi);
  final eqWrites = <(int, int, int)>[];
  final batches = <Adi2Param>[];

  @override
  void setEq(int address, int index, int raw) {
    eqWrites.add((address, index, raw));
    super.setEq(address, index, raw);
  }

  @override
  void setMany(List<Adi2Param> params) {
    batches.addAll(params);
    super.setMany(params);
  }
}

void main() {
  for (final variant in Adi2Variant.values) {
    for (final offline in [false, true]) {
      testWidgets(
        'Clear ${variant.name}, offline=$offline erhält Schalter und Presetwahl',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final midi = _Midi();
          final controller = _Controller(midi);
          try {
            await controller.startOffline(variant);
            final device = MidiDevice(
              'reset-test',
              'ADI-2',
              MidiDeviceType.serial,
              true,
            );
            addTearDown(device.dispose);
            if (!offline) controller.device = device;
            if (!offline) controller.state = ConnState.connected;
            final defaults = offlineDefaults(variant);
            final channels = [
              if (variant.hasInput) Adi2Addr.input,
              Adi2Addr.line,
              Adi2Addr.ph12,
              if (variant.hasPhones34) Adi2Addr.ph34,
            ];
            for (final channel in channels) {
              final left = channel + 1, right = channel + 2;
              const kept = {
                EqIdx2.enable: 1,
                EqIdx2.btEnable: 0,
                EqIdx2.loadBtWithPreset: 1,
                EqIdx2.presetSelect: 7,
                EqIdx2.presetFlags: 0x33,
              };
              final targetDefaults = {
                for (final e in defaults.entries)
                  if ([left, right].contains(e.key >> 8) &&
                      !kept.containsKey(e.key & 0xff))
                    e.key: e.value,
              };
              final gainIndices = {for (final band in eqBands) band.gainIdx};
              controller.setMany([
                for (final e in targetDefaults.entries)
                  Adi2Param(
                    e.key >> 8,
                    e.key & 0xff,
                    gainIndices.contains(e.key & 0xff)
                        ? (e.key >> 8 == left ? -4 : 4)
                        : e.value + 1,
                  ),
                for (final e in kept.entries) Adi2Param(left, e.key, e.value),
                Adi2Param(channel, channel == 0 ? 8 : OutIdx.dualEq, 1),
                const Adi2Param(Adi2Addr.device, DevIdx.sampleRate, 96000),
              ]);
              // Vorherige Gain-Ziele müssen durch Clear ersetzt werden.
              controller.setEq(left, 4, 20);
              controller.eqWrites.clear();
              controller.batches.clear();
              midi.sent.clear();
              controller.resetEq(channel);
              final gains = {
                for (final e in targetDefaults.entries)
                  if (gainIndices.contains(e.key & 0xff)) e.key: e.value,
              };
              expect(
                controller.eqWrites,
                offline
                    ? isEmpty
                    : unorderedEquals([
                        for (final e in gains.entries)
                          (e.key >> 8, e.key & 0xff, e.value),
                      ]),
              );
              expect(
                {for (final p in controller.batches) p.key: p.value},
                {
                  for (final e in targetDefaults.entries)
                    if (offline || !gains.containsKey(e.key)) e.key: e.value,
                },
              );
              if (!offline) {
                expect(controller.value(left, 4), -4);
                expect(controller.eqValue(left, 4), 0);
                await tester.pump(const Duration(milliseconds: 50));
                expect(controller.value(left, 4), -3);
                expect(controller.value(right, 4), 0);
                await tester.pump(const Duration(milliseconds: 150));
              } else {
                await tester.pump(const Duration(milliseconds: 200));
                expect(midi.sent, isEmpty);
              }
              for (final e in targetDefaults.entries) {
                expect(controller.value(e.key >> 8, e.key & 0xff), e.value);
              }
              for (final e in kept.entries) {
                expect(controller.value(left, e.key), e.value);
              }
              expect(
                controller.value(channel, channel == 0 ? 8 : OutIdx.dualEq),
                1,
              );
              expect(
                controller.value(Adi2Addr.device, DevIdx.sampleRate),
                96000,
              );
              final sent = [
                for (final data in midi.sent)
                  if (parseSysex(data) case Adi2ParamsMessage(:final params))
                    ...params,
              ];
              expect(
                sent.every((p) => targetDefaults.containsKey(p.key)),
                isTrue,
              );
              expect(
                sent
                    .where((p) => p.address == left && p.index == 4)
                    .map((p) => p.value),
                offline ? isEmpty : orderedEquals([-3, -2, -1, 0]),
              );
            }
          } finally {
            controller.dispose();
          }
        },
      );
    }
  }
}
