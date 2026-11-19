import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/eq/eq_editor_buffer.dart';
import 'package:adi2_remote/eq/eq_math.dart';
import 'package:adi2_remote/eq/eq_model.dart';
import 'package:adi2_remote/eq/eq_plot_scale.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/ui/eq_page.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<EqBandShape> _shapes(EqEditorBuffer buffer) => [
  for (final b in eqBands)
    EqBandShape(
      b.kindFor(
        b.typeIdx == null ? null : buffer.value(Adi2Addr.presetEqL, b.typeIdx!),
      ),
      (buffer.value(Adi2Addr.presetEqL, b.freqIdx) ?? b.defF).toDouble(),
      (buffer.value(Adi2Addr.presetEqL, b.gainIdx) ?? 0) / 2,
      (buffer.value(Adi2Addr.presetEqL, b.qIdx) ?? 10) / 10,
    ),
];

void main() {
  setUp(() {
    AppLang.instance.language = AppLanguage.de;
    AppSettings.instance.autoFullscreenEq = false;
  });

  for (final fullscreen in [false, true]) {
    testWidgets(
      'Gain-Doppeltipp mit sofortiger Auswahl, Abbrechen und Bestätigen (fullscreen=$fullscreen)',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(800, 1200);
        addTearDown(tester.view.reset);
        final buffer = EqEditorBuffer()
          ..set(Adi2Addr.presetEqL, eqBands[2].gainIdx, 7);
        final writes = <(int, int, int)>[];
        var selected = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, update) => SizedBox(
                  height: fullscreen ? 400 : null,
                  child: EqPlot(
                    fullscreen: fullscreen,
                    read: buffer.value,
                    write: (a, i, raw) {
                      writes.add((a, i, raw));
                      update(() => buffer.set(a, i, raw));
                    },
                    eqAddr: Adi2Addr.presetEqL,
                    btAddr: Adi2Addr.presetEqL,
                    selected: selected,
                    enabled: true,
                    onSelect: (i) => update(() => selected = i),
                  ),
                ),
              ),
            ),
          ),
        );
        final rect = tester.getRect(find.byType(EqPlot));
        final shapes = _shapes(buffer);
        final scale = EqPlotScale.forShapes(shapes);
        final gain = totalResponseDb(shapes, 1000);
        final point =
            rect.topLeft +
            Offset(
              36 + freqToX(1000) * (rect.width - 50),
              16 +
                  (rect.height - 42) / 2 -
                  gain / scale.range * (rect.height - 42) / 2,
            );
        Future<void> tap(int millis, {int held = 10}) async {
          final stamp = Duration(milliseconds: millis);
          final gesture = await tester.createGesture();
          await gesture.down(point, timeStamp: stamp);
          await gesture.up(timeStamp: stamp + Duration(milliseconds: held));
          await tester.pump();
        }

        await tap(0, held: 400);
        expect(selected, 2); // no double-tap recognizer delay
        expect(find.byType(AlertDialog), findsNothing);
        await tap(
          500,
        ); // 110 ms between releases; timing uses tap-up, not down.
        await tester.pumpAndSettle();
        expect(find.text('Gain zurücksetzen?'), findsOneWidget);
        expect(
          find.text('Gain von Band 3 auf 0 dB setzen? (jetzt 3,5 dB)'),
          findsOneWidget,
        );
        expect(writes, isEmpty);
        await tester.tap(find.text('Abbrechen'));
        await tester.pumpAndSettle();
        expect(writes, isEmpty);
        await tap(1000);
        await tap(1200);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Zurücksetzen'));
        await tester.pumpAndSettle();
        expect(writes, [(Adi2Addr.presetEqL, eqBands[2].gainIdx, 0)]);
      },
    );
  }

  testWidgets(
    'langsame oder verschiedene Tipps, null Gain, gesperrter EQ und Filter ohne Gain',
    (tester) async {
      final buffer = EqEditorBuffer();
      final writes = <int>[];
      var enabled = true;
      Future<void> mount() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EqPlot(
              read: buffer.value,
              write: (_, _, raw) => writes.add(raw),
              eqAddr: Adi2Addr.presetEqL,
              btAddr: Adi2Addr.presetEqL,
              selected: 0,
              enabled: enabled,
              onSelect: (_) {},
            ),
          ),
        ),
      );
      await mount();
      Future<Offset> point(int band) async {
        final rect = tester.getRect(find.byType(EqPlot));
        final shapes = _shapes(buffer);
        final f = shapes[band].freq;
        final range = EqPlotScale.forShapes(shapes).range;
        return rect.topLeft +
            Offset(
              36 + freqToX(f) * (rect.width - 50),
              16 +
                  (rect.height - 42) / 2 -
                  totalResponseDb(shapes, f) / range * (rect.height - 42) / 2,
            );
      }

      Future<void> tap(int band, int millis) async {
        final stamp = Duration(milliseconds: millis);
        final gesture = await tester.createGesture();
        await gesture.down(await point(band), timeStamp: stamp);
        await gesture.up(timeStamp: stamp + const Duration(milliseconds: 10));
        await tester.pumpAndSettle();
      }

      await tap(2, 0);
      await tap(2, 200); // already zero
      expect(find.byType(AlertDialog), findsNothing);
      buffer.set(Adi2Addr.presetEqL, eqBands[2].gainIdx, 8);
      await mount();
      await tester.pumpAndSettle();
      await tap(2, 1000);
      await tap(2, 1600); // outside 500 ms
      expect(find.byType(AlertDialog), findsNothing);
      await tap(1, 2100);
      await tap(2, 2200); // different points
      expect(find.byType(AlertDialog), findsNothing);
      enabled = false;
      await mount();
      await tap(2, 3000);
      await tap(2, 3200);
      expect(find.byType(AlertDialog), findsNothing);
      enabled = true;
      // Band 1 low cut: its gain register is nonzero but the shape has no gain.
      buffer.set(Adi2Addr.presetEqL, eqBands[0].typeIdx!, 2);
      buffer.set(Adi2Addr.presetEqL, eqBands[0].gainIdx, 8);
      await mount();
      await tester.pumpAndSettle();
      await tap(0, 4000);
      await tap(0, 4200);
      expect(find.byType(AlertDialog), findsNothing);
      expect(writes, isEmpty);
    },
  );
}
