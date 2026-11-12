import 'dart:async';
import 'dart:typed_data';

import 'package:adi2_remote/analyzer/analyzer_routing.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/loopback_routing.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/protocol/adi2_status.dart';
import 'package:adi2_remote/ui/loopback_section.dart';
import 'package:adi2_remote/ui/param_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Midi implements MidiCommand {
  final packets = StreamController<MidiPacket>.broadcast(sync: true);
  final messages = <List<Adi2Param>>[];
  int requests = 0;
  final device = MidiDevice('loopback', 'ADI-2', MidiDeviceType.serial, true);
  @override
  Future<List<MidiDevice>> get devices async => [];
  @override
  Stream<MidiPacket> get onMidiPacketReceived => packets.stream;
  @override
  void sendData(Uint8List data, {String? deviceId, int? timestamp}) {
    final message = parseSysex(data);
    if (message is Adi2ParamsMessage) {
      messages.add(message.params);
    } else {
      requests++;
    }
  }

  void reply(Adi2Model model, List<int> values) {
    for (final message in buildSetParams(model.id, [
      for (var i = 0; i < 3; i++)
        if (model != Adi2Model.pro || i != 1)
          Adi2Param([3, 6, 9][i], OutIdx.loopback, values[i]),
    ])) {
      packets.add(MidiPacket(message, 0, device));
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLang.instance.language = AppLanguage.de;
  });

  Future<(Adi2Controller, _Midi)> connected(Adi2Variant variant) async {
    final midi = _Midi();
    final ctrl = Adi2Controller(midi: midi);
    await ctrl.start();
    ctrl.device = midi.device;
    ctrl.model = variant.isDac
        ? Adi2Model.dac
        : variant == Adi2Variant.pro
        ? Adi2Model.pro
        : Adi2Model.pro4;
    ctrl.status = Adi2Status([variant == Adi2Variant.pro4ex ? 4 : 0]);
    ctrl.state = ConnState.connected;
    midi.reply(ctrl.model!, [0, 0, 0]);
    addTearDown(() async {
      ctrl.dispose();
      midi.device.dispose();
      await midi.packets.close();
    });
    return (ctrl, midi);
  }

  testWidgets('DAC one selection reads MIDI values and sends one parameter', (
    tester,
  ) async {
    final (ctrl, midi) = await connected(Adi2Variant.dac);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LoopbackSection(ctrl: ctrl)),
      ),
    );
    expect(find.byType(ParamChoices), findsOneWidget);
    expect(find.text('Gilt für alle Ausgänge'), findsOneWidget);
    midi.reply(Adi2Model.dac, [2, 2, 2]);
    await tester.pump();
    expect(tester.widget<ParamChoices>(find.byType(ParamChoices)).selected, 2);
    // Inconsistent readbacks: active output wins; without status use Line.
    midi.reply(Adi2Model.dac, [1, 2, 3]);
    ctrl.status = Adi2Status([2]);
    ctrl.notifyListeners();
    await tester.pump();
    expect(tester.widget<ParamChoices>(find.byType(ParamChoices)).selected, 3);
    ctrl.status = null;
    ctrl.notifyListeners();
    await tester.pump();
    expect(tester.widget<ParamChoices>(find.byType(ParamChoices)).selected, 1);
    await tester.tap(find.text('post FX'));
    await tester.pump();
    expect(midi.messages.length, 1);
    expect(midi.messages.single.length, 1);
    expect(midi.messages.single.single.address, Adi2Addr.line);
    expect(midi.messages.single.single.index, OutIdx.loopback);
    expect(midi.messages.single.single.value, 2);
    await tester.pump(const Duration(milliseconds: 401));
    midi.reply(Adi2Model.dac, [2, 2, 2]);
    await tester.pump();
    expect(tester.widget<ParamChoices>(find.byType(ParamChoices)).selected, 2);
    midi.messages.clear();
    routeAnalyzerLoopback(ctrl, Adi2Addr.ph12, 3);
    expect(midi.messages.length, 1);
    expect(midi.messages.single.length, 1);
    expect(midi.messages.single.single.value, 3);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 401));
  });

  for (final variant in [
    Adi2Variant.pro,
    Adi2Variant.pro4se,
    Adi2Variant.pro4ex,
  ]) {
    for (final language in AppLanguage.values) {
      testWidgets(
        'occupied pair transfers in two messages with feedback $variant $language',
        (tester) async {
          AppLang.instance.language = language;
          final (ctrl, midi) = await connected(variant);
          final occupiedAddress = variant == Adi2Variant.pro
              ? Adi2Addr.ph34
              : Adi2Addr.ph12;
          final occupiedName = variant == Adi2Variant.pro
              ? 'Phones 3/4'
              : 'Phones 1/2';
          midi.reply(
            ctrl.model!,
            variant == Adi2Variant.pro ? [1, 0, 5] : [1, 5, 9],
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(child: LoopbackSection(ctrl: ctrl)),
              ),
            ),
          );
          final row = find.byKey(const ValueKey('loopback-3'));
          expect(
            find.descendant(
              of: row,
              matching: find.text(
                trf('belegt: {Ausgang}', {'Ausgang': occupiedName}),
              ),
            ),
            findsOneWidget,
          );
          final target = find.descendant(of: row, matching: find.text('3/4'));
          await tester.ensureVisible(target);
          await tester.tap(target);
          await tester.pump();
          expect(
            midi.messages
                .map(
                  (m) => m.map((p) => (p.address, p.index, p.value)).toList(),
                )
                .toList(),
            [
              [(occupiedAddress, OutIdx.loopback, 0)],
              [(Adi2Addr.line, OutIdx.loopback, 4)],
            ],
          );
          expect(
            find.text(
              trf(
                'Loopback von {Ausgang} ausgeschaltet, weil {Paar} jetzt belegt ist',
                {'Ausgang': occupiedName, 'Paar': '3/4'},
              ),
            ),
            findsOneWidget,
          );
          expect(
            ctrl.value(Adi2Addr.ph34, OutIdx.loopback),
            variant == Adi2Variant.pro ? 0 : 9,
          );
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 401));
        },
      );
    }
  }

  test('offline DAC mirrors shared value; Pro transfers all pairs', () async {
    final ctrl = Adi2Controller(midi: _Midi());
    addTearDown(ctrl.dispose);
    await ctrl.startOffline(Adi2Variant.dac);
    setLoopbackRoute(ctrl, Adi2Addr.line, tap: 3, pair: 0);
    for (final address in loopbackOutputs(ctrl)) {
      expect(ctrl.value(address, OutIdx.loopback), 3);
    }
    routeAnalyzerLoopback(ctrl, Adi2Addr.ph12, 2);
    for (final address in loopbackOutputs(ctrl)) {
      expect(ctrl.value(address, OutIdx.loopback), 2);
    }
    await ctrl.startOffline(Adi2Variant.pro);
    for (var pair = 0; pair < 3; pair++) {
      setLoopbackRoute(ctrl, Adi2Addr.line, tap: 2, pair: pair);
      setLoopbackRoute(ctrl, Adi2Addr.ph34, tap: 3, pair: pair);
      expect(ctrl.value(Adi2Addr.line, OutIdx.loopback), 0);
      expect(ctrl.value(Adi2Addr.ph34, OutIdx.loopback), pair * 3 + 3);
    }
  });
}
