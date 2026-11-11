import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/analyzer/header_content.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/eq/eq_model.dart';
import 'package:adi2_remote/easy/easy_layout.dart';
import 'package:adi2_remote/ui/easy_mode_editor.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/protocol/adi2_status.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:adi2_remote/ui/easy_tile_grid.dart';
import 'package:adi2_remote/ui/eq_display_mode.dart';
import 'package:adi2_remote/ui/eq_page.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/outputs_page.dart';
import 'package:adi2_remote/ui/player_bar.dart';
import 'package:adi2_remote/ui/responsive_layout.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:adi2_remote/ui/volume_ring.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Controller extends Adi2Controller {
  _Controller(this.variant) : values = offlineDefaults(variant) {
    state = ConnState.connected;
    // Connected PCM device, AES and optical SPDIF locked/synchronous at 48k,
    // 24-bit inputs and Phones 3/4 active. Pro models render all four rows.
    final raw = List.filled(24, 0);
    raw[0] = 2;
    final io1 = 0x1f | (2 << 8) | (2 << 12) | (2 << 16);
    final io2 = (1 << 8) | (1 << 9) | (1 << 10);
    for (var byte = 0; byte < 4; byte++) {
      raw[1 + byte] = (io1 >> (7 * byte)) & 0x7f;
      raw[5 + byte] = (io2 >> (7 * byte)) & 0x7f;
    }
    status = Adi2Status(raw);
    values[Adi2Addr.device << 8 | DevIdx.sampleRate] = 1;
    if (!variant.isDac) values[Adi2Addr.device << 8 | 8] = 1;
  }

  @override
  final Adi2Variant variant;
  final Map<int, int> values;
  final eqWrites = <(int, int, int)>[];

  @override
  int? value(int address, int index) => values[address << 8 | index];
  @override
  int valueOr(int address, int index, int fallback) =>
      value(address, index) ?? fallback;
  @override
  int? eqValue(int address, int index) => value(address, index);
  @override
  void set(int address, int index, int raw) {
    values[address << 8 | index] = raw;
    notifyListeners();
  }

  @override
  void setEq(int address, int index, int raw) {
    eqWrites.add((address, index, raw));
    set(address, index, raw);
  }
}

void main() {
  late _Controller ctrl;
  late NowPlaying np;
  late AppLanguage previousLanguage;
  final platformCalls = <MethodCall>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
    previousLanguage = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    ctrl = _Controller(Adi2Variant.pro4ex);
    np = NowPlaying();
    platformCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
  });

  tearDown(() {
    ctrl.dispose();
    np.dispose();
    EqDisplayMode.setTablet(false);
    AppLang.instance.language = previousLanguage;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> prepare(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        builder: (context, child) => TabletOrientation(child: child!),
        home: HomePage(ctrl: ctrl, np: np),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder railLabel(String text) => find.descendant(
    of: find.byType(NavigationRail),
    matching: find.text(text),
  );

  for (final size in [const Size(600, 960), const Size(960, 600)]) {
    testWidgets('Tablet-Hinweise verschieben keine Bedienelemente $size', (
      tester,
    ) async {
      ctrl.dispose();
      ctrl = _Controller(Adi2Variant.dac)..selectedOutput = Adi2Addr.line;
      const address = Adi2Addr.line;
      ctrl.set(Adi2Addr.device, 1, 0);
      ctrl.set(address, OutIdx.volume, -300);
      await prepare(tester, size);
      final keys = [
        'output-volume-buttons',
        'output-lock',
        'output-link',
        'output-function-keys',
        'output-tiles',
        'output-ring-area',
      ];
      final original = {
        for (final key in keys) key: tester.getRect(find.byKey(ValueKey(key))),
      };
      final overlay = find.byKey(const ValueKey('output-hint-overlay'));
      expect(overlay, findsNothing);

      Future<void> checkHint(String text) async {
        await tester.pumpAndSettle();
        expect(overlay, findsOneWidget);
        expect(tester.widget<Text>(overlay).data, contains(text));
        for (final key in keys) {
          expect(tester.getRect(find.byKey(ValueKey(key))), original[key]);
        }
        final hintRect = tester.getRect(overlay);
        expect(
          original['output-ring-area']!.contains(hintRect.topLeft),
          isTrue,
        );
        expect(
          hintRect.bottom,
          lessThanOrEqualTo(original['output-lock']!.top),
        );
        final controls = find.descendant(
          of: find.byType(OutputsPage),
          matching: find.byType(InkWell),
        );
        for (final control in controls.evaluate()) {
          expect(
            hintRect.overlaps(tester.getRect(find.byWidget(control.widget))),
            isFalse,
          );
        }
        final level = find.descendant(
          of: find.byType(VolumeRing),
          matching: find.byWidgetPredicate(
            (w) => w is Text && (w.data?.contains('dBu') ?? false),
          ),
        );
        for (final text in level.evaluate()) {
          final box = tester.renderObject<RenderBox>(
            find.byWidget(text.widget),
          );
          final levelRect = MatrixUtils.transformRect(
            box.getTransformTo(null),
            Offset.zero & box.size,
          );
          expect(
            hintRect.overlaps(levelRect),
            isFalse,
            reason: '$text: $levelRect overlaps $hintRect',
          );
        }
        expect(tester.takeException(), isNull);
      }

      final plus = find.descendant(
        of: find.byKey(const ValueKey('output-volume-buttons')),
        matching: find.byIcon(Icons.add),
      );
      final gesture = await tester.startGesture(tester.getCenter(plus));
      await tester.pump(const Duration(milliseconds: 600));
      await checkHint('Wird langsam lauter');
      await gesture.up();
      await tester.pumpAndSettle();
      expect(overlay, findsNothing);

      ctrl.setVolume(address, -100);
      await checkHint('wird langsam angehoben');
      ctrl.stopVolumeRamp(address);
      ctrl.volGuard.setLimit(address, -300);
      ctrl.setVolume(address, -200);
      await checkHint('Obergrenze erreicht');
      ctrl.setVolume(address, -300);
      ctrl.set(address, OutIdx.lockVolume, 1);
      await checkHint('Lautstärke am Gerät gesperrt');
      ctrl.set(address, OutIdx.lockVolume, 0);
      ctrl.opts.linked.addAll([address, Adi2Addr.ph12]);
      ctrl.set(address, OutIdx.volume, -300);
      await checkHint('Gekoppelt mit');
      ctrl.opts.linked.clear();
      ctrl.set(Adi2Addr.device, 1, 1);
      await checkHint('Stumm: Kopfhörer eingesteckt');
      ctrl.set(Adi2Addr.device, 1, 0);
      await tester.pumpAndSettle();
      expect(overlay, findsNothing);
      for (final key in keys) {
        expect(tester.getRect(find.byKey(ValueKey(key))), original[key]);
      }
    });
  }

  for (final size in [const Size(360, 740), const Size(411, 914)]) {
    testWidgets('Handy bleibt einspaltig bei $size', (tester) async {
      await prepare(tester, size);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byKey(const ValueKey('tablet-extra-area')), findsNothing);
      expect(tester.getSize(find.byType(PlayerBar)).height, playerSlotHeight);
      final ring = tester.getSize(find.byType(VolumeRing));
      expect(ring.width, lessThanOrEqualTo(300));
      final switchRect = tester.getRect(find.byType(OutputSwitch));
      expect(switchRect.left, 20);
      expect(switchRect.width, size.width - 40);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Tablet-Hochformat 600×960 vergrößert die Hauptansicht', (
    tester,
  ) async {
    await prepare(tester, const Size(600, 960));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byKey(const ValueKey('tablet-output-columns')), findsNothing);
    expect(tester.getSize(find.byType(PlayerBar)).height, lessThan(150));
    final ring = find.descendant(
      of: find.byType(VolumeRing),
      matching: find.byType(CustomPaint),
    );
    expect(tester.getSize(ring).width, greaterThan(200));
    expect(tester.getSize(ring).width, lessThanOrEqualTo(420));
    expect(
      find.descendant(
        of: find.byType(OutputsPage),
        matching: find.byType(Scrollable),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Breites Hochformat zentriert Inhalt auf 720 dp', (tester) async {
    await prepare(tester, const Size(900, 1200));
    final rect = tester.getRect(find.byType(OutputsPage));
    expect(rect.width, tabletContentWidth);
    expect(rect.center.dx, 450);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(600, 960),
    const Size(960, 600),
    const Size(800, 1280),
    const Size(1280, 800),
  ]) {
    for (final variant in Adi2Variant.values) {
      for (final header in [HeaderContent.player, HeaderContent.status]) {
        testWidgets('Alle Hauptbedienelemente sichtbar $size $variant $header', (
          tester,
        ) async {
          ctrl.dispose();
          ctrl = _Controller(variant);
          AppLang.instance.language = header == HeaderContent.status
              ? AppLanguage.en
              : AppLanguage.de;
          await AppSettings.instance.setHeaderContent(header);
          // Android status bar and three-button navigation, in logical pixels.
          tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
          tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 48);
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewPadding);
          await prepare(tester, size);
          final portrait = size.height > size.width;
          final output = find.byType(OutputsPage);
          final page = tester.getRect(output);
          final bottom = portrait
              ? tester.getRect(find.byType(NavigationBar)).top
              : size.height - 48;
          expect(page.bottom, lessThanOrEqualTo(bottom));
          expect(page.top, greaterThanOrEqualTo(24));
          expect(
            find.descendant(of: output, matching: find.byType(Scrollable)),
            findsNothing,
          );

          void visible(Finder finder) {
            final rect = tester.getRect(finder);
            expect(rect.left, greaterThanOrEqualTo(page.left));
            expect(rect.right, lessThanOrEqualTo(page.right));
            expect(rect.top, greaterThanOrEqualTo(page.top));
            expect(rect.bottom, lessThanOrEqualTo(page.bottom));
            expect(rect.bottom, lessThanOrEqualTo(bottom));
          }

          if (portrait) {
            final status = find.byKey(const ValueKey('digital-mini'));
            expect(status, findsOneWidget);
            expect(
              find.descendant(of: status, matching: find.text('USB')),
              findsOneWidget,
            );
            expect(
              find.descendant(of: status, matching: find.text('AES')),
              variant.isDac ? findsNothing : findsOneWidget,
            );
            expect(tester.getSize(status).height, lessThan(150));
            expect(
              find.descendant(of: status, matching: find.byType(Row)),
              findsNWidgets(variant.isDac ? 4 : 5),
            );
            final statusRect = tester.getRect(status);
            expect(statusRect.bottom, lessThanOrEqualTo(page.top));
            for (final text
                in find
                    .descendant(of: status, matching: find.byType(Text))
                    .evaluate()) {
              final rect = tester.getRect(find.byWidget(text.widget));
              expect(rect.top, greaterThanOrEqualTo(statusRect.top));
              expect(rect.bottom, lessThanOrEqualTo(statusRect.bottom - 8));
            }
          }
          final controls = find.descendant(
            of: output,
            matching: find.byWidgetPredicate(
              (w) => w is InkWell && (w.onTap != null || w.onLongPress != null),
            ),
          );
          expect(controls, findsWidgets);
          final switcher = find.byType(OutputSwitch);
          final switches = find.descendant(
            of: switcher,
            matching: find.byType(GestureDetector),
          );
          expect(switches, findsNWidgets(outputsFor(variant).length));
          for (final outputInfo in outputsFor(variant)) {
            await tester.tap(
              find.descendant(
                of: switcher,
                matching: find.text(outputInfo.name),
              ),
            );
            await tester.pumpAndSettle();
            for (final control in [
              ...controls.evaluate(),
              ...switches.evaluate(),
            ]) {
              final finder = find.byWidget(control.widget);
              visible(finder);
              final rect = tester.getRect(finder);
              expect(rect.width, greaterThanOrEqualTo(48));
              expect(rect.height, greaterThanOrEqualTo(48));
              expect(finder.hitTestable(), findsOneWidget);
            }
            for (final key in ['output-function-keys', 'output-tiles']) {
              visible(find.byKey(ValueKey(key)));
            }
            final ring = find.descendant(
              of: find.byType(VolumeRing),
              matching: find.byType(CustomPaint),
            );
            visible(ring);
            expect(tester.getSize(ring).width, greaterThan(100));
            expect(tester.takeException(), isNull);
          }
          // A live hint floats above the controls in either orientation.
          final selected = tester.widget<OutputSwitch>(switcher).selected;
          ctrl.set(selected, OutIdx.lockVolume, 1);
          await tester.pumpAndSettle();
          visible(find.byKey(const ValueKey('output-tiles')));
          for (final key in ['Bass-minus', 'Treble-minus']) {
            final finder = find.byKey(ValueKey(key));
            visible(finder);
            expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
            expect(finder.hitTestable(), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('Tablet-Querformat mit vollständigem EQ folgt dem Ausgang', (
    tester,
  ) async {
    await prepare(tester, const Size(960, 600));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(const ValueKey('tablet-output-columns')), findsOneWidget);
    final outputRect = tester.getRect(find.byType(OutputsPage));
    final eqRect = tester.getRect(find.byType(EqPage));
    expect(eqRect.left, greaterThan(outputRect.right));
    expect(tester.widget<EqPage>(find.byType(EqPage)).embedded, isTrue);
    expect(find.byType(EqPlot), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) => widget is EqPlot && widget.fullscreen),
      findsNothing,
    );
    await tester.tap(
      find.descendant(
        of: find.byType(OutputSwitch),
        matching: find.text('Line Out'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<EqPage>(find.byType(EqPage)).channelAddr,
      Adi2Addr.line,
    );
    final controls = find.byType(EqBandControls);
    // Scroll at the list edge so the gesture does not drag an EQ point.
    await tester.dragFrom(
      Offset(eqRect.right - 4, eqRect.center.dy),
      const Offset(0, -450),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(controls);
    await tester.pumpAndSettle();
    expect(ctrl.eqWrites, isEmpty);
    final slider = find
        .descendant(of: controls, matching: find.byType(Slider))
        .first;
    tester.widget<Slider>(slider).onChanged!(0.25);
    await tester.pumpAndSettle();
    expect(ctrl.eqWrites.last.$1, Adi2Addr.line + 1);
    expect(ctrl.eqWrites.last.$2, eqBands.first.gainIdx);
    expect(tester.takeException(), isNull);
  });

  for (final variant in Adi2Variant.values) {
    testWidgets('Tablet ${variant.name}: Englisch und Systemleisten', (
      tester,
    ) async {
      ctrl.dispose();
      ctrl = _Controller(variant);
      AppLang.instance.language = AppLanguage.en;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await prepare(tester, const Size(600, 960));
      expect(find.byType(NavigationRail), findsNothing);
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(960, 600);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      for (final output in outputsFor(variant)) {
        if (!variant.isDac && output.address == Adi2Addr.ph12) continue;
        await tester.tap(
          find.descendant(
            of: find.byType(OutputSwitch),
            matching: find.text(output.name),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<EqPage>(find.byType(EqPage)).channelAddr,
          output.address,
        );
        expect(tester.takeException(), isNull);
      }
      for (final label in [
        if (variant.hasInput) tr('Eingang'),
        tr('Gerät'),
        tr('Setups'),
        tr('Status'),
      ]) {
        await tester.tap(railLabel(label));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('tablet-page-columns')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull, reason: label);
      }
    });
  }

  testWidgets('Zusatzbereich speichert Auswahl über Tabs, Rotation und Laden', (
    tester,
  ) async {
    await prepare(tester, const Size(960, 600));
    for (final selection in TabletExtraContent.values) {
      await tester.tap(find.byKey(ValueKey('tablet-extra-${selection.name}')));
      await tester.pumpAndSettle();
      expect(AppSettings.instance.tabletExtraContent, selection);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('tablet_extra_content'), selection.name);
      expect(tester.takeException(), isNull);
    }
    await tester.tap(railLabel('Gerät'));
    await tester.pumpAndSettle();
    await tester.tap(railLabel('Ausgänge'));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerBar), findsOneWidget);
    tester.view.physicalSize = const Size(600, 960);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(960, 600);
    await tester.pumpAndSettle();
    expect(AppSettings.instance.tabletExtraContent, TabletExtraContent.player);
    AppSettings.instance.tabletExtraContent = TabletExtraContent.eq;
    await AppSettings.instance.load();
    await tester.pumpAndSettle();
    expect(AppSettings.instance.tabletExtraContent, TabletExtraContent.player);
    expect(find.text('Kein Player aktiv'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Analyzer bleibt groß im Zusatzbereich beim Drehen', (
    tester,
  ) async {
    await AppSettings.instance.setTabletExtraContent(
      TabletExtraContent.analyzer,
    );
    await prepare(tester, const Size(600, 960));
    tester.view.physicalSize = const Size(960, 600);
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnalyzerPanel>(find.byType(AnalyzerPanel)).expanded,
      isTrue,
    );
    expect(tester.getSize(find.byType(AnalyzerPanel)).height, greaterThan(300));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byKey(const ValueKey('tablet-extra-area')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Tablet-Seiten nutzen zwei Spalten ohne Overflow', (
    tester,
  ) async {
    await prepare(tester, const Size(960, 600));
    for (final label in ['Eingang', 'Gerät', 'Setups', 'Status']) {
      await tester.tap(railLabel(label));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tablet-page-columns')), findsOneWidget);
      final lists = find.byType(ListView);
      expect(lists, findsNWidgets(2));
      final left = tester.getRect(lists.first);
      final right = tester.getRect(lists.last);
      expect(left.right, lessThanOrEqualTo(right.left));
      for (final list in [lists.first, lists.last]) {
        await tester.drag(list, const Offset(0, -2000));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: label);
      }
    }
  });

  for (final size in [const Size(960, 600), const Size(1280, 800)]) {
    testWidgets('Custom: zwei Spalten und begrenzte Kacheln $size', (
      tester,
    ) async {
      await AppSettings.instance.setEasyMode(true);
      final layout = EasyLayout.defaults(ctrl.variant)
          .withHeaderContent(HeaderContent.none);
      await AppSettings.instance.setEasyLayout(ctrl.variant, layout);
      await prepare(tester, size);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(
        find.byKey(const ValueKey('tablet-output-columns')),
        findsOneWidget,
      );
      final right = tester.getRect(
        find.byKey(const ValueKey('tablet-extra-area')),
      );
      final left = tester.getRect(find.byType(OutputsPage));
      expect(left.right, lessThanOrEqualTo(right.left));
      expect(left.width, closeTo(right.width, 0.01));
      final grid = tester.getRect(find.byType(EasyTileGrid));
      expect(grid.width, closeTo(left.width - 32, 0.01));
      for (var index = 0; index < layout.tiles.length; index++) {
        final tile = tester.getRect(find.byKey(ValueKey('easy-tile-$index')));
        expect(tile.width, lessThanOrEqualTo(left.width));
        expect(tile.left, greaterThanOrEqualTo(grid.left));
        expect(tile.right, lessThanOrEqualTo(grid.right + 0.01));
        expect(tile.top, greaterThanOrEqualTo(left.top));
        expect(tile.bottom, lessThanOrEqualTo(left.bottom));
        expect(tile.height, greaterThanOrEqualTo(44));
      }
      for (final element
          in find
              .descendant(
                of: find.byType(EasyTileGrid),
                matching: find.byType(Icon),
              )
              .evaluate()) {
        final icon = element.widget as Icon;
        expect(icon.size ?? IconTheme.of(element).size!, lessThanOrEqualTo(36));
      }
      for (final element
          in find
              .descendant(
                of: find.byType(EasyTileGrid),
                matching: find.byType(Text),
              )
              .evaluate()) {
        final text = element.widget as Text;
        expect(text.style?.fontSize ?? 14, lessThanOrEqualTo(57));
      }
      for (final element
          in find
              .descendant(
                of: find.byType(EasyTileGrid),
                matching: find.byType(FittedBox),
              )
              .evaluate()) {
        expect((element.widget as FittedBox).fit, BoxFit.scaleDown);
      }
      final scrollable = find
          .descendant(
            of: find.byKey(const ValueKey('easy-panel')),
            matching: find.byType(Scrollable),
          )
          .first;
      expect(
        tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
        0,
      );
      await tester.tap(
        find.byKey(const ValueKey('easy-segment-0-${Adi2Addr.line}')),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<EqPage>(find.byType(EqPage)).channelAddr,
        Adi2Addr.line,
      );
      for (final selection in TabletExtraContent.values) {
        await tester.tap(
          find.byKey(ValueKey('tablet-extra-${selection.name}')),
        );
        await tester.pumpAndSettle();
        expect(AppSettings.instance.tabletExtraContent, selection);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byKey(const ValueKey('easy-switch')));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerBar), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('easy-switch')));
      await tester.pumpAndSettle();
      expect(
        AppSettings.instance.tabletExtraContent,
        TabletExtraContent.player,
      );
      await AppSettings.instance.load();
      await tester.pumpAndSettle();
      expect(
        AppSettings.instance.tabletExtraContent,
        TabletExtraContent.player,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Custom: Editor-Vorschau hat Bedienfeldbreite $size', (
      tester,
    ) async {
      await AppSettings.instance.setEasyMode(true);
      await prepare(tester, size);
      final panelWidth = tester.getSize(find.byType(OutputsPage)).width;
      final gridWidth = tester.getSize(find.byType(EasyTileGrid)).width;
      final context = tester.element(find.byType(OutputsPage));
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => EasyModeEditor(ctrl: ctrl)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(OutputsPage));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(OutputsPage)).width, panelWidth);
      expect(tester.getSize(find.byType(EasyTileGrid)).width, gridWidth);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Custom: lange Layouts bleiben senkrecht scrollbar $size', (
      tester,
    ) async {
      await AppSettings.instance.setEasyMode(true);
      await AppSettings.instance.setEasyLayout(
        ctrl.variant,
        EasyLayout(
          showPlayer: false,
          showStatus: false,
          tiles: List.generate(
            60,
            (_) => const EasyTile(type: EasyTileType.mute),
          ),
        ),
      );
      await prepare(tester, size);
      final scrollable = find
          .descendant(
            of: find.byKey(const ValueKey('easy-panel')),
            matching: find.byType(Scrollable),
          )
          .first;
      final state = tester.state<ScrollableState>(scrollable);
      expect(state.position.maxScrollExtent, greaterThan(0));
      expect(state.axisDirection, AxisDirection.down);
      state.position.jumpTo(state.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final panel = tester.getRect(find.byType(OutputsPage));
      final last = tester.getRect(find.byKey(const ValueKey('easy-tile-59')));
      expect(last.bottom, lessThanOrEqualTo(panel.bottom));
      expect(last.top, greaterThanOrEqualTo(panel.top));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Custom: Player und Status folgen den Layoutoptionen $size', (
      tester,
    ) async {
      np.supported = true;
      np.access = true;
      np.info = const NowPlayingInfo(title: 'Testtitel', artist: 'Interpret');
      await AppSettings.instance.setEasyMode(true);
      await prepare(tester, size);
      for (final header in [
        HeaderContent.none,
        HeaderContent.status,
        HeaderContent.player,
      ]) {
        await AppSettings.instance.setEasyLayout(
          ctrl.variant,
          EasyLayout.defaults(ctrl.variant).withHeaderContent(header),
        );
        await tester.pumpAndSettle();
        final columns = tester.widget<Row>(
          find.byKey(const ValueKey('tablet-output-columns')),
        );
        final left = find.byWidget(columns.children.first);
        expect(
          find.descendant(of: left, matching: find.byType(PlayerBar)),
          header == HeaderContent.player ? findsOneWidget : findsNothing,
        );
        expect(
          find.descendant(
            of: left,
            matching: find.byKey(const ValueKey('digital-mini')),
          ),
          header == HeaderContent.status ? findsOneWidget : findsNothing,
        );
        if (header == HeaderContent.player && size.height == 800) {
          final scrollable = find
              .descendant(
                of: find.byKey(const ValueKey('easy-panel')),
                matching: find.byType(Scrollable),
              )
              .first;
          expect(
            tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
            0,
          );
          // The default grid fits the remaining height and stays at most square.
          final gridSize = tester.getSize(find.byType(EasyTileGrid));
          expect(gridSize.height, lessThanOrEqualTo(gridSize.width));
        }
        expect(tester.takeException(), isNull);
      }
      np.info = null;
      await AppSettings.instance.setEasyLayout(
        ctrl.variant,
        EasyLayout.defaults(ctrl.variant)
            .copyWith(showPlayer: true, showStatus: false),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('digital-mini')), findsNothing);
      await AppSettings.instance.setEasyLayout(
        ctrl.variant,
        EasyLayout.defaults(ctrl.variant)
            .copyWith(showPlayer: true, showStatus: true),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('digital-mini')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(600, 960), const Size(800, 1280)]) {
    testWidgets('Custom: Hochformatbreite und Ring bleiben begrenzt $size', (
      tester,
    ) async {
      await AppSettings.instance.setEasyMode(true);
      await prepare(tester, size);
      final grid = tester.getRect(find.byType(EasyTileGrid));
      expect(grid.width, lessThanOrEqualTo(tabletContentWidth - 32));
      expect(grid.center.dx, size.width / 2);
      final ring = find.descendant(
        of: find.byType(EasyTileGrid),
        matching: find.byType(VolumeRing),
      );
      final box = tester.renderObject<RenderBox>(ring);
      final rect = MatrixUtils.transformRect(
        box.getTransformTo(null),
        Offset.zero & box.size,
      );
      expect(rect.width, lessThanOrEqualTo(300));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Tablet-Rotation bleibt auch bei deaktiviertem Auto-Vollbild frei',
    (tester) async {
      await AppSettings.instance.setAutoFullscreenEq(false);
      await prepare(tester, const Size(600, 960));
      final calls = platformCalls.where(
        (c) => c.method == 'SystemChrome.setPreferredOrientations',
      );
      expect(calls.last.arguments, contains('DeviceOrientation.landscapeLeft'));
      await tester.tap(find.widgetWithText(NavigationDestination, 'Gerät'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(960, 600);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      tester.view.physicalSize = const Size(411, 914);
      await tester.pumpAndSettle();
      expect(calls.last.arguments, ['DeviceOrientation.portraitUp']);
      expect(tester.takeException(), isNull);
    },
  );

  test('Fehlende und ungültige gespeicherte Auswahl verwendet EQ', () async {
    expect(AppSettings.instance.tabletExtraContent, TabletExtraContent.eq);
    SharedPreferences.setMockInitialValues({'tablet_extra_content': 'invalid'});
    await AppSettings.instance.load();
    expect(AppSettings.instance.tabletExtraContent, TabletExtraContent.eq);
  });
}
