import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/param_tile.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends Adi2Controller {
  @override
  int? value(int address, int index) => 0;
}

void main() {
  for (final language in AppLanguage.values) {
    testWidgets('Weitere Auswahlparameter bei 360 dp (${language.name})', (
      tester,
    ) async {
      final previous = AppLang.instance.language;
      AppLang.instance.language = language;
      addTearDown(() => AppLang.instance.language = previous);
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ctrl = _Controller();
      addTearDown(ctrl.dispose);
      for (final variant in Adi2Variant.values) {
        for (final def in [
          ...deviceParams(variant),
          ...inputParams(variant),
          ...outputParams(variant, phones: false),
          ...outputParams(variant, phones: true),
        ].where((d) => d.isChoice && !d.isSwitch && d.max - d.min < 12)) {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: ParamTile(
                    ctrl: ctrl,
                    address: Adi2Addr.device,
                    def: def,
                  ),
                ),
              ),
            ),
          );
          final texts = find.descendant(
            of: find.byType(ParamChoices),
            matching: find.byType(Text),
          );
          expect(texts, findsNWidgets(def.max - def.min + 1));
          for (final text in texts.evaluate()) {
            final paragraph = text.renderObject! as RenderParagraph;
            expect(paragraph.didExceedMaxLines, isFalse, reason: def.name);
            final boxes = paragraph.getBoxesForSelection(
              TextSelection(
                baseOffset: 0,
                extentOffset: (text.widget as Text).data!.length,
              ),
            );
            for (final box in boxes) {
              expect(
                box.right,
                lessThanOrEqualTo(paragraph.size.width + 0.01),
                reason: def.name,
              );
              expect(
                box.bottom,
                lessThanOrEqualTo(paragraph.size.height + 0.01),
                reason: def.name,
              );
            }
          }
          expect(tester.takeException(), isNull, reason: def.name);
        }
      }
    });

    for (final width in [360.0, 800.0]) {
      testWidgets('Basic Mode gleichmäßig und lesbar $width ${language.name}', (
        tester,
      ) async {
        await tester.runAsync(() async {
          final font = FontLoader('Archivo')
            ..addFont(rootBundle.load('assets/fonts/Archivo.ttf'));
          await font.load();
        });
        final previous = AppLang.instance.language;
        AppLang.instance.language = language;
        addTearDown(() => AppLang.instance.language = previous);
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final ctrl = _Controller();
        addTearDown(ctrl.dispose);
        final def = deviceParams(Adi2Variant.pro)
            .firstWhere((d) => d.index == 6);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: Scaffold(
              body: ParamTile(ctrl: ctrl, address: Adi2Addr.device, def: def),
            ),
          ),
        );
        final cells = find.descendant(
          of: find.byType(ParamChoices),
          matching: find.byType(InkWell),
        );
        expect(cells, findsNWidgets(6));
        final rects = [for (var i = 0; i < 6; i++) tester.getRect(cells.at(i))];
        for (final rect in rects) {
          expect(rect.width, closeTo(rects.first.width, 0.01));
        }
        final rows = rects.map((r) => r.top).toSet();
        expect(rows.length, width == 360 ? 2 : 1);
        if (width == 360) {
          for (final top in rows) {
            expect(rects.where((r) => r.top == top), hasLength(3));
          }
        }
        for (final label in def.options!) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.text(tr(label)),
          );
          expect(paragraph.didExceedMaxLines, isFalse);
          final boxes = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: tr(label).length),
          );
          expect(boxes, hasLength(1));
          expect(
            boxes.single.right,
            lessThanOrEqualTo(paragraph.size.width + 0.01),
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
