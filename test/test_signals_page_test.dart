import 'package:adi2_remote/analyzer/analyzer_controller.dart';
import 'package:adi2_remote/analyzer/linux_test_signal.dart';
import 'package:adi2_remote/analyzer/test_signal.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/desktop/desktop_windows.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/ui/analyzer_controls.dart';
import 'package:adi2_remote/ui/app_settings_page.dart';
import 'package:adi2_remote/ui/test_signals_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Device extends Adi2Controller {
  _Device({this.embeddedHost = true});
  @override
  final bool embeddedHost;
  bool remote = false;
  @override
  bool get usesLocalHost => embeddedHost && !remote;
}

class _Windows extends DesktopWindows {
  @override
  Future<void> open(AuxiliaryWindow kind) async {}
}

class _Player extends LinuxTestSignalPlayer {
  final starts = <TestSignalSettings>[];
  int stops = 0;
  @override
  Future<void> start(TestSignalSettings value) async {
    starts.add(value);
    settings = value;
    running = true;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stops++;
    running = false;
    busy = false;
    notifyListeners();
  }
}

void main() {
  late _Device device;
  late _Player player;
  late _Windows windows;
  late AppLanguage previousLanguage;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
    previousLanguage = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    device = _Device();
    player = _Player();
    windows = _Windows();
  });
  tearDown(() {
    device.dispose();
    windows.dispose();
    player.dispose();
    AppLang.instance.language = previousLanguage;
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> page(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TestSignalsPage(ctrl: device, player: player),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> start(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('test-signal-start')));
    await tester.pumpAndSettle();
  }

  Future<void> stop(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('test-signal-stop')));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  }

  Future<void> choose(WidgetTester tester, TestSignal signal) async {
    await tester.tap(find.byKey(const ValueKey('test-signal-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(testSignalTitle(signal)).last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'first-start notice is mandatory, cancellable and session-scoped; defaults to −20',
    (tester) async {
      await page(tester);
      await start(tester);
      expect(find.text('Testsignal per USB'), findsOneWidget);
      expect(find.textContaining('Quelle USB/Auto'), findsOneWidget);
      expect(player.starts, isEmpty);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(player.sessionAccepted, isFalse);
      await start(tester);
      await tester.tap(find.text('Verstanden'));
      await tester.pumpAndSettle();
      expect(player.starts.single.dbfs, -20);
      expect(player.sessionAccepted, isTrue);
      await stop(tester);
      await start(tester);
      expect(player.starts.length, 2);
      expect(find.byType(AlertDialog), findsNothing);
      await finish(tester);
      await page(tester);
      await start(tester);
      expect(player.starts.length, 3);
      expect(find.byType(AlertDialog), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'level steps always require additional approval, repeated on every start',
    (tester) async {
      await page(tester);
      await choose(tester, TestSignal.levels);
      await start(tester);
      await tester.tap(find.text('Verstanden'));
      await tester.pumpAndSettle();
      expect(find.text('Hoher Testpegel'), findsOneWidget);
      expect(player.starts, isEmpty);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      await start(tester);
      expect(find.text('Hoher Testpegel'), findsOneWidget);
      await tester.tap(find.text('Hohen Pegel starten'));
      await tester.pumpAndSettle();
      expect(player.starts.single.signal, TestSignal.levels);
      await stop(tester);
      await start(tester);
      expect(find.text('Hoher Testpegel'), findsOneWidget);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(player.starts.length, 1);
      await finish(tester);
    },
  );

  testWidgets(
    '−6 dBFS needs no extra approval; −5 does; stop remains accessible',
    (tester) async {
      player.sessionAccepted = true;
      await page(tester);
      tester.widget<Slider>(find.byType(Slider)).onChanged!(-6);
      await tester.pump();
      await start(tester);
      expect(player.starts.single.dbfs, -6);
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
      await stop(tester);
      tester.widget<Slider>(find.byType(Slider)).onChanged!(-5);
      await tester.pump();
      await start(tester);
      expect(find.text('Hoher Testpegel'), findsOneWidget);
      expect(player.starts.length, 1);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      await finish(tester);
    },
  );

  testWidgets(
    'invalid frequency cannot start; quick frequency and valid value reach player',
    (tester) async {
      player.sessionAccepted = true;
      await page(tester);
      await tester.enterText(find.byType(TextField), 'NaN');
      await start(tester);
      expect(player.starts, isEmpty);
      await tester.tap(find.widgetWithText(ActionChip, '31.5 Hz'));
      await start(tester);
      expect(player.starts.single.frequency, 31.5);
      await finish(tester);
    },
  );

  testWidgets('leaving page and hidden lifecycle stop output', (tester) async {
    player.sessionAccepted = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => TestSignalsPage(ctrl: device, player: player),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await start(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(player.running, isFalse);
    expect(player.stops, greaterThan(0));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await start(tester);
    final stops = player.stops;
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(player.stops, greaterThan(stops));
    expect(player.running, isFalse);
    await finish(tester);
  });

  testWidgets(
    'both app menu and analyzer settings expose page in embedded Linux main window',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await tester.pumpWidget(
        DesktopWindowScope(
          windows: windows,
          child: MaterialApp(home: AppSettingsPage(ctrl: device)),
        ),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('test-signals-open')),
        200,
      );
      expect(find.text('Testsignale'), findsOneWidget);
      await finish(tester);
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final analyzer = AnalyzerController();
      await tester.pumpWidget(
        DesktopWindowScope(
          windows: windows,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      showAnalyzerSettings(context, analyzer, device),
                  child: const Text('settings'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('test-signals-open')));
      await tester.pumpAndSettle();
      expect(find.byType(TestSignalsPage), findsOneWidget);
      await finish(tester);
      analyzer.dispose();
    },
  );

  for (final platform in TargetPlatform.values) {
    for (final embedded in [true, false]) {
      testWidgets('visibility $platform, embedded=$embedded', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final ctrl = _Device(embeddedHost: embedded);
        await tester.pumpWidget(
          DesktopWindowScope(
            windows: windows,
            child: MaterialApp(
              home: Scaffold(body: TestSignalsTile(ctrl: ctrl)),
            ),
          ),
        );
        expect(
          find.byKey(const ValueKey('test-signals-open')),
          platform == TargetPlatform.linux && embedded
              ? findsOneWidget
              : findsNothing,
        );
        await finish(tester);
        ctrl.dispose();
      });
    }
  }

  testWidgets(
    'Remote desktop selection does not offer the local USB generator',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      device.remote = true;
      await tester.pumpWidget(
        DesktopWindowScope(
          windows: windows,
          child: MaterialApp(
            home: Scaffold(body: TestSignalsTile(ctrl: device)),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('test-signals-open')), findsNothing);
      await finish(tester);
    },
  );

  testWidgets('auxiliary process without main-window scope has no generator', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TestSignalsTile(ctrl: device)),
      ),
    );
    expect(find.byKey(const ValueKey('test-signals-open')), findsNothing);
    await finish(tester);
  });
}
