import 'package:adi2_remote/analyzer/header_content.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/player_bar.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Device extends Adi2Controller {
  _Device() {
    state = ConnState.connected;
    selectedOutput = Adi2Addr.line;
  }
  final values = offlineDefaults(Adi2Variant.dac);
  @override
  Adi2Variant get variant => Adi2Variant.dac;
  @override
  int? value(int address, int index) => values[address << 8 | index];
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
    await AppSettings.instance.setHeaderContent(HeaderContent.status);
  });

  Future<void> mount(
    WidgetTester tester,
    _Device c,
    NowPlaying np, {
    bool landscape = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = landscape
        ? const Size(1280, 800)
        : const Size(400, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: HomePage(ctrl: c, np: np),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> swipe(WidgetTester tester, double dx) async {
    final rect = tester.getRect(find.byKey(const ValueKey('header-swipe')));
    // A blank strip shared by the status, player and analyzer panels.
    // Über ein Drittel der Breite ziehen: die Seite folgt dem Finger und
    // schaltet beim Loslassen um.
    await tester.dragFrom(
      Offset(rect.center.dx, rect.bottom - 3),
      Offset(dx * 2, 0),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('kurzes langsames Ziehen federt zurück', (tester) async {
    final c = _Device(), np = NowPlaying();
    addTearDown(c.dispose);
    addTearDown(np.dispose);
    await mount(tester, c, np);
    final rect = tester.getRect(find.byKey(const ValueKey('header-swipe')));
    final g = await tester.startGesture(
      Offset(rect.center.dx, rect.bottom - 3),
    );
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(-6, 0));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(AppSettings.instance.headerContent, HeaderContent.status);
  });

  for (final easy in [false, true]) {
    testWidgets(
      'status → player → analyzer und zurück, gespeichert (${easy ? 'eigene Ansicht' : 'normal'})',
      (tester) async {
        final c = _Device(), np = NowPlaying();
        final settings = AppSettings.instance;
        addTearDown(c.dispose);
        addTearDown(np.dispose);
        if (easy) {
          await settings.setEasyMode(true);
          final layout = settings
              .easyLayout(c.variant)
              .withHeaderContent(HeaderContent.status)
              .setSamePageForAllOutputs(false, [
                Adi2Addr.line,
                Adi2Addr.ph12,
              ], selectedOutput: Adi2Addr.line);
          await settings.saveEasySlot(
            c.variant,
            2,
            layout.withPage(
              Adi2Addr.ph12,
              layout
                  .pageFor(Adi2Addr.ph12)
                  .withHeaderContent(HeaderContent.analyzer),
            ),
          );
          await settings.activateEasySlot(c.variant, 2);
        }
        HeaderContent current() => easy
            ? settings
                  .easyLayout(c.variant)
                  .pageFor(Adi2Addr.line)
                  .headerContent
            : settings.headerContent;
        await mount(tester, c, np);
        await swipe(tester, 100);
        expect(current(), HeaderContent.status); // no wrapping at the start
        await swipe(tester, -100);
        expect(current(), HeaderContent.player);
        expect(find.byType(PlayerBar), findsOneWidget);
        expect(find.byKey(const ValueKey('digital-mini')), findsOneWidget);
        await swipe(tester, -100);
        expect(current(), HeaderContent.analyzer);
        await settings.load();
        await tester.pumpAndSettle();
        expect(current(), HeaderContent.analyzer);
        final analyzer = tester
            .widget<AnalyzerPanel>(find.byType(AnalyzerPanel))
            .controller;
        await swipe(tester, -100);
        expect(current(), HeaderContent.analyzer); // no wrapping at the end
        expect(
          tester.widget<AnalyzerPanel>(find.byType(AnalyzerPanel)).controller,
          same(analyzer),
        );
        await swipe(tester, 100);
        expect(current(), HeaderContent.player);
        await swipe(tester, 100);
        expect(current(), HeaderContent.status);
        // Persistence is checked after a fresh read, including the separate page.
        await tester.pumpWidget(const SizedBox());
        await settings.load();
        expect(current(), HeaderContent.status);
        if (easy) {
          expect(settings.easySlots(c.variant).active, 2);
          expect(
            settings.easyLayout(c.variant).pageFor(Adi2Addr.ph12).headerContent,
            HeaderContent.analyzer,
          );
          expect(settings.headerContent, HeaderContent.status);
        }
      },
    );
  }

  testWidgets(
    'none, leerer Player und Tablet-Querformat haben keine Wischfläche',
    (tester) async {
      final c = _Device(), np = NowPlaying();
      addTearDown(c.dispose);
      addTearDown(np.dispose);
      await AppSettings.instance.setHeaderContent(HeaderContent.none);
      await mount(tester, c, np);
      expect(find.byKey(const ValueKey('header-swipe')), findsNothing);
      await AppSettings.instance.setHeaderContent(HeaderContent.player);
      await AppSettings.instance.setShowStatus(false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('header-swipe')), findsNothing);
      await AppSettings.instance.setHeaderContent(HeaderContent.status);
      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('header-swipe')), findsNothing);
    },
  );

  testWidgets('vertikale und kurze langsame Bewegungen wechseln nicht', (
    tester,
  ) async {
    final c = _Device(), np = NowPlaying();
    addTearDown(c.dispose);
    addTearDown(np.dispose);
    await mount(tester, c, np);
    await tester.drag(
      find.byKey(const ValueKey('header-swipe')),
      const Offset(0, 70),
    );
    await tester.pumpAndSettle();
    expect(AppSettings.instance.headerContent, HeaderContent.status);
    final start = tester.getCenter(find.byKey(const ValueKey('header-swipe')));
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(-25, 0));
    await tester.pump(const Duration(seconds: 1));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(AppSettings.instance.headerContent, HeaderContent.status);
  });
}
