import 'dart:async';

import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:adi2_remote/ui/host_connect_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Midi implements MidiCommand {
  final packets = StreamController<MidiPacket>.broadcast();
  @override
  Future<List<MidiDevice>> get devices async => [];
  @override
  Stream<MidiPacket> get onMidiPacketReceived => packets.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  testWidgets('Tippen auf einen gefundenen Host übernimmt Adresse und Port', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final c = Adi2Controller(midi: _Midi());
    addTearDown(c.dispose);
    c.hostDiscovery.hosts['h1'] = const HostEndpoint(
      id: 'h1',
      name: 'Test-Mac',
      address: '10.0.0.5',
      port: 47999,
    );
    await tester.pumpWidget(MaterialApp(home: HostConnectPage(ctrl: c)));
    await tester.tap(find.text('Test-Mac'));
    await tester.pump();
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields[0].controller!.text, '10.0.0.5');
    expect(fields[1].controller!.text, '47999');
  });
}
