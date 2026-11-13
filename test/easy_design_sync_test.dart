import 'dart:math' as math;

import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/easy/easy_layout.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/easy_slot_preview.dart';
import 'package:adi2_remote/ui/easy_tile_grid.dart';
import 'package:adi2_remote/ui/easy_tile_preview.dart';
import 'package:adi2_remote/ui/outputs_page.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Controller extends Adi2Controller {
  _Controller(this.variant) : values = offlineDefaults(variant);
  @override
  final Adi2Variant variant;
  final Map<int, int> values;
  @override
  int? value(int address, int index) => values[address << 8 | index];
  @override
  int valueOr(int address, int index, int fallback) =>
      value(address, index) ?? fallback;
  @override
  Future<void> requestPresetNames() async {}
}

void main() {
  late AppLanguage previous;
  setUp(() async {
    previous = AppLang.instance.language;
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
  });
  tearDown(() => AppLang.instance.language = previous);

  void containedText(WidgetTester tester, Finder tile, String reason) {
    final bounds = tester.getRect(tile).inflate(0.1);
    for (final element
        in find.descendant(of: tile, matching: find.byType(Text)).evaluate()) {
      final text = element.widget as Text;
      final box = element.findRenderObject()! as RenderBox;
      final rect = MatrixUtils.transformRect(
        box.getTransformTo(null),
        Offset.zero & box.size,
      );
      expect(
        bounds.contains(rect.topLeft) && bounds.contains(rect.bottomRight),
        isTrue,
        reason: '$reason: ${text.data} $rect outside $bounds',
      );
      expect(text.overflow, isNot(TextOverflow.ellipsis), reason: reason);
      final paragraph = find.descendant(
        of: find.byWidget(text),
        matching: find.byType(RichText),
      );
      for (final p in paragraph.evaluate()) {
        expect(
          (p.renderObject! as RenderParagraph).didExceedMaxLines,
          isFalse,
          reason: '$reason: ${text.data}',
        );
      }
    }
  }

  for (final screen in const [
    Size(360, 740),
    Size(412, 915),
    Size(800, 1280),
    Size(1280, 800),
  ]) {
    for (final scale in [1.0, 1.3]) {
      for (final surface in ['panel', 'editor', 'preview']) {
        testWidgets('Every legal tile fits $screen scale=$scale $surface', (
          tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = screen;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final ctrl = _Controller(Adi2Variant.pro4ex);
          addTearDown(ctrl.dispose);
          for (final language in [AppLanguage.de, AppLanguage.en]) {
            AppLang.instance.language = language;
            for (final type in EasyTileType.values) {
              final tiles = [
                for (final size in EasyTileSize.values)
                  for (final height in [0.5, 1.0, 1.5, 2.0])
                    if (EasyTile.supportsShape(type, size, height))
                      EasyTile.defaults(type).withShape(size, height),
              ];
              final layout = EasyLayout(tiles: tiles);
              await tester.pumpWidget(
                MaterialApp(
                  theme: buildTheme(),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: surface == 'preview'
                        ? SingleChildScrollView(
                            child: SizedBox(
                              width: math.min(screen.width, 720) - 32,
                              child: EasyTileGrid(
                                layout: layout,
                                itemBuilder: (_, i) => EasyTilePreview(
                                  ctrl: ctrl,
                                  tile: tiles[i],
                                  fillPreview: true,
                                ),
                              ),
                            ),
                          )
                        : OutputsPage(
                            key: UniqueKey(),
                            ctrl: ctrl,
                            easyLayout: layout,
                            onEditTile: surface == 'editor' ? (_) {} : null,
                            onPinTile: surface == 'editor' ? (_) {} : null,
                          ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              expect(
                tester.takeException(),
                isNull,
                reason: '$screen $scale $surface $language $type',
              );
              final rendered = find.byWidgetPredicate(
                (w) =>
                    w is Material &&
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith('easy-tile-'),
              );
              expect(rendered, findsNWidgets(tiles.length));
              for (var i = 0; i < tiles.length; i++) {
                containedText(
                  tester,
                  rendered.at(i),
                  '$type ${tiles[i].size} ${tiles[i].height} $surface $language',
                );
              }
            }
          }
        });
      }
    }
  }

  testWidgets('Custom surfaces share main view shape, icon and status styles', (
    tester,
  ) async {
    final ctrl = _Controller(Adi2Variant.dac);
    addTearDown(ctrl.dispose);
    AppLang.instance.language = AppLanguage.en;
    ctrl.selectedOutput = 3;
    for (final active in [false, true]) {
      ctrl.values[3 << 8 | OutIdx.mute] = active ? 1 : 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: Row(
              children: [
                Expanded(
                  child: OutputsPage(key: UniqueKey(), ctrl: ctrl),
                ),
                Expanded(
                  child: OutputsPage(
                    key: UniqueKey(),
                    ctrl: ctrl,
                    editorOutput: 3,
                    easyLayout: EasyLayout(
                      tiles: const [
                        EasyTile(type: EasyTileType.mute),
                        EasyTile(type: EasyTileType.dim),
                        EasyTile(type: EasyTileType.lock),
                        EasyTile(
                          type: EasyTileType.daFilter,
                          size: EasyTileSize.wide,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final custom = find.byKey(const ValueKey('easy-tile-0'));
      final mainMute = find
          .ancestor(
            of: find.byIcon(Icons.volume_off_outlined).first,
            matching: find.byType(Material),
          )
          .first;
      final actual = tester.widget<Material>(custom);
      final reference = tester.widget<Material>(mainMute);
      expect(actual.shape, reference.shape);
      expect(actual.color, reference.color);
      final status = tester.widget<Text>(
        find.descendant(of: custom, matching: find.text(active ? 'On' : 'Off')),
      );
      final context = tester.element(custom);
      expect(status.style!.fontSize, greaterThanOrEqualTo(12));
      expect(
        status.style!.fontWeight!.value,
        greaterThanOrEqualTo(FontWeight.w600.value),
      );
      expect(status.style!.color, active ? Palette.red : Palette.text);
      expect(status.style!.fontFamily, buttonStatusStyle(context).fontFamily);
      expect(
        find.descendant(of: custom, matching: find.byIcon(Icons.more_horiz)),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.brightness_low_outlined), findsWidgets);
      expect(find.byIcon(Icons.lock_open), findsWidgets);
      expect(find.byIcon(Icons.filter_alt_outlined), findsWidgets);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('DAC reference values and live slot previews fit at 1.3', (
    tester,
  ) async {
    final ctrl = _Controller(Adi2Variant.dac);
    addTearDown(ctrl.dispose);
    for (final output in [3, 9]) {
      for (final size in EasyTileSize.values) {
        for (final height in [0.5, 1.0, 1.5, 2.0]) {
          if (!EasyTile.supportsShape(EasyTileType.refLevel, size, height)) {
            continue;
          }
          await tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(1.3)),
                child: child!,
              ),
              home: Scaffold(
                body: OutputsPage(
                  key: UniqueKey(),
                  ctrl: ctrl,
                  editorOutput: output,
                  easyLayout: EasyLayout(
                    tiles: [
                      EasyTile(
                        type: EasyTileType.refLevel,
                        size: size,
                        height: height,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          containedText(
            tester,
            find.byKey(const ValueKey('easy-tile-0')),
            'DAC $output $size $height',
          );
          expect(tester.takeException(), isNull);
        }
      }
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 80,
            child: EasySlotPreview(
              index: 0,
              layout: EasyLayout.defaults(ctrl.variant),
              ctrl: ctrl,
              output: 3,
              name: 'Ein besonders langer gespeicherter Name',
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(EasyTilePreview), findsNWidgets(13));
    expect(tester.takeException(), isNull);
  });
}
