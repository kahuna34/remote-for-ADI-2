import 'package:adi2_remote/analyzer/analyzer_controller.dart';
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
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

  Future<List<Object?>> openFullscreen(WidgetTester tester, Size size) async {
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
  });

  testWidgets('Tablet im Hochformat bleibt im Analyzer-Vollbild hochkant', (
    tester,
  ) async {
    final orientations = await openFullscreen(tester, const Size(600, 960));
    expect(orientations, ['DeviceOrientation.portraitUp']);
  });

  testWidgets('Tablet im Querformat bleibt im Analyzer-Vollbild quer', (
    tester,
  ) async {
    final orientations = await openFullscreen(tester, const Size(960, 600));
    expect(orientations, contains('DeviceOrientation.landscapeLeft'));
    expect(orientations, isNot(contains('DeviceOrientation.portraitUp')));
  });
}
