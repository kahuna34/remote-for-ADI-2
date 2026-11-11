import 'dart:convert';

import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/easy/easy_layout.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/easy_mode_editor.dart';
import 'package:adi2_remote/ui/easy_tile_grid.dart';
import 'package:adi2_remote/ui/easy_tile_preview.dart';
import 'package:adi2_remote/ui/outputs_page.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:adi2_remote/ui/volume_ring.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Controller extends Adi2Controller {
  _Controller(this.variant) : values = offlineDefaults(variant);
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
  void set(int address, int index, int raw) =>
      writes.add((address, index, raw));
  @override
  void setVolume(int address, int raw, {bool followLink = true}) =>
      writes.add((address, OutIdx.volume, raw));
  @override
  Future<void> requestPresetNames() async {}
}

void main() {
  final settings = AppSettings.instance;
  late AppLanguage previous;
  setUp(() async {
    previous = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    SharedPreferences.setMockInitialValues({});
    await settings.load();
  });
  tearDown(() => AppLang.instance.language = previous);

  Future<void> open(
    WidgetTester tester,
    _Controller ctrl, {
    double width = 360,
    double height = 740,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await settings.setEasyLayout(
      ctrl.variant,
      EasyLayout(tiles: [], defaultColor: EasyTileColor.green),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: EasyModeEditor(ctrl: ctrl),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('easy-add')));
    await tester.pumpAndSettle();
  }

  for (final variant in Adi2Variant.values) {
    testWidgets(
      'Gallery has all supported operating previews for ${variant.name} at 360×740',
      (tester) async {
        final ctrl = _Controller(variant);
        addTearDown(ctrl.dispose);
        await open(tester, ctrl);
        final scroll = find
            .descendant(
              of: find.byKey(const ValueKey('easy-tile-gallery')),
              matching: find.byType(Scrollable),
            )
            .first;
        final seen = <EasyTileType>{};
        for (var i = 0; i < 30; i++) {
          for (final type in EasyTileType.values) {
            final card = find.byKey(ValueKey('easy-gallery-${type.name}'));
            if (card.evaluate().isEmpty) continue;
            seen.add(type);
            expect(card, findsOneWidget);
            expect(
              find.descendant(
                of: find.byKey(const ValueKey('easy-tile-gallery')),
                matching: find.byType(EasyColorPicker),
              ),
              findsNothing,
            );

            final preview = tester.widget<EasyTilePreview>(
              find.descendant(of: card, matching: find.byType(EasyTilePreview)),
            );
            expect(preview.tile.toJson(), EasyTile.defaults(type).toJson());
            final operating = find.descendant(
              of: card,
              matching: find.byType(OutputsPage),
            );
            expect(preview.defaultColor, EasyTileColor.green);
            final rendered = tester.getRect(operating);
            expect(rendered.width, greaterThanOrEqualTo(140));
            expect(
              tester.widget<OutputsPage>(operating).previewTile,
              preview.tile,
            );
            expect(
              find.descendant(of: card, matching: find.byType(IgnorePointer)),
              findsWidgets,
            );
          }
          await tester.drag(scroll, const Offset(0, -220));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        expect(
          seen,
          EasyTileType.values
              .where((t) => EasyTile.supportsType(t, variant))
              .toSet(),
        );
        expect(seen.contains(EasyTileType.basicMode), !variant.isDac);
        expect(ctrl.writes, isEmpty);
      },
    );
  }

  for (final type in EasyTileType.values) {
    testWidgets(
      'Size picker previews only valid $type shapes with selected default',
      (tester) async {
        final ctrl = _Controller(Adi2Variant.pro4ex);
        addTearDown(ctrl.dispose);
        await open(tester, ctrl);
        final card = find.byKey(ValueKey('easy-gallery-${type.name}'));
        final scroll = find
            .descendant(
              of: find.byKey(const ValueKey('easy-tile-gallery')),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(card, 180, scrollable: scroll);
        await tester.pumpAndSettle();
        await tester.tap(card);
        await tester.pumpAndSettle();
        final initial = EasyTile.defaults(type);
        final selected = find.byKey(
          ValueKey('easy-size-${initial.size.name}-${initial.height}'),
        );
        expect(selected.hitTestable(), findsOneWidget);
        final semantics = tester.widgetList<Semantics>(
          find.ancestor(of: selected, matching: find.byType(Semantics)),
        );
        expect(
          semantics.where((s) => s.properties.selected == true),
          hasLength(1),
        );
        for (final s in EasyTileSize.values) {
          for (final h in const [0.5, 1.0, 1.5, 2.0]) {
            final cell = find.byKey(ValueKey('easy-size-${s.name}-$h'));
            final allowed = EasyTile.supportsShape(type, s, h);
            expect(
              tester.widget<InkWell>(cell).onTap,
              allowed ? isNotNull : isNull,
            );
            final preview = find.descendant(
              of: cell,
              matching: find.byType(EasyTilePreview),
            );
            expect(preview, allowed ? findsOneWidget : findsNothing);
            if (allowed) {
              final tile = tester.widget<EasyTilePreview>(preview).tile;
              expect((tile.size, tile.height), (s, h));
            }
          }
        }
        if (type == EasyTileType.volumeRing) {
          expect(find.byType(VolumeRing), findsWidgets);
        }
        expect(find.text('Hinzufügen'), findsWidgets);
        expect(find.text('Kachelfarbe'), findsNothing);
        expect(
          find.descendant(
            of: find.byType(Scaffold).last,
            matching: find.byType(EasyColorPicker),
          ),
          findsNothing,
        );
        expect(ctrl.writes, isEmpty);
        expect(settings.easyLayout(ctrl.variant).tiles, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Abbrechen'));
        await tester.pumpAndSettle();
        expect(settings.easyLayout(ctrl.variant).tiles, isEmpty);
      },
    );
  }

  testWidgets('Narrow phones keep two previews per row without overflow', (
    tester,
  ) async {
    final ctrl = _Controller(Adi2Variant.dac);
    addTearDown(ctrl.dispose);
    await open(tester, ctrl, width: 320);
    final card = find.byKey(const ValueKey('easy-gallery-volumeDown'));
    final scroll = find
        .descendant(
          of: find.byKey(const ValueKey('easy-tile-gallery')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(card, 180, scrollable: scroll);
    await tester.pumpAndSettle();
    expect(
      tester
          .getRect(
            find.descendant(of: card, matching: find.byType(OutputsPage)),
          )
          .width,
      closeTo((320 - 32 - 12) / 2 - 16, 0.01),
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 360.0, 640.0, 1024.0]) {
    testWidgets('Gallery uses a full ring row and two cards at $width', (
      tester,
    ) async {
      final ctrl = _Controller(Adi2Variant.dac);
      addTearDown(ctrl.dispose);
      await open(tester, ctrl, width: width);
      final gallery = tester.getRect(
        find.byKey(const ValueKey('easy-tile-gallery')),
      );
      expect(gallery.left, 0);
      expect(gallery.width, width);
      expect(gallery.top, kToolbarHeight);
      expect(gallery.bottom, 740);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);
      final ring = tester.getRect(
        find.byKey(const ValueKey('easy-gallery-volumeRing')),
      );
      final down = tester.getRect(
        find.byKey(const ValueKey('easy-gallery-volumeDown')),
      );
      final up = tester.getRect(
        find.byKey(const ValueKey('easy-gallery-volumeUp')),
      );
      expect(ring.left, 16);
      expect(ring.right, width - 16);
      expect(down.top, up.top);
      expect(up.left - down.right, 12);
      expect(ring.width, closeTo(down.width * 2 + 12, 0.01));
      expect(down.top, greaterThan(ring.bottom));
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [360.0, 1024.0]) {
    testWidgets('Size matrix uses the full page width at $width', (
      tester,
    ) async {
      final ctrl = _Controller(Adi2Variant.dac);
      addTearDown(ctrl.dispose);
      await open(tester, ctrl, width: width);
      await tester.tap(find.byKey(const ValueKey('easy-gallery-volumeRing')));
      await tester.pumpAndSettle();
      final matrix = tester.getRect(
        find.byKey(const ValueKey('easy-size-scroll')),
      );
      expect(matrix.left, 16);
      expect(matrix.width, width - 32);
      final page = tester.getRect(find.byType(Scaffold).last);
      expect(page, Rect.fromLTWH(0, 0, width, 740));
      expect(find.byType(BackButton), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(settings.easyLayout(ctrl.variant).tiles, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Add and edit matrix fills 80 percent of a 411×914 screen', (
    tester,
  ) async {
    final ctrl = _Controller(Adi2Variant.dac);
    addTearDown(ctrl.dispose);
    await open(tester, ctrl, width: 411, height: 914);
    await tester.tap(find.byKey(const ValueKey('easy-gallery-volumeRing')));
    await tester.pumpAndSettle();
    Future<void> checkMatrix(String action) async {
      expect(find.byType(AlertDialog), findsNothing);
      final matrix = tester.getRect(
        find.byKey(const ValueKey('easy-size-scroll')),
      );
      expect(matrix.height, greaterThanOrEqualTo(914 * 0.8));
      final button = find.byKey(const ValueKey('easy-save-tile'));
      final fixed = tester.getRect(button);
      expect(button.hitTestable(), findsOneWidget);
      expect(find.widgetWithText(FilledButton, action), findsOneWidget);
      for (final h in [0.5, 1.0, 1.5, 2.0]) {
        final row = tester.getRect(find.byKey(ValueKey('easy-size-row-$h')));
        expect(row.top, greaterThanOrEqualTo(matrix.top));
        expect(row.bottom, lessThanOrEqualTo(matrix.bottom));
      }
      await tester.ensureVisible(find.byKey(const ValueKey('easy-label')));
      await tester.pumpAndSettle();
      expect(tester.getRect(button), fixed);
      await tester.enterText(find.byKey(const ValueKey('easy-label')), 'Test');
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    await checkMatrix('Hinzufügen');
    // Adding returns to the gallery; return to the editor to edit the new tile.
    if (find.byKey(const ValueKey('easy-tile-gallery')).evaluate().isNotEmpty) {
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(find.byKey(const ValueKey('easy-edit-0')));
    await tester.tap(find.byKey(const ValueKey('easy-edit-0')));
    await tester.pumpAndSettle();
    await checkMatrix('Übernehmen');
    expect(settings.easyLayout(ctrl.variant).tiles.single.label, 'Test');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Chosen size and setup parameter are saved only by Add', (
    tester,
  ) async {
    final ctrl = _Controller(Adi2Variant.pro);
    addTearDown(ctrl.dispose);
    await open(tester, ctrl);
    final card = find.byKey(const ValueKey('easy-gallery-setup'));
    final scroll = find
        .descendant(
          of: find.byKey(const ValueKey('easy-tile-gallery')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(card, 180, scrollable: scroll);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
    final wide = find.byKey(const ValueKey('easy-size-wide-0.5'));
    await tester.ensureVisible(wide);
    await tester.tap(wide);
    await tester.ensureVisible(find.byKey(const ValueKey('easy-param')));
    await tester.tap(find.byKey(const ValueKey('easy-param')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4 · Setup 4').last);
    await tester.pumpAndSettle();
    expect(settings.easyLayout(ctrl.variant).tiles, isEmpty);
    await tester.tap(find.byKey(const ValueKey('easy-save-tile')));
    await tester.pumpAndSettle();
    final tile = settings.easyLayout(ctrl.variant).tiles.single;
    expect(
      (tile.type, tile.size, tile.height, tile.param),
      (EasyTileType.setup, EasyTileSize.wide, 0.5, 4),
    );
    expect(tile.color, isNull);
    expect(settings.easyLayout(ctrl.variant).defaultColor, EasyTileColor.green);
    await tester.ensureVisible(find.byKey(const ValueKey('easy-edit-0')));
    await tester.tap(find.byKey(const ValueKey('easy-edit-0')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(Scaffold).last,
        matching: find.byType(EasyColorPicker),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<InkWell>(find.byKey(const ValueKey('easy-size-full-1.0')))
          .onTap,
      isNull,
    );
    expect(
      tester
          .widget<InkWell>(find.byKey(const ValueKey('easy-size-wide-2.0')))
          .onTap,
      isNull,
    );
    final picker = tester.widget<EasyColorPicker>(
      find.descendant(
        of: find.byType(Scaffold).last,
        matching: find.byType(EasyColorPicker),
      ),
    );
    picker.onChanged(EasyTileColor.blue);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('easy-save-tile')));
    await tester.pumpAndSettle();
    expect(
      settings.easyLayout(ctrl.variant).tiles.single.color,
      EasyTileColor.blue,
    );
    expect(ctrl.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'App preset is chosen after the size and cannot add the catalog example',
    (tester) async {
      final ctrl = _Controller(Adi2Variant.dac);
      addTearDown(ctrl.dispose);
      await open(tester, ctrl);
      final card = find.byKey(const ValueKey('easy-gallery-appPreset'));
      final scroll = find
          .descendant(
            of: find.byKey(const ValueKey('easy-tile-gallery')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(card, 180, scrollable: scroll);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('easy-size-single-0.5')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('easy-save-tile')));
      await tester.pumpAndSettle();
      expect(find.text('Bitte ein App-EQ-Preset wählen.'), findsOneWidget);
      expect(settings.easyLayout(ctrl.variant).tiles, isEmpty);
      expect(ctrl.writes, isEmpty);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  test('Saved invalid shapes migrate across slots and output pages without losing settings', () async {
    final invalid = {
      'version': EasyLayout.version,
      'samePageForAllOutputs': false,
      'tiles': [
        {
          'type': 'bass',
          'size': 'single',
          'height': 0.5,
          'label': 'Bass',
          'output': 9,
          'color': 'blue',
        },
        {'type': 'outputSelect', 'size': 'single', 'height': 2},
        {
          'type': 'volumeRing',
          'size': 'single',
          'height': 0.5,
          'pinned': true,
          'x': 9,
          'y': 0,
        },
      ],
    };
    invalid['outputPages'] = {'3': Map.of(invalid)};
    SharedPreferences.setMockInitialValues({
      'easy_slots_pro': jsonEncode({
        'version': 2,
        'active': 1,
        'slots': [
          null,
          {'name': 'Mein Slot', 'layout': invalid},
          null,
          null,
        ],
      }),
    });
    await settings.load();
    final slots = settings.easySlots(Adi2Variant.pro);
    expect(slots.names[1], 'Mein Slot');
    for (final page in [slots.layouts[1]!, slots.layouts[1]!.pageFor(3)]) {
      expect(page.tiles.map((t) => (t.size, t.height)), [
        (EasyTileSize.single, 1.0),
        (EasyTileSize.wide, 1.0),
        (EasyTileSize.wide, 2.0),
      ]);
      final bass = page.tiles.first;
      expect(
        (bass.label, bass.output, bass.color),
        ('Bass', 9, EasyTileColor.blue),
      );
      expect(page.tiles.last.pinned, isTrue);
      expect(
        page.tiles.last.x! + page.tiles.last.widthUnits,
        lessThanOrEqualTo(easyGridUnits),
      );
    }
    final encoded = slots.encode();
    await settings.load();
    expect(settings.easySlots(Adi2Variant.pro).encode(), encoded);
  });

  test(
    'Upper limits reject oversized buttons, selectors and landscape steppers',
    () {
      for (final type in EasyTileType.values) {
        final rule = EasyTileSizeRule.forType(type);
        for (final size in EasyTileSize.values) {
          for (final height in [0.5, 1.0, 1.5, 2.0]) {
            if (!rule.supports(size, height)) continue;
            if (type == EasyTileType.volumeRing) {
              expect(height, lessThanOrEqualTo(3));
            } else if (type == EasyTileType.outputSelect) {
              expect(height, lessThanOrEqualTo(1));
            } else if (type == EasyTileType.refLevel) {
              expect(size.units, greaterThanOrEqualTo(easyQuarterUnits));
              expect(height, lessThanOrEqualTo(2));
            } else if (EasyTile.isStepper(type) ||
                type == EasyTileType.source ||
                type == EasyTileType.daFilter) {
              expect(height, lessThanOrEqualTo(size.units > 30 ? 1 : 2));
            } else {
              expect(size.units, lessThanOrEqualTo(30));
              expect(height, lessThanOrEqualTo(1));
            }
          }
        }
        final oversized = EasyTile(
          type: type,
          size: EasyTileSize.full,
          height: 2,
        );
        final normalized = oversized.normalizeShape();
        expect(rule.supports(normalized.size, normalized.height), isTrue);
      }
    },
  );

  test('Central shape limits and defaults cover every type and reject invalid dimensions', () {
    for (final type in EasyTileType.values) {
      final tile = EasyTile.defaults(type);
      expect(EasyTile.supportsShape(type, tile.size, tile.height), isTrue);
      for (final h in [0.0, 0.7, 3.0, double.nan, double.infinity]) {
        expect(EasyTile.supportsShape(type, EasyTileSize.full, h), isFalse);
      }
    }
    for (final type in EasyTileType.values.where(EasyTile.isStepper)) {
      expect(EasyTile.supportsShape(type, EasyTileSize.single, 0.5), isFalse);
      expect(EasyTile.supportsShape(type, EasyTileSize.single, 1), isTrue);
      expect(EasyTile.supportsShape(type, EasyTileSize.wide, 0.5), isTrue);
    }
    for (final h in [0.5, 1.0, 1.5, 2.0]) {
      expect(
        EasyTile.supportsShape(
          EasyTileType.outputSelect,
          EasyTileSize.single,
          h,
        ),
        isFalse,
      );
    }
    expect(
      EasyTile.supportsShape(
        EasyTileType.volumeDirect,
        EasyTileSize.single,
        0.5,
      ),
      isTrue,
    );
  });
}
