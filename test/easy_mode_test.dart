import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/easy/easy_layout.dart';
import 'package:adi2_remote/eq/eq_library.dart';
import 'package:adi2_remote/eq/eq_model.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/app_settings_page.dart';
import 'package:adi2_remote/ui/easy_mode_editor.dart';
import 'package:adi2_remote/ui/eq_page.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/outputs_page.dart';
import 'package:adi2_remote/ui/player_bar.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:adi2_remote/ui/volume_ring.dart';
import 'package:adi2_remote/ui/easy_size_picker.dart';
import 'package:adi2_remote/ui/easy_tile_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Controller extends Adi2Controller {
  _Controller(this.variant) : values = offlineDefaults(variant) {
    state = ConnState.connected;
    selectedOutput = Adi2Addr.ph34;
    names[0x21] = 'Geräte-Setup';
    names[1] = 'Geräte-EQ';
  }
  @override
  final Adi2Variant variant;
  final Map<int, int> values;
  final writes = <(int, int, int)>[];
  final eqWrites = <(int, int, int)>[];
  final volumes = <(int, int)>[];
  final setups = <int>[];
  int toggles = 0;
  bool guarded = false;
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
  void setEq(int address, int index, int raw) {
    eqWrites.add((address, index, raw));
    super.setEq(address, index, raw);
  }

  @override
  void setVolume(int address, int raw, {bool followLink = true}) {
    volumes.add((address, raw));
    if (guarded) super.setVolume(address, raw, followLink: followLink);
  }

  @override
  void loadSetup(int n) => setups.add(n);
  @override
  void toggleOutputs() => toggles++;
  @override
  Future<void> requestPresetNames() async {}
}

void main() {
  late _Controller ctrl;
  late NowPlaying np;
  late AppLanguage previous;
  final settings = AppSettings.instance;

  setUp(() async {
    previous = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    SharedPreferences.setMockInitialValues({});
    await settings.load();
    ctrl = _Controller(Adi2Variant.pro4ex);
    np = NowPlaying();
  });
  tearDown(() {
    ctrl.dispose();
    np.dispose();
    AppLang.instance.language = previous;
  });

  Future<void> show(
    WidgetTester tester,
    Widget page, {
    Size size = const Size(360, 740),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: page));
    await tester.pumpAndSettle();
  }

  for (final language in AppLanguage.values) {
    testWidgets(
      'Eigene Balance-Kachel zeigt Mitte und ganze Schritte $language',
      (tester) async {
        AppLang.instance.language = language;
        await show(
          tester,
          Scaffold(
            body: OutputsPage(
              ctrl: ctrl,
              easyLayout: EasyLayout(
                tiles: [
                  EasyTile(type: EasyTileType.balance, size: EasyTileSize.full),
                ],
              ),
            ),
          ),
        );
        expect(
          find.text(language == AppLanguage.de ? 'Mitte' : 'Center'),
          findsOneWidget,
        );
        for (final (raw, label) in [
          (-35, 'L 35'),
          (100, 'R 100'),
          (-100, 'L 100'),
        ]) {
          ctrl.set(Adi2Addr.ph34, OutIdx.balance, raw);
          await tester.pump();
          expect(find.text(label), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  Future<void> tapTile(WidgetTester tester, int index) async {
    final tile = find.byKey(ValueKey('easy-tile-$index'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  for (final editor in [false, true]) {
    for (final shape in [
      (EasyTileSize.single, 0.5),
      (EasyTileSize.single, 1.0),
      (EasyTileSize.wide, 0.5),
      (EasyTileSize.wide, 1.0),
    ]) {
      for (final label in ['Dim', 'Eine sehr lange Kachelbeschriftung']) {
        testWidgets('Tile content centered editor=$editor $shape $label', (
          tester,
        ) async {
          final layout = EasyLayout(
            tiles: [
              EasyTile(
                type: EasyTileType.dim,
                label: label,
                size: shape.$1,
                height: shape.$2,
              ),
            ],
          );
          await settings.setEasyLayout(ctrl.variant, layout);
          await show(
            tester,
            editor
                ? EasyModeEditor(ctrl: ctrl)
                : Scaffold(
                    body: OutputsPage(ctrl: ctrl, easyLayout: layout),
                  ),
          );
          final tile = find.byKey(const ValueKey('easy-tile-0'));
          await tester.ensureVisible(tile);
          await tester.pumpAndSettle();
          final symbol = find.descendant(
            of: tile,
            matching: find.byIcon(Icons.brightness_low_outlined),
          );
          expect(symbol, findsOneWidget);
          var content = tester.getRect(symbol);
          // Measure rendered content, including the optional output value,
          // rather than a full-size alignment container.
          final texts = find.descendant(of: tile, matching: find.byType(Text));
          for (var i = 0; i < texts.evaluate().length; i++) {
            content = content.expandToInclude(tester.getRect(texts.at(i)));
          }
          final bounds = tester.getRect(tile);
          expect(content.center.dx, closeTo(bounds.center.dx, 2));
          expect(content.center.dy, closeTo(bounds.center.dy, 2));
          expect(bounds.contains(content.topLeft), isTrue);
          expect(bounds.contains(content.bottomRight), isTrue);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets(
    'Dragging between guides previews and saves the nearest snap with haptics',
    (tester) async {
      await settings.setEasyLayout(
        ctrl.variant,
        EasyLayout(
          tiles: [
            const EasyTile(type: EasyTileType.dim),
            const EasyTile(type: EasyTileType.mute, pinned: true, x: 45, y: 0),
          ],
        ),
      );
      final haptics = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await show(tester, EasyModeEditor(ctrl: ctrl));
      final tile = find.byKey(const ValueKey('easy-tile-0'));
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      final origin = tester.getTopLeft(tile);
      final pitch = (tester.getSize(tile).width + 8) / 3;
      final start = tester.getCenter(tile);
      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(start + Offset(pitch * 3.65, pitch * 1.5 * 0.7));
      await tester.pump(const Duration(milliseconds: 200));
      final marker = find.byKey(const ValueKey('easy-drop-position'));
      expect(
        tester.getTopLeft(marker),
        origin + Offset(4 * pitch, 1.5 * pitch),
      );
      expect(find.byKey(const ValueKey('easy-snap-guides')), findsOneWidget);
      expect(haptics, contains('HapticFeedbackType.selectionClick'));
      final clicks = haptics.length;
      await gesture.moveBy(const Offset(0.1, 0.1));
      await tester.pump();
      expect(haptics.length, clicks);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('easy-drop-position')), findsNothing);
      final tiles = settings.easyLayout(ctrl.variant).tiles;
      expect((tiles[0].x, tiles[0].y, tiles[0].pinned), (20, 1, false));
      expect((tiles[1].x, tiles[1].y, tiles[1].pinned), (45, 0, true));
      await settings.load();
      expect(
        (
          settings.easyLayout(ctrl.variant).tiles[0].x,
          settings.easyLayout(ctrl.variant).tiles[0].y,
        ),
        (20, 1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final variant in Adi2Variant.values) {
    testWidgets('Reduced default controls and reset work for ${variant.name}', (
      tester,
    ) async {
      final model = _Controller(variant);
      addTearDown(model.dispose);
      model.names[0x24] = 'Nacht';
      final layout = settings.easyLayout(variant);
      await show(
        tester,
        Scaffold(
          body: OutputsPage(ctrl: model, easyLayout: layout),
        ),
      );
      final selector = find.byKey(const ValueKey('easy-tile-0'));
      for (final output in outputsFor(variant)) {
        expect(
          find.descendant(of: selector, matching: find.text(output.name)),
          findsOneWidget,
        );
      }
      final ring = find.byKey(const ValueKey('easy-tile-1'));
      final ringSize = tester.getSize(ring);
      expect(ringSize.width, closeTo(ringSize.height, 0.01));
      expect(tester.getCenter(ring).dx, closeTo(180, 0.01));
      await tester.tap(find.byKey(const ValueKey('easy-segment-0-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('easy-tile-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('easy-tile-4')));
      await tester.pumpAndSettle();
      final volume = model.valueOr(3, OutIdx.volume, -1145);
      expect(model.volumes, [(3, volume - 5), (3, volume + 5)]);
      for (final n in [6, 7, 8, 9, 10]) {
        await tester.ensureVisible(find.byKey(ValueKey('easy-tile-$n')));
        await tester.tap(find.byKey(ValueKey('easy-tile-$n')));
        await tester.pumpAndSettle();
      }
      expect(model.setups, isEmpty);
      expect(model.value(3, OutIdx.mute), 1);
      expect(model.value(3, OutIdx.dim), 1);
      await settings.setEasyLayout(
        variant,
        EasyLayout(
          tiles: [const EasyTile(type: EasyTileType.dim, label: 'Individuell')],
        ),
      );
      await show(tester, EasyModeEditor(ctrl: model));
      final reset = find.byKey(const ValueKey('easy-reset'));
      await tester.scrollUntilVisible(
        reset,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(settings.easyLayout(variant).tiles.single.label, 'Individuell');
      await tester.tap(find.byKey(const ValueKey('easy-confirm')));
      await tester.pumpAndSettle();
      expect(
        settings.easyLayout(variant).toJson(),
        EasyLayout.defaults(variant).toJson(),
      );
      await settings.load();
      expect(
        settings.easyLayout(variant).toJson(),
        EasyLayout.defaults(variant).toJson(),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Pin toggles, persists its grid anchor and stays out of panel', (
    tester,
  ) async {
    await settings.setEasyLayout(
      ctrl.variant,
      EasyLayout(
        tiles: [
          const EasyTile(type: EasyTileType.mute),
          const EasyTile(type: EasyTileType.dim),
        ],
      ),
    );
    await show(tester, EasyModeEditor(ctrl: ctrl));
    final pin = find.byKey(const ValueKey('easy-pin-1'));
    await tester.ensureVisible(pin);
    await tester.tap(pin);
    await tester.pumpAndSettle();
    var tile = settings.easyLayout(ctrl.variant).tiles[1];
    expect((tile.pinned, tile.x, tile.y), (true, 15, 0));
    expect(tester.widget<IconButton>(pin).isSelected, isTrue);
    await settings.load();
    await tester.pumpAndSettle();
    tile = settings.easyLayout(ctrl.variant).tiles[1];
    expect((tile.pinned, tile.x, tile.y), (true, 15, 0));
    await tester.tap(pin);
    await tester.pumpAndSettle();
    expect(settings.easyLayout(ctrl.variant).tiles[1].pinned, isFalse);
    await show(
      tester,
      Scaffold(
        body: OutputsPage(
          ctrl: ctrl,
          easyLayout: settings.easyLayout(ctrl.variant),
        ),
      ),
    );
    expect(find.byIcon(Icons.push_pin), findsNothing);
    expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
    expect(ctrl.writes, isEmpty);
  });

  testWidgets('Pinned drag adopts a new grid anchor and remains pinned', (
    tester,
  ) async {
    await settings.setEasyLayout(
      ctrl.variant,
      EasyLayout(
        tiles: [
          const EasyTile(type: EasyTileType.mute, pinned: true, x: 0, y: 0),
          const EasyTile(type: EasyTileType.dim, pinned: true, x: 30, y: 0),
        ],
      ),
    );
    await show(tester, EasyModeEditor(ctrl: ctrl));
    final tile = find.byKey(const ValueKey('easy-tile-0'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    final origin = tester.getCenter(tile);
    final width = tester.getSize(tile).width + 8;
    final gesture = await tester.startGesture(origin);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(origin + Offset(width, 0));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();
    final tiles = settings.easyLayout(ctrl.variant).tiles;
    expect((tiles[0].pinned, tiles[0].x, tiles[0].y), (true, 15, 0));
    expect((tiles[1].x, tiles[1].y), (30, 0));
    await settings.load();
    expect(settings.easyLayout(ctrl.variant).tiles[0].x, 15);
    await tester.pumpAndSettle();
    final collision = await tester.startGesture(tester.getCenter(tile));
    await tester.pump(const Duration(milliseconds: 600));
    await collision.moveTo(tester.getCenter(tile) + Offset(width, 0));
    await tester.pump(const Duration(milliseconds: 200));
    await collision.up();
    await tester.pumpAndSettle();
    final repaired = settings.easyLayout(ctrl.variant).tiles;
    expect((repaired[0].pinned, repaired[0].x, repaired[0].y), (true, 15, 0));
    expect((repaired[1].x, repaired[1].y), (30, 0));
    expect(find.byKey(const ValueKey('easy-position-warning')), findsNothing);
    final abort = await tester.startGesture(tester.getCenter(tile));
    await tester.pump(const Duration(milliseconds: 600));
    await abort.moveTo(const Offset(-100, -100));
    await abort.up();
    await tester.pumpAndSettle();
    expect(settings.easyLayout(ctrl.variant).tiles[0].x, 15);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Editor explains repaired pins and preserves anchors on edits', (
    tester,
  ) async {
    await settings.setEasyLayout(
      ctrl.variant,
      EasyLayout(
        tiles: [
          const EasyTile(type: EasyTileType.mute, pinned: true, x: 45, y: 0),
        ],
      ),
    );
    await show(tester, EasyModeEditor(ctrl: ctrl));
    final edit = find.byKey(const ValueKey('easy-edit-0'));
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    final size = find.byKey(const ValueKey('easy-size-wide-1.0'));
    await tester.ensureVisible(size);
    await tester.tap(size);
    await tester.tap(find.byKey(const ValueKey('easy-save-tile')));
    await tester.pumpAndSettle();
    final tile = settings.easyLayout(ctrl.variant).tiles.single;
    expect((tile.pinned, tile.x, tile.y), (true, 0, 1));
    expect(find.byKey(const ValueKey('easy-position-warning')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final screen in [const Size(411, 914), const Size(360, 740)]) {
    testWidgets(
      'Stepper and selection forms have logical axes, no overflow at $screen',
      (tester) async {
        for (final type in [
          EasyTileType.bass,
          EasyTileType.treble,
          EasyTileType.balance,
          EasyTileType.volumeUp,
          EasyTileType.volumeDown,
          EasyTileType.refLevel,
          EasyTileType.source,
          EasyTileType.outputSelect,
          EasyTileType.daFilter,
        ]) {
          for (final shape in [
            (EasyTileSize.wide, 1.0, false),
            (EasyTileSize.single, 2.0, true),
            (EasyTileSize.single, 1.0, false),
            (EasyTileSize.wide, 0.5, false),
          ]) {
            await show(
              tester,
              Scaffold(
                body: OutputsPage(
                  key: UniqueKey(),
                  ctrl: ctrl,
                  easyLayout: EasyLayout(
                    tiles: [
                      EasyTile(
                        type: type,
                        size: shape.$1,
                        height: shape.$2,
                        param: type == EasyTileType.volumeDirect ? -30.0 : null,
                      ),
                    ],
                  ),
                ),
              ),
              size: screen,
            );
            if (type == EasyTileType.refLevel) {
              expect(find.text('Ref Level'), findsOneWidget);
              expect(
                find.byKey(const ValueKey('easy-step-0-plus')),
                findsNothing,
              );
              expect(tester.takeException(), isNull);
              continue;
            }
            final isStep = EasyTile.isStepper(type);
            if ({
                  EasyTileType.volumeDown,
                  EasyTileType.volumeUp,
                }.contains(type) &&
                shape.$1 == EasyTileSize.single &&
                shape.$2 == 1) {
              expect(find.byKey(const ValueKey('easy-tile-0')), findsOneWidget);
              expect(
                find.byKey(const ValueKey('easy-step-0-horizontal')),
                findsNothing,
              );
              expect(tester.takeException(), isNull);
              continue;
            }
            final vertical = type == EasyTileType.balance
                ? false
                : {EasyTileType.bass, EasyTileType.treble}.contains(type)
                ? shape.$2 >= 1
                : shape.$3;
            final axis = vertical ? 'vertical' : 'horizontal';
            expect(
              find.byKey(
                ValueKey('easy-${isStep ? 'step' : 'segments'}-0-$axis'),
              ),
              findsOneWidget,
            );
            if (isStep) {
              final plus = tester.getCenter(
                find.byKey(const ValueKey('easy-step-0-plus')),
              );
              final minus = tester.getCenter(
                find.byKey(const ValueKey('easy-step-0-minus')),
              );
              final value = tester.getCenter(
                find.byKey(const ValueKey('easy-step-0-value')),
              );
              if (vertical) {
                expect(plus.dy, lessThan(value.dy));
                expect(minus.dy, greaterThan(value.dy));
              } else {
                expect(minus.dx, lessThan(value.dx));
                expect(plus.dx, greaterThan(value.dx));
              }
              if (shape.$2 != 0.5 && shape.$1 != EasyTileSize.single) {
                expect(
                  tester
                      .getSize(find.byKey(const ValueKey('easy-step-0-plus')))
                      .width,
                  greaterThanOrEqualTo(44),
                );
              }
            }
            expect(
              tester.takeException(),
              isNull,
              reason: '${type.name} $shape at $screen',
            );
          }
        }
      },
    );
  }

  for (final tall in [true, false]) {
    testWidgets(
      'Stepper buttons and text grow along ${tall ? 'height' : 'width'}',
      (tester) async {
        for (final type in EasyTileType.values.where(EasyTile.isStepper)) {
          double? previousExtent;
          double? previousFont;
          for (final large in [false, true]) {
            await show(
              tester,
              Scaffold(
                body: OutputsPage(
                  key: UniqueKey(),
                  ctrl: ctrl,
                  easyLayout: EasyLayout(
                    tiles: [
                      EasyTile(
                        type: type,
                        size: tall
                            ? EasyTileSize.single
                            : large
                            ? EasyTileSize.full
                            : EasyTileSize.wide,
                        height: tall
                            ? large
                                  ? 2
                                  : 1.5
                            : 1,
                        param: type == EasyTileType.volumeDirect ? -30.0 : null,
                      ),
                    ],
                  ),
                ),
              ),
            );
            final tile = find.byKey(const ValueKey('easy-tile-0'));
            final tileRect = tester.getRect(tile);
            final plus = find.byKey(const ValueKey('easy-step-0-plus'));
            final minus = find.byKey(const ValueKey('easy-step-0-minus'));
            final plusRect = tester.getRect(plus);
            final extent = tall ? plusRect.height : plusRect.width;
            expect(
              extent,
              greaterThan((tall ? tileRect.height : tileRect.width) * 0.3),
            );
            expect(
              tall ? tester.getSize(minus).height : tester.getSize(minus).width,
              moreOrLessEquals(extent, epsilon: 0.01),
            );
            final font = tester
                .widget<Text>(
                  find.descendant(of: plus, matching: find.byType(Text)),
                )
                .style!
                .fontSize!;
            expect(font, inInclusiveRange(18, 36));
            if (previousExtent != null) {
              expect(extent, greaterThan(previousExtent));
              expect(font, greaterThanOrEqualTo(previousFont!));
            }
            previousExtent = extent;
            previousFont = font;
            if (type == EasyTileType.volumeUp) {
              // Exercise the expanded surface far from the centered symbol.
              final before = ctrl.volumes.length;
              await tester.tapAt(
                tall
                    ? Offset(plusRect.center.dx, plusRect.top + 3)
                    : Offset(plusRect.right - 3, plusRect.center.dy),
              );
              await tester.pump();
              expect(ctrl.volumes.length, before + 1);
              expect(ctrl.volumes.last, (
                Adi2Addr.ph34,
                ctrl.valueOr(Adi2Addr.ph34, OutIdx.volume, -1145) + 5,
              ));
            }
            expect(tester.takeException(), isNull, reason: type.name);
          }
        }
      },
    );
  }

  for (final type in [EasyTileType.volumeUp, EasyTileType.volumeDown]) {
    testWidgets('${type.name} only hides current volume for a matching ring', (
      tester,
    ) async {
      for (final shape in [
        (EasyTileSize.single, 1.0),
        (EasyTileSize.single, 2.0),
        (EasyTileSize.wide, 0.5),
        (EasyTileSize.wide, 1.0),
      ]) {
        // Null and unsupported output addresses both follow the selection.
        for (final output in [null, Adi2Addr.line, Adi2Addr.ph34, -1]) {
          for (final ring in [
            null,
            const EasyTile(type: EasyTileType.volumeRing),
            const EasyTile(
              type: EasyTileType.volumeRing,
              output: Adi2Addr.line,
            ),
            const EasyTile(
              type: EasyTileType.volumeRing,
              output: Adi2Addr.ph34,
            ),
            const EasyTile(type: EasyTileType.volumeRing, output: -1),
          ]) {
            final address = output == Adi2Addr.line
                ? Adi2Addr.line
                : Adi2Addr.ph34;
            final ringAddress = ring?.output == Adi2Addr.line
                ? Adi2Addr.line
                : Adi2Addr.ph34;
            await show(
              tester,
              Scaffold(
                body: OutputsPage(
                  key: UniqueKey(),
                  ctrl: ctrl,
                  easyLayout: EasyLayout(
                    tiles: [
                      EasyTile(
                        type: type,
                        output: output,
                        size: shape.$1,
                        height: shape.$2,
                      ),
                      ?ring,
                    ],
                  ),
                ),
              ),
            );
            final tile = find.byKey(const ValueKey('easy-tile-0'));
            expect(
              find.descendant(
                of: tile,
                matching: find.text(
                  fmtDb(ctrl.valueOr(address, OutIdx.volume, -1145) / 10),
                ),
              ),
              ring != null && address == ringAddress
                  ? findsNothing
                  : findsOneWidget,
              reason: '$shape output=$output ring=${ring?.output}',
            );
            expect(
              find.descendant(
                of: tile,
                matching: find.text(
                  type == EasyTileType.volumeUp ? '+0,5 dB' : '−0,5 dB',
                ),
              ),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
          }
        }
      }
    });
  }

  testWidgets(
    'Volume visibility follows selection and all rings in the layout',
    (tester) async {
      await show(
        tester,
        Scaffold(
          body: OutputsPage(
            ctrl: ctrl,
            easyLayout: EasyLayout(
              tiles: [
                const EasyTile(
                  type: EasyTileType.volumeUp,
                  size: EasyTileSize.wide,
                ),
                const EasyTile(
                  type: EasyTileType.outputSelect,
                  size: EasyTileSize.full,
                ),
                const EasyTile(
                  type: EasyTileType.volumeRing,
                  output: Adi2Addr.line,
                ),
                const EasyTile(
                  type: EasyTileType.volumeRing,
                  output: Adi2Addr.ph12,
                ),
              ],
            ),
          ),
        ),
      );
      final value = find.byKey(const ValueKey('easy-step-0-value'));
      expect(value, findsOneWidget);
      await tester.tap(find.byKey(ValueKey('easy-segment-1-${Adi2Addr.line}')));
      await tester.pumpAndSettle();
      expect(value, findsNothing);
      await tester.tap(find.byKey(ValueKey('easy-segment-1-${Adi2Addr.ph34}')));
      await tester.pumpAndSettle();
      expect(value, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Tone, balance and volume steps repeat, stop and respect lock', (
    tester,
  ) async {
    for (final type in [
      EasyTileType.bass,
      EasyTileType.treble,
      EasyTileType.balance,
      EasyTileType.volumeUp,
    ]) {
      await show(
        tester,
        Scaffold(
          body: OutputsPage(
            key: UniqueKey(),
            ctrl: ctrl,
            easyLayout: EasyLayout(
              tiles: [EasyTile(type: type, size: EasyTileSize.wide)],
            ),
          ),
        ),
      );
      final before =
          ctrl.eqWrites.length + ctrl.writes.length + ctrl.volumes.length;
      final plus = find.byKey(const ValueKey('easy-step-0-plus'));
      await tester.tap(plus);
      await tester.pump();
      expect(
        ctrl.eqWrites.length + ctrl.writes.length + ctrl.volumes.length,
        greaterThan(before),
      );
      final gesture = await tester.startGesture(tester.getCenter(plus));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 800));
      await gesture.up();
      await tester.pumpAndSettle();
      final count =
          ctrl.eqWrites.length + ctrl.writes.length + ctrl.volumes.length;
      expect(count, greaterThan(before + 2));
      await tester.pump(const Duration(seconds: 1));
      expect(
        ctrl.eqWrites.length + ctrl.writes.length + ctrl.volumes.length,
        count,
      );
    }
    ctrl.values[9 << 8 | OutIdx.lockVolume] = 1;
    ctrl.notifyListeners();
    await tester.pump();
    final count = ctrl.volumes.length;
    await tester.tap(find.byKey(const ValueKey('easy-step-0-plus')));
    await tester.pump();
    expect(ctrl.volumes.length, count);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Output segments fill every tile size and taps never open a menu',
    (tester) async {
      final model = _Controller(Adi2Variant.dac);
      addTearDown(model.dispose);
      double? previousFont;
      for (final shape in [
        (EasyTileSize.full, 0.5),
        (EasyTileSize.full, 1.0),
        (EasyTileSize.full, 2.0),
        (EasyTileSize.single, 1.5),
        (EasyTileSize.single, 2.0),
      ]) {
        await show(
          tester,
          Scaffold(
            body: OutputsPage(
              key: UniqueKey(),
              ctrl: model,
              easyLayout: EasyLayout(
                tiles: [
                  EasyTile(
                    type: EasyTileType.outputSelect,
                    size: shape.$1,
                    height: shape.$2,
                  ),
                ],
              ),
            ),
          ),
        );
        final tile = tester.getRect(find.byKey(const ValueKey('easy-tile-0')));
        final vertical = tile.height > tile.width;
        final outs = outputsFor(model.variant);
        final rects = [
          for (final out in outs)
            tester.getRect(
              find.byKey(ValueKey('easy-segment-0-${out.address}')),
            ),
        ];
        expect(rects.first.topLeft, tile.topLeft);
        expect(rects.last.bottomRight, tile.bottomRight);
        for (var i = 0; i < rects.length; i++) {
          final rect = rects[i];
          expect(
            rect.width,
            closeTo(vertical ? tile.width : tile.width / outs.length, 0.01),
          );
          expect(
            rect.height,
            closeTo(vertical ? tile.height / outs.length : tile.height, 0.01),
          );
          if (i > 0) {
            expect(
              vertical ? rect.top : rect.left,
              closeTo(
                vertical ? rects[i - 1].bottom : rects[i - 1].right,
                0.01,
              ),
            );
          }
          // Exercise the old dead margins as well as each segment's center.
          for (final point in [
            rect.center,
            Offset(rect.center.dx, rect.top + 1),
            Offset(rect.center.dx, rect.bottom - 1),
            Offset(rect.left + 1, rect.center.dy),
            Offset(rect.right - 1, rect.center.dy),
          ]) {
            await tester.tapAt(point);
            await tester.pumpAndSettle();
            expect(model.selectedOutput, outs[i].address);
            expect(find.byType(BottomSheet), findsNothing);
            expect(find.byType(AlertDialog), findsNothing);
            expect(find.byTooltip('Kachel bearbeiten'), findsNothing);
          }
        }
        final label = tester.widget<Text>(
          find.descendant(
            of: find.byKey(ValueKey('easy-segment-0-${outs.first.address}')),
            matching: find.byType(Text),
          ),
        );
        expect(label.style!.fontSize, inInclusiveRange(12, 28));
        if (shape.$1 == EasyTileSize.full) {
          if (previousFont != null) {
            expect(label.style!.fontSize!, previousFont);
          }
          previousFont = label.style!.fontSize;
        }
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'Composite tile margins never open menus and long press follows tile policy',
    (tester) async {
      for (final type in [
        EasyTileType.source,
        EasyTileType.daFilter,
        EasyTileType.bass,
        EasyTileType.treble,
        EasyTileType.balance,
        EasyTileType.refLevel,
        EasyTileType.volumeUp,
        EasyTileType.volumeDown,
        EasyTileType.volumeDirect,
      ]) {
        await show(
          tester,
          Scaffold(
            body: OutputsPage(
              key: UniqueKey(),
              ctrl: ctrl,
              easyLayout: EasyLayout(
                tiles: [
                  EasyTile(
                    type: type,
                    size: EasyTileSize.full,
                    param: type == EasyTileType.volumeDirect ? -30.0 : null,
                  ),
                ],
              ),
            ),
          ),
        );
        final rect = tester.getRect(find.byKey(const ValueKey('easy-tile-0')));
        final before = (
          ctrl.writes.length,
          ctrl.eqWrites.length,
          ctrl.volumes.length,
        );
        await tester.tapAt(Offset(rect.center.dx, rect.top + 1));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing, reason: type.name);
        expect(find.byType(AlertDialog), findsNothing, reason: type.name);
        if (!{
          EasyTileType.volumeUp,
          EasyTileType.volumeDown,
          EasyTileType.volumeDirect,
        }.contains(type)) {
          expect((
            ctrl.writes.length,
            ctrl.eqWrites.length,
            ctrl.volumes.length,
          ), before);
        }
        if (EasyTile.isStepper(type)) {
          for (final name in ['minus', 'plus']) {
            final button = find.byKey(ValueKey('easy-step-0-$name'));
            final ink = tester.widget<Ink>(
              find.descendant(of: button, matching: find.byType(Ink)),
            );
            final shape =
                (ink.decoration! as ShapeDecoration).shape
                    as RoundedRectangleBorder;
            expect(shape.side.color, Palette.line);
            expect(shape.side.width, greaterThan(0));
            expect(shape.borderRadius, BorderRadius.circular(10));
            expect(tester.getSize(button).width, greaterThan(44));
          }
        }
        final outer = tester.widget<InkWell>(
          find
              .descendant(
                of: find.byKey(const ValueKey('easy-tile-0')),
                matching: find.byType(InkWell),
              )
              .first,
        );
        expect(
          outer.onLongPress,
          {
                EasyTileType.volumeUp,
                EasyTileType.volumeDown,
                EasyTileType.volumeDirect,
              }.contains(type)
              ? isNull
              : isNotNull,
          reason: type.name,
        );
        if (type == EasyTileType.source) {
          await tester.longPressAt(Offset(rect.center.dx, rect.top + 1));
          await tester.pumpAndSettle();
          expect(find.byType(BottomSheet), findsOneWidget);
          expect(find.byTooltip('Kachel bearbeiten'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'Output long press retains Phones settings and disabled outputs',
    (tester) async {
      ctrl.values[Adi2Addr.device << 8 | 8] = 0;
      await show(
        tester,
        Scaffold(
          body: OutputsPage(
            ctrl: ctrl,
            easyLayout: EasyLayout(
              tiles: [
                const EasyTile(
                  type: EasyTileType.outputSelect,
                  size: EasyTileSize.full,
                ),
              ],
            ),
          ),
        ),
      );
      final disabled = find.byKey(ValueKey('easy-segment-0-${Adi2Addr.ph12}'));
      final selected = ctrl.selectedOutput;
      await tester.tap(disabled);
      await tester.pumpAndSettle();
      expect(ctrl.selectedOutput, selected);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.longPress(
        find.byKey(ValueKey('easy-segment-0-${Adi2Addr.ph34}')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byTooltip('Kachel bearbeiten'), findsNothing);
    },
  );

  testWidgets(
    'Source and output segments write and select their explicit values',
    (tester) async {
      await show(
        tester,
        Scaffold(
          body: OutputsPage(
            ctrl: ctrl,
            easyLayout: EasyLayout(
              tiles: [
                const EasyTile(
                  type: EasyTileType.outputSelect,
                  size: EasyTileSize.full,
                ),
                const EasyTile(
                  type: EasyTileType.source,
                  size: EasyTileSize.full,
                  output: 3,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('easy-segment-0-3')));
      await tester.pumpAndSettle();
      expect(ctrl.selectedOutput, 3);
      await tester.tap(find.byKey(const ValueKey('easy-segment-1-1')));
      await tester.pumpAndSettle();
      expect(ctrl.writes, contains((3, OutIdx.source, 1)));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Volume hold release cancels the guarded upward ramp', (
    tester,
  ) async {
    ctrl.guarded = true;
    await show(
      tester,
      Scaffold(
        body: OutputsPage(
          ctrl: ctrl,
          easyLayout: EasyLayout(
            tiles: [
              const EasyTile(
                type: EasyTileType.volumeUp,
                size: EasyTileSize.wide,
              ),
            ],
          ),
        ),
      ),
    );
    final plus = find.byKey(const ValueKey('easy-step-0-plus'));
    final gesture = await tester.startGesture(tester.getCenter(plus));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 500));
    expect(ctrl.volumeTarget(9), isNotNull);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(ctrl.volumeTarget(9), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ref tile opens shared picker and cancellation writes nothing', (
    tester,
  ) async {
    ctrl.values[3 << 8 | OutIdx.refLevel] = 0;
    await show(
      tester,
      Scaffold(
        body: OutputsPage(
          ctrl: ctrl,
          easyLayout: EasyLayout(
            tiles: const [
              EasyTile(
                type: EasyTileType.refLevel,
                output: 3,
                size: EasyTileSize.wide,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('easy-step-0-plus')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('easy-tile-0')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    final chips = find.byType(ChoiceChip);
    await tester.tap(chips.last);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(ctrl.writes, isEmpty);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(ctrl.writes, isEmpty);
  });

  testWidgets('Editor excludes small stepper forms and previews do not write', (
    tester,
  ) async {
    await settings.setEasyLayout(
      ctrl.variant,
      EasyLayout(
        tiles: [
          const EasyTile(type: EasyTileType.bass, size: EasyTileSize.wide),
        ],
      ),
    );
    await show(tester, EasyModeEditor(ctrl: ctrl));
    final edit = find.byKey(const ValueKey('easy-edit-0'));
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<InkWell>(find.byKey(const ValueKey('easy-size-single-0.5')))
          .onTap,
      isNull,
    );
    expect(
      tester
          .widget<InkWell>(find.byKey(const ValueKey('easy-size-single-1.0')))
          .onTap,
      isNotNull,
    );
    expect(find.byKey(const ValueKey('easy-size-single-1.5')), findsOneWidget);
    expect(find.byKey(const ValueKey('easy-size-wide-0.5')), findsOneWidget);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    // The preview routes every tile tap to the editor, even over +/-.
    await tester.tap(find.byKey(const ValueKey('easy-step-0-plus')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('easy-save-tile')), findsOneWidget);
    expect(ctrl.eqWrites, isEmpty);
    expect(ctrl.writes, isEmpty);
  });

  testWidgets(
    'Header switch shows Custom Mode, remembers it and restores normal outputs',
    (tester) async {
      await show(tester, HomePage(ctrl: ctrl, np: np));
      expect(find.byKey(const ValueKey('easy-panel')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('easy-switch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('easy-panel')), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getBool('easy_mode'),
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('easy-switch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('easy-panel')), findsNothing);
    },
  );

  testWidgets(
    'Direct actions use setup slots, EQ raw 2..21, model sources and guarded volume',
    (tester) async {
      final snapshot = AppEqPreset(
        name: 'Bibliothek',
        dual: true,
        left: {4: 2, 21: -1},
        right: {4: -3},
      );
      final tiles = [
        const EasyTile(type: EasyTileType.setup, param: 1),
        const EasyTile(type: EasyTileType.setup, param: 9, label: 'Abend'),
        const EasyTile(type: EasyTileType.eqPreset, output: 3, param: 1),
        const EasyTile(type: EasyTileType.eqPreset, output: 9, param: 20),
        const EasyTile(type: EasyTileType.sourceDirect, output: 9, param: 6),
        const EasyTile(type: EasyTileType.toggleOutputs),
        const EasyTile(type: EasyTileType.basicMode, param: 5),
        const EasyTile(
          type: EasyTileType.volumeDirect,
          output: 3,
          param: -50.5,
        ),
        const EasyTile(type: EasyTileType.volumeDirect, output: 9, param: -5),
        const EasyTile(type: EasyTileType.volumeDown),
        const EasyTile(type: EasyTileType.volumeUp),
        EasyTile(
          type: EasyTileType.appPreset,
          output: 6,
          param: snapshot.toJson(),
        ),
      ];
      await show(
        tester,
        Scaffold(
          body: OutputsPage(
            ctrl: ctrl,
            easyLayout: EasyLayout(tiles: tiles),
          ),
        ),
      );
      expect(find.text('Geräte-Setup'), findsOneWidget);
      expect(find.text('Geräte-EQ'), findsOneWidget);
      for (var i = 0; i < tiles.length; i++) {
        await tapTile(tester, i);
      }
      expect(ctrl.setups, [1, 9]);
      expect(
        ctrl.writes,
        containsAll([
          (4, EqIdx2.presetSelect, 2),
          (10, EqIdx2.presetSelect, 21),
          (9, OutIdx.source, 6),
          (Adi2Addr.device, 6, 5),
          (6, OutIdx.dualEq, 1),
        ]),
      );
      expect(ctrl.toggles, 1);
      expect(ctrl.volumes, [(3, -505), (9, -50), (9, -105), (9, -95)]);
      expect(ctrl.eqWrites, containsAll([(7, 4, 2), (7, 21, -1), (8, 4, -3)]));
      expect(ctrl.names[0x21], 'Geräte-Setup');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Selected output, lock and unreported source are respected', (
    tester,
  ) async {
    ctrl.values.remove(6 << 8 | OutIdx.source);
    ctrl.values[9 << 8 | OutIdx.lockVolume] = 1;
    await show(
      tester,
      Scaffold(
        body: OutputsPage(
          ctrl: ctrl,
          easyLayout: EasyLayout(
            tiles: [
              const EasyTile(type: EasyTileType.volumeDirect, param: 0),
              const EasyTile(
                type: EasyTileType.sourceDirect,
                output: 6,
                param: 2,
              ),
              const EasyTile(type: EasyTileType.mute),
            ],
          ),
        ),
      ),
    );
    await tapTile(tester, 0);
    await tapTile(tester, 1);
    await tapTile(tester, 2);
    expect(ctrl.volumes, isEmpty);
    expect(ctrl.writes, [(9, OutIdx.mute, 1)]);
  });

  testWidgets(
    'Known active direct action is amber and long press opens EQ settings',
    (tester) async {
      ctrl.values[9 << 8 | OutIdx.source] = 4;
      await show(
        tester,
        Scaffold(
          body: OutputsPage(
            ctrl: ctrl,
            easyLayout: EasyLayout(
              tiles: [
                const EasyTile(type: EasyTileType.sourceDirect, param: 4),
                const EasyTile(type: EasyTileType.eqPreset, param: 1),
              ],
            ),
          ),
        ),
      );
      final material = tester.widget<Material>(
        find.byKey(const ValueKey('easy-tile-0')),
      );
      expect(
        (material.shape! as RoundedRectangleBorder).side.color,
        Palette.amber,
      );
      await tester.longPress(find.byKey(const ValueKey('easy-tile-1')));
      await tester.pumpAndSettle();
      expect(find.byType(EqPage), findsOneWidget);
    },
  );

  for (final player in [false, true]) {
    for (final status in [false, true]) {
      testWidgets(
        'Player=$player, Status=$status are independently selectable',
        (tester) async {
          await settings.setEasyMode(true);
          await settings.setEasyLayout(
            ctrl.variant,
            EasyLayout(showPlayer: player, showStatus: status, tiles: []),
          );
          await show(tester, HomePage(ctrl: ctrl, np: np));
          expect(
            find.byType(PlayerBar),
            player ? findsOneWidget : findsNothing,
          );
          expect(
            find.byKey(const ValueKey('digital-mini')),
            status ? findsOneWidget : findsNothing,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final player in [false, true]) {
    for (final status in [false, true]) {
      testWidgets(
        'Normal view player=$player status=$status independent of Custom Mode',
        (tester) async {
          await settings.setShowPlayer(player);
          await settings.setShowStatus(status);
          await settings.setEasyLayout(
            ctrl.variant,
            EasyLayout(showPlayer: !player, showStatus: !status, tiles: []),
          );
          await show(tester, HomePage(ctrl: ctrl, np: np));
          expect(
            find.byType(PlayerBar),
            player ? findsOneWidget : findsNothing,
          );
          expect(
            find.byKey(const ValueKey('digital-mini')),
            status ? findsOneWidget : findsNothing,
          );
          expect(find.text(tr('Eigene\nAnsicht')), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('easy-switch')));
          await tester.pumpAndSettle();
          expect(
            find.byType(PlayerBar),
            !player ? findsOneWidget : findsNothing,
          );
          expect(
            find.byKey(const ValueKey('digital-mini')),
            !status ? findsOneWidget : findsNothing,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('Header selection hides player and status and moves outputs up', (
    tester,
  ) async {
    np.supported = true;
    np.access = true;
    np.info = const NowPlayingInfo(title: 'Testmusik', playing: true);
    await show(tester, HomePage(ctrl: ctrl, np: np));
    expect(find.text('Testmusik'), findsOneWidget);
    final before = tester.getTopLeft(find.byType(OutputsPage)).dy;
    await tester.tap(find.byIcon(Icons.settings_outlined).first);
    await tester.pumpAndSettle();
    final playerSwitch = find.byKey(const ValueKey('header-status'));
    await tester.scrollUntilVisible(
      playerSwitch,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(playerSwitch);
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Testmusik'), findsNothing);
    expect(find.byKey(const ValueKey('digital-mini')), findsOneWidget);
    await tester.tap(find.byIcon(Icons.settings_outlined).first);
    await tester.pumpAndSettle();
    final statusSwitch = find.byKey(const ValueKey('header-none'));
    await tester.scrollUntilVisible(
      statusSwitch,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(statusSwitch);
    await tester.pumpAndSettle();
    await tester.tap(statusSwitch);
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerBar), findsNothing);
    expect(find.byKey(const ValueKey('digital-mini')), findsNothing);
    expect(tester.getTopLeft(find.byType(OutputsPage)).dy, lessThan(before));
    expect(settings.easyLayout(ctrl.variant).showPlayer, true);
    expect(settings.easyLayout(ctrl.variant).showStatus, true);
    expect(tester.takeException(), isNull);
  });

  for (final language in AppLanguage.values) {
    testWidgets('Two-line Custom Mode button fits at 360dp in $language', (
      tester,
    ) async {
      AppLang.instance.language = language;
      final model = _Controller(Adi2Variant.pro4se);
      addTearDown(model.dispose);
      await show(tester, HomePage(ctrl: model, np: np));
      final label = tester.widget<Text>(find.text(model.deviceLabel));
      expect(model.deviceLabel, contains('ADI-2/4 Pro SE'));
      expect(label.maxLines, 1);
      expect(label.overflow, TextOverflow.ellipsis);
      final button = find.byKey(const ValueKey('easy-switch'));
      expect(tester.getSize(button).height, lessThanOrEqualTo(44));
      expect(tester.getRect(button).right, lessThan(360));
      final text = find.text(tr('Eigene\nAnsicht'));
      expect(text, findsOneWidget);
      expect(tester.widget<Text>(text).style?.height, 1.0);
      expect(tester.widget<Text>(text).textAlign, TextAlign.center);
      expect(
        tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
        isFalse,
      );
      expect(
        tester.getRect(text).center.dy,
        closeTo(tester.getRect(button).center.dy, 1),
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(text).center.dy,
        closeTo(tester.getRect(button).center.dy, 1),
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final language in AppLanguage.values) {
    for (final size in [const Size(360, 740), const Size(411, 914)]) {
      testWidgets(
        'Editor footer tiles and compact hints in $language at $size',
        (tester) async {
          AppLang.instance.language = language;
          await settings.setEasyLayout(
            ctrl.variant,
            EasyLayout.defaults(ctrl.variant),
          );
          tester.view.padding = const FakeViewPadding(bottom: 34);
          addTearDown(tester.view.resetPadding);
          await show(tester, EasyModeEditor(ctrl: ctrl), size: size);
          final add = find.byKey(const ValueKey('easy-add'));
          expect(
            find.descendant(of: add, matching: find.text(tr('Hinzufügen'))),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: add,
              matching: find.byIcon(Icons.add_box_outlined),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(of: add, matching: find.text('+')),
            findsNothing,
          );
          final footer = find.byKey(const ValueKey('easy-editor-footer'));
          final footerMaterial = tester.widget<Material>(
            find.ancestor(of: footer, matching: find.byType(Material)).first,
          );
          expect(footerMaterial.color, Palette.surf);
          expect((footerMaterial.shape! as Border).top.color, Palette.line);
          Rect? previousRect;
          for (final (key, color, border, filled, icon) in [
            (
              'easy-add',
              Palette.amber,
              Palette.amber,
              true,
              Icons.add_box_outlined,
            ),
            (
              'easy-clear-slot',
              Palette.red,
              Palette.red.withValues(alpha: 0.45),
              false,
              Icons.delete_outline,
            ),
            (
              'easy-save-setup',
              Palette.amber,
              Palette.amber,
              false,
              Icons.save_outlined,
            ),
            (
              'easy-reset',
              Palette.text,
              Palette.line,
              false,
              Icons.restart_alt,
            ),
          ]) {
            final button = find.byKey(ValueKey(key));
            final material = tester.widget<Material>(button);
            expect(material.color, filled ? color : Palette.bg);
            final shape = material.shape! as RoundedRectangleBorder;
            expect(shape.side.color, border);
            expect(shape.borderRadius, BorderRadius.circular(10));
            expect(material.clipBehavior, Clip.antiAlias);
            final ink = tester.widget<InkWell>(
              find.descendant(of: button, matching: find.byType(InkWell)),
            );
            expect(ink.onTap, isNotNull);
            expect(ink.splashColor!.a, greaterThan(0));
            expect(ink.highlightColor!.a, greaterThan(0));
            final symbol = find.descendant(
              of: button,
              matching: find.byIcon(icon),
            );
            expect(tester.widget<Icon>(symbol).size, 24);
            expect(
              tester.widget<Icon>(symbol).color,
              filled ? Palette.bg : color,
            );
            final label = find.descendant(
              of: button,
              matching: find.byType(Text),
            );
            expect(tester.widget<Text>(label).style!.fontSize, 12);
            expect(
              tester.getRect(symbol).bottom,
              lessThan(tester.getRect(label).top),
            );
            final rect = tester.getRect(button);
            expect(rect.height, 64);
            expect(rect.width, closeTo((size.width - 40) / 4, 0.01));
            expect(rect.bottom, lessThanOrEqualTo(size.height - 34 - 8));
            if (previousRect != null) {
              expect(rect.left - previousRect.right, closeTo(8, 0.01));
              expect(rect.top, previousRect.top);
            }
            expect(
              tester.getSize(label).width,
              lessThanOrEqualTo(rect.width - 8),
            );
            previousRect = rect;
          }
          final hints = find.byKey(const ValueKey('easy-editor-hints'));
          expect(
            find.descendant(
              of: hints,
              matching: find.byIcon(Icons.push_pin_outlined),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: hints,
              matching: find.byIcon(Icons.edit_outlined),
            ),
            findsOneWidget,
          );
          for (final label in [
            'fixieren',
            'bearbeiten',
            'lange drücken = verschieben',
          ]) {
            final text = find.descendant(
              of: hints,
              matching: find.text(tr(label)),
            );
            expect(text, findsOneWidget);
            expect(tester.widget<Text>(text).style!.fontSize, 12);
            expect(tester.widget<Text>(text).style!.color, Palette.muted);
          }
          expect(tester.getSize(hints).height, lessThan(24));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'Editor disables clear for an empty slot and updates after saving',
    (tester) async {
      await settings.activateEasySlot(ctrl.variant, 1);
      await show(tester, EasyModeEditor(ctrl: ctrl));
      final button = find.byKey(const ValueKey('easy-clear-slot'));
      Finder ink() =>
          find.descendant(of: button, matching: find.byType(InkWell));
      expect(tester.widget<InkWell>(ink()).onTap, isNull);
      final icon = find.descendant(
        of: button,
        matching: find.byIcon(Icons.delete_outline),
      );
      expect(
        tester.widget<Icon>(icon).color,
        Palette.red.withValues(alpha: 0.38),
      );
      final semantics = tester.getSemantics(button);
      expect(
        semantics,
        matchesSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
          label: 'Löschen',
        ),
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await settings.setEasyLayout(
        ctrl.variant,
        EasyLayout.defaults(ctrl.variant),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<InkWell>(ink()).onTap, isNotNull);
      expect(tester.widget<Icon>(icon).color, Palette.red);
      await settings.clearEasySlot(ctrl.variant, 1);
      await tester.pumpAndSettle();
      expect(tester.widget<InkWell>(ink()).onTap, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Editor confirms reset, overwrite and clear and saves named snapshots',
    (tester) async {
      final original = EasyLayout(
        tiles: const [EasyTile(type: EasyTileType.dim, label: 'Mein Setup')],
      );
      await settings.setEasyLayout(ctrl.variant, original);
      await show(tester, EasyModeEditor(ctrl: ctrl));
      final keys = [
        'easy-add',
        'easy-clear-slot',
        'easy-save-setup',
        'easy-reset',
      ];
      final rects = [
        for (final key in keys) tester.getRect(find.byKey(ValueKey(key))),
      ];
      for (var i = 0; i < rects.length; i++) {
        expect(rects[i].width, closeTo(rects.first.width, 0.01));
        expect(rects[i].top, rects.first.top);
        expect(rects[i].bottom, lessThanOrEqualTo(740));
        if (i > 0) expect(rects[i].left, closeTo(rects[i - 1].right + 8, 0.01));
      }
      Future<void> footer(String key) async {
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
      }

      await footer('easy-reset');
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(settings.easyLayout(ctrl.variant).toJson(), original.toJson());
      await footer('easy-save-setup');
      await tester.tap(find.byKey(const ValueKey('easy-save-slot-1')));
      await tester.enterText(
        find.byKey(const ValueKey('easy-slot-name')),
        'Abend',
      );
      await tester.tap(find.byKey(const ValueKey('easy-save-setup-confirm')));
      await tester.pumpAndSettle();
      expect(settings.easySlots(ctrl.variant).active, 1);
      expect(settings.easySlots(ctrl.variant).names[1], 'Abend');
      expect(settings.easyLayout(ctrl.variant).toJson(), original.toJson());
      await footer('easy-save-setup');
      await tester.enterText(
        find.byKey(const ValueKey('easy-slot-name')),
        'Neu',
      );
      await tester.tap(find.byKey(const ValueKey('easy-save-setup-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Eigene Ansicht 2 überschreiben?'), findsOneWidget);
      await tester.tap(find.text('Abbrechen').last);
      await tester.pumpAndSettle();
      expect(settings.easySlots(ctrl.variant).names[1], 'Abend');
      await tester.tap(find.byKey(const ValueKey('easy-save-setup-confirm')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('easy-confirm')));
      await tester.pumpAndSettle();
      expect(settings.easySlots(ctrl.variant).names[1], 'Neu');
      await footer('easy-clear-slot');
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(settings.easySlots(ctrl.variant).layouts[1], isNotNull);
      await footer('easy-clear-slot');
      await tester.tap(find.byKey(const ValueKey('easy-confirm')));
      await tester.pumpAndSettle();
      expect(settings.easySlots(ctrl.variant).layouts[1], isNull);
      await footer('easy-reset');
      await tester.tap(find.byKey(const ValueKey('easy-confirm')));
      await tester.pumpAndSettle();
      expect(
        settings.easyLayout(ctrl.variant).toJson(),
        EasyLayout.defaults(ctrl.variant).toJson(),
      );
      expect(
        settings.easySlots(ctrl.variant).layouts[0]!.toJson(),
        original.toJson(),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Editor is reachable through app settings', (tester) async {
    await show(tester, AppSettingsPage(ctrl: ctrl));
    await tester.tap(find.byKey(const ValueKey('easy-open-editor')));
    await tester.pumpAndSettle();
    expect(find.byType(EasyModeEditor), findsOneWidget);
  });

  testWidgets(
    'Editor adds, renames, resizes, assigns output, removes and restores tiles',
    (tester) async {
      await settings.setEasyLayout(ctrl.variant, EasyLayout(tiles: []));
      await show(tester, EasyModeEditor(ctrl: ctrl));
      final outer = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('easy-add')),
        250,
        scrollable: outer,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('easy-add')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('easy-gallery-mute')),
        180,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('easy-tile-gallery')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('easy-gallery-mute')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('easy-label')), 'Ruhe');
      expect(find.byType(EasySizePicker), findsOneWidget);
      expect(
        find.byKey(const ValueKey('easy-size-shape-wide-1.0')),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('easy-size-wide-1.0')),
      );
      await tester.tap(find.byKey(const ValueKey('easy-size-wide-1.0')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('easy-output')));
      await tester.tap(find.byKey(const ValueKey('easy-output')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Line Out').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('easy-save-tile')));
      await tester.pumpAndSettle();
      final tile = settings.easyLayout(ctrl.variant).tiles.single;
      expect(tile.label, 'Ruhe');
      expect(tile.size, EasyTileSize.wide);
      expect(tile.output, 3);
      expect(find.text('Ruhe'), findsWidgets);
      await tester.ensureVisible(find.byKey(const ValueKey('easy-edit-0')));
      await tester.tap(find.byKey(const ValueKey('easy-edit-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('easy-remove-0')));
      await tester.pumpAndSettle();
      expect(settings.easyLayout(ctrl.variant).tiles, isEmpty);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('easy-reset')),
        250,
        scrollable: outer,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('easy-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('easy-confirm')));
      await tester.pumpAndSettle();
      expect(
        settings.easyLayout(ctrl.variant).toJson(),
        EasyLayout.defaults(ctrl.variant).toJson(),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Editor reorders tiles and stores model-specific display options',
    (tester) async {
      await settings.setEasyLayout(
        ctrl.variant,
        EasyLayout(
          tiles: [
            const EasyTile(type: EasyTileType.mute, label: 'Erste'),
            const EasyTile(type: EasyTileType.dim, label: 'Zweite'),
            const EasyTile(type: EasyTileType.eqPage, label: 'Dritte'),
          ],
        ),
      );
      await show(tester, EasyModeEditor(ctrl: ctrl));
      await tester.tap(find.byKey(const ValueKey('header-none')));
      await tester.pumpAndSettle();
      expect(settings.easyLayout(ctrl.variant).showPlayer, isFalse);
      expect(settings.easyLayout(ctrl.variant).showStatus, isFalse);
      final source = find.byKey(const ValueKey('easy-drag-0'));
      final target = find.byKey(const ValueKey('easy-drag-2'));
      await tester.ensureVisible(source);
      await tester.pumpAndSettle();
      final destination = tester.getCenter(target);
      final gesture = await tester.startGesture(tester.getCenter(source));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(destination);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('easy-drop-position')), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(settings.easyLayout(ctrl.variant).tiles[0].x, 30);
      expect(settings.easyLayout(ctrl.variant).tiles[0].pinned, isFalse);
      expect(find.byKey(const ValueKey('easy-model')), findsNothing);
      expect(find.byType(DropdownButtonFormField<Adi2Variant>), findsNothing);
      expect(settings.easyLayout(Adi2Variant.dac).showPlayer, isTrue);
      expect(settings.easyLayout(ctrl.variant).showPlayer, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Editor long-press dragging auto-scrolls within the grid', (
    tester,
  ) async {
    await settings.setEasyLayout(
      ctrl.variant,
      EasyLayout(
        tiles: [
          for (var n = 0; n < 25; n++)
            EasyTile(
              type: EasyTileType.mute,
              label: 'Kachel $n',
              size: EasyTileSize.wide,
              height: 1.5,
            ),
        ],
      ),
    );
    await show(tester, EasyModeEditor(ctrl: ctrl));
    final outerScroll = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    outerScroll.jumpTo(outerScroll.maxScrollExtent);
    await tester.pumpAndSettle();
    final grid = find.byType(EasyTileGrid);
    final scrollable = find
        .ancestor(of: grid, matching: find.byType(Scrollable))
        .first;
    final scroll = tester.state<ScrollableState>(scrollable).position;
    scroll.jumpTo(scroll.maxScrollExtent);
    await tester.pumpAndSettle();
    final source = find.byKey(const ValueKey('easy-drag-24'));
    final before = scroll.pixels;
    final gesture = await tester.startGesture(tester.getCenter(source));
    await tester.pump(const Duration(milliseconds: 600));
    final viewport = tester.getRect(scrollable);
    await gesture.moveTo(Offset(viewport.left + 30, viewport.top + 15));
    for (var n = 0; n < 30; n++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(scroll.pixels, lessThan(before - 200));
    expect(settings.easyLayout(ctrl.variant).tiles[24].y, lessThan(30));
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(411, 914), const Size(360, 740)]) {
    testWidgets('Square remains quarter width and flat tiles fit: $size', (
      tester,
    ) async {
      await show(
        tester,
        Scaffold(
          body: OutputsPage(
            ctrl: ctrl,
            easyLayout: EasyLayout(
              tiles: [
                const EasyTile(type: EasyTileType.dim),
                const EasyTile(
                  type: EasyTileType.mute,
                  height: 0.5,
                  label: 'Eine sehr lange flache Beschriftung',
                ),
                const EasyTile(
                  type: EasyTileType.volumeRing,
                  size: EasyTileSize.wide,
                  height: 2,
                ),
              ],
            ),
          ),
        ),
        size: size,
      );
      final square = tester.getSize(find.byKey(const ValueKey('easy-tile-0')));
      final flat = tester.getSize(find.byKey(const ValueKey('easy-tile-1')));
      expect(square.width, closeTo((size.width - 32 + 8) / 4 - 8, 0.01));
      expect(square.height, closeTo(square.width, 0.01));
      expect(flat.height, closeTo((square.width + 8) / 2 - 8, 0.01));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Editor offers all six graphical widths in a matrix', (
    tester,
  ) async {
    await settings.setEasyLayout(
      ctrl.variant,
      EasyLayout(tiles: [const EasyTile(type: EasyTileType.mute)]),
    );
    await show(tester, EasyModeEditor(ctrl: ctrl));
    expect(find.text('Raster'), findsNothing);
    expect(find.text('Spalten'), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('easy-edit-0')));
    await tester.tap(find.byKey(const ValueKey('easy-edit-0')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(EasySizePicker), findsOneWidget);
    expect(
      find.byKey(const ValueKey('easy-size-shape-threeQuarters-0.5')),
      findsOneWidget,
    );
    for (final width in EasyTileSize.values) {
      expect(
        find.byKey(ValueKey('easy-size-shape-${width.name}-1.0')),
        findsOneWidget,
      );
    }
    final flat = find.byKey(const ValueKey('easy-size-wide-0.5'));
    await tester.ensureVisible(flat);
    await tester.tap(flat);
    await tester.tap(find.byKey(const ValueKey('easy-save-tile')));
    await tester.pumpAndSettle();
    expect(settings.easyLayout(ctrl.variant).tiles.single.height, 0.5);
    expect(
      settings.easyLayout(ctrl.variant).tiles.single.size,
      EasyTileSize.wide,
    );
    await settings.load();
    expect(settings.easyLayout(ctrl.variant).tiles.single.height, 0.5);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ring editor disables unusable dimensions', (tester) async {
    await settings.setEasyLayout(
      ctrl.variant,
      EasyLayout(
        tiles: [
          const EasyTile(
            type: EasyTileType.volumeRing,
            size: EasyTileSize.wide,
            height: 2,
          ),
        ],
      ),
    );
    await show(tester, EasyModeEditor(ctrl: ctrl));
    await tester.ensureVisible(find.byKey(const ValueKey('easy-edit-0')));
    await tester.tap(find.byKey(const ValueKey('easy-edit-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('easy-size-wide-2.0')), findsOneWidget);
    for (final key in [
      'easy-size-single-2.0',
      'easy-size-wide-0.5',
      'easy-size-wide-1.0',
    ]) {
      expect(tester.widget<InkWell>(find.byKey(ValueKey(key))).onTap, isNull);
    }
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Tile and default colors persist and mute uses the main view red accent',
    (tester) async {
      await settings.setEasyLayout(
        ctrl.variant,
        EasyLayout(
          tiles: [
            const EasyTile(type: EasyTileType.mute),
            const EasyTile(type: EasyTileType.dim),
          ],
        ),
      );
      await show(tester, EasyModeEditor(ctrl: ctrl));
      await tester.tap(find.text('Standardfarbe'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('easy-color-petrol')));
      await tester.pumpAndSettle();
      expect(
        settings.easyLayout(ctrl.variant).defaultColor,
        EasyTileColor.petrol,
      );
      await tester.tap(find.text('Standardfarbe'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('easy-edit-0')));
      await tester.tap(find.byKey(const ValueKey('easy-edit-0')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('easy-color-blue')));
      await tester.tap(find.byKey(const ValueKey('easy-color-blue')));
      await tester.tap(find.byKey(const ValueKey('easy-save-tile')));
      await tester.pumpAndSettle();
      await settings.load();
      await tester.pumpAndSettle();
      expect(
        settings.easyLayout(ctrl.variant).tiles.first.color,
        EasyTileColor.blue,
      );
      expect(
        settings.easyLayout(ctrl.variant).defaultColor,
        EasyTileColor.petrol,
      );
      Material surface(int i) =>
          tester.widget<Material>(find.byKey(ValueKey('easy-tile-$i')));
      expect(surface(0).color, easyTileBackground(EasyTileColor.blue));
      expect(surface(1).color, easyTileBackground(EasyTileColor.petrol));
      ctrl.values[ctrl.selectedOutput! << 8 | OutIdx.mute] = 1;
      ctrl.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        (surface(0).shape as RoundedRectangleBorder).side.color,
        Palette.red,
      );
      expect(
        surface(0).color,
        Color.alphaBlend(
          Palette.red.withValues(alpha: 0.14),
          easyTileBackground(EasyTileColor.blue),
        ),
      );
      // Returning to the inherited color removes the per-tile override.
      await tester.tap(find.byKey(const ValueKey('easy-edit-0')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('easy-color-inherit')),
      );
      await tester.tap(find.byKey(const ValueKey('easy-color-inherit')));
      await tester.tap(find.byKey(const ValueKey('easy-save-tile')));
      await tester.pumpAndSettle();
      expect(settings.easyLayout(ctrl.variant).tiles.first.color, isNull);
      expect(ctrl.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  test('All palette colors have readable text and symbols, including active surfaces', () {
    for (final color in EasyTileColor.values) {
      for (final active in [false, true]) {
        final base = easyTileBackground(color);
        final background = active
            ? Color.alphaBlend(Palette.amber.withValues(alpha: 0.14), base)
            : base;
        final foreground = easyTileForeground(background);
        final light = foreground.computeLuminance();
        final dark = background.computeLuminance();
        expect((light + 0.05) / (dark + 0.05), greaterThanOrEqualTo(4.5));
        final symbol = active
            ? Palette.amber
            : Color.alphaBlend(foreground.withValues(alpha: 0.78), background);
        expect(
          (symbol.computeLuminance() + 0.05) / (dark + 0.05),
          greaterThanOrEqualTo(3),
        );
      }
    }
  });

  for (final size in [const Size(411, 914), const Size(360, 740)]) {
    testWidgets(
      'Editor mixed heights, colors, ring and dialog do not overflow $size',
      (tester) async {
        await settings.setEasyLayout(
          ctrl.variant,
          EasyLayout(
            tiles: [
              const EasyTile(
                type: EasyTileType.volumeRing,
                size: EasyTileSize.wide,
                height: 2,
              ),
              for (var n = 0; n < 12; n++)
                EasyTile(
                  type: EasyTileType.dim,
                  size: EasyTileSize.values[n % EasyTileSize.values.length],
                  height: [0.5, 1.0, 1.5, 2.0][n % 4],
                  color: EasyTileColor.values[n % 10],
                  label: 'Eine sehr lange Kachelbeschriftung im Editor',
                ),
            ],
          ),
        );
        await show(tester, EasyModeEditor(ctrl: ctrl), size: size);
        await tester.ensureVisible(find.byKey(const ValueKey('easy-edit-1')));
        await tester.tap(find.byKey(const ValueKey('easy-edit-1')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('easy-output')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Abbrechen'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Mixed-size grid cancels outside drops and persists accepted reordering',
    (tester) async {
      final initial = EasyLayout(
        defaultColor: EasyTileColor.green,
        tiles: [
          const EasyTile(type: EasyTileType.mute, label: 'Erste', height: 0.5),
          const EasyTile(
            type: EasyTileType.dim,
            label: 'Zweite',
            size: EasyTileSize.wide,
            height: 2,
          ),
          const EasyTile(
            type: EasyTileType.eqPage,
            label: 'Dritte',
            size: EasyTileSize.third,
            color: EasyTileColor.rose,
          ),
        ],
      );
      await settings.setEasyLayout(ctrl.variant, initial);
      await show(tester, EasyModeEditor(ctrl: ctrl));
      final source = find.byKey(const ValueKey('easy-drag-2'));
      await tester.ensureVisible(source);
      await tester.pumpAndSettle();
      var gesture = await tester.startGesture(tester.getCenter(source));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(const Offset(-100, -100));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(settings.easyLayout(ctrl.variant).toJson(), initial.toJson());
      final destination = tester.getCenter(
        find.byKey(const ValueKey('easy-drag-0')),
      );
      gesture = await tester.startGesture(tester.getCenter(source));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(destination);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('easy-drop-position')), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      await settings.load();
      expect(settings.easyLayout(ctrl.variant).tiles[2].x, 0);
      expect(
        settings.easyLayout(ctrl.variant).tiles[2].color,
        EasyTileColor.rose,
      );
      expect(
        settings.easyLayout(ctrl.variant).defaultColor,
        EasyTileColor.green,
      );
      expect(ctrl.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Volume direct action lowers in one tick and raises through the guard limit',
    (tester) async {
      ctrl.guarded = true;
      ctrl.volGuard.setLimit(9, -200);
      await show(
        tester,
        Scaffold(
          body: OutputsPage(
            ctrl: ctrl,
            easyLayout: EasyLayout(
              tiles: [
                const EasyTile(type: EasyTileType.volumeDirect, param: -60),
                const EasyTile(type: EasyTileType.volumeDirect, param: 6),
              ],
            ),
          ),
        ),
      );
      await tapTile(tester, 0);
      expect(ctrl.volGuard.tick((a) => ctrl.value(a, OutIdx.volume)), {
        9: -600,
      });
      ctrl.values[9 << 8 | OutIdx.volume] = -600;
      await tapTile(tester, 1);
      expect(ctrl.volumeTarget(9), -200);
      final step = ctrl.volGuard.tick((a) => ctrl.value(a, OutIdx.volume))[9]!;
      expect(step, greaterThan(-600));
      expect(step, lessThan(-200));
      expect(ctrl.writes, isEmpty);
    },
  );

  testWidgets(
    'Setup and EQ labels can be renamed in the preview without device writes',
    (tester) async {
      await settings.setEasyLayout(
        ctrl.variant,
        EasyLayout(
          tiles: [
            const EasyTile(type: EasyTileType.setup, param: 1),
            const EasyTile(type: EasyTileType.eqPreset, param: 1),
          ],
        ),
      );
      await show(tester, EasyModeEditor(ctrl: ctrl));
      for (var i = 0; i < 2; i++) {
        await tapTile(tester, i);
        await tester.enterText(
          find.byKey(const ValueKey('easy-label')),
          'Name $i',
        );
        await tester.tap(find.byKey(const ValueKey('easy-save-tile')));
        await tester.pumpAndSettle();
      }
      expect(settings.easyLayout(ctrl.variant).tiles.map((t) => t.label), [
        'Name 0',
        'Name 1',
      ]);
      expect(ctrl.names[0x21], 'Geräte-Setup');
      expect(ctrl.names[1], 'Geräte-EQ');
      expect(ctrl.writes, isEmpty);
      expect(ctrl.setups, isEmpty);
    },
  );

  testWidgets('Player visibility updates when media appears and disappears', (
    tester,
  ) async {
    np.supported = true;
    np.access = true;
    await settings.setEasyMode(true);
    await settings.setEasyLayout(
      ctrl.variant,
      EasyLayout(showStatus: false, tiles: []),
    );
    await show(tester, HomePage(ctrl: ctrl, np: np));
    expect(tester.getSize(find.byType(PlayerBar)).height, 0);
    np.info = const NowPlayingInfo(title: 'Testtitel', playing: true);
    np.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Testtitel'), findsOneWidget);
    expect(
      tester.getSize(find.byType(PlayerBar)).height,
      headerSlotHeight(tester.element(find.byType(PlayerBar))),
    );
    await settings.setEasyLayout(
      ctrl.variant,
      EasyLayout(showPlayer: false, tiles: []),
    );
    await tester.pumpAndSettle();
    expect(find.text('Testtitel'), findsNothing);
    expect(find.byKey(const ValueKey('digital-mini')), findsOneWidget);
  });

  for (final size in [const Size(411, 914), const Size(360, 740)]) {
    testWidgets('Full catalog, mixed sizes and long labels fits $size', (
      tester,
    ) async {
      final tiles = <EasyTile>[];
      for (final type in EasyTileType.values) {
        final param = switch (type) {
          EasyTileType.setup || EasyTileType.eqPreset => 1,
          EasyTileType.basicMode || EasyTileType.sourceDirect => 0,
          EasyTileType.volumeDirect => -30,
          EasyTileType.appPreset => AppEqPreset(
            name: 'App',
            dual: false,
            left: {4: 0},
            right: {},
          ).toJson(),
          _ => null,
        };
        tiles.add(
          EasyTile(
            type: type,
            param: param,
            label: 'Eine besonders lange Beschriftung für die Kachel',
            size:
                EasyTileSize.values[tiles.length % EasyTileSize.values.length],
          ),
        );
      }
      await show(
        tester,
        Scaffold(
          body: OutputsPage(
            ctrl: ctrl,
            easyLayout: EasyLayout(tiles: tiles),
          ),
        ),
        size: size,
      );
      await tester.fling(
        find.byKey(const ValueKey('easy-panel')),
        const Offset(0, -3500),
        2000,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(411, 914), const Size(360, 740)]) {
    for (final variant in Adi2Variant.values) {
      testWidgets('No overflow ${size.width}×${size.height}, ${variant.name}', (
        tester,
      ) async {
        final modelCtrl = _Controller(variant);
        addTearDown(modelCtrl.dispose);
        await settings.setEasyMode(true);
        await settings.setEasyLayout(variant, EasyLayout.defaults(variant));
        await show(
          tester,
          HomePage(ctrl: modelCtrl, np: np),
          size: size,
        );
        await tester.fling(
          find.byKey(const ValueKey('easy-panel')),
          const Offset(0, -1800),
          2500,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        modelCtrl.state = ConnState.offline;
        modelCtrl.notifyListeners();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
