import 'package:adi2_remote/analyzer/analyzer_controller.dart';
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:adi2_remote/ui/analyzer_controls.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/ui/eq_display_mode.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late List<MethodCall> calls;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
    calls = [];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  });

  Future<List<Object?>> openFullscreen(
    WidgetTester tester,
    Size size, {
    double scale = 1,
  }) async {
    await AppSettings.instance.setAutoFullscreenEq(false);
    EqDisplayMode.setTablet(true);
    addTearDown(() => EqDisplayMode.setTablet(false));
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    final controller = AnalyzerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: AnalyzerPanel(controller: controller, expanded: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
    expect(tester.takeException(), isNull);
    return calls
            .lastWhere(
              (c) => c.method == 'SystemChrome.setPreferredOrientations',
            )
            .arguments
        as List<Object?>;
  }

  test(
    'Balken, Peak hold und Ballistik überleben neue Anzeige und Neustart',
    () async {
      final first = AnalyzerController()
        ..setBars(true)
        ..setPeakHold(false)
        ..setBallistics(AnalyzerBallistics.fast);
      first.dispose();

      void expectKept(AnalyzerController c) {
        expect(c.bars, isTrue);
        expect(c.peakHold, isFalse);
        expect(c.ballistics, AnalyzerBallistics.fast);
        expect(c.spectrum.ballistics, AnalyzerBallistics.fast);
        expect(c.bands.ballistics, AnalyzerBallistics.fast);
        c.dispose();
      }

      expectKept(AnalyzerController());
      await pumpEventQueue();
      await AppSettings.instance.load();
      expectKept(AnalyzerController());
    },
  );

  testWidgets('Wechsel der Anzeige lässt die laufende Aufnahme weiterlaufen', (
    tester,
  ) async {
    final native = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('adi2/analyzer'), (
      call,
    ) async {
      native.add(call.method);
      return true;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('adi2/analyzer/events'),
      (_) async => null,
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(
        const MethodChannel('adi2/analyzer'),
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('adi2/analyzer/events'),
        null,
      );
    });
    final controller = AnalyzerController();
    addTearDown(controller.dispose);
    Widget view(Key key) => MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: SizedBox(
          height: 300,
          child: AnalyzerPanel(key: key, controller: controller),
        ),
      ),
    );

    await tester.pumpWidget(view(const ValueKey('portrait')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(native.where((m) => m == 'start'), hasLength(1));

    await tester.pumpWidget(view(const ValueKey('landscape')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(native.where((m) => m == 'start'), hasLength(1));
    expect(native, isNot(contains('stop')));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  for (final size in [
    const Size(568, 320),
    const Size(740, 360),
    const Size(960, 600),
    const Size(1280, 800),
  ]) {
    for (final (language, scale) in [
      for (final language in AppLanguage.values)
        for (final scale in [1.0, 1.3]) (language, scale),
    ]) {
      testWidgets(
        'Vollbild-Kopfzeile und werkzeugeigene Knöpfe passen $size $language scale=$scale',
        (tester) async {
          final previous = AppLang.instance.language;
          AppLang.instance.language = language;
          addTearDown(() => AppLang.instance.language = previous);
          await openFullscreen(tester, size, scale: scale);
          final toolbar = find.byKey(
            const ValueKey('analyzer-fullscreen-toolbar'),
          );
          final ballistics = find.byKey(
            const ValueKey('analyzer-ballistics-header'),
          );
          final loopback = find.byKey(const ValueKey('analyzer-loopback-tap'));
          for (final dropdown in [ballistics, loopback]) {
            expect(
              find.descendant(of: toolbar, matching: dropdown),
              findsOneWidget,
            );
            expect(
              tester.getRect(dropdown).right,
              lessThan(tester.getRect(find.byIcon(Icons.hide_source)).left),
            );
            expect(
              (tester.widget(dropdown) as DropdownButton).isExpanded,
              isTrue,
            );
          }
          expect(
            find.byType(DropdownButton<AnalyzerBandResolution>),
            findsNothing,
          );
          expect(
            find.byType(AnalyzerChoices<AnalyzerBandResolution>),
            findsOneWidget,
          );
          final tool = find.byType(AnalyzerChoices<AnalyzerView>);
          expect(tool, findsOneWidget);
          expect(find.text(tr('Spektrum')), findsOneWidget);
          expect(find.text(tr('Linien')), findsOneWidget);
          expect(find.text(tr('Balken')), findsOneWidget);
          expect(find.text(tr('Peak hold')), findsOneWidget);
          final reset = find.byKey(const ValueKey('analyzer-peak-reset'));
          expect(reset, findsOneWidget);
          expect(
            tester.getRect(reset).left,
            greaterThan(tester.getRect(find.text(tr('Peak hold'))).right),
          );
          final resetButton = find.descendant(
            of: reset,
            matching: find.byType(OutlinedButton),
          );
          final peak = find.byKey(const ValueKey('analyzer-peak-hold'));
          final peakButton = find.descendant(
            of: peak,
            matching: find.byType(OutlinedButton),
          );
          expect(peakButton, findsOneWidget);
          expect(
            tester.widget(peakButton).runtimeType,
            tester.widget(resetButton).runtimeType,
          );
          expect(
            tester.getSize(peakButton).height,
            tester.getSize(resetButton).height,
          );
          expect(
            tester.getSize(peakButton).width,
            isNot(tester.getSize(resetButton).width),
          );
          final peakStyle = tester.widget<OutlinedButton>(peakButton).style!;
          final resetStyle = tester.widget<OutlinedButton>(resetButton).style!;
          expect(peakStyle.shape!.resolve({}), resetStyle.shape!.resolve({}));
          expect(peakStyle.backgroundColor!.resolve({}), Palette.amber);
          final peakText = tester
              .widget<Text>(find.text(tr('Peak hold')))
              .style!;
          final resetText = tester
              .widget<Text>(find.text(tr('Zurücksetzen')))
              .style!;
          expect(peakText.fontSize, resetText.fontSize);
          expect(peakText.fontWeight, resetText.fontWeight);
          // Ausgewählt: dunkle Schrift auf Amber, gut lesbar.
          expect(peakText.color, Palette.bg);
          expect(
            tester.widget<OutlinedButton>(resetButton).onPressed,
            isNotNull,
          );
          await tester.tap(find.text(tr('Peak hold')));
          await tester.pump();
          expect(tester.widget<OutlinedButton>(resetButton).onPressed, isNull);
          for (final label in ['1/3', '1/6', '1/12']) {
            final option = find.text(label);
            expect(option, findsOneWidget);
            // Spectrum steht in der Zeile mit Zahnrad/Vollbild; die
            // Bandauflösung folgt direkt darunter.
            expect(
              tester.getRect(option).top,
              lessThanOrEqualTo(tester.getRect(tool).bottom + 16),
            );
          }
          await tester.tap(find.text('1/12'));
          await tester.pumpAndSettle();
          expect(
            AppSettings.instance.analyzerBandResolution,
            AnalyzerBandResolution.twelfth,
          );
          await tester.tap(ballistics);
          await tester.pumpAndSettle();
          await tester.tap(find.text(tr('langsam')).last);
          await tester.pumpAndSettle();
          expect(
            AppSettings.instance.analyzerBallistics,
            AnalyzerBallistics.slow,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pumpAndSettle();
        },
      );
    }
  }

  testWidgets('Tablet im Hochformat öffnet Analyzer-Vollbild im Querformat', (
    tester,
  ) async {
    final orientations = await openFullscreen(tester, const Size(600, 960));
    expect(orientations, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);
    tester.view.physicalSize = const Size(960, 600);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pumpAndSettle();
    expect(
      calls
          .lastWhere((c) => c.method == 'SystemChrome.setPreferredOrientations')
          .arguments,
      contains('DeviceOrientation.portraitUp'),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('Tablet im Querformat bleibt im Analyzer-Vollbild quer', (
    tester,
  ) async {
    final orientations = await openFullscreen(tester, const Size(960, 600));
    expect(orientations, contains('DeviceOrientation.landscapeLeft'));
    expect(orientations, isNot(contains('DeviceOrientation.portraitUp')));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });
}
