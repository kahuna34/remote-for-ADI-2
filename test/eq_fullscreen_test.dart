import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/eq/eq_editor_buffer.dart';
import 'package:adi2_remote/eq/eq_math.dart';
import 'package:adi2_remote/eq/eq_model.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/app_settings_page.dart';
import 'package:adi2_remote/ui/eq_page.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LiveController extends Adi2Controller {
  final values = <(int, int), int>{};
  final writes = <(int, int, int)>[];

  @override
  Adi2Variant get variant => Adi2Variant.dac;

  @override
  int? eqValue(int address, int index) => values[(address, index)];

  @override
  int valueOr(int address, int index, int fallback) =>
      values[(address, index)] ?? fallback;

  @override
  void setEq(int address, int index, int raw) {
    writes.add((address, index, raw));
    values[(address, index)] = raw;
    notifyListeners();
  }
}

Finder get _fullscreenPlot =>
    find.byWidgetPredicate((widget) => widget is EqPlot && widget.fullscreen);

Future<void> _rotate(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  await tester.pumpAndSettle();
}

Future<void> _dragBandThree(WidgetTester tester) async {
  final rect = tester.getRect(_fullscreenPlot);
  final point =
      rect.topLeft +
      Offset(
        36 + freqToX(1000) * (rect.width - 50),
        16 + (rect.height - 42) / 2,
      );
  await tester.dragFrom(point, const Offset(30, -30));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> platformCalls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppSettings.instance.autoFullscreenEq = true;
    platformCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    AppSettings.instance.autoFullscreenEq = true;
  });

  Future<void> prepare(WidgetTester tester, Widget home) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: home));
    await tester.pumpAndSettle();
  }

  Widget bufferPage(EqEditorBuffer buffer, {bool bassTreble = true}) {
    var selected = 0;
    return Scaffold(
      body: StatefulBuilder(
        builder: (context, update) => ListView(
          children: [
            EqPlot(
              read: buffer.value,
              write: (address, index, raw) =>
                  update(() => buffer.set(address, index, raw)),
              eqAddr: Adi2Addr.presetEqR,
              btAddr: Adi2Addr.presetEqL,
              selected: selected,
              enabled: true,
              includeBassTreble: bassTreble,
              onSelect: (band) => update(() => selected = band),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AppSettingsPage(),
                ),
              ),
              child: const Text('Settings'),
            ),
            const SizedBox(height: 1600),
          ],
        ),
      ),
    );
  }

  Finder controls() => find.byWidgetPredicate(
    (widget) => widget is EqBandControls && widget.compact,
  );

  Finder controlIcon(IconData icon, int parameter) => find
      .descendant(of: controls(), matching: find.byIcon(icon))
      .at(parameter);

  Finder controlSliders() =>
      find.descendant(of: controls(), matching: find.byType(Slider));

  for (final size in [const Size(914, 411), const Size(740, 360)]) {
    for (final language in AppLanguage.values) {
      testWidgets('Vollbildregler ohne Overflow bei $size $language', (
        tester,
      ) async {
        final previousLanguage = AppLang.instance.language;
        AppLang.instance.language = language;
        addTearDown(() => AppLang.instance.language = previousLanguage);
        final buffer = EqEditorBuffer();
        await prepare(tester, bufferPage(buffer));
        await _rotate(tester, size);
        for (var i = 0; i < eqBands.length; i++) {
          final band = eqBands[i];
          await tester.tap(find.text(tr(band.label)));
          await tester.pumpAndSettle();
          if (band.types.length > 1) {
            final tiles = find.byWidgetPredicate(
              (widget) => widget is EqTypeTiles && widget.compact,
            );
            expect(tiles, findsOneWidget);
            for (final type in band.types) {
              expect(
                find
                    .descendant(of: tiles, matching: find.text(tr(type.$1)))
                    .hitTestable(),
                findsOneWidget,
              );
            }
          } else {
            final label = i == 5
                ? 'Low-Shelf'
                : i == 6
                ? 'High-Shelf'
                : 'Peak';
            final fixedType = find.text(tr(label)).hitTestable();
            expect(fixedType, findsOneWidget);
            expect(
              find.ancestor(of: fixedType, matching: find.byType(InkWell)),
              findsNothing,
            );
            expect(find.byType(EqTypeTiles), findsNothing);
            final before = buffer.copy();
            await tester.tap(fixedType);
            await tester.pumpAndSettle();
            expect(buffer.left, before.left);
            expect(buffer.right, before.right);
          }
          expect(controlSliders(), findsNWidgets(3));
          for (final label in ['Gain', 'Freq', 'Q']) {
            expect(find.text(tr(label)).hitTestable(), findsOneWidget);
          }
          final sliders = controlSliders();
          expect(
            tester.getCenter(sliders.at(0)).dy,
            tester.getCenter(sliders.at(2)).dy,
          );
          expect(
            tester.getBottomRight(controls()).dy,
            lessThanOrEqualTo(tester.getTopLeft(_fullscreenPlot).dy),
          );
          expect(tester.getSize(_fullscreenPlot).height, greaterThan(250));
          expect(
            tester.getBottomRight(_fullscreenPlot).dy,
            lessThanOrEqualTo(size.height),
          );
          expect(tester.takeException(), isNull);
        }
      });
    }
  }

  for (final live in [false, true]) {
    testWidgets('Vollbildregler schreiben alle Bänder korrekt, live=$live', (
      tester,
    ) async {
      final buffer = EqEditorBuffer();
      final controller = _LiveController();
      addTearDown(controller.dispose);
      controller.values[(Adi2Addr.line, OutIdx.dualEq)] = 1;
      await prepare(
        tester,
        live
            ? EqPage(
                ctrl: controller,
                channelAddr: Adi2Addr.line,
                title: 'Line',
              )
            : bufferPage(buffer),
      );
      if (live) {
        await tester.tap(find.text(tr('Rechts')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip(tr('Vollbild')));
      await tester.pumpAndSettle();
      await _rotate(tester, const Size(740, 360));
      for (var i = 0; i < eqBands.length; i++) {
        final band = eqBands[i];
        await tester.tap(find.text(tr(band.label)));
        await tester.pumpAndSettle();
        final address = live
            ? (band.isBassTreble ? Adi2Addr.lineEqL : Adi2Addr.lineEqR)
            : (band.isBassTreble ? Adi2Addr.presetEqL : Adi2Addr.presetEqR);
        final indices = [band.gainIdx, band.freqIdx, band.qIdx];
        final defaults = [0, band.defF, (band.defQ * 10).round()];
        final incremented = [1, stepFreq(band, band.defF, 1), defaults[2] + 1];
        final read = live ? controller.eqValue : buffer.value;
        for (var parameter = 0; parameter < 3; parameter++) {
          await tester.tap(controlIcon(Icons.add, parameter));
          await tester.pumpAndSettle();
          expect(read(address, indices[parameter]), incremented[parameter]);
          if (live) {
            expect(controller.writes.last, (
              address,
              indices[parameter],
              incremented[parameter],
            ));
          }
          await tester.tap(controlIcon(Icons.remove, parameter));
          await tester.pumpAndSettle();
          final decremented = parameter == 1
              ? stepFreq(band, incremented[parameter], -1)
              : defaults[parameter];
          expect(read(address, indices[parameter]), decremented);
          // Slider mapping uses the same bounds and logarithmic frequency grid.
          tester.widget<Slider>(controlSliders().at(parameter)).onChanged!(1);
          await tester.pumpAndSettle();
          final maximum = [eqGainMaxRaw, band.maxF, (band.maxQ * 10).round()];
          expect(read(address, indices[parameter]), maximum[parameter]);
          final graph = tester.widget<EqPlot>(_fullscreenPlot);
          expect(graph.read(address, indices[parameter]), maximum[parameter]);
        }
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final live in [false, true]) {
    testWidgets('Vollbildtypen schreiben typeIdx, live=$live', (tester) async {
      final buffer = EqEditorBuffer();
      final controller = _LiveController();
      addTearDown(controller.dispose);
      controller.values[(Adi2Addr.line, OutIdx.dualEq)] = 1;
      await prepare(
        tester,
        live
            ? EqPage(
                ctrl: controller,
                channelAddr: Adi2Addr.line,
                title: 'Line',
              )
            : bufferPage(buffer),
      );
      if (live) {
        await tester.tap(find.text(tr('Rechts')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip(tr('Vollbild')));
      await tester.pumpAndSettle();
      await _rotate(tester, const Size(740, 360));
      final address = live ? Adi2Addr.lineEqR : Adi2Addr.presetEqR;
      final read = live ? controller.eqValue : buffer.value;
      for (final bandIndex in [0, 4]) {
        final band = eqBands[bandIndex];
        await tester.tap(find.text(tr(band.label)));
        await tester.pumpAndSettle();
        for (final type in [
          ...List.generate(band.types.length - 2, (i) => i + 2),
          0,
          1,
        ]) {
          final tiles = find.byWidgetPredicate(
            (widget) => widget is EqTypeTiles && widget.compact,
          );
          await tester.tap(
            find.descendant(
              of: tiles,
              matching: find.text(tr(band.types[type].$1)),
            ),
          );
          await tester.pumpAndSettle();
          expect(read(address, band.typeIdx!), type);
          if (live) {
            expect(controller.writes.last, (address, band.typeIdx!, type));
          }
          expect(tester.widget<EqTypeTiles>(tiles).value, type);
          final graph = tester.widget<EqPlot>(_fullscreenPlot);
          expect(graph.read(address, band.typeIdx!), type);
          final hasGain =
              band.types[type].$2 != FilterKind.highPass &&
              band.types[type].$2 != FilterKind.lowPass;
          expect(
            tester.widget<Slider>(controlSliders().first).onChanged,
            hasGain ? isNotNull : isNull,
          );
          expect(tester.takeException(), isNull);
        }
      }
      if (live) {
        controller.setEq(address, eqBands[4].typeIdx!, 1);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<EqTypeTiles>(
                find.byWidgetPredicate(
                  (widget) => widget is EqTypeTiles && widget.compact,
                ),
              )
              .value,
          1,
        );
      }
    });
  }

  testWidgets('Hoch- und Tiefpass behalten deaktivierte Gain-Gruppe', (
    tester,
  ) async {
    final buffer = EqEditorBuffer();
    await prepare(tester, bufferPage(buffer));
    await _rotate(tester, const Size(740, 360));
    final initialSize = tester.getSize(controls());
    for (final (bandIndex, type) in [(0, 2), (0, 3), (4, 2)]) {
      final band = eqBands[bandIndex];
      buffer.set(Adi2Addr.presetEqR, band.typeIdx!, type);
      await tester.tap(find.text(band.label));
      await tester.pumpAndSettle();
      expect(tester.getSize(controls()), initialSize);
      expect(tester.widget<Slider>(controlSliders().first).onChanged, isNull);
      expect(
        tester.widget<Slider>(controlSliders().at(1)).onChanged,
        isNotNull,
      );
      expect(
        tester.widget<Slider>(controlSliders().at(2)).onChanged,
        isNotNull,
      );
      await tester.tap(controlIcon(Icons.add, 0));
      await tester.tap(controlIcon(Icons.remove, 0));
      await tester.pumpAndSettle();
      expect(buffer.value(Adi2Addr.presetEqR, band.gainIdx), 0);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('EqPage übernimmt die Kurvenoption ins Vollbild und zurück', (
    tester,
  ) async {
    final controller = _LiveController();
    addTearDown(controller.dispose);
    await prepare(
      tester,
      EqPage(ctrl: controller, channelAddr: Adi2Addr.line, title: 'Line'),
    );
    final curveSwitch = find.descendant(
      of: find.byType(EqCurveControls),
      matching: find.byType(Switch),
    );
    await tester.scrollUntilVisible(curveSwitch, 150);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(curveSwitch).value, isTrue);
    for (final include in [false, true]) {
      await tester.ensureVisible(curveSwitch);
      await tester.tap(curveSwitch);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(EqPlot));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(tr('Vollbild')));
      await tester.pumpAndSettle();
      expect(tester.widget<EqPlot>(_fullscreenPlot).includeBassTreble, include);
      await tester.tap(find.byTooltip(tr('Vollbild schließen')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<EqPlot>(find.byType(EqPlot)).includeBassTreble,
        include,
      );
      expect(tester.widget<Switch>(curveSwitch).value, include);
    }
    expect(controller.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Knopf öffnet Vollbild, Puffer und Bandwahl bleiben verbunden', (
    tester,
  ) async {
    final buffer = EqEditorBuffer();
    await prepare(tester, bufferPage(buffer, bassTreble: false));
    await tester.tap(find.byTooltip(tr('Vollbild')));
    await tester.pumpAndSettle();
    expect(_fullscreenPlot, findsOneWidget);
    expect(
      platformCalls.any(
        (call) =>
            call.method == 'SystemChrome.setPreferredOrientations' &&
            (call.arguments as List).join(',') == 'DeviceOrientation.landscapeLeft,DeviceOrientation.landscapeRight',
      ),
      isTrue,
    );
    expect(
      platformCalls.any(
        (call) =>
            call.method == 'SystemChrome.setEnabledSystemUIMode' &&
            call.arguments == 'SystemUiMode.immersiveSticky',
      ),
      isTrue,
    );

    await _rotate(tester, const Size(800, 400));
    final graph = tester.widget<EqPlot>(_fullscreenPlot);
    expect(graph.includeBassTreble, isFalse);
    expect(tester.getSize(_fullscreenPlot).height, greaterThan(280));
    await _dragBandThree(tester);
    expect(buffer.value(Adi2Addr.presetEqR, 10), greaterThan(0));
    expect(buffer.value(Adi2Addr.presetEqR, 11), greaterThan(1000));
    expect(buffer.value(Adi2Addr.presetEqL, 10), 0);
    expect(find.text(fmtQ(10)), findsOneWidget);
    expect(
      find.text(fmtGain(buffer.value(Adi2Addr.presetEqR, 10)!)),
      findsOneWidget,
    );
    expect(
      find.text(fmtFreq(buffer.value(Adi2Addr.presetEqR, 11)!)),
      findsOneWidget,
    );
    await tester.tap(find.text('5'));
    await tester.pumpAndSettle();
    expect(tester.widget<EqPlot>(_fullscreenPlot).selected, 4);

    // Manuell geöffnetes Vollbild bleibt bei Hochformat offen.
    await _rotate(tester, const Size(400, 800));
    expect(_fullscreenPlot, findsOneWidget);
    await tester.tap(find.byTooltip(tr('Vollbild schließen')));
    await tester.pumpAndSettle();
    expect(_fullscreenPlot, findsNothing);
    expect(tester.widget<EqPlot>(find.byType(EqPlot)).selected, 4);
    expect(
      platformCalls
          .lastWhere(
            (call) => call.method == 'SystemChrome.setEnabledSystemUIMode',
          )
          .arguments,
      'SystemUiMode.edgeToEdge',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Live-EQ nutzt setEq und folgt externen Änderungen', (
    tester,
  ) async {
    final controller = _LiveController();
    addTearDown(controller.dispose);
    await prepare(
      tester,
      EqPage(ctrl: controller, channelAddr: 3, title: 'Line'),
    );
    await tester.tap(find.byTooltip(tr('Vollbild')));
    await tester.pumpAndSettle();
    await _rotate(tester, const Size(800, 400));
    await _dragBandThree(tester);
    expect(
      controller.writes.any(
        (write) => write.$1 == 4 && write.$2 == 10 && write.$3 > 0,
      ),
      isTrue,
    );
    controller.setEq(4, 12, 25);
    await tester.pumpAndSettle();
    expect(find.text(fmtQ(25)), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_fullscreenPlot, findsNothing);
    expect(
      platformCalls
          .lastWhere(
            (call) => call.method == 'SystemChrome.setPreferredOrientations',
          )
          .arguments,
      ['DeviceOrientation.portraitUp'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Drehen öffnet und schließt nur automatisches Vollbild', (
    tester,
  ) async {
    await prepare(tester, bufferPage(EqEditorBuffer()));
    await _rotate(tester, const Size(800, 400));
    expect(_fullscreenPlot, findsOneWidget);
    await _rotate(tester, const Size(400, 800));
    expect(_fullscreenPlot, findsNothing);
    await _rotate(tester, const Size(800, 400));
    expect(_fullscreenPlot, findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_fullscreenPlot, findsNothing);
    await tester.pumpAndSettle();
    expect(_fullscreenPlot, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ausgeschaltete Automatik erlaubt weiterhin den Vollbildknopf', (
    tester,
  ) async {
    AppSettings.instance.autoFullscreenEq = false;
    await prepare(tester, bufferPage(EqEditorBuffer()));
    await _rotate(tester, const Size(800, 400));
    expect(_fullscreenPlot, findsNothing);
    await tester.tap(find.byTooltip(tr('Vollbild')));
    await tester.pumpAndSettle();
    expect(_fullscreenPlot, findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_fullscreenPlot, findsNothing);
  });

  testWidgets('Automatik bleibt beim Scrollen auf der EQ-Seite verfügbar', (
    tester,
  ) async {
    await prepare(tester, bufferPage(EqEditorBuffer()));
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.byTooltip(tr('Vollbild')).hitTestable(), findsNothing);
    await _rotate(tester, const Size(800, 400));
    expect(_fullscreenPlot, findsOneWidget);
    await _rotate(tester, const Size(400, 800));
    expect(_fullscreenPlot, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Verdeckter EQ lässt andere Seiten im Hochformat', (
    tester,
  ) async {
    await prepare(tester, bufferPage(EqEditorBuffer()));
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(
      platformCalls
          .lastWhere(
            (call) => call.method == 'SystemChrome.setPreferredOrientations',
          )
          .arguments,
      ['DeviceOrientation.portraitUp'],
    );
    await _rotate(tester, const Size(800, 400));
    expect(_fullscreenPlot, findsNothing);
    await _rotate(tester, const Size(400, 800));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await _rotate(tester, const Size(800, 400));
    expect(_fullscreenPlot, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Entfernter Quellgraph hinterlässt keine Vollbildroute', (
    tester,
  ) async {
    var visible = true;
    late StateSetter update;
    await prepare(
      tester,
      StatefulBuilder(
        builder: (_, setState) {
          update = setState;
          return visible ? bufferPage(EqEditorBuffer()) : const Scaffold();
        },
      ),
    );
    await tester.tap(find.byTooltip(tr('Vollbild')));
    await tester.pumpAndSettle();
    update(() => visible = false);
    await tester.pumpAndSettle();
    expect(_fullscreenPlot, findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'Automatik ist standardmäßig an und wird gespeichert und geladen',
    () async {
      final settings = AppSettings.instance;
      settings.autoFullscreenEq = false;
      await settings.load();
      expect(settings.autoFullscreenEq, isTrue);
      await settings.setAutoFullscreenEq(false);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('auto_fullscreen_eq'), isFalse);
      settings.autoFullscreenEq = true;
      await settings.load();
      expect(settings.autoFullscreenEq, isFalse);
      await settings.setAutoFullscreenEq(true);
      settings.autoFullscreenEq = false;
      await settings.load();
      expect(settings.autoFullscreenEq, isTrue);
    },
  );

  testWidgets('Einstellungsschalter speichert die Automatik', (tester) async {
    await prepare(tester, const AppSettingsPage());
    final title = find.text(
      tr('EQ-Graph im Querformat automatisch im Vollbild'),
    );
    await tester.ensureVisible(title);
    await tester.pumpAndSettle();
    await tester.ensureVisible(title);
    await tester.pumpAndSettle();
    await tester.tap(title);
    await tester.pumpAndSettle();
    expect(AppSettings.instance.autoFullscreenEq, isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool('auto_fullscreen_eq'),
      isFalse,
    );
  });
}
