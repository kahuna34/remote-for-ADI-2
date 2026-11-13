import 'dart:convert';

import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/easy/easy_layout.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/easy_mode_editor.dart';
import 'package:adi2_remote/ui/easy_tile_grid.dart';
import 'package:adi2_remote/ui/outputs_page.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Controller extends Adi2Controller {
  @override
  final Adi2Variant variant = Adi2Variant.pro4ex;
  late final values = offlineDefaults(variant);
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
  Future<void> requestPresetNames() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = AppSettings.instance;
  late AppLanguage language;
  setUp(() async {
    language = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    SharedPreferences.setMockInitialValues({});
    await settings.load();
  });
  tearDown(() => AppLang.instance.language = language);

  for (final shared in [false, true]) {
    test(
      'v5 migrates every slot and output page once, shared=$shared',
      () async {
        Map<String, dynamic> page(int slot, int output) => {
          'version': 5,
          'defaultColor': 'blue',
          'showPlayer': false,
          'showStatus': false,
          'tiles': [
            {
              'type': 'setup',
              'size': 'third',
              'height': 0.5,
              'pinned': true,
              'x': 8,
              'y': 3,
              'color': 'rose',
              'label': 'Slot $slot / $output',
              'param': slot + 1,
            },
            {
              'type': 'volumeDirect',
              'size': 'single',
              'height': 1,
              'pinned': false,
              'x': 3,
              'y': 1,
              'output': output,
              'param': -42.5,
            },
          ],
        };
        for (final variant in Adi2Variant.values) {
          final oldLayouts = [
            for (var slot = 0; slot < 4; slot++)
              {
                ...page(slot, 3),
                'samePageForAllOutputs': shared,
                'outputPages': {
                  for (final output in [3, 6, 9]) '$output': page(slot, output),
                },
              },
          ];
          SharedPreferences.setMockInitialValues({
            'easy_slots_${variant.name}': jsonEncode({
              'version': 2,
              'active': 2,
              'slots': [
                for (var slot = 0; slot < 4; slot++)
                  {'name': 'Slot $slot', 'layout': oldLayouts[slot]},
              ],
            }),
          });
          await settings.load();
          final slots = settings.easySlots(variant);
          expect(slots.active, 2);
          expect(slots.names, ['Slot 0', 'Slot 1', 'Slot 2', 'Slot 3']);
          for (var slot = 0; slot < 4; slot++) {
            final migrated = slots.layouts[slot]!;
            expect(migrated.samePageForAllOutputs, shared);
            expect(migrated.outputPages.keys, [3, 6, 9]);
            for (final pair in [
              (oldLayouts[slot], migrated),
              for (final output in [3, 6, 9])
                (page(slot, output), migrated.outputPages[output]!),
            ]) {
              final expected = jsonDecode(jsonEncode(pair.$1)) as Map;
              expected['version'] = EasyLayout.version;
              expected.remove('outputPages');
              expected['samePageForAllOutputs'] = true;
              for (final tile in expected['tiles'] as List) {
                tile['x'] = (tile['x'] as int) * 5;
              }
              expect(pair.$2.asPage().toJson(), expected);
              expect(pair.$2.tiles.map((t) => t.widthUnits), [20, 15]);
              expect(pair.$2.positionsAdjusted, isFalse);
            }
          }
          final encoded = slots.encode();
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getString('easy_slots_${variant.name}'), encoded);
          await settings.load();
          expect(settings.easySlots(variant).encode(), encoded);
        }
      },
    );
  }

  test('Every legacy width and anchor scales by five in versions 2–5', () {
    const widths = {
      'single': 3,
      'third': 4,
      'wide': 6,
      'twoThirds': 8,
      'threeQuarters': 9,
      'full': 12,
    };
    for (final version in [2, 3, 4, 5]) {
      final layout = EasyLayout.decode(
        jsonEncode({
          'version': version,
          'tiles': [
            for (final entry in widths.entries.indexed)
              {
                'type': 'bass',
                'size': entry.$2.key,
                'height': 1.0,
                'pinned': true,
                'x': 12 - entry.$2.value,
                'y': entry.$1 * 2,
              },
          ],
        }),
        Adi2Variant.pro,
      );
      expect(
        layout.tiles.map((t) => t.widthUnits),
        widths.values.map((w) => w * 5),
      );
      if (version >= 3) {
        expect(layout.tiles.every((t) => t.pinned), isTrue);
        expect(
          layout.tiles.map((t) => t.x),
          widths.values.map((w) => (12 - w) * 5),
        );
        expect(layout.tiles.map((t) => t.y), [0, 2, 4, 6, 8, 10]);
      }
      expect(
        EasyLayout.decode(layout.encode(), Adi2Variant.pro).toJson(),
        layout.toJson(),
      );
    }
  });

  test('Fifth rules preserve usable controls for each tile type', () {
    for (final type in [
      EasyTileType.mute,
      EasyTileType.dim,
      EasyTileType.loudness,
      EasyTileType.crossfeed,
      EasyTileType.recall,
      EasyTileType.setup,
      EasyTileType.eqPreset,
      EasyTileType.sourceDirect,
      EasyTileType.toggleOutputs,
      EasyTileType.basicMode,
      EasyTileType.volumeDirect,
      EasyTileType.appPreset,
    ]) {
      expect(EasyTile.supportsShape(type, EasyTileSize.fifth, 0.5), isTrue);
    }
    for (final type in [EasyTileType.volumeUp, EasyTileType.volumeDown]) {
      expect(EasyTile.supportsShape(type, EasyTileSize.fifth, 0.5), isFalse);
      expect(EasyTile.supportsShape(type, EasyTileSize.fifth, 1), isTrue);
    }
    for (final type in [
      EasyTileType.volumeRing,
      EasyTileType.outputSelect,
      EasyTileType.bass,
      EasyTileType.treble,
      EasyTileType.balance,
      EasyTileType.refLevel,
      EasyTileType.source,
      EasyTileType.daFilter,
    ]) {
      for (final h in [0.5, 1.0, 1.5, 2.0]) {
        expect(EasyTile.supportsShape(type, EasyTileSize.fifth, h), isFalse);
      }
    }
  });

  test('Five fifths pack one row; complementary fractions fill a row', () {
    for (final height in [0.5, 1.0]) {
      final packed = packEasyTiles([
        for (var i = 0; i < 5; i++)
          EasyTile(
            type: EasyTileType.mute,
            size: EasyTileSize.fifth,
            height: height,
          ),
      ]);
      expect(packed.map((p) => (p.x, p.y, p.width)), [
        (0, 0, 12),
        (12, 0, 12),
        (24, 0, 12),
        (36, 0, 12),
        (48, 0, 12),
      ]);
    }
    for (final sizes in [
      [EasyTileSize.fifth, EasyTileSize.fourFifths],
      [EasyTileSize.twoFifths, EasyTileSize.threeFifths],
      [EasyTileSize.single, EasyTileSize.threeQuarters],
      [EasyTileSize.third, EasyTileSize.twoThirds],
    ]) {
      final packed = packEasyTiles([
        for (final size in sizes) EasyTile(type: EasyTileType.dim, size: size),
      ]);
      expect(packed.last.y, 0);
      expect(packed.last.x + packed.last.width, easyGridUnits);
    }
  });

  test('Snaps either edge to every fifth and respects pinned rectangles', () {
    final layout = EasyLayout(
      tiles: const [EasyTile(type: EasyTileType.dim, size: EasyTileSize.fifth)],
    );
    final quarter = EasyLayout(tiles: const [EasyTile(type: EasyTileType.dim)]);
    for (final edge in [12, 24, 36, 48]) {
      expect(layout.snapTarget(0, edge + 0.1, 2.1), (edge, 2));
      expect(
        quarter.snapTarget(0, edge - 15 + 0.1, 2.1),
        edge < 15 ? (0, 2) : (edge - 15, 2),
      );
    }
    final pinned = EasyLayout(
      tiles: const [
        EasyTile(type: EasyTileType.dim, size: EasyTileSize.fifth),
        EasyTile(
          type: EasyTileType.mute,
          size: EasyTileSize.fifth,
          pinned: true,
          x: 24,
          y: 0,
        ),
      ],
    );
    final moved = pinned.moveTile(0, 24, 0);
    expect((moved.tiles[1].x, moved.tiles[1].y), (24, 0));
    final packed = packEasyTiles(moved.tiles);
    expect(
      packed[0].x + packed[0].width <= 24 ||
          packed[0].x >= 36 ||
          packed[0].y >= 2,
      isTrue,
    );
  });

  for (final height in [0.5, 1.0]) {
    for (final editor in [false, true]) {
      testWidgets(
        'Five operating fifths fit 360dp, height=$height editor=$editor',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(360, 740);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final ctrl = _Controller();
          addTearDown(ctrl.dispose);
          final layout = EasyLayout(
            tiles: [
              for (final type in [
                EasyTileType.mute,
                EasyTileType.dim,
                EasyTileType.loudness,
                EasyTileType.crossfeed,
                EasyTileType.recall,
              ])
                EasyTile(type: type, size: EasyTileSize.fifth, height: height),
            ],
          );
          await settings.setEasyLayout(ctrl.variant, layout);
          await tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(),
              home: editor
                  ? EasyModeEditor(ctrl: ctrl)
                  : Scaffold(
                      body: OutputsPage(ctrl: ctrl, easyLayout: layout),
                    ),
            ),
          );
          await tester.pumpAndSettle();
          Rect? previous;
          for (var i = 0; i < 5; i++) {
            final tile = find.byKey(ValueKey('easy-tile-$i'));
            final bounds = tester.getRect(tile);
            expect(bounds.width, greaterThanOrEqualTo(44));
            expect(bounds.height, greaterThanOrEqualTo(44));
            expect(bounds.left, greaterThanOrEqualTo(0));
            expect(bounds.right, lessThanOrEqualTo(360));
            if (previous != null) {
              expect(bounds.top, previous.top);
              expect(bounds.left, greaterThan(previous.right));
            }
            expect(
              find.descendant(of: tile, matching: find.byType(Text)),
              findsNWidgets(2),
            );
            if (i == 2 || i == 3) {
              expect(
                find.descendant(
                  of: tile,
                  matching: find.text(i == 2 ? 'Loudness' : 'Crossfeed'),
                ),
                findsOneWidget,
              );
            }
            if (!editor && i < 4) await tester.tap(tile);
            previous = bounds;
          }
          if (!editor) expect(ctrl.writes, hasLength(4));
          expect(tester.takeException(), isNull);
          // Exercise live dragging at the new resolution in the same widget tree.
          if (editor) {
            final grid = tester.widget<EasyTileGrid>(find.byType(EasyTileGrid));
            expect(grid.onMove, isNotNull);
            final tile = find.byKey(const ValueKey('easy-drag-0'));
            final gesture = await tester.startGesture(tester.getCenter(tile));
            await tester.pump(const Duration(milliseconds: 600));
            await gesture.moveBy(
              Offset((tester.getSize(tile).width + 8) * 2, 0),
            );
            await tester.pump(const Duration(milliseconds: 200));
            expect(
              find.byKey(const ValueKey('easy-drop-position')),
              findsOneWidget,
            );
            await gesture.up();
            await tester.pumpAndSettle();
            expect(settings.easyLayout(ctrl.variant).tiles.first.x, 24);
            expect(tester.takeException(), isNull);
          }
        },
      );
    }
  }
}
