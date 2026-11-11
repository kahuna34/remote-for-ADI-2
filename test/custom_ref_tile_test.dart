import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/easy/easy_layout.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/outputs_page.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends Adi2Controller {
  @override
  final variant = Adi2Variant.dac;
  final values = offlineDefaults(Adi2Variant.dac);
  final writes = <(int, int, int)>[];

  @override
  int? value(int address, int index) => values[address << 8 | index];
  @override
  int valueOr(int address, int index, int fallback) =>
      value(address, index) ?? fallback;
  @override
  void set(int address, int index, int raw) {
    writes.add((address, index, raw));
    values[address << 8 | index] = raw;
    notifyListeners();
  }

  @override
  void setMany(List<Adi2Param> params) {
    for (final p in params) {
      set(p.address, p.index, p.value);
    }
  }
}

void main() {
  const line = Adi2Addr.line;
  late _Controller ctrl;
  late AppLanguage previous;
  setUp(() {
    previous = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    ctrl = _Controller()..selectedOutput = line;
    ctrl.values[line << 8 | OutIdx.refLevel] = 2; // +7 dBu RCA
    ctrl.values[line << 8 | OutIdx.volume] = -200;
    ctrl.values[line << 8 | OutIdx.autoRef] = 0;
  });
  tearDown(() {
    ctrl.dispose();
    AppLang.instance.language = previous;
  });

  Future<void> show(WidgetTester tester, EasyTile? tile) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: OutputsPage(
            ctrl: ctrl,
            easyLayout: tile == null ? null : EasyLayout(tiles: [tile]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final size in [
    EasyTileSize.single,
    EasyTileSize.wide,
    EasyTileSize.twoThirds,
    EasyTileSize.threeQuarters,
    EasyTileSize.full,
  ]) {
    for (final height in [0.5, 1.0, 2.0]) {
      if (!EasyTile.supportsShape(EasyTileType.refLevel, size, height)) {
        continue;
      }
      testWidgets(
        'Ref form ${size.name} x $height shows values and correct selection',
        (tester) async {
          ctrl.values[line << 8 | OutIdx.autoRef] = 1;
          await show(
            tester,
            EasyTile(type: EasyTileType.refLevel, size: size, height: height),
          );
          expect(find.text('Ref Level'), findsOneWidget);
          expect(find.byKey(const ValueKey('easy-step-0-plus')), findsNothing);
          expect(find.byKey(const ValueKey('easy-step-0-minus')), findsNothing);
          final segmented = size.units >= 45 && height >= 1;
          expect(
            find.byKey(const ValueKey('easy-segments-0-horizontal')),
            segmented ? findsOneWidget : findsNothing,
          );
          if (segmented) {
            for (final n in [-1, 0, 1, 2, 3]) {
              expect(find.byKey(ValueKey('easy-segment-0-$n')), findsOneWidget);
            }
            final auto = find.byKey(const ValueKey('easy-segment-0--1'));
            expect(
              tester
                  .widget<Text>(
                    find.descendant(of: auto, matching: find.text('Auto')),
                  )
                  .style!
                  .color,
              Palette.amber,
            );
          } else {
            expect(find.text('Auto +7 dBu'), findsOneWidget);
            expect(find.text('(XLR +13 dBu)'), findsOneWidget);
            await tester.tap(find.byKey(const ValueKey('easy-tile-0')));
            await tester.pumpAndSettle();
            expect(find.byType(BottomSheet), findsOneWidget);
            expect(find.text('Ref Level, Line Out RCA'), findsOneWidget);
            expect(find.text('Auto'), findsOneWidget);
            expect(find.text('(XLR +19 dBu)'), findsOneWidget);
          }
          expect(ctrl.writes, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  // Exercise the real setRefLevel implementation through all three entry paths.
  for (final path in ['main', 'custom-picker', 'custom-segments']) {
    testWidgets('$path confirms and lowers volume before changing Ref', (
      tester,
    ) async {
      await show(
        tester,
        path == 'main'
            ? null
            : EasyTile(
                type: EasyTileType.refLevel,
                size: path == 'custom-segments'
                    ? EasyTileSize.threeQuarters
                    : EasyTileSize.single,
              ),
      );
      Future<void> choose() async {
        if (path == 'custom-segments') {
          await tester.tap(find.byKey(const ValueKey('easy-segment-0-3')));
        } else {
          await tester.tap(
            find.byKey(
              ValueKey(path == 'main' ? 'output-ref-level' : 'easy-tile-0'),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(
              of: find.byType(BottomSheet),
              matching: find.text('+13 dBu'),
            ),
          );
        }
        await tester.pumpAndSettle();
      }

      await choose();
      expect(find.text('Ref Level auf +13 dBu umschalten?'), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue,
      );
      expect(ctrl.writes, isEmpty);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(ctrl.writes, isEmpty);
      await choose();
      await tester.tap(find.text('Umschalten'));
      await tester.pumpAndSettle();
      expect(ctrl.writes, [
        (line, OutIdx.volume, -260),
        (line, OutIdx.refLevel, 3),
      ]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Auto segment writes Auto; cancelling manual selection preserves Auto',
    (tester) async {
      await show(
        tester,
        const EasyTile(type: EasyTileType.refLevel, size: EasyTileSize.full),
      );
      await tester.tap(find.byKey(const ValueKey('easy-segment-0--1')));
      await tester.pumpAndSettle();
      expect(ctrl.writes, [(line, OutIdx.autoRef, 1)]);
      ctrl.writes.clear();
      await tester.tap(find.byKey(const ValueKey('easy-segment-0-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(ctrl.writes, isEmpty);
      expect(ctrl.value(line, OutIdx.autoRef), 1);
      await tester.tap(find.byKey(const ValueKey('easy-segment-0-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Umschalten'));
      await tester.pumpAndSettle();
      expect(ctrl.writes, [
        (line, OutIdx.autoRef, 0),
        (line, OutIdx.volume, -260),
        (line, OutIdx.refLevel, 3),
      ]);
    },
  );
}
