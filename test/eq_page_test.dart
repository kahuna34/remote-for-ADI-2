import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/eq/eq_model.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/eq_page.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends Adi2Controller {
  final values = <(int, int), int>{};
  final writes = <(int, int, int)>[];
  final resets = <int>[];

  @override
  Adi2Variant get variant => Adi2Variant.pro;

  @override
  int valueOr(int address, int index, int fallback) =>
      values[(address, index)] ?? fallback;

  @override
  int? eqValue(int address, int index) => values[(address, index)];

  @override
  void setEq(int address, int index, int raw) => set(address, index, raw);

  @override
  void set(int address, int index, int raw) {
    writes.add((address, index, raw));
    values[(address, index)] = raw;
    notifyListeners();
  }

  @override
  void resetEq(int channelAddr) => resets.add(channelAddr);
}

void main() {
  late _Controller controller;
  late AppLanguage previousLanguage;

  setUp(() {
    previousLanguage = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    controller = _Controller();
  });

  tearDown(() {
    controller.dispose();
    AppLang.instance.language = previousLanguage;
  });

  Future<void> showPage(
    WidgetTester tester, {
    int channel = Adi2Addr.line,
    double width = 320,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: EqPage(ctrl: controller, channelAddr: channel, title: 'Test EQ'),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final channel in [
    Adi2Addr.input,
    Adi2Addr.line,
    Adi2Addr.ph12,
    Adi2Addr.ph34,
  ]) {
    testWidgets('EQ vollständig scrollbar mit Systemleisten, Kanal $channel', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 740);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: channel == Adi2Addr.input
              ? Scaffold(body: InputPage(ctrl: controller))
              : EqPage(
                  ctrl: controller,
                  channelAddr: channel,
                  title: 'Test EQ',
                ),
        ),
      );
      if (channel == Adi2Addr.input) {
        await tester.tap(find.text(tr('Equalizer (Eingang)')));
      }
      await tester.pumpAndSettle();
      final page = find.byType(EqPage);
      final pageContext = tester.element(page);
      expect(MediaQuery.paddingOf(pageContext).bottom, 34);
      expect(MediaQuery.viewPaddingOf(pageContext).bottom, 34);
      final scrollable = find
          .descendant(of: page, matching: find.byType(Scrollable))
          .first;
      await tester.fling(scrollable, const Offset(0, -1800), 3000);
      await tester.pumpAndSettle();
      final save = find.widgetWithText(
        FilledButton,
        tr('Als Preset speichern'),
      );
      expect(save.hitTestable(), findsOneWidget);
      expect(tester.getBottomRight(save).dy, lessThanOrEqualTo(740 - 34 - 24));
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final channel in [Adi2Addr.input, Adi2Addr.line, Adi2Addr.ph34]) {
    for (final language in AppLanguage.values) {
      testWidgets('EQ ohne Scrollbedarf bei 411×914: $channel $language', (
        tester,
      ) async {
        AppLang.instance.language = language;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(411, 914);
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
        tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: EqPage(
              ctrl: controller,
              channelAddr: channel,
              title: 'Test EQ',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(EqTypeTiles), findsOneWidget);
        final scroll = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        expect(scroll.position.maxScrollExtent, 0);
        expect(find.text(tr('Q')).hitTestable(), findsOneWidget);
        expect(find.byType(EqCurveControls).hitTestable(), findsOneWidget);
        expect(
          find.text(tr('Als Preset speichern')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  Finder dualSwitch() => find.descendant(
    of: find.byType(EqDualControls),
    matching: find.byType(Switch),
  );

  Finder curveSwitch() => find.descendant(
    of: find.byType(EqCurveControls),
    matching: find.byType(Switch),
  );

  for (final language in AppLanguage.values) {
    testWidgets(
      'Kurvenzeile unter Q steuert nur die Anzeige (${language.name})',
      (tester) async {
        AppLang.instance.language = language;
        await showPage(tester);
        final row = find.byType(EqCurveControls);
        await tester.scrollUntilVisible(row, 150);
        await tester.pumpAndSettle();
        expect(tester.widget<Switch>(curveSwitch()).value, isTrue);
        expect(
          tester.widget<EqPlot>(find.byType(EqPlot)).includeBassTreble,
          isTrue,
        );
        expect(tester.getSize(row).height, 36);
        expect(
          tester.getTopLeft(row).dy,
          tester.getBottomRight(find.byType(EqBandControls)).dy,
        );
        final label = tester.widget<Text>(
          find.text(tr('Bass/Treble in Kurve')),
        );
        expect(label.style?.fontSize, 13);
        expect(label.style?.color, Palette.muted);
        final scale = tester.widget<Transform>(
          find.descendant(of: row, matching: find.byType(Transform)).first,
        );
        expect(scale.transform.entry(0, 0), closeTo(0.8, 0.0001));

        await tester.ensureVisible(curveSwitch());
        await tester.tap(curveSwitch());
        await tester.pumpAndSettle();
        expect(
          tester.widget<EqPlot>(find.byType(EqPlot)).includeBassTreble,
          isFalse,
        );
        expect(controller.writes, isEmpty);

        // Controller-Updates und Bandwechsel erhalten die lokale Anzeigeoption.
        controller.notifyListeners();
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byType(EqBandChips));
        await tester.tap(find.text('Bass').first);
        await tester.pumpAndSettle();
        final deviceSwitch = find.descendant(
          of: find.byType(EqBandControls),
          matching: find.byType(Switch),
        );
        expect(tester.widget<Switch>(deviceSwitch).value, isTrue);
        await tester.ensureVisible(deviceSwitch);
        await tester.tap(deviceSwitch);
        await tester.pumpAndSettle();
        expect(controller.writes, [(Adi2Addr.lineEqL, EqIdx2.btEnable, 0)]);
        expect(
          tester.widget<EqPlot>(find.byType(EqPlot)).includeBassTreble,
          isFalse,
        );

        await tester.ensureVisible(curveSwitch());
        await tester.tap(curveSwitch());
        await tester.pumpAndSettle();
        expect(
          tester.widget<EqPlot>(find.byType(EqPlot)).includeBassTreble,
          isTrue,
        );
        expect(tester.widget<Switch>(deviceSwitch).value, isFalse);
        expect(controller.writes, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final language in AppLanguage.values) {
    for (final width in [320.0, 400.0]) {
      testWidgets(
        'Clear bleibt beim Dual-Umschalten fest (${language.name}, $width)',
        (tester) async {
          AppLang.instance.language = language;
          await showPage(tester, width: width);
          final clear = find.widgetWithText(OutlinedButton, tr('Clear'));
          final plot = find.byType(EqPlot);
          final row = find.byType(EqDualControls);
          final clearRect = tester.getRect(clear);
          final plotRect = tester.getRect(plot);
          final rowRect = tester.getRect(row);
          expect(clearRect.size, const Size(56, 40));
          expect(rowRect.height, 48);
          expect(clearRect.center.dy, tester.getCenter(dualSwitch()).dy);
          expect(clearRect.right, plotRect.right);
          expect(clearRect.bottom, lessThan(plotRect.top));
          expect(
            find.descendant(
              of: find.byType(AppBar),
              matching: find.text(tr('Clear')),
            ),
            findsNothing,
          );
          expect(find.byType(EqSideSwitch), findsNothing);

          await tester.tap(dualSwitch());
          await tester.pumpAndSettle();
          expect(controller.writes, [(Adi2Addr.line, OutIdx.dualEq, 1)]);
          expect(find.byType(EqSideSwitch), findsOneWidget);
          expect(tester.getRect(clear), clearRect);
          expect(tester.getRect(plot), plotRect);
          expect(tester.getRect(row), rowRect);
          expect(
            tester.getBottomRight(find.byType(EqSideSwitch)).dx,
            lessThan(clearRect.left),
          );
          expect(tester.takeException(), isNull);

          await tester.tap(find.text(tr('Rechts')));
          await tester.pumpAndSettle();
          expect(tester.widget<EqPlot>(plot).eqAddr, Adi2Addr.lineEqR);
          await tester.tap(dualSwitch());
          await tester.pumpAndSettle();
          expect(find.byType(EqSideSwitch), findsNothing);
          expect(tester.widget<EqPlot>(plot).eqAddr, Adi2Addr.lineEqL);
          expect(tester.getRect(clear), clearRect);
          expect(tester.getRect(plot), plotRect);
          expect(tester.getRect(row), rowRect);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final channel in [
    Adi2Addr.input,
    Adi2Addr.line,
    Adi2Addr.ph12,
    Adi2Addr.ph34,
  ]) {
    testWidgets('Clear bestätigt vor dem Zurücksetzen von Kanal $channel', (
      tester,
    ) async {
      await showPage(tester, channel: channel);
      final clear = find.widgetWithText(OutlinedButton, tr('Clear'));
      for (final dual in [false, true]) {
        if (dual) {
          await tester.tap(dualSwitch());
          await tester.pumpAndSettle();
          expect(controller.writes.last, (
            channel,
            channel == 0 ? 8 : OutIdx.dualEq,
            1,
          ));
        }
        await tester.tap(clear);
        await tester.pumpAndSettle();
        expect(find.text(tr('EQ zurücksetzen?')), findsOneWidget);
        expect(find.textContaining('Test EQ'), findsNWidgets(2));
        expect(controller.resets, isEmpty);
        await tester.tap(find.text(tr('Abbrechen')));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(controller.resets, isEmpty);
      }
      await tester.tap(clear);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, tr('Clear')));
      await tester.pumpAndSettle();
      expect(controller.resets, [channel]);
      expect(find.byType(AlertDialog), findsNothing);
    });
  }
}
