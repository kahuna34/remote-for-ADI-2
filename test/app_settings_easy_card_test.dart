import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/easy/easy_layout.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/app_settings_page.dart';
import 'package:adi2_remote/ui/easy_mode_editor.dart';
import 'package:adi2_remote/ui/easy_tile_grid.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Controller extends Adi2Controller {
  @override
  Adi2Variant? variant = Adi2Variant.dac;
  @override
  Future<void> requestPresetNames() async {}
}

void main() {
  late _Controller ctrl;
  final settings = AppSettings.instance;
  late AppLanguage previous;

  setUp(() async {
    ctrl = _Controller();
    addTearDown(ctrl.dispose);
    previous = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    SharedPreferences.setMockInitialValues({});
    await settings.load();
  });

  tearDown(() => AppLang.instance.language = previous);

  Future<void> show(WidgetTester tester, {double textScale = 1}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 740);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: AppSettingsPage(ctrl: ctrl),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Card and editor follow current model and hide slots without one',
    (tester) async {
      await settings.activateEasySlot(Adi2Variant.pro, 2);
      await show(tester);
      expect(find.byKey(const ValueKey('easy-slot-active-0')), findsOneWidget);
      ctrl.variant = Adi2Variant.pro;
      ctrl.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('easy-slot-active-2')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('easy-open-editor')));
      await tester.pumpAndSettle();
      expect(find.text('Eigene Ansicht 3'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<Adi2Variant>), findsNothing);
      ctrl.variant = Adi2Variant.dac;
      ctrl.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Eigene Ansicht 1'), findsOneWidget);
      ctrl.variant = null;
      ctrl.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        find.text('Gerät anschließen oder offline ein Modell wählen'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('easy-editor-footer')), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.text('Gerät anschließen oder offline ein Modell wählen'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('easy-slot-0')), findsNothing);
    },
  );

  testWidgets(
    'Editor uses the selected offline model and preserves separate layouts',
    (tester) async {
      final offline = Adi2Controller();
      try {
        await offline.startOffline(Adi2Variant.pro4ex);
        await settings.setEasyLayout(Adi2Variant.dac, EasyLayout(tiles: []));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: EasyModeEditor(ctrl: offline),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('easy-model')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('header-status')));
        await tester.pumpAndSettle();
        expect(settings.easyLayout(Adi2Variant.pro4ex).showPlayer, isFalse);
        expect(settings.easyLayout(Adi2Variant.dac).tiles, isEmpty);
        expect(settings.easyLayout(Adi2Variant.dac).showPlayer, isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        offline.dispose();
      }
    },
  );

  for (final language in AppLanguage.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Card fits 360x740 in $language at text scale $scale', (
        tester,
      ) async {
        AppLang.instance.language = language;
        await settings.setEasyMode(true);
        await show(tester, textScale: scale);
        final title = find.text(tr('Eigene Ansicht einrichten'));
        expect(title, findsOneWidget);
        expect(
          find.text(tr('Eigenes Bedienfeld aus Kacheln bauen')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('easy-slot-active-0')),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          find.text(tr('Sprache')),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          tester.getTopLeft(title).dy,
          lessThan(tester.getTopLeft(find.text(tr('Sprache'))).dy),
        );
        expect(tester.takeException(), isNull);
        // Only the explicit full-width pencil button opens the editor.
        await tester.ensureVisible(
          find.byKey(const ValueKey('easy-open-editor')),
        );
        final edit = find.byKey(const ValueKey('easy-open-editor'));
        expect(
          find.descendant(of: edit, matching: find.text(tr('Bearbeiten'))),
          findsOneWidget,
        );
        final firstSlot = tester.getRect(
          find.byKey(const ValueKey('easy-slot-0')),
        );
        final lastSlot = tester.getRect(
          find.byKey(const ValueKey('easy-slot-3')),
        );
        expect(tester.getRect(edit).left, closeTo(firstSlot.left, 0.01));
        expect(tester.getRect(edit).right, closeTo(lastSlot.right, 0.01));
        await tester.tap(edit);
        await tester.pumpAndSettle();
        expect(find.byType(EasyModeEditor), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'Card title, description, background and active slot do not open editor',
    (tester) async {
      await show(tester);
      for (final target in [
        find.text('Eigene Ansicht einrichten'),
        find.text('Eigenes Bedienfeld aus Kacheln bauen'),
        find.byIcon(Icons.dashboard_customize),
        find.byKey(const ValueKey('easy-slot-0')),
      ]) {
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(find.byType(EasyModeEditor), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
      }
      final editRect = tester.getRect(
        find.byKey(const ValueKey('easy-open-editor')),
      );
      await tester.tapAt(Offset(editRect.center.dx, editRect.top - 6));
      await tester.pumpAndSettle();
      expect(find.byType(EasyModeEditor), findsNothing);
      await tester.tap(find.byKey(const ValueKey('easy-open-editor')));
      await tester.pumpAndSettle();
      expect(find.byType(EasyModeEditor), findsOneWidget);
    },
  );

  testWidgets('Slot activation requires confirmation including empty slots', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('leer'), findsNWidgets(3));
    await tester.tap(find.byKey(const ValueKey('easy-slot-1')));
    await tester.pumpAndSettle();
    expect(find.text('Eigene Ansicht 2 aktivieren?'), findsOneWidget);
    expect(settings.easySlots(Adi2Variant.dac).active, 0);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(settings.easySlots(Adi2Variant.dac).active, 0);
    await tester.tap(find.byKey(const ValueKey('easy-slot-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('easy-confirm')));
    await tester.pumpAndSettle();
    expect(settings.easySlots(Adi2Variant.dac).active, 1);
    expect(find.byType(EasyModeEditor), findsNothing);
    expect(find.byKey(const ValueKey('easy-slot-active-0')), findsNothing);
    final badge = find.byKey(const ValueKey('easy-slot-active-1'));
    expect(badge, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('easy-slot-1')),
        matching: badge,
      ),
      findsOneWidget,
    );
    expect(settings.easySlots(Adi2Variant.dac).layouts[1], isNull);
    await tester.tap(find.byKey(const ValueKey('easy-open-editor')));
    await tester.pumpAndSettle();
    expect(find.text('Eigene Ansicht 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Card follows activation and layout colors and hides empty preview',
    (tester) async {
      await show(tester);
      expect(find.byKey(const ValueKey('easy-slot-active-0')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('easy-settings-preview-5')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('easy-settings-preview-6')),
        findsOneWidget,
      );
      await settings.setEasyMode(true);
      await settings.setEasyLayout(
        Adi2Variant.dac,
        EasyLayout(
          defaultColor: EasyTileColor.blue,
          tiles: const [
            EasyTile(type: EasyTileType.mute),
            EasyTile(type: EasyTileType.dim, color: EasyTileColor.amber),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('easy-slot-active-0')), findsOneWidget);
      for (var i = 0; i < 2; i++) {
        final tile = tester.widget<DecoratedBox>(
          find.byKey(ValueKey('easy-settings-preview-$i')),
        );
        expect(
          (tile.decoration as BoxDecoration).color,
          easyTileBackground(i == 0 ? EasyTileColor.blue : EasyTileColor.amber),
        );
      }
      await settings.setEasyMode(false);
      await settings.setEasyLayout(Adi2Variant.dac, EasyLayout(tiles: []));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('easy-slot-active-0')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('easy-settings-preview-0')),
        findsNothing,
      );
      expect(find.text('Eigene Ansicht einrichten'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
