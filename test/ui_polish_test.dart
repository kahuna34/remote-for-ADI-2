import 'package:adi2_remote/analyzer/analyzer_controller.dart';
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/analyzer/header_content.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/dev/analyzer_selftest_diagnostics.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:adi2_remote/ui/eq_display_mode.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/outputs_page.dart';
import 'package:adi2_remote/ui/responsive_layout.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Device extends Adi2Controller {
  _Device() {
    state = ConnState.connected;
  }

  @override
  Adi2Variant get variant => Adi2Variant.dac;
  final values = offlineDefaults(Adi2Variant.dac);

  @override
  int? value(int address, int index) => values[address << 8 | index];

  @override
  int valueOr(int address, int index, int fallback) =>
      value(address, index) ?? fallback;

  // Keep the header mounted to exercise its pending-connection presentation.
  @override
  bool get isConnected => true;

  void connection(ConnState next) {
    state = next;
    notifyListeners();
  }
}

AnalyzerController _analyzer() => AnalyzerController()
  ..status = AnalyzerStatus.running
  ..frame = AnalyzerFrame(
    sampleRate: 48000,
    spectrum: List.filled(2049, 0.1),
    peak: const [-6, -12],
    rms: const [-12, -18],
    clipped: const [false, false],
  );

void main() {
  final settings = AppSettings.instance;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
    final previous = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    addTearDown(() => AppLang.instance.language = previous);
    addTearDown(() => analyzerDeveloperMode.value = false);
    addTearDown(() => EqDisplayMode.setTablet(false));
  });

  void viewport(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
  }

  const sizes = [
    Size(360, 740),
    Size(411, 914),
    Size(600, 960),
    Size(960, 600),
  ];

  for (final size in sizes) {
    testWidgets('Header and output contents stay centered at $size', (
      tester,
    ) async {
      viewport(tester, size);
      await settings.setHeaderContent(HeaderContent.none);
      final device = _Device();
      final np = NowPlaying();
      addTearDown(device.dispose);
      addTearDown(np.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: HomePage(ctrl: device, np: np),
        ),
      );
      await tester.pumpAndSettle();

      Color? dotColor() =>
          (tester
                      .widget<Container>(
                        find.byKey(const ValueKey('connection-status-dot')),
                      )
                      .decoration
                  as BoxDecoration)
              .color;
      expect(dotColor(), Palette.green);
      for (final language in AppLanguage.values) {
        AppLang.instance.language = language;
        for (final state in [
          ConnState.offline,
          ConnState.searching,
          ConnState.connected,
        ]) {
          device.connection(state);
          await tester.pumpAndSettle();
          expect(
            dotColor(),
            state == ConnState.offline
                ? Palette.red
                : state == ConnState.connected
                ? Palette.green
                : Palette.muted,
          );
          final badge = find.byKey(const ValueKey('offline-badge'));
          if (state == ConnState.offline) {
            final badgeRect = tester.getRect(badge);
            final buttons = [
              find.byKey(const ValueKey('easy-switch')),
              find.byTooltip(tr('App')),
              find.text(tr('Beenden')),
            ];
            for (final button in buttons) {
              expect(badgeRect.overlaps(tester.getRect(button)), isFalse);
            }
          } else {
            expect(badge, findsNothing);
          }

          final tiles = find.byKey(const ValueKey('output-tiles'));
          final row = tester.widget<Row>(tiles);
          for (final tile in row.children.whereType<Expanded>()) {
            final tileFinder = find.byWidget(tile.child);
            final rect = tester.getRect(tileFinder);
            final icon = find.descendant(
              of: tileFinder,
              matching: find.byType(Icon),
            );
            var contentRect = tester.getRect(icon);
            for (final text
                in find
                    .descendant(of: tileFinder, matching: find.byType(Text))
                    .evaluate()) {
              final box = text.renderObject! as RenderBox;
              final textRect = MatrixUtils.transformRect(
                box.getTransformTo(null),
                Offset.zero & box.size,
              );
              contentRect = contentRect.expandToInclude(textRect);
            }
            expect(contentRect.center.dx, closeTo(rect.center.dx, 0.01));
          }
          final switcher = find.byType(OutputSwitch);
          for (final output in outputsFor(device.variant)) {
            final label = find.descendant(
              of: switcher,
              matching: find.text(output.name),
            );
            final tile = find.ancestor(
              of: label,
              matching: find.byType(AnimatedContainer),
            );
            expect(
              tester.getCenter(label).dy,
              closeTo(tester.getCenter(tile).dy, 1.01),
            );
          }
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets(
      'Compact information toggles without moving spectrum at $size',
      (tester) async {
        viewport(tester, size);
        final controller = _analyzer()
          ..diagnostics = {
            'routedDevice': {'name': 'ADI-2 DAC', 'type': 11, 'id': 17},
            'pcmScaling': 'PCM16 / 32768',
          };
        addTearDown(controller.dispose);
        analyzerDeveloperMode.value = true;
        var parentTaps = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: Scaffold(
              body: Column(
                children: [
                  SizedBox(
                    height: size.shortestSide >= 600 ? 172 : 112,
                    child: InkWell(
                      onTap: () => parentTaps++,
                      child: AnalyzerDisplay(
                        controller: controller,
                        compact: true,
                      ),
                    ),
                  ),
                  const Text('Below analyzer'),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final spectrum = find.byKey(const ValueKey('analyzer-spectrum'));
        final plotRect = tester.getRect(spectrum);
        final belowRect = tester.getRect(find.text('Below analyzer'));
        final summary = tester.widget<Text>(
          find.byKey(const ValueKey('analyzer-info-summary')),
        );
        expect(summary.maxLines, 1);
        expect(summary.overflow, TextOverflow.ellipsis);
        final toggle = find.byKey(const ValueKey('analyzer-info-toggle'));
        expect(find.byIcon(Icons.expand_more), findsOneWidget);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        final details = find.byKey(const ValueKey('analyzer-info-expanded'));
        expect(details, findsOneWidget);
        expect(
          find.descendant(
            of: details,
            matching: find.textContaining('ADI-2 DAC'),
          ),
          findsOneWidget,
        );
        expect(
          tester.getRect(details).bottom,
          lessThanOrEqualTo(tester.getRect(toggle).top),
        );
        expect(tester.getRect(details).top, greaterThanOrEqualTo(0));
        expect(tester.getRect(spectrum), plotRect);
        expect(tester.getRect(find.text('Below analyzer')), belowRect);
        expect(find.byIcon(Icons.expand_less), findsOneWidget);
        expect(parentTaps, 0);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(details, findsNothing);
        expect(tester.getRect(spectrum), plotRect);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        await tester.tapAt(tester.getRect(details).center);
        await tester.pumpAndSettle();
        expect(details, findsNothing);
        expect(parentTaps, 0);
        expect(tester.takeException(), isNull);
      },
    );

    for (final compact in [false, true]) {
      testWidgets(
        'Spectrum scales fit every range and style at $size / $compact',
        (tester) async {
          viewport(tester, size);
          final controller = _analyzer();
          addTearDown(controller.dispose);
          for (final range in [60, 80, 100]) {
            await settings.setAnalyzerRange(range);
            for (final bars in [false, true]) {
              controller.setBars(bars);
              await tester.pumpWidget(
                MaterialApp(
                  theme: buildTheme(),
                  home: Scaffold(
                    body: SizedBox(
                      height: compact ? 112 : size.height,
                      child: AnalyzerDisplay(
                        controller: controller,
                        compact: compact,
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              final plotSize = tester.getSize(
                find.byKey(const ValueKey('analyzer-spectrum')),
              );
              final scale = AnalyzerSpectrumScale(
                size: plotSize,
                compact: compact,
                range: range,
                bars: bars,
                resolution: controller.bandResolution,
              );
              expect(scale.frequencyLabels.keys.first, 20);
              expect(scale.frequencyLabels.keys.last, 20000);
              for (final hz in scale.frequencyLabels.keys) {
                expect(
                  scale.frequencyX(hz),
                  greaterThanOrEqualTo(scale.area.left),
                );
                expect(
                  scale.frequencyX(hz),
                  lessThanOrEqualTo(scale.area.right),
                );
              }
              if (scale.area.width > 480) {
                expect(scale.frequencyLabels.keys, [
                  20,
                  50,
                  100,
                  200,
                  500,
                  1000,
                  2000,
                  5000,
                  10000,
                  20000,
                ]);
              }
              var lastRight = -1.0;
              for (final rect in scale.frequencyLabels.values) {
                expect(rect.left, greaterThan(lastRight));
                expect(rect.right, lessThanOrEqualTo(plotSize.width));
                expect(rect.bottom, lessThanOrEqualTo(plotSize.height));
                lastRight = rect.right;
              }
              expect(scale.levelLabels.keys.first, 0);
              expect(scale.levelLabels.keys.last, -range);
              var lastBottom = -1.0;
              for (final rect in scale.levelLabels.values) {
                expect(rect.top, greaterThanOrEqualTo(lastBottom));
                expect(rect.right, lessThan(scale.area.left));
                expect(rect.left, greaterThanOrEqualTo(0));
                lastBottom = rect.bottom;
              }
              expect(tester.takeException(), isNull);
            }
          }
        },
      );
    }
  }

  testWidgets('Tablet analyzer column exposes controls and long level tracks', (
    tester,
  ) async {
    viewport(tester, const Size(960, 600));
    final device = _Device();
    final controller = _analyzer();
    addTearDown(device.dispose);
    addTearDown(controller.dispose);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('adi2/analyzer'),
      (_) async => false,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('adi2/analyzer'),
        null,
      ),
    );
    for (final language in AppLanguage.values) {
      AppLang.instance.language = language;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: SizedBox(
                width: tabletOutputColumnWidth(960),
                height: 430,
                child: AnalyzerPanel(
                  controller: controller,
                  deviceController: device,
                  expanded: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Capture is stubbed. Supply a deterministic live status after activation.
      controller.status = AnalyzerStatus.running;
      controller.setBars(true);
      await tester.pumpAndSettle();
      final panel = tester.getRect(find.byType(AnalyzerPanel));
      final plot = tester.getRect(
        find.byKey(const ValueKey('analyzer-spectrum')),
      );
      final controls = find.byKey(const ValueKey('analyzer-view-controls'));
      final gear = tester.getRect(find.byTooltip(tr('Analyzer-Einstellungen')));
      expect(tester.getRect(controls).top, greaterThanOrEqualTo(gear.bottom));
      for (final chip in [tr('Linien'), tr('Balken'), tr('Peak hold')]) {
        final finder = find.descendant(of: controls, matching: find.text(chip));
        final rect = tester.getRect(finder);
        expect(rect.left, greaterThanOrEqualTo(panel.left));
        expect(rect.right, lessThanOrEqualTo(panel.right));
        expect(finder.hitTestable(), findsOneWidget);
      }
      for (var channel = 0; channel < 2; channel++) {
        final track = tester.getRect(
          find.byKey(ValueKey('analyzer-track-$channel')),
        );
        expect(track.width, greaterThan(180));
        expect(track.bottom, lessThan(plot.top));
      }
      expect(plot.height, greaterThan(130));
      expect(tester.takeException(), isNull);
    }
  });
}
