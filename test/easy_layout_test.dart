import 'dart:convert';

import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/easy/easy_layout.dart';
import 'package:adi2_remote/eq/eq_library.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'v2 migration preserves complete tiles and writes v6 without pinning',
    () async {
      final original = EasyLayout(
        defaultColor: EasyTileColor.rose,
        showPlayer: false,
        showStatus: false,
        tiles: [
          const EasyTile(
            type: EasyTileType.bass,
            size: EasyTileSize.single,
            height: 0.5,
            output: 9,
            label: 'Tief',
            color: EasyTileColor.blue,
          ),
          const EasyTile(
            type: EasyTileType.volumeDirect,
            param: -42.5,
            size: EasyTileSize.twoThirds,
            height: 1.5,
          ),
        ],
      );
      final v2 = original.toJson()..['version'] = 2;
      for (final tile in v2['tiles'] as List) {
        (tile as Map).remove('pinned');
      }
      SharedPreferences.setMockInitialValues({
        'easy_layout_pro': jsonEncode(v2),
      });
      final settings = AppSettings.instance;
      await settings.load();
      final migrated = settings.easyLayout(Adi2Variant.pro);
      expect(migrated.tiles.first.size, EasyTileSize.single);
      expect(migrated.tiles.first.height, 1);
      expect(migrated.tiles.first.label, 'Tief');
      expect(migrated.tiles.first.output, 9);
      expect(migrated.tiles.first.color, EasyTileColor.blue);
      expect(migrated.tiles.last.size, EasyTileSize.wide);
      expect(migrated.tiles.last.height, 1);
      expect(migrated.tiles.last.param, -42.5);
      expect(
        migrated.tiles.every((t) => !t.pinned && t.x == null && t.y == null),
        isTrue,
      );
      await settings.setEasyLayout(Adi2Variant.pro, migrated);
      expect(
        jsonDecode(
          (await SharedPreferences.getInstance()).getString('easy_slots_pro')!,
        )['slots'][0]['layout']['version'],
        EasyLayout.version,
      );
    },
  );

  test('Four slots migrate, persist names and active index independently per model', () async {
    final old = EasyLayout(
      showPlayer: false,
      tiles: const [
        EasyTile(type: EasyTileType.dim, color: EasyTileColor.rose),
      ],
    );
    SharedPreferences.setMockInitialValues({'easy_layout_dac': old.encode()});
    final settings = AppSettings.instance;
    await settings.load();
    expect(settings.easySlots(Adi2Variant.dac).active, 0);
    expect(
      settings.easySlots(Adi2Variant.dac).layouts.skip(1),
      everyElement(isNull),
    );
    expect(settings.easyLayout(Adi2Variant.dac).toJson(), old.toJson());
    final second = EasyLayout(
      showStatus: false,
      tiles: const [EasyTile(type: EasyTileType.mute)],
    );
    await settings.saveEasySlot(Adi2Variant.dac, 3, second, name: ' Nacht ');
    await settings.setEasyLayout(
      Adi2Variant.dac,
      second.copyWith(showPlayer: false),
    );
    await settings.load();
    expect(settings.easySlots(Adi2Variant.dac).active, 3);
    expect(settings.easySlots(Adi2Variant.dac).names[3], 'Nacht');
    expect(settings.easyLayout(Adi2Variant.dac).showPlayer, false);
    expect(settings.easySlots(Adi2Variant.pro).active, 0);
    await settings.activateEasySlot(Adi2Variant.dac, 0);
    expect(settings.easyLayout(Adi2Variant.dac).toJson(), old.toJson());
    await settings.clearEasySlot(Adi2Variant.dac, 0);
    await settings.clearEasySlot(Adi2Variant.dac, 3);
    await settings.load();
    expect(settings.easySlots(Adi2Variant.dac).layouts, everyElement(isNull));
    expect(settings.easySlots(Adi2Variant.dac).names, everyElement(isNull));
    expect(
      settings.easyLayout(Adi2Variant.dac).toJson(),
      EasyLayout.defaults(Adi2Variant.dac).toJson(),
    );
    // Editing a selected empty slot occupies just that slot.
    await settings.activateEasySlot(Adi2Variant.dac, 2);
    await settings.setEasyLayout(Adi2Variant.dac, second);
    await settings.load();
    expect(settings.easySlots(Adi2Variant.dac).active, 2);
    expect(settings.easySlots(Adi2Variant.dac).layouts[0], isNull);
    expect(settings.easyLayout(Adi2Variant.dac).toJson(), second.toJson());
    expect(
      () => settings.easySlots(Adi2Variant.dac).layouts.clear(),
      throwsUnsupportedError,
    );
  });

  test(
    'Main display settings persist independently of easy layout flags',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettings.instance;
      await settings.load();
      expect(settings.showPlayer, true);
      expect(settings.showStatus, true);
      await Future.wait([
        settings.setShowPlayer(false),
        settings.setShowStatus(false),
        settings.setEasyLayout(
          Adi2Variant.dac,
          EasyLayout.defaults(Adi2Variant.dac),
        ),
      ]);
      await settings.load();
      expect(settings.showPlayer, false);
      expect(settings.showStatus, false);
      expect(settings.easyLayout(Adi2Variant.dac).showPlayer, true);
      expect(settings.easyLayout(Adi2Variant.dac).showStatus, true);
    },
  );

  test(
    'Pins remain fixed through move, add, delete, resize and layout changes',
    () {
      const pin = EasyTile(
        type: EasyTileType.mute,
        pinned: true,
        x: 30,
        y: 2,
        size: EasyTileSize.wide,
        height: 1.5,
      );
      const small = EasyTile(type: EasyTileType.dim);
      final layouts = [
        [small, pin, small],
        [small, small, pin],
        [pin, small, small, small],
        [pin],
        [
          const EasyTile(
            type: EasyTileType.dim,
            size: EasyTileSize.full,
            height: 2,
          ),
          pin,
        ],
      ];
      for (final tiles in layouts) {
        final layout = EasyLayout(tiles: tiles).resolvePins();
        final packed = packEasyTiles(layout.tiles);
        final p = packed[tiles.indexOf(pin)];
        expect((p.x, p.y, p.width, p.height), (30, 2, 30, 3));
        final cells = <(int, int)>{};
        for (final pos in packed) {
          for (var y = pos.y; y < pos.y + pos.height; y++) {
            for (var x = pos.x; x < pos.x + pos.width; x++) {
              expect(cells.add((x, y)), isTrue);
            }
          }
        }
        expect(layout.positionsAdjusted, isFalse);
      }
      final packed = packEasyTiles([small, pin, small]);
      expect((packed[0].x, packed[0].y), (0, 0));
      expect((packed[2].x, packed[2].y), (15, 0));
    },
  );

  test(
    'Conflicting, out-of-bounds and missing anchors repair and round trip',
    () {
      final layout = EasyLayout(
        tiles: [
          const EasyTile(
            type: EasyTileType.mute,
            pinned: true,
            x: 30,
            y: 0,
            size: EasyTileSize.wide,
          ),
          const EasyTile(
            type: EasyTileType.dim,
            pinned: true,
            x: 30,
            y: 0,
            size: EasyTileSize.wide,
          ),
          const EasyTile(
            type: EasyTileType.lock,
            pinned: true,
            x: 55,
            y: 0,
            size: EasyTileSize.wide,
          ),
          const EasyTile(type: EasyTileType.bass, pinned: true),
          const EasyTile(
            type: EasyTileType.treble,
            pinned: true,
            x: -15,
            y: -4,
          ),
        ],
      ).resolvePins();
      expect(layout.positionsAdjusted, isTrue);
      expect(layout.tiles.map((t) => (t.x, t.y)), [
        (30, 0),
        (0, 1),
        (30, 2),
        (0, 3),
        (15, 3),
      ]);
      final loaded = EasyLayout.decode(layout.encode(), Adi2Variant.pro);
      expect(loaded.toJson(), layout.toJson());
      expect(loaded.positionsAdjusted, isFalse);
      final broken = layout.toJson();
      (broken['tiles'] as List)[1]['x'] = 30;
      (broken['tiles'] as List)[1]['y'] = 0;
      expect(
        EasyLayout.decode(
          jsonEncode(broken),
          Adi2Variant.pro,
        ).positionsAdjusted,
        isTrue,
      );
    },
  );

  test('v2 and v3 ignore obsolete columns and retain customized layouts', () {
    for (final version in [2, 3]) {
      for (final columns in [2, 3, 4, 99, 'invalid', null]) {
        final stored = {
          'version': version,
          'columns': columns,
          'showPlayer': false,
          'tiles': [
            {
              'type': 'dim',
              'size': 'third',
              'height': 1.5,
              'label': 'Mein Layout',
              'color': 'rose',
              'pinned': version == 3,
              'x': 4,
              'y': 3,
            },
          ],
        };
        final decoded = EasyLayout.decode(jsonEncode(stored), Adi2Variant.dac);
        expect(decoded.tiles, hasLength(1));
        expect(decoded.tiles.single.label, 'Mein Layout');
        expect(decoded.tiles.single.widthUnits, 20);
        expect(decoded.tiles.single.height, 1);
        expect(decoded.showPlayer, isFalse);
        expect(decoded.toJson().containsKey('columns'), isFalse);
        expect(decoded.toJson()['version'], EasyLayout.version);
        if (version == 3) {
          expect((decoded.tiles.single.x, decoded.tiles.single.y), (20, 3));
        }
      }
    }
  });

  test(
    'Snaps both edges, half rows and avoids fixed tiles without moving them',
    () {
      final layout = EasyLayout(
        tiles: [
          const EasyTile(type: EasyTileType.dim),
          const EasyTile(
            type: EasyTileType.mute,
            size: EasyTileSize.wide,
            pinned: true,
            x: 30,
            y: 0,
          ),
        ],
      );
      expect(layout.snapTarget(0, 18.5, 4.3), (20, 4));
      expect(layout.snapTarget(0, 25.2, 4.7), (25, 5)); // right edge at 2/3
      final moved = layout.moveTile(0, 30, 0);
      expect((moved.tiles[1].x, moved.tiles[1].y), (30, 0));
      expect((moved.tiles[0].x, moved.tiles[0].y), (15, 0));
      expect(moved.tiles[0].pinned, isFalse);
      expect(
        EasyLayout.decode(moved.encode(), Adi2Variant.dac).toJson(),
        moved.toJson(),
      );
    },
  );

  test('Stepper size offers exclude unusable small shapes', () {
    for (final type in EasyTileType.values.where(EasyTile.isStepper)) {
      expect(EasyTile.supportsShape(type, EasyTileSize.single, 0.5), isFalse);
      expect(EasyTile.supportsShape(type, EasyTileSize.single, 1), isTrue);
      expect(EasyTile.supportsShape(type, EasyTileSize.single, 1.5), isTrue);
      expect(EasyTile.supportsShape(type, EasyTileSize.wide, 0.5), isTrue);
    }
  });

  test(
    'JSON round trip with sizes, outputs, labels and app preset snapshot',
    () {
      final layout = EasyLayout(
        showPlayer: false,
        showStatus: false,
        tiles: [
          const EasyTile(
            type: EasyTileType.setup,
            size: EasyTileSize.wide,
            param: 9,
            label: 'Abend',
          ),
          const EasyTile(type: EasyTileType.eqPreset, output: 9, param: 20),
          const EasyTile(
            type: EasyTileType.volumeDirect,
            output: 3,
            param: -42.5,
          ),
          EasyTile(
            type: EasyTileType.appPreset,
            param: AppEqPreset(
              name: 'Test',
              dual: true,
              left: {4: -2},
              right: {4: 3},
            ).toJson(),
          ),
        ],
      );
      final decoded = EasyLayout.decode(layout.encode(), Adi2Variant.pro);
      expect(decoded.toJson(), layout.toJson());
      expect(decoded.toJson()['version'], EasyLayout.version);
      expect(() => decoded.tiles.clear(), throwsUnsupportedError);
    },
  );

  for (final columns in [2, 3]) {
    test(
      'Migrates v1 widths, parameters and display flags ($columns columns)',
      () {
        final migrated = EasyLayout.decode(
          jsonEncode({
            'version': 1,
            'columns': columns,
            'showPlayer': false,
            'showStatus': false,
            'tiles': [
              {'type': 'mute', 'size': 'single', 'output': 3, 'label': 'Ruhe'},
              {'type': 'eqPreset', 'size': 'wide', 'param': 4},
              {'type': 'volumeRing', 'size': 'single'},
              {'type': 'setup', 'size': 'full', 'param': 9},
            ],
          }),
          Adi2Variant.pro,
        );
        expect(migrated.showPlayer, isFalse);
        expect(migrated.showStatus, isFalse);
        expect(migrated.defaultColor, EasyTileColor.graphite);
        expect(migrated.tiles.map((t) => t.widthUnits), [
          60 ~/ columns,
          30,
          30,
          30,
        ]);
        expect(migrated.tiles.map((t) => t.heightUnits), [1.0, 1.0, 2, 1.0]);
        expect(migrated.tiles.first.output, 3);
        expect(migrated.tiles.first.label, 'Ruhe');
        expect(migrated.tiles[1].param, 4);
        expect(migrated.tiles.last.param, 9);
        expect(migrated.toJson()['version'], EasyLayout.version);
        expect(
          EasyLayout.decode(migrated.encode(), Adi2Variant.pro).toJson(),
          migrated.toJson(),
        );
      },
    );
  }

  test(
    'v2 round trip includes every valid width, height and palette color',
    () {
      final layout = EasyLayout(
        defaultColor: EasyTileColor.petrol,
        tiles: [
          for (final size in EasyTileSize.values)
            for (final height in [0.5, 1.0, 1.5, 2.0])
              for (final color in [null, ...EasyTileColor.values])
                if (EasyTile.supportsShape(EasyTileType.dim, size, height))
                  EasyTile(
                    type: EasyTileType.dim,
                    size: size,
                    height: height,
                    color: color,
                  ),
        ],
      );
      expect(
        EasyLayout.decode(layout.encode(), Adi2Variant.dac).toJson(),
        layout.toJson(),
      );
    },
  );

  test('v2 skips malformed dimensions/colors and normalizes ring minimum', () {
    final layout = EasyLayout.decode(
      jsonEncode({
        'version': 2,
        'columns': 4,
        'defaultColor': 'future',
        'tiles': [
          for (final height in [0, -1, 0.7, 3, '1', null])
            {'type': 'mute', 'size': 'single', 'height': height},
          {'type': 'mute', 'size': 'single', 'height': 1, 'color': 'future'},
          {'type': 'volumeRing', 'size': 'single', 'height': 0.5},
          {'type': 'mute', 'size': 'third', 'height': 0.5, 'color': 'blue'},
        ],
      }),
      Adi2Variant.dac,
    );
    expect(layout.defaultColor, EasyTileColor.graphite);
    expect(layout.tiles, hasLength(2));
    expect(layout.tiles.first.widthUnits, 30);
    expect(layout.tiles.first.heightUnits, 2);
    expect(layout.tiles.last.height, 0.5);
    expect(layout.tiles.last.color, EasyTileColor.blue);
    expect(EasyTile.heightsFor(EasyTileType.volumeRing), [2]);
  });

  test('Volume ring height follows its width and survives saving', () {
    EasyTile ring(EasyTileSize size) =>
        EasyTile(type: EasyTileType.volumeRing, size: size, height: 2);
    expect(ring(EasyTileSize.wide).heightUnits, 2);
    expect(ring(EasyTileSize.threeFifths).heightUnits, 2.5);
    expect(ring(EasyTileSize.twoThirds).heightUnits, 2.5);
    expect(ring(EasyTileSize.threeQuarters).heightUnits, 3);
    expect(ring(EasyTileSize.fourFifths).heightUnits, 3);
    expect(ring(EasyTileSize.full).heightUnits, 4);

    final placed = packEasyTiles([ring(EasyTileSize.full)]).single;
    expect(placed.width, 60);
    expect(placed.height, 8);

    final decoded = EasyLayout.decode(
      EasyLayout(tiles: [ring(EasyTileSize.full)]).encode(),
      Adi2Variant.pro,
    );
    expect(decoded.tiles.single.size, EasyTileSize.full);
    expect(decoded.tiles.single.heightUnits, 4);
  });

  test('60-unit first-fit packing fills holes and stacks half heights', () {
    final tiles = [
      const EasyTile(
        type: EasyTileType.mute,
        size: EasyTileSize.threeQuarters,
        height: 2,
      ),
      const EasyTile(type: EasyTileType.dim, size: EasyTileSize.wide),
      const EasyTile(type: EasyTileType.volumeUp, height: 0.5),
      const EasyTile(type: EasyTileType.volumeDown, height: 0.5),
    ];
    final packed = packEasyTiles(tiles);
    expect(packed.map((p) => (p.x, p.y, p.width, p.height)), [
      (0, 0, 45, 4),
      (0, 4, 30, 2),
      (45, 0, 15, 1),
      (45, 1, 15, 1),
    ]);
    expect(packEasyTiles([]), isEmpty);
  });

  test(
    'Mixed packing never overlaps or leaves a fitting earlier slot empty',
    () {
      final tiles = [
        for (var i = 0; i < 120; i++)
          EasyTile(
            type: EasyTileType.mute,
            size: EasyTileSize
                .values[(i * 7 + i ~/ 5) % EasyTileSize.values.length],
            height: [0.5, 1.0, 1.5, 2.0][i % 4],
          ),
      ];
      final occupied = <(int, int)>{};
      for (final p in packEasyTiles(tiles)) {
        expect(p.x, greaterThanOrEqualTo(0));
        expect(p.x + p.width, lessThanOrEqualTo(easyGridUnits));
        for (var y = 0; y <= p.y; y++) {
          for (var x = 0; x <= easyGridUnits - p.width; x++) {
            if (y == p.y && x >= p.x) break;
            expect(
              [
                for (var yy = y; yy < y + p.height; yy++)
                  for (var xx = x; xx < x + p.width; xx++)
                    occupied.contains((xx, yy)),
              ],
              contains(true),
              reason: 'Earlier slot $x/$y fits tile ${p.index}',
            );
          }
        }
        for (var y = p.y; y < p.y + p.height; y++) {
          for (var x = p.x; x < p.x + p.width; x++) {
            expect(occupied.add((x, y)), isTrue, reason: 'Overlap at $x/$y');
          }
        }
      }
    },
  );

  test(
    'Stored v1 settings load per model and save back as v6 without remigrating',
    () async {
      String legacy(int columns) => jsonEncode({
        'version': 1,
        'columns': columns,
        'tiles': [
          {'type': 'mute', 'size': 'single', 'label': 'Alt'},
        ],
      });
      SharedPreferences.setMockInitialValues({
        'easy_layout_dac': legacy(3),
        'easy_layout_pro': legacy(2),
      });
      final settings = AppSettings.instance;
      await settings.load();
      final migrated = settings.easyLayout(Adi2Variant.dac);
      expect(migrated.tiles.single.widthUnits, 20);
      expect(settings.easyLayout(Adi2Variant.pro).tiles.single.widthUnits, 30);
      await settings.setEasyLayout(Adi2Variant.dac, migrated);
      final stored = (await SharedPreferences.getInstance()).getString(
        'easy_slots_dac',
      )!;
      expect(
        jsonDecode(stored)['slots'][0]['layout']['version'],
        EasyLayout.version,
      );
      await settings.load();
      expect(settings.easyLayout(Adi2Variant.dac).toJson(), migrated.toJson());
    },
  );

  test('Invalid entries are individually skipped and later tiles survive', () {
    final invalid = [
      null,
      3,
      'tile',
      {},
      {'type': 'future', 'size': 'single'},
      {'type': 'mute', 'size': 'huge'},
      {'type': 'mute', 'size': 'single', 'output': '3'},
      {'type': 'mute', 'size': 'single', 'output': 0},
      {'type': 'mute', 'size': 'single', 'label': 7},
      {'type': 'mute', 'size': 'single', 'param': 1},
      for (final n in [0, 10, '1', 1.5])
        {'type': 'setup', 'size': 'single', 'param': n},
      for (final n in [0, 21, null])
        {'type': 'eqPreset', 'size': 'single', 'param': n},
      {'type': 'sourceDirect', 'size': 'single', 'param': 6},
      {'type': 'volumeDirect', 'size': 'single', 'param': 6.5},
      {'type': 'volumeDirect', 'size': 'single', 'param': -115},
      {'type': 'volumeDirect', 'size': 'single', 'param': 'NaN'},
      {'type': 'basicMode', 'size': 'single', 'param': 2},
      {
        'type': 'appPreset',
        'size': 'single',
        'param': {'type': 'bad'},
      },
      {
        'type': 'appPreset',
        'size': 'single',
        'param': {
          'type': 'adi2-eq-preset',
          'name': 4,
          'l': {'4': 0},
        },
      },
    ];
    final layout = EasyLayout.decode(
      jsonEncode({
        'version': 1,
        'columns': 99,
        'showPlayer': 0,
        'showStatus': 'no',
        'tiles': [
          ...invalid,
          {'type': 'mute', 'size': 'full', 'label': '  Test  '},
        ],
      }),
      Adi2Variant.dac,
    );
    expect(layout.tiles, hasLength(1));
    expect(layout.tiles.single.label, 'Test');
    expect(layout.showPlayer, isTrue);
    expect(layout.showStatus, isTrue);
    expect(
      EasyTile.fromJson({
        'type': 'volumeDirect',
        'size': 'single',
        'param': double.nan,
      }, Adi2Variant.pro),
      isNull,
    );
    expect(
      EasyTile.fromJson({
        'type': 'volumeDirect',
        'size': 'single',
        'param': double.infinity,
      }, Adi2Variant.pro),
      isNull,
    );
  });

  for (final variant in Adi2Variant.values) {
    test('Defaults are valid for ${variant.name}', () {
      final layout = EasyLayout.defaults(variant);
      expect(layout.tiles.map((t) => t.type), [
        EasyTileType.outputSelect,
        EasyTileType.volumeRing,
        EasyTileType.lock,
        EasyTileType.volumeDown,
        EasyTileType.volumeUp,
        EasyTileType.link,
        EasyTileType.mute,
        EasyTileType.dim,
        EasyTileType.loudness,
        EasyTileType.crossfeed,
        EasyTileType.recall,
        EasyTileType.bass,
        EasyTileType.treble,
      ]);
      expect(
        packEasyTiles(layout.tiles).map((p) => (p.x, p.y, p.width, p.height)),
        [
          (0, 0, 60, 1),
          (15, 1, 30, 4),
          (0, 5, 15, 2),
          (15, 5, 15, 2),
          (30, 5, 15, 2),
          (45, 5, 15, 2),
          (0, 7, 12, 2),
          (12, 7, 12, 2),
          (24, 7, 12, 2),
          (36, 7, 12, 2),
          (48, 7, 12, 2),
          (0, 1, 15, 4),
          (45, 1, 15, 4),
        ],
      );
      final placements = packEasyTiles(layout.tiles);
      for (final a in placements) {
        expect(
          EasyTile.supportsShape(
            layout.tiles[a.index].type,
            layout.tiles[a.index].size,
            layout.tiles[a.index].height,
          ),
          isTrue,
        );
        for (final b in placements.where((b) => b.index > a.index)) {
          expect(
            a.x < b.x + b.width &&
                a.x + a.width > b.x &&
                a.y < b.y + b.height &&
                a.y + a.height > b.y,
            isFalse,
          );
        }
      }
      expect(layout.tiles[1].pinned, isTrue);
      expect(
        EasyLayout.decode(layout.encode(), variant).toJson(),
        layout.toJson(),
      );
      for (final invalid in [
        'no JSON',
        '[]',
        '{"version":99,"tiles":[]}',
        '{"version":1,"tiles":{}}',
      ]) {
        expect(EasyLayout.decode(invalid, variant).toJson(), layout.toJson());
      }
    });
  }

  test('Source and Basic Mode validation follows the model', () {
    const source = EasyTile(type: EasyTileType.sourceDirect, param: 6);
    expect(EasyTile.fromJson(source.toJson(), Adi2Variant.pro4ex), isNotNull);
    expect(EasyTile.fromJson(source.toJson(), Adi2Variant.pro4se), isNull);
    expect(
      EasyTile.fromJson(
        const EasyTile(type: EasyTileType.basicMode, param: 5).toJson(),
        Adi2Variant.pro,
      ),
      isNotNull,
    );
  });

  test(
    'Settings persist per variant and serialize rapid writes in order',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettings.instance;
      await settings.load();
      final first = EasyLayout(showStatus: false, tiles: []);
      final second = EasyLayout(
        showPlayer: false,
        tiles: [const EasyTile(type: EasyTileType.dim)],
      );
      final writes = [
        settings.setEasyMode(true),
        settings.setEasyLayout(Adi2Variant.dac, first),
        settings.setEasyLayout(Adi2Variant.pro, first),
        settings.setEasyLayout(Adi2Variant.dac, second),
      ];
      await Future.wait(writes);
      await settings.load();
      expect(settings.easyMode, isTrue);
      expect(settings.easyLayout(Adi2Variant.dac).toJson(), second.toJson());
      expect(settings.easyLayout(Adi2Variant.pro).toJson(), first.toJson());
      expect(
        settings.easyLayout(Adi2Variant.pro4se).toJson(),
        EasyLayout.defaults(Adi2Variant.pro4se).toJson(),
      );
      await settings.setEasyMode(false);
    },
  );
}
