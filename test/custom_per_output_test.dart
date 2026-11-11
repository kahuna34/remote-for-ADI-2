import 'dart:convert';

import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/easy/easy_layout.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/app_settings_page.dart';
import 'package:adi2_remote/ui/easy_mode_editor.dart';
import 'package:adi2_remote/ui/easy_slot_preview.dart';
import 'package:adi2_remote/ui/easy_tile_grid.dart';
import 'package:adi2_remote/ui/outputs_page.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Controller extends Adi2Controller {
  _Controller(this.variant) : values = offlineDefaults(variant) {
    selectedOutput = 3;
  }
  @override
  final Adi2Variant variant;
  final Map<int, int> values;
  final writes = <(int, int, int)>[];
  @override
  int? value(int address, int index) => values[address << 8 | index];
  @override
  int valueOr(int address, int index, int fallback) =>
      value(address, index) ?? fallback;
  @override
  Future<void> requestPresetNames() async {}
  @override
  void set(int address, int index, int raw) {
    writes.add((address, index, raw));
    values[address << 8 | index] = raw;
    notifyListeners();
  }

  void deviceOutput(int output) {
    selectedOutput = output;
    notifyListeners();
  }
}

EasyLayout _page(String label, EasyTileColor color, {bool selector = false}) =>
    EasyLayout(
      defaultColor: color,
      tiles: [
        if (selector)
          const EasyTile(
            type: EasyTileType.outputSelect,
            size: EasyTileSize.full,
            height: 0.5,
          ),
        EasyTile(
          type: EasyTileType.mute,
          label: label,
          pinned: true,
          x: 15,
          y: 2,
        ),
      ],
    );

EasyLayout _split(Adi2Variant variant, {bool selector = false}) {
  var setup = _page('Gemeinsam', EasyTileColor.graphite, selector: selector)
      .setSamePageForAllOutputs(
        false,
        outputsFor(variant).map((o) => o.address),
        selectedOutput: 3,
      );
  for (final out in outputsFor(variant)) {
    setup = setup.withPage(
      out.address,
      _page(
        'Seite ${out.address}',
        EasyTileColor.values[out.address ~/ 3],
        selector: selector,
      ),
    );
  }
  return setup;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = AppSettings.instance;
  late AppLanguage previousLanguage;
  setUp(() async {
    previousLanguage = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    SharedPreferences.setMockInitialValues({});
    await settings.load();
  });
  tearDown(() => AppLang.instance.language = previousLanguage);

  for (final variant in Adi2Variant.values) {
    test(
      'Migrates all legacy slots without losing names/pages: ${variant.name}',
      () async {
        final original = _page('Alt', EasyTileColor.rose);
        for (final version in [1, 2, 3, 4]) {
          final legacy = original.toJson()
            ..['version'] = version
            ..remove('samePageForAllOutputs');
          (legacy['tiles'] as List).single['x'] = 3;
          if (version == 1) legacy['columns'] = 2;
          SharedPreferences.setMockInitialValues({
            'easy_slots_${variant.name}': jsonEncode({
              'version': 1,
              'active': 2,
              'slots': [
                for (var i = 0; i < 4; i++)
                  {'name': 'Name $i', 'layout': legacy},
              ],
            }),
          });
          await settings.load();
          final slots = settings.easySlots(variant);
          expect(slots.active, 2);
          expect(slots.names, ['Name 0', 'Name 1', 'Name 2', 'Name 3']);
          for (final layout in slots.layouts.cast<EasyLayout>()) {
            expect(layout.samePageForAllOutputs, isTrue);
            for (final out in outputsFor(variant)) {
              final page = layout.pageFor(out.address);
              expect(page.tiles.single.label, 'Alt');
              expect(page.defaultColor, EasyTileColor.rose);
              expect(page.tiles.single.pinned, version >= 3);
              if (version >= 3) {
                expect((page.tiles.single.x, page.tiles.single.y), (15, 2));
              }
            }
          }
          final stored = jsonDecode(
            (await SharedPreferences.getInstance()).getString(
              'easy_slots_${variant.name}',
            )!,
          );
          expect(stored['version'], 2);
          expect(stored['slots'][0]['layout']['version'], EasyLayout.version);
          await settings.load();
          expect(settings.easySlots(variant).encode(), slots.encode());
        }
      },
    );

    test(
      'Splits, edits, reunites and retains all independent pages: ${variant.name}',
      () {
        final original = _page('Original', EasyTileColor.petrol);
        final addresses = outputsFor(variant).map((o) => o.address).toList();
        final split = original.setSamePageForAllOutputs(
          false,
          addresses,
          selectedOutput: 3,
        );
        for (final address in addresses) {
          expect(split.pageFor(address).toJson(), original.toJson());
        }
        final edited = split.withPage(3, _page('Line', EasyTileColor.red));
        expect(edited.pageFor(addresses.last).tiles.single.label, 'Original');
        expect(original.tiles.single.label, 'Original');
        final shared = edited.setSamePageForAllOutputs(
          true,
          addresses,
          selectedOutput: 3,
        );
        expect(shared.pageFor(addresses.last).tiles.single.label, 'Line');
        final restored = shared.setSamePageForAllOutputs(
          false,
          addresses,
          selectedOutput: 3,
        );
        for (final address in addresses) {
          expect(
            restored.pageFor(address).toJson(),
            edited.pageFor(address).toJson(),
          );
        }
        expect(() => restored.outputPages.clear(), throwsUnsupportedError);
        expect(
          EasyLayout.decode(restored.encode(), variant).toJson(),
          restored.toJson(),
        );
        final copied = edited.copyPageTo(3, addresses.skip(1));
        for (final address in addresses) {
          expect(copied.pageFor(address).toJson(), edited.pageFor(3).toJson());
        }
        var slots = EasySlots.defaults(variant);
        for (var i = 0; i < 4; i++) {
          slots = slots.save(i, restored, name: 'Slot $i');
        }
        expect(
          EasySlots.decode(slots.encode(), variant).encode(),
          slots.encode(),
        );
      },
    );
  }

  Future<void> show(WidgetTester tester, Widget page, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: page));
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  for (final size in [const Size(360, 740), const Size(411, 914)]) {
    testWidgets('Editor switch, selection, swipe, copy and save at $size', (
      tester,
    ) async {
      final ctrl = _Controller(Adi2Variant.dac);
      addTearDown(ctrl.dispose);
      final original = _page('Alt', EasyTileColor.rose);
      await settings.setEasyLayout(ctrl.variant, original);
      await show(tester, EasyModeEditor(ctrl: ctrl), size);
      expect(find.byKey(const ValueKey('easy-editor-outputs')), findsNothing);
      await tapKey(tester, 'easy-same-page');
      expect(settings.easyLayout(ctrl.variant).samePageForAllOutputs, isFalse);
      for (final out in outputsFor(ctrl.variant)) {
        expect(
          settings.easyLayout(ctrl.variant).pageFor(out.address).toJson(),
          original.toJson(),
        );
      }
      await settings.setEasyLayout(ctrl.variant, _split(ctrl.variant));
      await tester.pumpAndSettle();
      final selector = find.byKey(const ValueKey('easy-editor-outputs'));
      await tester.ensureVisible(selector);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: selector, matching: find.text('Phones')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<OutputSwitch>(selector).selected, 6);
      expect(
        tester
            .widget<EasyTileGrid>(find.byType(EasyTileGrid))
            .layout
            .tiles
            .last
            .label,
        'Seite 6',
      );
      expect(ctrl.selectedOutput, 3);
      await tester.drag(selector, const Offset(-180, 0));
      await tester.pumpAndSettle();
      expect(tester.widget<OutputSwitch>(selector).selected, 9);
      expect(
        tester
            .widget<EasyTileGrid>(find.byType(EasyTileGrid))
            .layout
            .tiles
            .last
            .label,
        'Seite 9',
      );
      await tester.drag(selector, const Offset(180, 0));
      await tester.pumpAndSettle();
      expect(tester.widget<OutputSwitch>(selector).selected, 6);

      await tapKey(tester, 'easy-copy-outputs');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('easy-copy-confirm')),
            )
            .onPressed,
        isNull,
      );
      await tapKey(tester, 'easy-copy-target-3');
      await tapKey(tester, 'easy-copy-confirm');
      expect(
        find.text('Seiten der gewählten Ausgänge überschreiben?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Abbrechen').last);
      await tester.pumpAndSettle();
      expect(
        settings.easyLayout(ctrl.variant).pageFor(3).tiles.last.label,
        'Seite 3',
      );
      await tapKey(tester, 'easy-copy-confirm');
      await tapKey(tester, 'easy-confirm');
      final setup = settings.easyLayout(ctrl.variant);
      expect(setup.pageFor(3).toJson(), setup.pageFor(6).toJson());
      expect(setup.pageFor(9).tiles.last.label, 'Seite 9');

      // Pins and page colors are independent even after copying a page.
      await tapKey(tester, 'easy-pin-0');
      expect(
        settings.easyLayout(ctrl.variant).pageFor(6).tiles.single.pinned,
        isFalse,
      );
      expect(
        settings.easyLayout(ctrl.variant).pageFor(3).tiles.single.pinned,
        isTrue,
      );
      await tapKey(tester, 'easy-layout-color');
      await tapKey(tester, 'easy-color-copper');
      expect(
        settings.easyLayout(ctrl.variant).pageFor(6).defaultColor,
        EasyTileColor.copper,
      );
      expect(
        settings.easyLayout(ctrl.variant).pageFor(3).defaultColor,
        isNot(EasyTileColor.copper),
      );
      await tapKey(tester, 'easy-layout-color');

      // Changes to page settings affect just the selected page.
      await tapKey(tester, 'header-status');
      expect(settings.easyLayout(ctrl.variant).pageFor(6).showPlayer, isFalse);
      expect(settings.easyLayout(ctrl.variant).pageFor(3).showPlayer, isTrue);
      await tapKey(tester, 'easy-save-setup');
      await tapKey(tester, 'easy-save-slot-1');
      await tapKey(tester, 'easy-save-setup-confirm');
      await settings.load();
      expect(settings.easySlots(ctrl.variant).active, 1);
      expect(
        settings.easySlots(ctrl.variant).layouts[1]!.toJson(),
        settings.easySlots(ctrl.variant).layouts[0]!.toJson(),
      );
      await tapKey(tester, 'easy-same-page');
      expect(find.byKey(const ValueKey('easy-editor-outputs')), findsNothing);
      expect(settings.easyLayout(ctrl.variant).samePageForAllOutputs, isTrue);
      await tapKey(tester, 'easy-same-page');
      expect(
        settings.easyLayout(ctrl.variant).pageFor(9).tiles.last.label,
        'Seite 9',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Panel follows output tile and device selection at $size', (
      tester,
    ) async {
      final ctrl = _Controller(Adi2Variant.dac);
      addTearDown(ctrl.dispose);
      final setup = _split(ctrl.variant, selector: true);
      await show(
        tester,
        Scaffold(
          body: OutputsPage(ctrl: ctrl, easyLayout: setup),
        ),
        size,
      );
      expect(find.text('Seite 3'), findsOneWidget);
      await tapKey(tester, 'easy-segment-0-6');
      expect(ctrl.selectedOutput, 6);
      expect(find.text('Seite 6'), findsOneWidget);
      expect(find.text('Seite 3'), findsNothing);
      await tapKey(tester, 'easy-tile-1');
      expect(ctrl.writes.last, (6, OutIdx.mute, 1));
      ctrl.deviceOutput(9);
      await tester.pump();
      expect(find.byType(FadeTransition), findsWidgets);
      await tester.pumpAndSettle();
      expect(find.text('Seite 9'), findsOneWidget);
      expect(find.text('Seite 6'), findsNothing);
      await tapKey(tester, 'easy-tile-1');
      expect(ctrl.writes.last, (9, OutIdx.mute, 1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Settings previews update to the selected output for every slot',
    (tester) async {
      final ctrl = _Controller(Adi2Variant.dac);
      addTearDown(ctrl.dispose);
      for (var i = 0; i < 4; i++) {
        await settings.saveEasySlot(ctrl.variant, i, _split(ctrl.variant));
      }
      await show(tester, AppSettingsPage(ctrl: ctrl), const Size(360, 740));
      for (final preview in tester.widgetList<EasyLayoutPreview>(
        find.byType(EasyLayoutPreview),
      )) {
        expect(preview.layout.tiles.last.label, 'Seite 3');
      }
      expect(find.byType(EasyLayoutPreview), findsNWidgets(4));
      ctrl.deviceOutput(6);
      await tester.pumpAndSettle();
      for (final preview in tester.widgetList<EasyLayoutPreview>(
        find.byType(EasyLayoutPreview),
      )) {
        expect(preview.layout.tiles.last.label, 'Seite 6');
      }
      expect(tester.takeException(), isNull);
    },
  );
}
