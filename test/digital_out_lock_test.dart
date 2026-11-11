import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/param_tile.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends Adi2Controller {
  _Controller(this.mode);
  final int mode;
  final writes = <int>[];

  @override
  int? value(int address, int index) =>
      address == Adi2Addr.device && index == 6 ? mode : 0;

  @override
  void set(int address, int index, int value) => writes.add(value);
}

void main() {
  const modes = {
    0: 'Auto',
    1: 'AD/DA',
    2: 'USB',
    3: 'Preamp',
    4: 'Dig Thru',
    5: 'DAC',
  };
  for (final entry in modes.entries) {
    final locked = entry.key == 3 || entry.key == 4;
    testWidgets('Digital Out Quelle in ${entry.value}: gesperrt = $locked', (
      tester,
    ) async {
      final ctrl = _Controller(entry.key);
      addTearDown(ctrl.dispose);
      final def = deviceParams(Adi2Variant.pro).firstWhere((d) => d.index == 7);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: ParamTile(ctrl: ctrl, address: Adi2Addr.device, def: def),
          ),
        ),
      );
      await tester.tap(find.text('Main Out'));
      await tester.pump();
      expect(ctrl.writes, locked ? isEmpty : [1]);
      expect(
        find.text(tr('In Preamp und Dig Thru nicht wählbar.')),
        locked ? findsOneWidget : findsNothing,
      );
    });
  }
}
