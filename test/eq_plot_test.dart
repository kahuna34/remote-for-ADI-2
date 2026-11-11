import 'package:adi2_remote/eq/eq_editor_buffer.dart';
import 'package:adi2_remote/eq/eq_math.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/ui/eq_page.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Punkt ziehen gewinnt vertikale Gesten gegen die scrollbare Seite',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      addTearDown(tester.view.resetPhysicalSize);
      final buffer = EqEditorBuffer();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => ListView(
                controller: scroll,
                children: [
                  EqPlot(
                    read: buffer.value,
                    write: (address, index, raw) {
                      update(() => buffer.set(address, index, raw));
                    },
                    eqAddr: Adi2Addr.presetEqL,
                    btAddr: Adi2Addr.presetEqL,
                    selected: selected,
                    enabled: true,
                    onSelect: (value) => update(() => selected = value),
                  ),
                  const SizedBox(height: 1500),
                ],
              ),
            ),
          ),
        ),
      );
      final plot = find.byType(EqPlot);
      final size = tester.getSize(plot);
      final origin = tester.getTopLeft(plot);
      final point =
          origin +
          Offset(
            36 + freqToX(1000) * (size.width - 50),
            16 + (size.height - 42) / 2,
          );
      await tester.tapAt(point);
      await tester.pump();
      expect(selected, 2);
      await tester.dragFrom(point, const Offset(0, -35));
      await tester.pumpAndSettle();
      expect(buffer.value(Adi2Addr.presetEqL, 10), greaterThan(0));
      expect(buffer.value(Adi2Addr.presetEqL, 11), 1000);
      expect(scroll.offset, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
