import 'package:adi2_remote/easy/easy_layout.dart';

import 'dart:math' as math;

import 'package:adi2_remote/app_settings.dart';

import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/eq/eq_model.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/ui/eq_page.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/volume_ring.dart';
import 'package:adi2_remote/ui/param_tile.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/outputs_page.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Controller extends Adi2Controller {
  final values = <(int, int), int>{};
  final writes = <(int, int, int)>[];
  final eqWrites = <(int, int, int)>[];
  final calls = <(String, int, int, int)>[];
  final volumeWrites = <(int, int)>[];

  @override
  Adi2Variant variant = Adi2Variant.dac;

  @override
  int? value(int address, int index) => values[(address, index)];

  @override
  int valueOr(int address, int index, int fallback) =>
      value(address, index) ?? fallback;

  @override
  void set(int address, int index, int raw) {
    calls.add(('set', address, index, raw));
    writes.add((address, index, raw));
    values[(address, index)] = raw;
    notifyListeners();
  }

  @override
  void setEq(int address, int index, int raw) {
    calls.add(('setEq', address, index, raw));
    eqWrites.add((address, index, raw));
    super.setEq(address, index, raw);
  }

  @override
  void setVolume(int address, int raw, {bool followLink = true}) {
    volumeWrites.add((address, raw));
    values[(address, OutIdx.volume)] = raw;
    notifyListeners();
  }

  @override
  Future<void> setLinked(int address, bool on) async {
    on ? opts.linked.add(address) : opts.linked.remove(address);
    notifyListeners();
  }
}

void main() {
  late _Controller controller;
  late AppLanguage previousLanguage;
  const phones = Adi2Addr.ph12;
  const line = Adi2Addr.line;

  setUp(() {
    previousLanguage = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    controller = _Controller()..selectedOutput = phones;
    for (final a in [phones, line]) {
      controller.values[(a, OutIdx.crossfeed)] = 0;
      controller.values[(a, OutIdx.refLevel)] = 0;
      controller.values[(a, OutIdx.daFilter)] = 0;
      controller.values[(a, OutIdx.lockVolume)] = 0;
      controller.values[(a, OutIdx.mute)] = 0;
      controller.values[(a, OutIdx.dim)] = 0;
      controller.values[(a, OutIdx.loudness)] = 0;
    }
  });

  tearDown(() {
    controller.dispose();
    AppLang.instance.language = previousLanguage;
  });

  for (final size in [
    const Size(360, 740),
    const Size(412, 915),
    const Size(915, 412),
    const Size(600, 960),
    const Size(960, 600),
    const Size(800, 1280),
    const Size(1280, 800),
  ]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('Output button design and spacing $size scale=$scale', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          for (final family in ['Archivo', 'ArchivoNarrow']) {
            await (FontLoader(
              family,
            )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
          }
        });
        final tablet = size.shortestSide >= 600;
        final np = NowPlaying();
        addTearDown(np.dispose);
        SharedPreferences.setMockInitialValues({});
        final settings = AppSettings.instance;
        final previous = (
          settings.easyMode,
          settings.showPlayer,
          settings.showStatus,
        );
        addTearDown(() {
          settings.easyMode = previous.$1;
          settings.showPlayer = previous.$2;
          settings.showStatus = previous.$3;
        });
        settings.easyMode = false;
        settings.showPlayer = true;
        settings.showStatus = true;
        controller.state = ConnState.connected;
        for (final entry in offlineDefaults(controller.variant).entries) {
          controller.values[(entry.key >> 8, entry.key & 255)] = entry.value;
        }
        controller.values[(phones, OutIdx.autoRef)] = 0;
        controller.opts.of(phones).recallRaw = -200;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: HomePage(ctrl: controller, np: np),
          ),
        );
        await tester.pumpAndSettle();

        Finder key(String name) => find.byKey(ValueKey(name));
        List<Material> materials(Finder parent) => tester
            .widgetList<Material>(
              find.descendant(
                of: parent,
                matching: find.byType(Material),
                matchRoot: true,
              ),
            )
            .toList();
        final upper = materials(key('output-volume-buttons'));
        final shape = upper.first.shape! as RoundedRectangleBorder;
        expect(shape.side, const BorderSide(color: Palette.line));
        for (final name in [
          'output-lock',
          'output-link',
          'Balance-tile',
          'output-ref-level',
          'output-da-filter',
          'output-function-keys',
          'output-tiles',
        ]) {
          final found = materials(key(name));
          expect(found, isNotEmpty, reason: name);
          for (final material in found) {
            expect(material.shape, shape, reason: name);
            expect(material.color, Palette.surf, reason: name);
          }
        }
        final rowHeight = tester.getSize(key('Balance-tile')).height;
        expect(rowHeight, greaterThanOrEqualTo(48));
        for (final (name, label) in [
          ('output-ref-level', 'Ref Level'),
          ('Balance-center', 'Balance'),
          ('output-da-filter', 'DA-Filter'),
        ]) {
          final parent = key(name);
          final texts = find.descendant(
            of: parent,
            matching: find.byType(Text),
          );
          expect(texts, findsNWidgets(2));
          final title = tester.widget<Text>(texts.first);
          final status = tester.widget<Text>(texts.last);
          expect(title.data, label);
          expect(title.style, buttonLabelStyle(tester.element(parent)));
          expect(
            status.style,
            buttonStatusStyle(
              tester.element(parent),
              active: name == 'Balance-center',
            ),
          );
          expect(
            tester.getRect(texts.first).bottom,
            lessThanOrEqualTo(tester.getRect(texts.last).top + .1),
          );
          expect(tester.getSize(parent).height, rowHeight);
          expect(parent.hitTestable(), findsOneWidget);
          for (final text in [texts.first, texts.last]) {
            final rect = Rect.fromPoints(
              tester.getTopLeft(text),
              tester.getBottomRight(text),
            );
            final bounds = tester.getRect(parent);
            expect(rect.left, greaterThanOrEqualTo(bounds.left - .1));
            expect(rect.right, lessThanOrEqualTo(bounds.right + .1));
            expect(rect.top, greaterThanOrEqualTo(bounds.top - .1));
            expect(rect.bottom, lessThanOrEqualTo(bounds.bottom + .1));
          }
        }
        final volume = tester.getRect(key('output-volume-buttons'));
        for (final name in ['output-lock', 'output-link']) {
          final rect = tester.getRect(key(name));
          final gap = volume.top >= rect.bottom
              ? volume.top - rect.bottom
              : name == 'output-lock'
              ? volume.left - rect.right
              : rect.left - volume.right;
          expect(gap, greaterThanOrEqualTo(8 - .01), reason: name);
        }
        final statuses = [
          ...tester
              .widgetList<Text>(
                find.descendant(
                  of: key('output-tiles'),
                  matching: find.byType(Text),
                ),
              )
              .where((text) => text.style?.fontFamily == 'ArchivoNarrow'),
          ...tester
              .widgetList<Text>(
                find.descendant(
                  of: key('output-function-keys'),
                  matching: find.byType(Text),
                ),
              )
              .where(
                (text) =>
                    text.data != 'Ag' &&
                    text.style?.fontFamily == 'ArchivoNarrow',
              ),
        ];
        expect(statuses.length, 8);
        for (final text in statuses) {
          expect(text.style!.fontSize, tablet ? 13 : 12);
          expect(text.style!.fontSize, statuses.first.style!.fontSize);
          expect(text.style!.fontWeight!.value, FontWeight.w600.value);
          expect(text.style!.color, Palette.text);
          final painter = TextPainter(
            text: TextSpan(text: text.data, style: text.style),
            textDirection: TextDirection.ltr,
            textScaler: TextScaler.linear(scale),
            maxLines: 1,
            ellipsis: '…',
          )..layout(maxWidth: tester.getSize(find.byWidget(text)).width);
          expect(painter.didExceedMaxLines, isFalse, reason: text.data);
          painter.dispose();
        }
        expect(
          tester.getTopLeft(find.text('Recall')).dy,
          lessThan(tester.getTopLeft(find.text('−20,0 dB')).dy),
        );
        final labels = [
          for (final row in ['output-function-keys', 'output-tiles'])
            ...tester
                .widgetList<Text>(
                  find.descendant(of: key(row), matching: find.byType(Text)),
                )
                .where(
                  (text) =>
                      text.data != 'Ag' && text.style?.fontFamily == 'Archivo',
                ),
        ];
        expect(labels.length, 8);
        for (final name in [
          'output-ref-level',
          'output-da-filter',
          'output-lock',
          'output-link',
          'output-volume-buttons',
          'Bass-settings',
          'Treble-settings',
        ]) {
          labels.addAll(
            tester
                .widgetList<Text>(
                  find.descendant(of: key(name), matching: find.byType(Text)),
                )
                .where((text) => text.style?.fontFamily == 'Archivo'),
          );
        }
        labels.add(tester.widget<Text>(find.text('Balance')));
        expect(labels.length, 17);
        for (final text in labels) {
          expect(text.style, labels.first.style, reason: text.data);
          expect(text.style!.fontSize, tablet ? 15 : 14);
          expect(text.style!.fontWeight, FontWeight.w600);
          expect(text.style!.color, Palette.text);
        }
        expect(tester.takeException(), isNull);
        // Active controls retain their accent while sharing border width/radius.
        controller.set(phones, OutIdx.mute, 1);
        await tester.pump();
        final mute = materials(key('output-function-keys')).first;
        final activeShape = mute.shape! as RoundedRectangleBorder;
        expect(activeShape.borderRadius, shape.borderRadius);
        expect(activeShape.side.width, shape.side.width);
        expect(activeShape.side.color, Palette.red);
        expect(
          mute.color,
          Color.alphaBlend(Palette.red.withValues(alpha: 0.14), Palette.surf),
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final custom in [false, true]) {
    for (final raw in <int?>[-1, null]) {
      testWidgets('IEM fixed Ref Level custom=$custom raw=$raw', (
        tester,
      ) async {
        controller.selectedOutput = Adi2Addr.ph34;
        if (raw == null) {
          controller.values.remove((Adi2Addr.ph34, OutIdx.refLevel));
        } else {
          controller.values[(Adi2Addr.ph34, OutIdx.refLevel)] = raw;
        }
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: Scaffold(
              body: OutputsPage(
                ctrl: controller,
                easyLayout: custom
                    ? EasyLayout(
                        tiles: const [EasyTile(type: EasyTileType.refLevel)],
                      )
                    : null,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('−3 dBu'), findsOneWidget);
        if (custom) expect(find.text('Ref Level'), findsOneWidget);
        final target = find.byKey(
          ValueKey(custom ? 'easy-tile-0' : 'output-ref-level'),
        );
        expect(
          find.descendant(
            of: target,
            matching: find.byIcon(Icons.lock_outline),
          ),
          findsOneWidget,
        );
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(find.text('Fester Pegel beim IEM-Ausgang'), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
        expect(controller.writes, isEmpty);
      });
    }
  }

  Future<void> showPage(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => OutputsPage(ctrl: controller),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void phoneScreen(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(411, 914);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
  }

  for (final variant in Adi2Variant.values) {
    for (final out in outputsFor(variant)) {
      testWidgets(
        'Letzte Ausgangseinstellung erreichbar: $variant ${out.address}',
        (tester) async {
          phoneScreen(tester);
          controller.variant = variant;
          for (final e in offlineDefaults(variant).entries) {
            controller.values[(e.key >> 8, e.key & 255)] = e.value;
          }
          await tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(),
              home: OutputSettingsPage(ctrl: controller, out: out),
            ),
          );
          await tester.pumpAndSettle();
          final scrollable = find.byType(Scrollable).first;
          await tester.fling(scrollable, const Offset(0, -3000), 3000);
          await tester.pumpAndSettle();
          final last = find.byWidgetPredicate(
            (w) => w is ParamTile && w.def.index == OutIdx.loudLowVolRef,
          );
          final plus = find.descendant(
            of: last,
            matching: find.byIcon(Icons.add),
          );
          expect(plus.hitTestable(), findsOneWidget);
          expect(
            tester.getBottomRight(last).dy,
            lessThanOrEqualTo(914 - 34 - 16),
          );
          await tester.tap(plus);
          await tester.pumpAndSettle();
          expect(controller.writes.last, (
            out.address,
            OutIdx.loudLowVolRef,
            -59,
          ));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final variant in [Adi2Variant.pro4se, Adi2Variant.pro4ex]) {
    for (final address in [Adi2Addr.line, Adi2Addr.ph34]) {
      testWidgets(
        'Rear TRS in Phones 3/4 liest und schreibt $address bei $variant',
        (tester) async {
          phoneScreen(tester);
          controller.variant = variant;
          controller.values[(address, OutIdx.rearTrsSource)] = 1;
          await tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(),
              home: OutputSettingsPage(
                ctrl: controller,
                out: outputsFor(variant).last,
              ),
            ),
          );
          await tester.pumpAndSettle();
          final rear = find.byWidgetPredicate(
            (w) => w is ParamTile && w.def.index == OutIdx.rearTrsSource,
          );
          await tester.ensureVisible(rear);
          await tester.pumpAndSettle();
          expect(tester.widget<ParamTile>(rear).address, address);
          final choices = tester.widget<ParamChoices>(
            find.descendant(of: rear, matching: find.byType(ParamChoices)),
          );
          expect(choices.selected, 1);
          await tester.tap(
            find.descendant(of: rear, matching: find.text('Line 1/2')),
          );
          await tester.pumpAndSettle();
          expect(controller.writes.last, (address, OutIdx.rearTrsSource, 0));
          controller.set(address, OutIdx.rearTrsSource, 1);
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<ParamChoices>(
                  find.descendant(
                    of: rear,
                    matching: find.byType(ParamChoices),
                  ),
                )
                .selected,
            1,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('Phones-Langdruck öffnet scrollbar sicheres Settings-Sheet', (
    tester,
  ) async {
    phoneScreen(tester);
    controller.variant = Adi2Variant.pro4se;
    for (final e in offlineDefaults(controller.variant).entries) {
      controller.values[(e.key >> 8, e.key & 255)] = e.value;
    }
    controller.selectedOutput = Adi2Addr.ph34;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: OutputsPage(ctrl: controller)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Phones 3/4').first);
    await tester.pumpAndSettle();
    final sheet = find.byType(DraggableScrollableSheet);
    expect(sheet, findsOneWidget);
    expect(tester.widget<DraggableScrollableSheet>(sheet).maxChildSize, 0.95);
    final list = find
        .descendant(of: sheet, matching: find.byType(Scrollable))
        .first;
    await tester.fling(list, const Offset(0, -1500), 3000);
    await tester.pumpAndSettle();
    final last = find.byWidgetPredicate(
      (w) => w is ParamTile && w.address == Adi2Addr.device && w.def.index == 9,
    );
    expect(last.hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(last).dy, lessThanOrEqualTo(914 - 34));
    await tester.tap(find.descendant(of: last, matching: find.text('An')));
    await tester.pumpAndSettle();
    expect(controller.writes.last, (Adi2Addr.device, 9, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Bass + nutzt setEq, aktiviert zuerst und folgt Zielwerten', (
    tester,
  ) async {
    final bass = eqBands.firstWhere((b) => b.isBassTreble);
    controller.values[(phones + 1, bass.gainIdx)] = 4;
    controller.values[(phones + 1, EqIdx2.btEnable)] = 0;
    await showPage(tester);
    final settings = find.byKey(const ValueKey('Bass-settings'));
    final opacity = find.ancestor(of: settings, matching: find.byType(Opacity));
    expect(tester.widget<Opacity>(opacity).opacity, 0.45);
    expect(find.text('+2,0 dB'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('Bass-plus')));
    await tester.pump();
    expect(controller.calls, [
      ('set', phones + 1, EqIdx2.btEnable, 1),
      ('setEq', phones + 1, bass.gainIdx, 5),
    ]);
    expect(find.text('+2,5 dB'), findsOneWidget);
    expect(tester.widget<Opacity>(opacity).opacity, 1);
    await tester.tap(find.byKey(const ValueKey('Bass-plus')));
    await tester.pump();
    expect(controller.eqWrites.last, (phones + 1, bass.gainIdx, 6));
    expect(controller.writes, [(phones + 1, EqIdx2.btEnable, 1)]);
  });

  testWidgets('Bass und Treble beachten Gain-Grenzen', (tester) async {
    await showPage(tester);
    for (final band in eqBands.where((b) => b.isBassTreble)) {
      controller.setEq(phones + 1, band.gainIdx, eqGainMaxRaw);
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('${band.label}-plus')));
      await tester.pump();
      expect(controller.eqWrites.last, (
        phones + 1,
        band.gainIdx,
        eqGainMaxRaw,
      ));
      controller.setEq(phones + 1, band.gainIdx, eqGainMinRaw);
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('${band.label}-minus')));
      await tester.pump();
      expect(controller.eqWrites.last, (
        phones + 1,
        band.gainIdx,
        eqGainMinRaw,
      ));
    }
  });

  testWidgets(
    'Ring-Kacheln teilen Rahmen und Farben bei größeren Tippflächen',
    (tester) async {
      await showPage(tester);
      final tiles = [
        'Bass',
        'Treble',
        'Balance',
      ].map((name) => find.byKey(ValueKey('$name-tile'))).toList();
      final side = find
          .descendant(
            of: find.byKey(const ValueKey('output-da-filter')),
            matching: find.byType(Material),
          )
          .first;
      final reference = tester.widget<Material>(side);
      for (final tile in tiles) {
        final material = tester.widget<Material>(tile);
        expect(material.color, Palette.surf);
        expect(material.shape, reference.shape);
        expect(material.clipBehavior, Clip.antiAlias);
      }
      expect(tester.getSize(tiles[0]), tester.getSize(tiles[1]));
      expect(tester.getSize(tiles[2]).height, tester.getSize(side).height);
      for (final name in ['Bass', 'Treble', 'Balance']) {
        for (final direction in ['plus', 'minus']) {
          expect(
            tester.getSize(find.byKey(ValueKey('$name-$direction'))).height,
            name == 'Balance' ? tester.getSize(side).height : 48,
          );
        }
      }
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('Bass-value')))
            .style!
            .color,
        Palette.amber,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final variant in Adi2Variant.values) {
    for (final out in outputsFor(variant)) {
      testWidgets(
        'B/T-Einstellung synchronisiert offline $variant ${out.address}',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final offline = Adi2Controller();
          try {
            await offline.startOffline(variant);
            offline.selectedOutput = out.address;
            offline.set(Adi2Addr.device, 8, 1); // Dual Phones
            await tester.pumpWidget(
              MaterialApp(
                theme: buildTheme(),
                home: Scaffold(body: OutputsPage(ctrl: offline)),
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('Settings'));
            await tester.pumpAndSettle();
            final toggle = find.byKey(const ValueKey('output-bass-treble'));
            await tester.tap(toggle);
            await tester.pump();
            expect(offline.value(out.address + 1, 20), 0);
            expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
            // Geräteänderungen werden auch bei geöffneten Einstellungen angezeigt.
            offline.set(out.address + 1, 20, 1);
            await tester.pump();
            expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
            await tester.tap(toggle);
            await tester.pump();
            Navigator.of(tester.element(toggle)).pop();
            await tester.pumpAndSettle();
            for (final name in ['Bass', 'Treble']) {
              final opacity = find.descendant(
                of: find.byKey(ValueKey('$name-tile')),
                matching: find.byType(Opacity),
              );
              expect(tester.widget<Opacity>(opacity).opacity, 0.45);
            }
            await tester.tap(find.byKey(const ValueKey('Bass-plus')));
            await tester.pumpAndSettle();
            expect(offline.value(out.address + 1, 20), 1);
            await tester.tap(find.text('Settings'));
            await tester.pumpAndSettle();
            expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          } finally {
            offline.dispose();
          }
        },
      );
    }
  }

  testWidgets('B/T-Schalter schreibt Index 20 auch ohne gemeldeten Wert', (
    tester,
  ) async {
    AppLang.instance.language = AppLanguage.en;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: OutputSettingsPage(
          ctrl: controller,
          out: outputsFor(controller.variant).first,
        ),
      ),
    );
    final toggle = find.byKey(const ValueKey('output-bass-treble'));
    expect(find.text('Bass/Treble'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pump();
    expect(controller.writes.single, (line + 1, 20, 0));
    await tester.tap(toggle);
    await tester.pump();
    expect(controller.writes.last, (line + 1, 20, 1));
  });

  testWidgets('Balance +/−, L/R-Anzeige, Grenzen und Langdruck zur Mitte', (
    tester,
  ) async {
    await showPage(tester);
    final center = find.byKey(const ValueKey('Balance-center'));
    expect(
      find.descendant(of: center, matching: find.text('Mitte')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('Balance-plus')));
    await tester.pump();
    expect(controller.writes.last, (phones, OutIdx.balance, 1));
    expect(find.text('R 1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('Balance-minus')));
    await tester.pump();
    expect(controller.writes.last, (phones, OutIdx.balance, 0));
    await tester.tap(find.byKey(const ValueKey('Balance-minus')));
    await tester.pump();
    expect(find.text('L 1'), findsOneWidget);
    for (final (raw, key) in [(100, 'Balance-plus'), (-100, 'Balance-minus')]) {
      controller.set(phones, OutIdx.balance, raw);
      await tester.pump();
      expect(find.text(raw < 0 ? 'L 100' : 'R 100'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pump();
      expect(controller.writes.last, (phones, OutIdx.balance, raw));
    }
    await tester.longPress(center);
    await tester.pump();
    expect(controller.writes.last, (phones, OutIdx.balance, 0));
    expect(
      find.descendant(of: center, matching: find.text('Mitte')),
      findsOneWidget,
    );
  });

  for (final language in AppLanguage.values) {
    testWidgets('Balance im Einstellungsdialog $language', (tester) async {
      AppLang.instance.language = language;
      final def = outputParams(
        Adi2Variant.dac,
        phones: true,
      ).firstWhere((def) => def.index == OutIdx.balance);
      controller.set(phones, OutIdx.balance, 0);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (context, _) =>
                  ParamTile(ctrl: controller, address: phones, def: def),
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
        controller.set(phones, OutIdx.balance, raw);
        await tester.pump();
        expect(find.text(label), findsOneWidget);
      }
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect((slider.min, slider.max, slider.divisions), (-100, 100, 200));
      slider.onChangeEnd!(35);
      await tester.pump();
      expect(controller.writes.last, (phones, OutIdx.balance, 35));
      expect(find.text('R 35'), findsOneWidget);
    });
  }

  for (final key in [
    'Bass-plus',
    'Treble-minus',
    'Balance-plus',
    'Balance-minus',
  ]) {
    testWidgets('$key wiederholt nur während des Haltens', (tester) async {
      await showPage(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey(key))),
      );
      await tester.pump(const Duration(milliseconds: 1100));
      final count = controller.eqWrites.length + controller.writes.length;
      expect(count, greaterThanOrEqualTo(2));
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
      expect(controller.eqWrites.length + controller.writes.length, count);
    });
  }

  for (final band in eqBands.where((b) => b.isBassTreble)) {
    testWidgets(
      '${band.label}-Langdruck öffnet vorhandene Band-Einstellungen',
      (tester) async {
        await showPage(tester);
        await tester.longPress(find.byKey(ValueKey('${band.label}-settings')));
        await tester.pumpAndSettle();
        final controls = tester.widget<EqBandControls>(
          find.byType(EqBandControls),
        );
        expect(controls.band, eqBands.indexOf(band));
        expect(controls.address, phones + 1);
        expect(find.text('Frequenz'), findsOneWidget);
        expect(find.text('Q'), findsOneWidget);
        await tester.tap(find.byType(Switch));
        await tester.pump();
        expect(controller.writes.last, (phones + 1, EqIdx2.btEnable, 0));
      },
    );
  }

  for (final variant in Adi2Variant.values) {
    testWidgets('Offline-Stand und Gain-Rampe ${variant.name}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final offline = Adi2Controller();
      try {
        await offline.startOffline(variant);
        offline.selectedOutput = line;
        offline.set(line + 1, EqIdx2.btEnable, 0);
        offline.set(line + 1, 21, 4);
        offline.set(line, OutIdx.balance, -25);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: Scaffold(body: OutputsPage(ctrl: offline)),
          ),
        );
        await tester.pump();
        expect(find.text('+2,0 dB'), findsOneWidget);
        expect(find.text('L 25'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('Bass-plus')));
        expect(offline.value(line + 1, EqIdx2.btEnable), 1);
        expect(offline.eqValue(line + 1, 21), 5);
        expect(offline.value(line + 1, 21), 4);
        await tester.pump(const Duration(milliseconds: 50));
        expect(offline.value(line + 1, 21), 5);
        await tester.tap(find.byKey(const ValueKey('Balance-plus')));
        expect(offline.value(line, OutIdx.balance), -24);
        await tester.pump(const Duration(milliseconds: 600));
        await offline.startOffline(variant);
        expect(offline.value(line + 1, 21), 5);
        expect(offline.value(line, OutIdx.balance), -24);
        expect(offline.value(line + 1, EqIdx2.btEnable), 1);
        await tester.pumpWidget(const SizedBox());
      } finally {
        offline.dispose();
      }
    });
  }

  for (final size in [const Size(411, 914), const Size(360, 740)]) {
    for (final variant in Adi2Variant.values) {
      testWidgets('Hauptansicht, Ausgänge und Ring-Gesten $size $variant', (
        tester,
      ) async {
        // Prüfe die Geometrie mit den ausgelieferten Schriften: Ahem hat
        // andere Zeilenhöhen und erzwingt künstliche Zeilenumbrüche.
        await tester.runAsync(() async {
          for (final family in ['Archivo', 'ArchivoNarrow']) {
            await (FontLoader(
              family,
            )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
          }
        });
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
        tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        controller.variant = variant;
        controller.state = ConnState.connected;
        for (final entry in offlineDefaults(variant).entries) {
          controller.values[(entry.key >> 8, entry.key & 255)] = entry.value;
        }
        controller.values[(Adi2Addr.device, 8)] = 1; // Dual Phones
        final np = NowPlaying();
        addTearDown(np.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: HomePage(ctrl: controller, np: np),
          ),
        );
        await tester.pumpAndSettle();
        for (final output in outputsFor(variant)) {
          await tester.tap(find.text(output.name).first);
          await tester.pumpAndSettle();
          final bass = eqBands.firstWhere((b) => b.isBassTreble);
          final treble = eqBands.last;
          controller.set(output.address + 1, bass.gainIdx, 4);
          controller.set(output.address + 1, treble.gainIdx, -4);
          controller.set(output.address, OutIdx.balance, -25);
          await tester.pump();
          expect(find.text('+2,0 dB'), findsOneWidget);
          expect(find.text('−2,0 dB'), findsOneWidget);
          expect(find.text('L 25'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('Bass-plus')));
          await tester.tap(find.byKey(const ValueKey('Treble-minus')));
          await tester.tap(find.byKey(const ValueKey('Balance-plus')));
          await tester.pump();
          expect(controller.eqWrites[controller.eqWrites.length - 2], (
            output.address + 1,
            bass.gainIdx,
            5,
          ));
          expect(controller.eqWrites.last, (
            output.address + 1,
            treble.gainIdx,
            -5,
          ));
          expect(controller.writes.last, (output.address, OutIdx.balance, -24));
          // Globale Eckpunkte berücksichtigen auch eine mögliche Skalierung
          // durch die FittedBox der Ton-Kacheln.
          Rect bounds(Finder finder) => Rect.fromPoints(
            tester.getTopLeft(finder),
            tester.getBottomRight(finder),
          );
          void verifySpacing() {
            final refFinder = find.byKey(const ValueKey('output-ref-level'));
            final filterFinder = find.byKey(const ValueKey('output-da-filter'));
            final lock = bounds(find.byKey(const ValueKey('output-lock')));
            final link = bounds(find.byKey(const ValueKey('output-link')));
            final balance = bounds(find.byKey(const ValueKey('Balance-tile')));
            final topRow = [balance];
            if (refFinder.evaluate().isNotEmpty) {
              final ref = bounds(refFinder);
              topRow.add(ref);
              expect(balance.left - ref.right, greaterThanOrEqualTo(8 - .01));
            }
            if (filterFinder.evaluate().isNotEmpty) {
              final filter = bounds(filterFinder);
              topRow.add(filter);
              expect(
                filter.left - balance.right,
                greaterThanOrEqualTo(8 - .01),
              );
            }
            for (final name in ['Bass', 'Treble', 'Balance']) {
              for (final direction in ['plus', 'minus']) {
                final button = find.byKey(ValueKey('$name-$direction'));
                final rect = bounds(button);
                if (name == 'Balance') {
                  expect(rect.width, greaterThanOrEqualTo(44 - .01));
                } else {
                  expect(rect.height, greaterThanOrEqualTo(48 - .01));
                }
                expect(button.hitTestable(), findsOneWidget);
              }
            }
            for (final name in ['Bass', 'Treble']) {
              final tile = bounds(find.byKey(ValueKey('$name-tile')));
              final topRowBottom = topRow
                  .map((rect) => rect.bottom)
                  .reduce(math.max);
              expect(tile.top - topRowBottom, greaterThanOrEqualTo(8 - .01));
              expect(
                math.min(lock.top, link.top) - tile.bottom,
                greaterThanOrEqualTo(8 - .01),
              );
              expect(name == 'Bass' ? tile.left : size.width - tile.right, 20);
              final plus = bounds(find.byKey(ValueKey('$name-plus')));
              final value = bounds(find.byKey(ValueKey('$name-value')));
              final minus = bounds(find.byKey(ValueKey('$name-minus')));
              expect(value.top, greaterThan(plus.bottom));
              expect(value.bottom, lessThan(minus.top));
            }
          }

          verifySpacing();
          final ring = find.descendant(
            of: find.byType(VolumeRing),
            matching: find.byType(RawGestureDetector),
          );
          final rect = tester.getRect(ring);
          final center = rect.topLeft + Offset(rect.width / 2, rect.width / 2);
          final radius = rect.width / 2 - 36;
          final before = controller.volumeWrites.length;
          // Beide Seiten des sichtbaren Bogens müssen drehbar bleiben.
          for (final degrees in [180.0, 0.0]) {
            Offset at(double angle) =>
                center +
                Offset(
                      math.cos(angle * math.pi / 180),
                      math.sin(angle * math.pi / 180),
                    ) *
                    radius;
            final gesture = await tester.startGesture(at(degrees));
            await gesture.moveTo(at(degrees - 20));
            await gesture.up();
          }
          await tester.pump();
          expect(
            controller.volumeWrites.length,
            greaterThanOrEqualTo(before + 2),
          );
          final level = find.descendant(
            of: find.byType(VolumeRing),
            matching: find.byWidgetPredicate(
              (w) => w is Text && (w.data?.contains('dBu') ?? false),
            ),
          );
          expect(
            tester.getBottomRight(level).dy,
            lessThanOrEqualTo(rect.bottom + 0.1),
          );
          controller.set(output.address, OutIdx.lockVolume, 1);
          await tester.pump();
          expect(find.text('Lautstärke am Gerät gesperrt'), findsOneWidget);
          verifySpacing();
          expect(tester.takeException(), isNull);
          controller.set(output.address, OutIdx.lockVolume, 0);
          await tester.pump();
          expect(
            find.descendant(
              of: find.byType(OutputsPage),
              matching: find.byType(Scrollable),
            ),
            findsNothing,
          );
        }
      });
    }
  }

  for (final size in [const Size(411, 914), const Size(360, 740)]) {
    for (final variant in Adi2Variant.values) {
      testWidgets(
        'Freier Platz vergrößert Bedienelemente und zentriert Ring $size $variant',
        (tester) async {
          await tester.runAsync(() async {
            for (final family in ['Archivo', 'ArchivoNarrow']) {
              await (FontLoader(
                family,
              )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
            }
          });
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
          tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
          addTearDown(tester.view.reset);
          final settings = AppSettings.instance;
          final previous = (
            settings.showPlayer,
            settings.showStatus,
            settings.easyMode,
          );
          addTearDown(() {
            settings.showPlayer = previous.$1;
            settings.showStatus = previous.$2;
            settings.easyMode = previous.$3;
          });
          SharedPreferences.setMockInitialValues({});
          settings.easyMode = false;
          controller.variant = variant;
          controller.state = ConnState.connected;
          for (final entry in offlineDefaults(controller.variant).entries) {
            controller.values[(entry.key >> 8, entry.key & 255)] = entry.value;
          }
          final np = NowPlaying()..supported = true;
          addTearDown(np.dispose);
          Future<void> show(bool player, bool status) async {
            settings.showPlayer = player;
            settings.showStatus = status;
            await tester.pumpWidget(
              MaterialApp(
                theme: buildTheme(),
                home: HomePage(ctrl: controller, np: np),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }

          final controls = [
            for (final key in [
              'output-ref-level',
              'Balance-tile',
              'output-da-filter',
              'output-lock',
              'output-link',
              'Bass-tile',
              'Treble-tile',
            ])
              find.byKey(ValueKey(key)),
            find
                .ancestor(
                  of: find.text('0,5 dB').first,
                  matching: find.byType(Material),
                )
                .first,
          ];
          await show(true, true);
          final oldHeights = controls
              .map((finder) => tester.getSize(finder).height)
              .toList();
          final oldSwitch = tester.getSize(find.byType(OutputSwitch)).height;
          for (final state in [(false, false), (true, false)]) {
            np.supported =
                !state.$1; // Enabled but unsupported player also collapses.
            await show(state.$1, state.$2);
            expect(
              tester
                  .widget<OutputsPage>(find.byType(OutputsPage))
                  .useFreedSpace,
              isTrue,
            );
            for (var i = 0; i < controls.length; i++) {
              expect(
                tester.getSize(controls[i]).height,
                greaterThan(oldHeights[i]),
                reason: 'Control $i',
              );
              expect(controls[i].hitTestable(), findsOneWidget);
            }
            final switchHeight = tester
                .getSize(find.byType(OutputSwitch))
                .height;
            expect(switchHeight, greaterThan(oldSwitch));
            expect(switchHeight, lessThanOrEqualTo(oldSwitch * 1.5));
            final area = tester.getRect(
              find.byKey(const ValueKey('output-ring-area')),
            );
            final topRow = tester.getRect(
              find.byKey(const ValueKey('Balance-tile')),
            );
            final ring = tester.getRect(
              find.descendant(
                of: find.byType(VolumeRing),
                matching: find.byType(RawGestureDetector),
              ),
            );
            expect(
              ring.center.dy,
              closeTo((topRow.bottom + 8 + area.bottom - 8) / 2, 0.1),
            );
            expect(
              ring.width,
              lessThanOrEqualTo(math.min(size.width - 160, 300)),
            );
            expect(tester.takeException(), isNull);
          }
          await show(false, true);
          expect(
            tester.widget<OutputsPage>(find.byType(OutputsPage)).useFreedSpace,
            isFalse,
          );
          // A live media change must restore the original layout without reopening.
          await show(true, false);
          np.supported = true;
          await tester.pumpWidget(const SizedBox());
          await show(true, false);
          expect(
            tester.widget<OutputsPage>(find.byType(OutputsPage)).useFreedSpace,
            isFalse,
          );
          for (var i = 0; i < controls.length; i++) {
            expect(tester.getSize(controls[i]).height, oldHeights[i]);
          }
          await np.dismissPrompt();
          await tester.pumpAndSettle();
          expect(
            tester.widget<OutputsPage>(find.byType(OutputsPage)).useFreedSpace,
            isTrue,
          );
        },
      );
    }
  }

  Finder crossfeedButton() => find
      .ancestor(of: find.text('Crossfeed'), matching: find.byType(InkWell))
      .first;

  Future<void> tapCrossfeed(WidgetTester tester) async {
    await tester.tap(crossfeedButton());
    await tester.pumpAndSettle();
  }

  for (final language in AppLanguage.values) {
    testWidgets('Status und Recall-Reihenfolge ${language.name}', (
      tester,
    ) async {
      AppLang.instance.language = language;
      SharedPreferences.setMockInitialValues({});
      controller.opts.of(phones).recallRaw = null;
      await showPage(tester);
      Finder button(String label) => find
          .ancestor(of: find.text(label), matching: find.byType(InkWell))
          .first;
      Text status(String label) => tester
          .widgetList<Text>(
            find.descendant(of: button(label), matching: find.byType(Text)),
          )
          .firstWhere(
            (text) =>
                text.data != 'Ag' && text.style?.fontFamily == 'ArchivoNarrow',
          );
      expect(status('Recall').data, tr('speichern'));
      controller.setRecall(phones, -200);
      await tester.pumpAndSettle();
      expect(status('Recall').data, '−20,0 dB');
      expect(
        tester.getTopLeft(find.text('Recall')).dy,
        lessThan(tester.getTopLeft(find.text('−20,0 dB')).dy),
      );
      for (final label in ['Mute', 'Dim', 'Crossfeed', 'EQ', 'Limit']) {
        expect(status(label).data, language == AppLanguage.de ? 'Aus' : 'Off');
        expect(status(label).style!.color, Palette.text);
      }
      controller.opts.of(phones).limitDbu = -10;
      controller.set(phones, OutIdx.mute, 1);
      controller.set(phones, OutIdx.dim, 1);
      controller.set(phones, OutIdx.crossfeed, 3);
      controller.set(phones + 1, 2, 1);
      await tester.pumpAndSettle();
      for (final label in ['Mute', 'Dim', 'EQ']) {
        expect(status(label).data, language == AppLanguage.de ? 'An' : 'On');
        expect(status(label).style!.color, Palette.amber);
      }
      expect(status('Limit').data, '−10,0 dBu');
      expect(status('Limit').style!.color, Palette.amber);
      expect(status('Crossfeed').data, '3');
      expect(status('Crossfeed').style!.color, Palette.amber);
      expect(status('Recall').style!.color, Palette.text);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Crossfeed schaltet mit Standard 1 und merkt Stufen je Ausgang', (
    tester,
  ) async {
    controller.values[(line, OutIdx.crossfeed)] = 4;
    await showPage(tester);
    expect(
      find.descendant(of: crossfeedButton(), matching: find.text('Aus')),
      findsOneWidget,
    );
    await tapCrossfeed(tester);
    expect(controller.writes.last, (phones, OutIdx.crossfeed, 1));
    await tapCrossfeed(tester);
    expect(controller.writes.last, (phones, OutIdx.crossfeed, 0));

    await tester.tap(find.text('Line Out'));
    await tester.pumpAndSettle();
    expect(find.text('4'), findsOneWidget);
    await tapCrossfeed(tester);
    await tapCrossfeed(tester);
    expect(controller.writes.last, (line, OutIdx.crossfeed, 4));
    await tester.tap(find.text('Phones'));
    await tester.pumpAndSettle();
    await tapCrossfeed(tester);
    expect(controller.writes.last, (phones, OutIdx.crossfeed, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Crossfeed-Auswahl bietet Aus und 1–5 und merkt Auswahl', (
    tester,
  ) async {
    await showPage(tester);
    await tester.longPress(crossfeedButton());
    await tester.pumpAndSettle();
    for (final label in ['Aus', '1', '2', '3', '4', '5']) {
      expect(find.widgetWithText(ChoiceChip, label), findsOneWidget);
    }
    await tester.tap(find.widgetWithText(ChoiceChip, '5'));
    await tester.pumpAndSettle();
    expect(controller.writes.last, (phones, OutIdx.crossfeed, 5));
    await tester.longPress(crossfeedButton());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Aus'));
    await tester.pumpAndSettle();
    await tapCrossfeed(tester);
    expect(controller.writes.last, (phones, OutIdx.crossfeed, 5));
  });

  testWidgets('Ref links oben, Link rechts unter dem Ring mit alten Gesten', (
    tester,
  ) async {
    await showPage(tester);
    final ref = find.byKey(const ValueKey('output-ref-level'));
    final filter = find.byKey(const ValueKey('output-da-filter'));
    final link = find.byIcon(Icons.link);
    final lock = find.byIcon(Icons.lock_open);
    expect(tester.getTopLeft(ref).dx, lessThan(tester.getTopLeft(filter).dx));
    expect(tester.getCenter(ref).dy, tester.getCenter(filter).dy);
    expect(tester.getCenter(link).dy, tester.getCenter(lock).dy);
    expect(tester.getTopLeft(link).dy, greaterThan(tester.getTopLeft(ref).dy));
    await tester.tap(ref);
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsWidgets);
    expect(controller.writes, isEmpty);
    Navigator.of(tester.element(find.byType(ChoiceChip).first)).pop();
    await tester.pumpAndSettle();

    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(find.text('Link Volume'), findsOneWidget);
    expect(controller.opts.linked, {phones});
    await tester.tap(find.widgetWithText(FilterChip, 'Line Out'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(FilterChip).first)).pop();
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);
    await tester.longPress(link);
    await tester.pumpAndSettle();
    expect(find.text('Link Volume'), findsOneWidget);
    expect(controller.opts.linked, {phones, line});
    Navigator.of(tester.element(find.byType(FilterChip).first)).pop();
    await tester.pumpAndSettle();
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(controller.opts.linked, isEmpty);
    expect(find.text('Link'), findsOneWidget);
  });

  testWidgets('Auto nur bei gemeldetem Parameter und ohne Bestätigung', (
    tester,
  ) async {
    await showPage(tester);
    await tester.tap(find.byKey(const ValueKey('output-ref-level')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'Auto'), findsNothing);
    Navigator.of(tester.element(find.byType(ChoiceChip).first)).pop();
    await tester.pumpAndSettle();

    controller.set(phones, OutIdx.autoRef, 0);
    controller.writes.clear();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('output-ref-level')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Auto'));
    await tester.pumpAndSettle();
    expect(controller.writes, [(phones, OutIdx.autoRef, 1)]);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('Auto '), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('output-ref-level')));
    await tester.pumpAndSettle();
    final chips = tester
        .widgetList<ChoiceChip>(find.byType(ChoiceChip))
        .toList();
    expect(chips.first.selected, isTrue);
    expect(chips.skip(1).every((chip) => !chip.selected), isTrue);
    // Auch der aktuelle feste Pegel kann Auto ausschalten.
    await tester.tap(find.byType(ChoiceChip).at(1));
    await tester.pumpAndSettle();
    expect(controller.writes, [(phones, OutIdx.autoRef, 1)]);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Umschalten'));
    await tester.pumpAndSettle();
    expect(controller.writes.last, (phones, OutIdx.refLevel, 0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('DAC Line behält XLR-Unterzeilen bei Auto', (tester) async {
    controller.selectedOutput = line;
    controller.values[(line, OutIdx.autoRef)] = 1;
    await showPage(tester);
    expect(find.textContaining('Auto '), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('output-ref-level')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'Auto'), findsOneWidget);
    expect(find.textContaining('(XLR'), findsNWidgets(4));
    await tester.tap(find.byType(ChoiceChip).at(2));
    await tester.pumpAndSettle();
    expect(controller.writes, isEmpty);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(controller.writes, isEmpty);
    expect(controller.value(line, OutIdx.autoRef), 1);
  });

  testWidgets('Nicht gemeldete Parameter fehlen, englische Anzeige passt', (
    tester,
  ) async {
    AppLang.instance.language = AppLanguage.en;
    await showPage(tester);
    expect(
      find.descendant(of: crossfeedButton(), matching: find.text('Off')),
      findsOneWidget,
    );
    controller.values.remove((phones, OutIdx.crossfeed));
    controller.values.remove((phones, OutIdx.refLevel));
    controller.set(phones, OutIdx.mute, 1);
    await tester.pumpAndSettle();
    expect(find.text('Crossfeed'), findsNothing);
    expect(find.byIcon(Icons.tune), findsOneWidget); // EQ-Kachel bleibt.
    expect(find.text('Link'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
