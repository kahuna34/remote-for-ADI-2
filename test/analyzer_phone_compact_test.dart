import 'package:adi2_remote/analyzer/analyzer_controller.dart';
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/ui/analyzer_controls.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final settings = AppSettings.instance;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
    final previous = AppLang.instance.language;
    addTearDown(() => AppLang.instance.language = previous);
  });

  AnalyzerController signal() => AnalyzerController()
    ..status = AnalyzerStatus.silent
    ..frame = AnalyzerFrame(
      sampleRate: 48000,
      spectrum: List.filled(2049, .1),
      peak: [-120, -6],
      rms: [-120, -18],
      clipped: [false, false],
    );

  for (final size in [
    const Size(360, 800),
    const Size(412, 915),
    const Size(800, 1280),
    const Size(1280, 800),
    const Size(960, 600),
  ]) {
    for (final language in AppLanguage.values) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('Compact $size $language scale=$scale', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.reset);
          AppLang.instance.language = language;
          final c = signal();
          addTearDown(c.dispose);
          final phone = size.width < 600;
          await tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: size.width - 32,
                    height: phone ? 112 : 172,
                    child: AnalyzerDisplay(controller: c, compact: true),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final plot = find.byKey(const ValueKey('analyzer-spectrum'));
          final levels = find.byKey(const ValueKey('analyzer-compact-levels'));
          final toggle = find.byKey(
            const ValueKey('analyzer-main-view-toggle'),
          );
          final info = find.byKey(const ValueKey('analyzer-info-toggle'));
          final diagnostics = find.byKey(
            const ValueKey('analyzer-diagnostics'),
          );
          final expandedInfo = find.byKey(
            const ValueKey('analyzer-info-expanded'),
          );
          expect(settings.analyzerMainView, AnalyzerMainView.both);
          expect(plot, findsOneWidget);
          expect(levels, phone ? findsNothing : findsOneWidget);
          expect(toggle, findsOneWidget);
          expect(diagnostics, findsNothing);
          expect(tester.getSize(info), const Size(44, 32));
          final bounds = tester.getRect(plot);
          if (phone) expect(bounds.width, size.width - 48);
          await tester.tap(info);
          await tester.pumpAndSettle();
          expect(expandedInfo, findsOneWidget);
          expect(find.textContaining('48.0 kHz'), findsOneWidget);
          expect(
            find.textContaining(tr('Kein Signal. Loopback aktivieren.')),
            findsOneWidget,
          );
          expect(tester.getRect(plot), bounds);
          await tester.tap(info);
          await tester.pumpAndSettle();
          expect(expandedInfo, findsNothing);
          expect(tester.getRect(plot), bounds);

          final peak = find.byKey(const ValueKey('analyzer-peak-hold'));
          final reset = find.byKey(const ValueKey('analyzer-peak-reset'));
          final peakSize = tester.getSize(peak),
              resetSize = tester.getSize(reset);
          expect(peakSize.height, greaterThanOrEqualTo(28));
          expect(resetSize.height, peakSize.height);
          expect(resetSize.width, isNot(peakSize.width));
          final resetText = tester.widget<Text>(find.text(tr('Zurücksetzen')));
          expect(resetText.style!.fontSize, 11);
          final painter = TextPainter(
            text: TextSpan(
              text: tr('Zurücksetzen'),
              style: DefaultTextStyle.of(
                tester.element(find.text(tr('Zurücksetzen'))),
              ).style.merge(resetText.style),
            ),
            textDirection: TextDirection.ltr,
            textScaler: TextScaler.linear(scale),
          )..layout();
          expect(resetSize.width, closeTo(painter.width + 24, 1));
          painter.dispose();
          if (language == AppLanguage.de) {
            final old = TextPainter(
              text: TextSpan(text: tr('Zurücksetzen'), style: ts(12)),
              textDirection: TextDirection.ltr,
              textScaler: TextScaler.linear(scale),
            )..layout();
            expect(resetSize.width, lessThan(old.width + 48));
            old.dispose();
          }
          await tester.tap(peak);
          await tester.pump();
          expect(c.peakHold, isFalse);
          if (phone) {
            expect(tester.getSize(toggle).height, greaterThanOrEqualTo(28));
            await tester.tap(toggle);
            await tester.pumpAndSettle();
            expect(plot, findsNothing);
            expect(levels, findsOneWidget);
            expect(peak, findsNothing);
            expect(reset, findsNothing);
            final prefs = await SharedPreferences.getInstance();
            expect(prefs.getString('analyzer_main_view'), 'levels');
            await settings.load();
            await tester.pump();
            expect(settings.analyzerMainView, AnalyzerMainView.levels);
          } else {
            // Tablet cycles Both → Spectrum → Levels → Both.
            await tester.tap(toggle);
            await tester.pumpAndSettle();
            expect(settings.analyzerMainView, AnalyzerMainView.spectrum);
            expect(plot, findsOneWidget);
            expect(levels, findsNothing);
            await tester.tap(toggle);
            await tester.pumpAndSettle();
            expect(settings.analyzerMainView, AnalyzerMainView.levels);
            expect(plot, findsNothing);
            expect(levels, findsOneWidget);
            expect(peak, findsNothing);
            expect(reset, findsNothing);
          }
          for (var ch = 0; ch < 2; ch++) {
            final value = find.byKey(ValueKey('analyzer-compact-values-$ch'));
            final text = tester.widget<Text>(value);
            expect(text.style!.fontSize, greaterThanOrEqualTo(14));
            expect(
              find.ancestor(of: value, matching: find.byType(FittedBox)),
              findsNothing,
            );
            final transform = tester.renderObject(value).getTransformTo(null);
            expect(
              text.style!.fontSize! * scale * transform.getMaxScaleOnAxis(),
              greaterThanOrEqualTo(10),
            );
          }
          if (!phone) {
            await tester.tap(toggle);
            await tester.pumpAndSettle();
            await settings.load();
            await tester.pump();
            expect(settings.analyzerMainView, AnalyzerMainView.both);
            expect(plot, findsOneWidget);
            expect(levels, findsOneWidget);
            expect(peak, findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          if (phone) {
            await tester.tap(toggle);
            await tester.pumpAndSettle();
            expect(plot, findsOneWidget);
            expect(levels, findsNothing);
            expect(
              (await SharedPreferences.getInstance()).getString(
                'analyzer_main_view',
              ),
              'spectrum',
            );
          }
        });
      }
    }
  }

  for (final size in [
    const Size(360, 800),
    const Size(412, 915),
    const Size(800, 1280),
    const Size(1280, 800),
    const Size(960, 600),
  ]) {
    testWidgets('Panel actions fit at $size and scale 1.3', (tester) async {
      AppLang.instance.language = AppLanguage.de;
      await settings.setAutoFullscreenEq(false);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final c = AnalyzerController();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(body: AnalyzerPanel(controller: c)),
        ),
      );
      await tester.pumpAndSettle();
      c.frame = AnalyzerFrame(
        sampleRate: 48000,
        spectrum: List.filled(2049, .1),
        peak: [-6, -9],
        rms: [-12, -18],
        clipped: [false, false],
      );
      c.status = AnalyzerStatus.running;
      c.notifyListeners();
      await tester.pump();
      final plot = tester.getRect(
        find.byKey(const ValueKey('analyzer-spectrum')),
      );
      final toolbar = tester.getRect(
        find.byKey(const ValueKey('analyzer-compact-buttons')),
      );
      expect(toolbar.top, greaterThanOrEqualTo(plot.bottom));
      for (final icon in [
        Icons.info_outline,
        size.shortestSide < 600 ? Icons.equalizer : Icons.show_chart,
        Icons.settings_outlined,
        Icons.fullscreen,
      ]) {
        final button = find.ancestor(
          of: find.byIcon(icon),
          matching: find.byType(IconButton),
        );
        expect(tester.getSize(button), const Size(44, 32));
        expect(toolbar.contains(tester.getCenter(button)), isTrue);
        expect(button.hitTestable(), findsOneWidget);
        expect(
          tester.widget<IconButton>(button).style!.side!.resolve({}),
          const BorderSide(color: Palette.line),
        );
      }
      final toggle = find.byKey(const ValueKey('analyzer-main-view-toggle'));
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      if (size.shortestSide >= 600) {
        await tester.tap(toggle);
        await tester.pumpAndSettle();
      }
      final meters = tester.getRect(
        find.byKey(const ValueKey('analyzer-compact-levels')),
      );
      final settingsButton = find.byTooltip(tr('Analyzer-Einstellungen'));
      expect(
        tester.getRect(settingsButton).top,
        greaterThanOrEqualTo(meters.bottom),
      );
      expect(find.byKey(const ValueKey('analyzer-spectrum')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('Settings selects and restores the main view', (tester) async {
    final c = signal();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAnalyzerSettings(context, c, null),
              child: const Text('Settings'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('analyzer-main-view-setting'));
    final levels = find.descendant(
      of: field,
      matching: find.text(tr('Pegel (Peak/RMS)')),
    );
    await tester.ensureVisible(levels);
    await tester.tap(levels);
    await tester.pumpAndSettle();
    await settings.load();
    expect(settings.analyzerMainView, AnalyzerMainView.levels);
    expect(find.text(tr('Anzeige im Hauptfenster')), findsOneWidget);
  });

  testWidgets(
    'Tablet-Einstellung Beides bleibt beim Wechsel zum Smartphone erhalten',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1280);
      addTearDown(tester.view.reset);
      final c = signal();
      addTearDown(c.dispose);
      await settings.setAnalyzerMainView(AnalyzerMainView.levels);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: Column(
              children: [
                Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showAnalyzerSettings(context, c, null),
                    child: const Text('Settings'),
                  ),
                ),
                SizedBox(
                  height: 172,
                  child: AnalyzerDisplay(controller: c, compact: true),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('analyzer-main-view-setting'));
      expect(
        tester.widget<AnalyzerChoices<AnalyzerMainView>>(field).values,
        AnalyzerMainView.values,
      );
      final both = find.descendant(
        of: field,
        matching: find.text(tr('Beides')),
      );
      await tester.ensureVisible(both);
      await tester.tap(both);
      await tester.pumpAndSettle();
      await settings.load();
      expect(settings.analyzerMainView, AnalyzerMainView.both);
      expect(
        (await SharedPreferences.getInstance()).getString('analyzer_main_view'),
        'both',
      );
      Navigator.of(tester.element(field)).pop();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('analyzer-compact-levels')),
        findsOneWidget,
      );
      tester.view.physicalSize = const Size(360, 800);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('analyzer-spectrum')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('analyzer-compact-levels')),
        findsNothing,
      );
      expect(settings.analyzerMainView, AnalyzerMainView.both);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      final choices = tester.widget<AnalyzerChoices<AnalyzerMainView>>(field);
      expect(choices.values, [
        AnalyzerMainView.spectrum,
        AnalyzerMainView.levels,
      ]);
      expect(choices.value, AnalyzerMainView.spectrum);
      expect(tester.takeException(), isNull);
    },
  );

  test('Invalid saved main view falls back to both', () async {
    SharedPreferences.setMockInitialValues({'analyzer_main_view': 'unknown'});
    await settings.load();
    expect(settings.analyzerMainView, AnalyzerMainView.both);
  });
}
