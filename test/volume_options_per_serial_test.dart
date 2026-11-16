import 'dart:convert';

import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Midi implements MidiCommand {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Obergrenze wird pro Seriennummer und als Modellvorlage gespeichert',
    () async {
      SharedPreferences.setMockInitialValues({});
      final ctrl = Adi2Controller(midi: _Midi());
      addTearDown(ctrl.dispose);
      ctrl.model = Adi2Model.pro4;
      ctrl.device = MidiDevice(
        'usb',
        'ADI-2/4 Pro SE (12345678)',
        MidiDeviceType.serial,
        true,
      );
      await ctrl.setLimitDbu(Adi2Addr.ph34, 6);
      final prefs = await SharedPreferences.getInstance();
      final own = prefs.getString('vopts_sn_12345678');
      expect(own, isNotNull);
      expect(jsonDecode(own!)['out'][Adi2Addr.ph34.toString()]['l'], 6);
      // Ein anderes Gerät desselben Modells bekommt den Modellwert nur als Vorlage.
      expect(prefs.getString('vopts_${Adi2Model.pro4.id}'), own);
      expect(prefs.getString('vopts_sn_87654321'), isNull);
    },
  );

  test('Ohne Seriennummer nur unter dem Modell', () async {
    SharedPreferences.setMockInitialValues({});
    final ctrl = Adi2Controller(midi: _Midi());
    addTearDown(ctrl.dispose);
    ctrl.model = Adi2Model.dac;
    ctrl.device = MidiDevice('usb', 'ADI-2 DAC', MidiDeviceType.serial, true);
    await ctrl.setLimitDbu(Adi2Addr.ph34, 3);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((k) => k.startsWith('vopts_sn_')), isEmpty);
    expect(prefs.getString('vopts_${Adi2Model.dac.id}'), isNotNull);
  });
}
