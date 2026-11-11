import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/supported_models.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Midi implements MidiCommand {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Controller extends Adi2Controller {
  _Controller(String name, this.fixedVariant, {this.ess = false})
    : super(midi: _Midi()) {
    device = MidiDevice('usb', name, MidiDeviceType.serial, true);
  }
  final Adi2Variant fixedVariant;
  final bool ess;

  @override
  bool get hasEss => ess;

  @override
  Adi2Variant? get variant => fixedVariant;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only eight digits starting with exactly 5601 are a Pro EX', () {
    for (final serial in ['56010000', '56010042', '56019999']) {
      expect(isProExSerial(serial), isTrue, reason: serial);
    }
    for (final serial in [
      null,
      '',
      '56000000',
      '56001234',
      '56021310',
      '56101310',
      '5601131',
      '560100420',
      '50011310',
      '51011310',
      '55011310',
      '57011310',
      '59011310',
      '5601ABCD',
    ]) {
      expect(isProExSerial(serial), isFalse, reason: '$serial');
    }
  });

  test('converters follow the model and the SD LD result', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
    _Controller at(String name, Adi2Variant variant, {bool ess = false}) {
      final c = _Controller(name, variant, ess: ess);
      addTearDown(c.dispose);
      return c;
    }

    final pro = at('ADI-2 Pro (11111111)', Adi2Variant.pro);
    expect(pro.adConverter, 'AK5574');
    expect(pro.daConverter, isNull);
    await AppSettings.instance.setDaFilterSdLd('11111111', false);
    expect(pro.daConverter, 'AK4490');
    await AppSettings.instance.setDaFilterSdLd('11111111', true);
    expect(pro.daConverter, 'AK4493');

    final dac = at('ADI-2 DAC (22222222)', Adi2Variant.dac);
    expect(dac.adConverter, isNull);
    expect(dac.daConverter, isNull);
    await AppSettings.instance.setDaFilterSdLd('22222222', false);
    expect(dac.daConverter, 'AK4490');
    final ess = at('ADI-2 DAC (33333333)', Adi2Variant.dac, ess: true);
    expect(ess.daConverter, 'ES9028Q2M');

    final se = at('ADI-2/4 Pro SE (44444444)', Adi2Variant.pro4se);
    expect((se.adConverter, se.daConverter), ('ES9822Pro', 'ES9038Q2M'));
    final ex = at('ADI-2/4 Pro EX (55555555)', Adi2Variant.pro4ex);
    expect((ex.adConverter, ex.daConverter), ('ES9823Pro', 'ES9039Q2M'));
  });

  test('label uses the serial for ADI-2 Pro devices only', () {
    String label(String name, Adi2Variant variant) {
      final c = _Controller(name, variant);
      addTearDown(c.dispose);
      return c.deviceLabel;
    }

    expect(label('ADI-2 Pro (56010042)', Adi2Variant.pro), 'ADI-2 Pro EX');
    expect(label('ADI-2 Pro (56001234)', Adi2Variant.pro), 'ADI-2 Pro');
    expect(label('ADI-2 Pro (52011234)', Adi2Variant.pro), 'ADI-2 Pro');
    expect(label('ADI-2 Pro', Adi2Variant.pro), 'ADI-2 Pro');
    expect(label('ADI-2 DAC (56010042)', Adi2Variant.dac), 'ADI-2 DAC');
    expect(
      label('ADI-2/4 Pro SE (56010042)', Adi2Variant.pro4se),
      'ADI-2/4 Pro SE',
    );
  });
}
