import 'package:adi2_remote/analyzer/analyzer_controller.dart';
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/dev/analyzer_selftest_diagnostics.dart';
import 'package:adi2_remote/analyzer/header_content.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/easy/easy_layout.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:adi2_remote/ui/analyzer_controls.dart';
import 'package:adi2_remote/ui/header_content_picker.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/player_bar.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Controller extends Adi2Controller {
  _Controller() {
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
}

void main() {
  final settings = AppSettings.instance;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
    final previous = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    addTearDown(() => AppLang.instance.language = previous);
  });

  testWidgets('microphone fallback shows source warning without a spectrum', (
    tester,
  ) async {
    final controller = AnalyzerController()
      ..status = AnalyzerStatus.usbUnavailable
      ..inputRejected = true
      ..diagnostics = {
        'routedDevice': {
          'name': 'Built-in mic',
          'type': 15,
          'id': 8,
          'phoneMicrophone': true,
        },
      };
    addTearDown(controller.dispose);
    for (final language in AppLanguage.values) {
      AppLang.instance.language = language;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AnalyzerDisplay(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          tr('Quelle: Handy-Mikrofon – ADI-2-Aufnahme nicht verfügbar'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('analyzer-spectrum')), findsNothing);
    }
  });

  testWidgets(
    'developer capture info fits compact analyzer and hides outside developer mode',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      final controller = AnalyzerController()
        ..status = AnalyzerStatus.usbUnavailable
        ..diagnostics = {
          'routedDevice': {'name': 'ADI-2 DAC', 'type': 11, 'id': 17},
          'requestedFormat': {
            'sampleRate': 48000,
            'channels': 2,
            'encoding': 2,
          },
          'actualFormat': {'sampleRate': 48000, 'channels': 2, 'encoding': 2},
          'audioSource': 6,
          'pcmScaling': 'PCM16 / 32768',
        };
      addTearDown(controller.dispose);
      addTearDown(() => analyzerDeveloperMode.value = false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 112,
              child: AnalyzerDisplay(controller: controller, compact: true),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('analyzer-diagnostics')), findsNothing);
      analyzerDeveloperMode.value = true;
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('analyzer-info-expanded')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('analyzer-info-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('analyzer-info-expanded')),
          matching: find.textContaining('ADI-2 DAC (Typ 11, ID 17)'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('analyzer-info-expanded')),
          matching: find.textContaining('PCM16 / 32768'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test('bar gaps are positive at all resolutions, outer edges flush', () {
    for (final resolution in AnalyzerBandResolution.values) {
      for (final width in [1.0, 107.3, 328.0, 708.0, 882.0]) {
        for (final left in [0.0, 2.0, 32.0]) {
          final area = Rect.fromLTWH(left, 4, width, 100);
          final first = analyzerBarBounds(area, resolution, 0);
          final last = analyzerBarBounds(
            area,
            resolution,
            resolution.count - 1,
          );
          expect(first.left, greaterThanOrEqualTo(0));
          expect(first.left, area.left);
          expect(first.width, greaterThan(0));
          expect(last.right, area.right);
          for (var i = 1; i < resolution.count; i++) {
            final previous = analyzerBarBounds(area, resolution, i - 1);
            final current = analyzerBarBounds(area, resolution, i);
            expect(current.left, greaterThan(previous.right));
            if (width >= 328) {
              expect(
                current.left - previous.right,
                greaterThanOrEqualTo(1 - 1e-10),
              );
            }
            expect(current.width, greaterThan(0));
          }
        }
      }
    }
  });

  for (final compact in [true, false]) {
    testWidgets('RMS fill and peak marker remain distinct compact=$compact', (
      tester,
    ) async {
      final c = AnalyzerController()..status = AnalyzerStatus.running;
      addTearDown(c.dispose);
      c.frame = AnalyzerFrame(
        sampleRate: 48000,
        spectrum: List.filled(2049, 0.1),
        peak: [0, -6],
        rms: [-12, -18],
        clipped: [true, false],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 740,
              height: compact ? 112 : 360,
              child: AnalyzerDisplay(controller: c, compact: compact),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bar = find.byType(AnalyzerLevelBar).last;
      final rmsFinder = find.descendant(
        of: bar,
        matching: find.byKey(const ValueKey('analyzer-rms-fill')),
      );
      final peakFinder = find.descendant(
        of: bar,
        matching: find.byKey(const ValueKey('analyzer-peak-marker')),
      );
      final rms = tester.getRect(rmsFinder), peak = tester.getRect(peakFinder);
      expect(rms.width / tester.getSize(bar).width, closeTo(0.7, 0.001));
      expect(rms.height, greaterThanOrEqualTo(7));
      expect(peak.left, greaterThan(rms.right));
      expect(tester.widget<ColoredBox>(rmsFinder).color.a, 1);
      expect(
        tester.widget<ColoredBox>(peakFinder).color,
        isNot(tester.widget<ColoredBox>(rmsFinder).color),
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final custom in [false, true]) {
    testWidgets('header selection player/status/analyzer/none custom=$custom', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      final c = _Controller(), np = NowPlaying();
      addTearDown(c.dispose);
      addTearDown(np.dispose);
      await settings.setEasyMode(custom);
      for (final choice in HeaderContent.values) {
        if (custom) {
          await settings.setEasyLayout(
            c.variant,
            EasyLayout(tiles: []).withHeaderContent(choice),
          );
        } else {
          await settings.setHeaderContent(choice);
        }
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: HomePage(ctrl: c, np: np),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(PlayerBar),
          choice == HeaderContent.player ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(AnalyzerPanel),
          choice == HeaderContent.analyzer ? findsOneWidget : findsNothing,
        );
        if (choice == HeaderContent.status) {
          expect(find.byKey(const ValueKey('digital-mini')), findsOneWidget);
        }
        if (choice == HeaderContent.none) {
          expect(find.byKey(const ValueKey('digital-mini')), findsNothing);
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('picker makes exclusive choices and exposes automatic source', (
    tester,
  ) async {
    var selected = HeaderContent.player;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: StatefulBuilder(
          builder: (context, update) => Scaffold(
            body: HeaderContentPicker(
              value: selected,
              onChanged: (v) => update(() => selected = v),
            ),
          ),
        ),
      ),
    );
    for (final choice in HeaderContent.values) {
      await tester.tap(find.byKey(ValueKey('header-${choice.name}')));
      await tester.pumpAndSettle();
      expect(selected, choice);
      expect(
        tester
            .widgetList<ChoiceChip>(find.byType(ChoiceChip))
            .where((c) => c.selected)
            .length,
        1,
      );
      if (choice == HeaderContent.analyzer) {
        expect(
          find.text('Quelle: Automatisch (Loopback, sonst Eingang)'),
          findsOneWidget,
        );
      }
    }
  });

  for (final status in [
    AnalyzerStatus.permissionRequired,
    AnalyzerStatus.usbUnavailable,
    AnalyzerStatus.captureFailed,
    AnalyzerStatus.silent,
  ]) {
    testWidgets('explanatory message for $status in German and English', (
      tester,
    ) async {
      final controller = AnalyzerController()..status = status;
      addTearDown(controller.dispose);
      for (final language in AppLanguage.values) {
        AppLang.instance.language = language;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: Scaffold(
              body: SizedBox(
                height: 112,
                child: AnalyzerDisplay(controller: controller, compact: true),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(tr(AnalyzerDisplay.statusText(status))),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('permission explanation precedes platform request', (
    tester,
  ) async {
    var requests = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('adi2/analyzer'),
      (call) async {
        if (call.method == 'requestPermission') requests++;
        return false;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('adi2/analyzer'),
        null,
      ),
    );
    final controller = AnalyzerController()
      ..status = AnalyzerStatus.permissionRequired;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: SizedBox(
            height: 112,
            child: AnalyzerDisplay(controller: controller, compact: true),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Berechtigung erteilen'));
    await tester.pumpAndSettle();
    expect(find.text('USB-Audio aufnehmen'), findsOneWidget);
    expect(requests, 0);
    await tester.tap(
      find.widgetWithText(FilledButton, 'Berechtigung erteilen'),
    );
    await tester.pumpAndSettle();
    expect(requests, 1);
  });

  testWidgets(
    'compact signal and fullscreen controls fit and keep capture running',
    (tester) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('adi2/analyzer'),
        (call) async {
          calls.add(call.method);
          return call.method == 'permission' ? true : null;
        },
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('adi2/analyzer/events'),
        (_) async => null,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('adi2/analyzer'),
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('adi2/analyzer/events'),
          null,
        );
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      final controller = AnalyzerController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(body: AnalyzerPanel(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls.where((c) => c == 'start').length, 1);
      controller.frame = AnalyzerFrame(
        sampleRate: 48000,
        spectrum: List.filled(2049, 0.1),
        peak: [0, -6],
        rms: [-3, -9],
        clipped: [true, false],
      );
      controller.status = AnalyzerStatus.running;
      controller.notifyListeners();
      await tester.pump();
      expect(find.text('Peak / RMS · dBFS'), findsNothing);
      await tester.tap(find.byType(AnalyzerDisplay));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(800, 360);
      await tester.pumpAndSettle();
      expect(find.text('Balken'), findsOneWidget);
      await tester.tap(find.text('Balken'));
      await tester.pumpAndSettle();
      expect(controller.bars, isTrue);
      expect(
        find.byType(AnalyzerChoices<AnalyzerBandResolution>),
        findsOneWidget,
      );
      await tester.tap(find.text('1/12').last);
      await tester.pumpAndSettle();
      expect(controller.bandResolution, AnalyzerBandResolution.twelfth);
      await controller.setBandResolution(AnalyzerBandResolution.third);
      await tester.pumpAndSettle();
      expect(controller.bandResolution, AnalyzerBandResolution.third);
      for (final size in [const Size(914, 411), const Size(740, 360)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.ensureVisible(find.text('Peak hold'));
      await tester.tap(find.text('Peak hold'));
      await tester.pumpAndSettle();
      expect(controller.peakHold, isFalse);
      expect(calls.where((c) => c == 'start').length, 1);
      expect(calls.where((c) => c == 'stop'), isEmpty);
      for (final size in [const Size(914, 411), const Size(740, 360)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(tr('Nur Spektrum')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('analyzer-fullscreen-levels')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('analyzer-view-controls')),
          findsNothing,
        );
        final plot = tester.getRect(
          find.byKey(const ValueKey('analyzer-spectrum')).last,
        );
        expect(plot.size, size);
        expect(find.byTooltip(tr('Bedienleiste anzeigen')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('analyzer-spectrum-only')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('analyzer-fullscreen-levels')),
          findsOneWidget,
        );
        expect(controller.bars, isTrue);
        expect(controller.peakHold, isFalse);
      }
      await tester.tap(find.byIcon(Icons.fullscreen_exit));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      expect(calls.where((c) => c == 'stop').length, 1);
      expect(tester.takeException(), isNull);
    },
  );
  for (final size in [const Size(914, 411), const Size(740, 360)]) {
    for (final language in AppLanguage.values) {
      testWidgets(
        'fullscreen levels sit above full-width plot at $size / $language',
        (tester) async {
          AppLang.instance.language = language;
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.reset);
          final c = AnalyzerController()..status = AnalyzerStatus.running;
          addTearDown(c.dispose);
          c.frame = AnalyzerFrame(
            sampleRate: 48000,
            spectrum: List.filled(2049, 0.1),
            peak: const [0, -6],
            rms: const [-3, -9],
            clipped: const [true, false],
          );
          for (final resolution in AnalyzerBandResolution.values) {
            await c.setBandResolution(resolution);
            for (final bars in [false, true]) {
              c.setBars(bars);
              c.spectrum.update(List.filled(2049, -24), 2);
              c.bands.update(List.filled(resolution.count, -24), 2);
              await tester.pumpWidget(
                MaterialApp(
                  theme: buildTheme(),
                  home: Scaffold(body: AnalyzerDisplay(controller: c)),
                ),
              );
              await tester.pumpAndSettle();
              final plot = tester.getRect(
                find.byKey(const ValueKey('analyzer-spectrum')),
              );
              final levels = tester.getRect(
                find.byKey(const ValueKey('analyzer-fullscreen-levels')),
              );
              expect(plot.width, size.width - 32);
              expect(levels.bottom, lessThan(plot.top));
              expect(levels.right, plot.right);
              expect(find.byType(AnalyzerLevelBar), findsNWidgets(2));
              expect(levels.width, (size.width - 48) / 2);
              final viewControls = tester.getRect(
                find.byKey(const ValueKey('analyzer-view-controls')),
              );
              // Quick dropdowns belong to the fullscreen route's top bar.
              expect(
                find.byKey(const ValueKey('analyzer-ballistics-header')),
                findsNothing,
              );
              expect(viewControls.right, lessThan(levels.left));
              expect(levels.top, viewControls.top);
              expect(viewControls.height, greaterThanOrEqualTo(28));
              final tracks = tester.getRect(
                find.byKey(const ValueKey('analyzer-track-0')),
              );
              final rightTrack = tester.getRect(
                find.byKey(const ValueKey('analyzer-track-1')),
              );
              expect(tracks.left, rightTrack.left);
              expect(tracks.width, rightTrack.width);
              expect(tracks.height, rightTrack.height);
              final labels = tester.getRect(
                find.byKey(const ValueKey('analyzer-channel-0')),
              );
              expect(
                labels.left,
                tester
                    .getRect(find.byKey(const ValueKey('analyzer-channel-1')))
                    .left,
              );
              final numbers = tester.getRect(
                find.byKey(const ValueKey('analyzer-values-0')),
              );
              expect(
                numbers.left,
                tester
                    .getRect(find.byKey(const ValueKey('analyzer-values-1')))
                    .left,
              );
              expect(
                numbers.right,
                tester
                    .getRect(find.byKey(const ValueKey('analyzer-values-1')))
                    .right,
              );

              for (var metric = 0; metric < 2; metric++) {
                final left = tester.getRect(
                  find.byKey(ValueKey('analyzer-number-0-$metric')),
                );
                final right = tester.getRect(
                  find.byKey(ValueKey('analyzer-number-1-$metric')),
                );
                expect(left.left, right.left);
                expect(left.right, right.right);
              }
              expect(plot.height, greaterThan(size.height * 0.5));
              final rms = tester.getRect(
                find.byKey(const ValueKey('analyzer-rms-fill')).last,
              );
              final peak = tester.getRect(
                find.byKey(const ValueKey('analyzer-peak-marker')).last,
              );
              expect(rms.height, 18);
              expect(rms.width, greaterThan(100));
              expect(peak.width, 2);
              expect(find.text(tr('Peak / RMS · dBFS')), findsOneWidget);
              expect(tester.takeException(), isNull);
            }
          }
        },
      );
    }
  }
  testWidgets('capture stops behind routes and in background, resumes once', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('adi2/analyzer'),
      (call) async {
        calls.add(call.method);
        return call.method == 'permission' ? true : null;
      },
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('adi2/analyzer/events'),
      (_) async => null,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('adi2/analyzer'),
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('adi2/analyzer/events'),
        null,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const Scaffold(body: AnalyzerPanel()),
      ),
    );
    await tester.pumpAndSettle();
    final navigator = Navigator.of(tester.element(find.byType(AnalyzerPanel)));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Other page')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(calls.where((v) => v == 'stop').length, 1);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(calls.where((v) => v == 'start').length, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(calls.where((v) => v == 'stop').length, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls.where((v) => v == 'start').length, 3);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(calls.where((v) => v == 'stop').length, 3);
  });

  testWidgets(
    'automatic landscape opens and portrait closes the same analyzer',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: const Scaffold(body: AnalyzerPanel()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.fullscreen_exit), findsNothing);
      tester.view.physicalSize = const Size(800, 360);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
      expect(find.byType(AnalyzerChoices<AnalyzerView>), findsOneWidget);
      tester.view.physicalSize = const Size(360, 800);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.fullscreen_exit), findsNothing);
      expect(find.byType(AnalyzerPanel), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('custom header follows the selected output page', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    final c = _Controller(), np = NowPlaying();
    addTearDown(c.dispose);
    addTearDown(np.dispose);
    c.selectedOutput = Adi2Addr.ph12;
    await settings.setEasyMode(true);
    await settings.setEasyLayout(
      c.variant,
      EasyLayout(
        samePageForAllOutputs: false,
        tiles: [],
        outputPages: {
          Adi2Addr.line: EasyLayout(
            tiles: [const EasyTile(type: EasyTileType.outputSelect)],
          ).withHeaderContent(HeaderContent.status),
          Adi2Addr.ph12: EasyLayout(
            tiles: [const EasyTile(type: EasyTileType.outputSelect)],
          ).withHeaderContent(HeaderContent.analyzer),
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: HomePage(ctrl: c, np: np),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AnalyzerPanel), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('easy-segment-0-3')));
    await tester.pumpAndSettle();
    expect(find.byType(AnalyzerPanel), findsNothing);
    expect(find.byKey(const ValueKey('digital-mini')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact levels and silence hint fit enlarged text', (
    tester,
  ) async {
    final c = AnalyzerController()..status = AnalyzerStatus.silent;
    addTearDown(c.dispose);
    c.frame = AnalyzerFrame(
      sampleRate: 48000,
      spectrum: List.filled(2049, 0),
      peak: [-120, -120],
      rms: [-120, -120],
      clipped: [false, false],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: SizedBox(
              width: 328,
              height: 112,
              child: AnalyzerDisplay(controller: c, compact: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('home controls remain valid while analyzer opens on rotation', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    final c = _Controller(), np = NowPlaying();
    addTearDown(c.dispose);
    addTearDown(np.dispose);
    await settings.setHeaderContent(HeaderContent.analyzer);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: HomePage(ctrl: c, np: np),
      ),
    );
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(800, 360);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(360, 800);
    await tester.pumpAndSettle();
    expect(find.byType(AnalyzerPanel), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
