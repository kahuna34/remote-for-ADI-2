import 'dart:convert';

import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/easy/easy_layout.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/main_view_colors.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/ui/app_settings_page.dart';
import 'package:adi2_remote/ui/easy_mode_editor.dart';
import 'package:adi2_remote/ui/easy_tile_grid.dart';
import 'package:adi2_remote/ui/header_content_picker.dart';
import 'package:adi2_remote/ui/main_view_colors_editor.dart';
import 'package:adi2_remote/ui/main_view_control_surface.dart';
import 'package:adi2_remote/ui/outputs_page.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:adi2_remote/ui/volume_ring.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Controller extends Adi2Controller {
  _Controller() : values = offlineDefaults(Adi2Variant.dac) {
    selectedOutput = Adi2Addr.ph12;
  }
  @override
  final Adi2Variant variant = Adi2Variant.dac;
  final Map<int, int> values;
  final writes = <(int, int, int)>[];
  @override
  int? value(int address, int index) => values[address << 8 | index];
  @override
  int valueOr(int address, int index, int fallback) =>
      value(address, index) ?? fallback;
  @override
  void set(int address, int index, int raw) =>
      writes.add((address, index, raw));
  @override
  void setVolume(int address, int raw, {bool followLink = true}) =>
      writes.add((address, OutIdx.volume, raw));
  @override
  void setEq(int address, int index, int raw) =>
      writes.add((address, index, raw));
  @override
  Future<void> requestPresetNames() async {}
}

void main() {
  final settings = AppSettings.instance;
  late _Controller ctrl;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
    final language = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    addTearDown(() => AppLang.instance.language = language);
    ctrl = _Controller();
    addTearDown(ctrl.dispose);
  });

  Future<void> show(
    WidgetTester tester,
    Widget page, {
    Size size = const Size(800, 1280),
    double scale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: page,
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder control(MainViewControl id) =>
      find.byWidgetPredicate((w) => w is MainViewControlSurface && w.id == id);
  Material surface(WidgetTester tester, MainViewControl id) =>
      tester.widget<Material>(
        find.descendant(of: control(id), matching: find.byType(Material)).first,
      );

  EasyTileColor defaultColor(MainViewControl id) =>
      AppSettings.defaultMainViewColors[id] ?? EasyTileColor.graphite;

  test('Colors round trip independently, graphite overrides persist, reset restores defaults', () async {
    for (final id in MainViewControl.values) {
      await settings.setMainViewColor(id, EasyTileColor.blue);
    }
    await settings.setMainViewColor(MainViewControl.mute, EasyTileColor.rose);
    await settings.load();
    expect(settings.mainViewColor(MainViewControl.mute), EasyTileColor.rose);
    for (final id in MainViewControl.values.where(
      (id) => id != MainViewControl.mute,
    )) {
      expect(settings.mainViewColor(id), EasyTileColor.blue);
    }
    await settings.setMainViewColor(
      MainViewControl.mute,
      EasyTileColor.graphite,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      jsonDecode(prefs.getString('main_view_colors')!),
      containsPair('mute', 'graphite'),
    );
    await settings.load();
    expect(
      settings.mainViewColor(MainViewControl.mute),
      EasyTileColor.graphite,
    );
    await settings.setMainViewColor(
      MainViewControl.mute,
      defaultColor(MainViewControl.mute),
    );
    expect(
      jsonDecode(prefs.getString('main_view_colors')!),
      isNot(contains('mute')),
    );
    await settings.resetMainViewColors();
    await settings.load();
    for (final id in MainViewControl.values) {
      expect(settings.mainViewColor(id), defaultColor(id));
    }
    expect(jsonDecode(prefs.getString('main_view_colors')!), isEmpty);
  });

  test('Unknown IDs, colors and corrupt data fall back safely', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'main_view_colors',
      '{"future":"red","mute":"future","dim":17,"lock":"blue"}',
    );
    await settings.load();
    expect(settings.mainViewColor(MainViewControl.lock), EasyTileColor.blue);
    expect(
      settings.mainViewColor(MainViewControl.mute),
      defaultColor(MainViewControl.mute),
    );
    expect(
      settings.mainViewColor(MainViewControl.dim),
      defaultColor(MainViewControl.dim),
    );
    for (final malformed in ['{', '[]', 'null', '17']) {
      await prefs.setString('main_view_colors', malformed);
      await settings.load();
      for (final id in MainViewControl.values) {
        expect(settings.mainViewColor(id), defaultColor(id), reason: malformed);
      }
    }
  });

  testWidgets(
    'Each ID colors exactly its own real button; reset restores every surface',
    (tester) async {
      ctrl.selectedOutput = Adi2Addr.line;
      await show(tester, Scaffold(body: OutputsPage(ctrl: ctrl)));
      final originals = {
        for (final id in MainViewControl.values)
          id: (surface(tester, id).color, surface(tester, id).shape),
      };
      final ring = tester.getRect(find.byType(VolumeRing));
      final outputs = tester.getRect(find.byType(OutputSwitch));
      for (final id in MainViewControl.values) {
        await settings.setMainViewColor(
          id,
          defaultColor(id) == EasyTileColor.petrol
              ? EasyTileColor.rose
              : EasyTileColor.petrol,
        );
        await tester.pumpAndSettle();
        expect(
          surface(tester, id).color,
          isNot(originals[id]!.$1),
          reason: id.name,
        );
        for (final other in MainViewControl.values.where(
          (other) => other != id,
        )) {
          expect(
            (surface(tester, other).color, surface(tester, other).shape),
            originals[other],
            reason: '$id changed $other',
          );
        }
        expect(tester.getRect(find.byType(VolumeRing)), ring);
        expect(tester.getRect(find.byType(OutputSwitch)), outputs);
        await settings.setMainViewColor(id, defaultColor(id));
        await tester.pumpAndSettle();
        expect((
          surface(tester, id).color,
          surface(tester, id).shape,
        ), originals[id]);
      }
      for (final id in MainViewControl.values) {
        await settings.setMainViewColor(id, EasyTileColor.violet);
      }
      await tester.pumpAndSettle();
      await settings.resetMainViewColors();
      await tester.pumpAndSettle();
      for (final id in MainViewControl.values) {
        expect((
          surface(tester, id).color,
          surface(tester, id).shape,
        ), originals[id]);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Default colors appear without saved overrides', (tester) async {
    ctrl.selectedOutput = Adi2Addr.line;
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('main_view_colors'), isFalse);
    await show(tester, Scaffold(body: OutputsPage(ctrl: ctrl)));
    expect(settings.mainViewColor(MainViewControl.mute), EasyTileColor.red);
    expect(
      settings.mainViewColor(MainViewControl.settings),
      EasyTileColor.blue,
    );
    for (final id in MainViewControl.values) {
      expect(settings.mainViewColor(id), defaultColor(id));
    }
    for (final id in [MainViewControl.mute, MainViewControl.settings]) {
      expect(
        surface(tester, id).color,
        easyTileBackground(defaultColor(id)),
        reason: id.name,
      );
    }
  });

  testWidgets(
    'Active mute and dim retain red/amber outlines, icons and status',
    (tester) async {
      ctrl.selectedOutput = Adi2Addr.line;
      ctrl.values[Adi2Addr.line << 8 | OutIdx.mute] = 1;
      ctrl.values[Adi2Addr.line << 8 | OutIdx.dim] = 1;
      await show(tester, Scaffold(body: OutputsPage(ctrl: ctrl)));
      for (final color in EasyTileColor.values) {
        for (final (id, accent, icon) in [
          (MainViewControl.mute, Palette.red, Icons.volume_off_outlined),
          (MainViewControl.dim, Palette.amber, Icons.brightness_low_outlined),
        ]) {
          await settings.setMainViewColor(id, color);
          await tester.pumpAndSettle();
          final material = surface(tester, id);
          expect(
            (material.shape! as RoundedRectangleBorder).side.color,
            accent,
          );
          final symbol = tester.widget<Icon>(
            find.descendant(of: control(id), matching: find.byIcon(icon)),
          );
          expect(symbol.color, accent);
          expect(
            find.descendant(of: control(id), matching: find.text('An')),
            findsOneWidget,
          );
          final bg = material.color!.computeLuminance();
          final fg = Palette.text.computeLuminance();
          expect((fg + 0.05) / (bg + 0.05), greaterThanOrEqualTo(4.5));
        }
      }
    },
  );

  testWidgets(
    'Preview opens color picker, saves, resets, and sends no commands including holds',
    (tester) async {
      await show(tester, MainViewColorsEditor(ctrl: ctrl));
      expect(ctrl.selectedOutput, Adi2Addr.ph12);
      for (final id in MainViewControl.values) {
        await tester.ensureVisible(control(id));
        await tester.tap(control(id));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget, reason: id.name);
        expect(find.text(mainViewControlName(id)), findsWidgets);
        await tester.tap(find.byKey(const ValueKey('easy-color-blue')));
        await tester.pumpAndSettle();
        expect(settings.mainViewColor(id), EasyTileColor.blue);
      }
      await tester.ensureVisible(control(MainViewControl.volumeUp));
      final gesture = await tester.startGesture(
        tester.getCenter(control(MainViewControl.volumeUp)),
      );
      await tester.pump(const Duration(seconds: 2));
      await gesture.up();
      await tester.pumpAndSettle();
      if (find.byType(AlertDialog).evaluate().isNotEmpty) {
        await tester.tap(find.text('Abbrechen'));
        await tester.pumpAndSettle();
      }
      final selector = find.byType(OutputSwitch);
      await tester.ensureVisible(selector);
      await tester.tap(
        find.descendant(of: selector, matching: find.text('Phones')),
      );
      await tester.pumpAndSettle();
      expect(ctrl.selectedOutput, Adi2Addr.ph12);
      expect(ctrl.writes, isEmpty);
      await tester.tap(find.byKey(const ValueKey('main-colors-reset')));
      await tester.pumpAndSettle();
      await settings.load();
      for (final id in MainViewControl.values) {
        expect(settings.mainViewColor(id), defaultColor(id));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Settings show only the active mode card and open the dedicated main editor',
    (tester) async {
      await show(tester, AppSettingsPage(ctrl: ctrl));
      expect(find.byKey(const ValueKey('easy-settings-card')), findsNothing);
      final mainCard = tester.widget<Material>(
        find.byKey(const ValueKey('main-view-settings-card')),
      );
      expect(mainCard.color, Palette.surf);
      expect(
        (mainCard.shape! as RoundedRectangleBorder).side.color,
        Palette.line,
      );
      await settings.setEasyMode(true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('main-view-settings-card')),
        findsNothing,
      );
      final customCard = tester.widget<Material>(
        find.byKey(const ValueKey('easy-settings-card')),
      );
      expect(customCard.color, Palette.surf);
      expect(
        (customCard.shape! as RoundedRectangleBorder).side.color,
        Palette.line,
      );
      expect(
        tester.widget(find.byKey(const ValueKey('easy-open-editor'))),
        isA<OutlinedButton>(),
      );
      expect(find.byIcon(Icons.dashboard_customize), findsOneWidget);
      await settings.setEasyMode(false);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('main-view-open-editor')));
      await tester.pumpAndSettle();
      expect(find.byType(MainViewColorsEditor), findsOneWidget);
      expect(find.byType(EasyModeEditor), findsNothing);
      expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
      expect(find.text('Hauptansicht anpassen'), findsOneWidget);
    },
  );

  for (final size in [
    const Size(360, 740),
    const Size(740, 360),
    const Size(600, 960),
    const Size(960, 600),
    const Size(800, 1280),
    const Size(1280, 800),
  ]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets(
        'Editors fit $size at $scale, page options precede the grid',
        (tester) async {
          await settings.setEasyLayout(
            ctrl.variant,
            settings
                .easyLayout(ctrl.variant)
                .setSamePageForAllOutputs(
                  false,
                  outputsFor(ctrl.variant).map((o) => o.address),
                  selectedOutput: Adi2Addr.ph12,
                ),
          );
          await show(
            tester,
            EasyModeEditor(ctrl: ctrl),
            size: size,
            scale: scale,
          );
          final options = find.byKey(const ValueKey('easy-editor-options'));
          for (final option in [
            find.byKey(const ValueKey('easy-same-page')),
            find.byKey(const ValueKey('easy-layout-color')),
            find.byKey(const ValueKey('easy-editor-outputs')),
            find.byKey(const ValueKey('easy-copy-outputs')),
            find.byType(HeaderContentPicker),
          ]) {
            expect(
              find.descendant(of: options, matching: option),
              findsOneWidget,
            );
          }
          final grid = find.byType(OutputsPage);
          expect(
            tester.getBottomLeft(options).dy,
            lessThanOrEqualTo(tester.getTopLeft(grid).dy),
          );
          await tester.ensureVisible(
            find.byKey(const ValueKey('easy-layout-color')),
          );
          await tester.tap(find.byKey(const ValueKey('easy-layout-color')));
          await tester.pumpAndSettle();
          expect(
            tester.getBottomLeft(options).dy,
            lessThanOrEqualTo(tester.getTopLeft(grid).dy),
          );
          await tester.ensureVisible(grid);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          for (final id in MainViewControl.values) {
            await settings.setMainViewColor(id, EasyTileColor.rose);
          }
          AppLang.instance.language = AppLanguage.en;
          await show(
            tester,
            MainViewColorsEditor(ctrl: ctrl),
            size: size,
            scale: scale,
          );
          expect(find.text('Customize main view'), findsOneWidget);
          await tester.ensureVisible(control(MainViewControl.mute));
          await tester.tap(control(MainViewControl.mute));
          await tester.pumpAndSettle();
          expect(find.byType(EasyColorPicker), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('main-color-default')));
          await tester.pumpAndSettle();
          expect(
            settings.mainViewColor(MainViewControl.mute),
            EasyTileColor.graphite,
          );
          expect(tester.takeException(), isNull);
          expect(ctrl.writes, isEmpty);
        },
      );
    }
  }
}
