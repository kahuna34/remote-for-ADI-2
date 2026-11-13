import 'package:adi2_remote/analyzer/analyzer_controller.dart';
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/protocol/adi2_status.dart';
import 'package:adi2_remote/ui/analyzer_controls.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Midi implements MidiCommand {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Device extends Adi2Controller {
  _Device() : super(midi: _Midi());
  final writes = <(int, int, int)>[];
  // This widget fake acknowledges each command immediately.
  @override
  int? confirmedValue(int address, int index) => value(address, index);
  @override
  void set(int address, int index, int value) {
    writes.add((address, index, value));
    super.set(address, index, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = AppSettings.instance;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
    AppLang.instance.language = AppLanguage.de;
  });
  test(
    'all six colors persist; device-follow uses live and offline values',
    () async {
      final ctrl = _Device();
      await ctrl.startOffline(Adi2Variant.pro);
      for (var i = 0; i < 6; i++) {
        await settings.setAnalyzerColor(i);
        await settings.load();
        expect(analyzerColor(ctrl), analyzerColors[i]);
        ctrl.set(Adi2Addr.device, DevIdx.meterColor, (i + 1) % 6);
        expect(analyzerColor(ctrl), analyzerColors[i]);
      }
      await settings.setAnalyzerColor(-1);
      for (var i = 0; i < 6; i++) {
        ctrl.set(Adi2Addr.device, DevIdx.meterColor, i);
        expect(analyzerColor(ctrl), analyzerColors[i]);
      }
      ctrl.dispose();
    },
  );
  test('range and finer band choices persist', () async {
    for (final range in [60, 80, 100]) {
      await settings.setAnalyzerRange(range);
      await settings.load();
      expect(settings.analyzerRange, range);
    }
    for (final bands in [6, 12]) {
      SharedPreferences.setMockInitialValues({
        'analyzer_bands_per_octave': bands,
      });
      await settings.load();
      expect(settings.analyzerBandResolution.bandsPerOctave, bands);
      expect(settings.analyzerRange, 60);
      expect(settings.analyzerColor, -1);
      expect(
        (await SharedPreferences.getInstance()).getInt(
          'analyzer_bands_per_octave',
        ),
        bands,
      );
    }
    expect(AnalyzerBandResolution.third.count, 30);
    expect(AnalyzerBandResolution.third.centre(0), closeTo(25, 0.2));
    expect(AnalyzerBandResolution.third.centre(29), closeTo(20000, 50));
  });
  for (final variant in Adi2Variant.values) {
    test(
      'loopback writes USB 1/2 only and preserves other pairs: $variant',
      () async {
        final ctrl = _Device();
        await ctrl.startOffline(variant);
        final outputs = analyzerOutputs(ctrl);
        expect(outputs, isNotEmpty);
        ctrl.set(outputs.first.address, OutIdx.loopback, 2);
        if (outputs.length > 2 && variant.hasInput) {
          ctrl.set(outputs.last.address, OutIdx.loopback, 5);
        }
        ctrl.state = ConnState.connected;
        ctrl.writes.clear();
        setAnalyzerLoopback(ctrl, outputs[1].address, 3);
        if (variant.isDac) {
          expect(ctrl.writes, [(outputs[1].address, OutIdx.loopback, 3)]);
        } else {
          expect(ctrl.writes, [
            (outputs.first.address, OutIdx.loopback, 0),
            (outputs[1].address, OutIdx.loopback, 3),
          ]);
        }
        expect(ctrl.writes.last, (outputs[1].address, OutIdx.loopback, 3));
        if (outputs.length > 2 && variant.hasInput) {
          expect(ctrl.value(outputs.last.address, OutIdx.loopback), 5);
        }
        expect(
          analyzerLoopbackSource(ctrl)?.address,
          variant.isDac ? Adi2Addr.line : outputs[1].address,
        );
        setAnalyzerLoopback(ctrl, outputs[1].address, 0);
        expect(analyzerLoopbackSource(ctrl), isNull);
        ctrl.state = ConnState.offline;
        ctrl.writes.clear();
        setAnalyzerLoopback(ctrl, outputs.first.address, 2);
        expect(ctrl.writes, [(outputs.first.address, OutIdx.loopback, 2)]);
        ctrl.dispose();
      },
    );
  }
  for (final language in AppLanguage.values) {
    testWidgets('tool and spectrum buttons in settings: $language', (
      tester,
    ) async {
      AppLang.instance.language = language;
      final controller = AnalyzerController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showAnalyzerSettings(context, controller, null),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(tr('Werkzeug')), findsOneWidget);
      final tool = find.byKey(const ValueKey('analyzer-tool'));
      final mode = find.byKey(const ValueKey('analyzer-spectrum-mode'));
      final bands = find.byKey(const ValueKey('analyzer-band-resolution'));
      expect(
        tester.widget<AnalyzerChoices<AnalyzerView>>(tool).values,
        AnalyzerView.values,
      );
      expect(
        find.descendant(of: tool, matching: find.text(tr('Spektrum'))),
        findsOneWidget,
      );
      expect(tester.getRect(tool).bottom, lessThan(tester.getRect(mode).top));
      expect(tester.getRect(mode).bottom, lessThan(tester.getRect(bands).top));
      for (final bars in [true, false]) {
        final label = find.text(tr(bars ? 'Balken' : 'Linien'));
        expect(
          find.ancestor(of: label, matching: find.byType(ChoiceChip)),
          findsOneWidget,
        );
        await tester.tap(label);
        await tester.pump();
        expect(controller.bars, bars);
      }
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'settings sheet has color, range, ballistics and offline loopback',
    (tester) async {
      final ctrl = _Device();
      await ctrl.startOffline(Adi2Variant.pro);
      final analyzer = AnalyzerController();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAnalyzerSettings(context, analyzer, ctrl),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Analyzer-Farbe'), findsOneWidget);
      expect(find.text('Wie Gerät'), findsOneWidget);
      expect(find.text('Pegelbereich'), findsOneWidget);
      expect(find.text('Ballistik'), findsOneWidget);
      expect(find.text('Loopback-Quelle'), findsOneWidget);
      expect(find.text('Abgriff'), findsNothing);
      expect(find.byWidgetPredicate((w) => w is DropdownButton), findsNothing);
      for (final key in [
        'analyzer-tool',
        'analyzer-spectrum-mode',
        'analyzer-color',
        'analyzer-range',
        'analyzer-ballistics',
        'analyzer-band-resolution',
        'analyzer-loopback-output',
        'analyzer-loopback-tap',
        'analyzer-peak-hold-seconds',
      ]) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(ChoiceChip),
          ),
          findsWidgets,
        );
      }
      final dropdown = tester.widget<AnalyzerChoices<int>>(
        find.byKey(const ValueKey('analyzer-loopback-tap')),
      );
      expect(dropdown.onSelected, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      analyzer.dispose();
      ctrl.dispose();
    },
  );
  testWidgets(
    'Peak-Hold-Zeit wird gespeichert und sofort auf alle Anzeigen angewendet',
    (tester) async {
      final controller = AnalyzerController();
      addTearDown(controller.dispose);
      expect(settings.analyzerPeakHoldSeconds, 1);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showAnalyzerSettings(context, controller, null),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final envelopes = [
        controller.spectrum,
        controller.bassSpectrum,
        controller.bands,
      ];
      for (final envelope in envelopes) {
        envelope.update([-5], .1);
      }
      await Scrollable.ensureVisible(
        tester.element(find.text('5 s')),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('5 s'));
      await tester.pumpAndSettle();
      expect(
        (await SharedPreferences.getInstance()).getInt(
          'analyzer_peak_hold_seconds',
        ),
        5,
      );
      for (final envelope in envelopes) {
        expect(envelope.holdSeconds, 5);
        envelope.update([-60], 2);
        expect(envelope.held.single, -5);
        envelope.update([-60], 4);
        expect(envelope.held.single, closeTo(-17, .0001));
      }
      await Scrollable.ensureVisible(
        tester.element(find.text('∞')),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('∞'));
      await tester.pumpAndSettle();
      for (final envelope in envelopes) {
        expect(envelope.holdSeconds, double.infinity);
        envelope.update([-60], 1000);
        expect(envelope.held.single, closeTo(-17, .0001));
      }
      expect(
        (await SharedPreferences.getInstance()).getInt(
          'analyzer_peak_hold_seconds',
        ),
        0,
      );
      final infinite = AnalyzerController();
      expect(infinite.spectrum.holdSeconds, double.infinity);
      infinite.dispose();
      await Scrollable.ensureVisible(
        tester.element(find.text('2 s')),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('2 s'));
      await tester.pumpAndSettle();
      for (final envelope in envelopes) {
        expect(envelope.holdSeconds, 2);
        envelope.update([-60], 3);
        expect(envelope.held.single, closeTo(-29, .0001));
      }
      await settings.load();
      final restored = AnalyzerController();
      expect(settings.analyzerPeakHoldSeconds, 2);
      expect(restored.spectrum.holdSeconds, 2);
      expect(restored.bassSpectrum.holdSeconds, 2);
      expect(restored.bands.holdSeconds, 2);
      restored.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Abgriff zeigt den Gerätezustand statt des gespeicherten Werts', (
    tester,
  ) async {
    await settings.setAnalyzerRouting(output: 0, tap: 2);
    await settings.confirmAnalyzerLoopback();
    final ctrl = _Device();
    await ctrl.startOffline(Adi2Variant.dac);
    ctrl.state = ConnState.connected;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: AnalyzerLoopbackControls(ctrl: ctrl)),
      ),
    );
    await tester.pumpAndSettle();
    final tap = find.byKey(const ValueKey('analyzer-loopback-tap'));
    expect(tester.widget<AnalyzerChoices<int>>(tap).value, 0);
    expect(ctrl.writes, isEmpty);
    expect(
      find.byKey(const ValueKey('analyzer-loopback-output')),
      findsNothing,
    );

    await tester.tap(find.text('post FX').last);
    await tester.pumpAndSettle();
    expect(ctrl.writes, [(Adi2Addr.line, OutIdx.loopback, 2)]);
    expect(tester.widget<AnalyzerChoices<int>>(tap).value, 2);
    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });
  testWidgets('first loopback change asks once and writes chosen output/tap', (
    tester,
  ) async {
    final ctrl = _Device();
    await ctrl.startOffline(Adi2Variant.pro);
    ctrl.state = ConnState.connected;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: AnalyzerLoopbackControls(ctrl: ctrl)),
      ),
    );
    await tester.tap(find.text('post FX').last);
    await tester.pumpAndSettle();
    expect(ctrl.writes, isEmpty);
    expect(
      find.text(
        'Loopback auf USB 1/2 ersetzt dort die Aufnahme des Analogeingangs',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Bestätigen'));
    await tester.pumpAndSettle();
    expect(ctrl.writes.last, (Adi2Addr.line, OutIdx.loopback, 2));
    expect(settings.analyzerLoopbackConfirmed, isTrue);
    await tester.pumpWidget(const SizedBox());
    await settings.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: AnalyzerLoopbackControls(ctrl: ctrl)),
      ),
    );
    await tester.pumpAndSettle();
    ctrl.writes.clear();
    await tester.tap(find.text('Phones 3/4').last);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(ctrl.writes, [
      (Adi2Addr.line, OutIdx.loopback, 0),
      (Adi2Addr.ph34, OutIdx.loopback, 2),
    ]);
    expect(
      find.text(
        'Loopback von Line Out ausgeschaltet, weil 1/2 jetzt belegt ist',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });
  testWidgets(
    'display follows device color live, clips levels to selected range, keeps source below plot',
    (tester) async {
      final ctrl = _Device();
      await ctrl.startOffline(Adi2Variant.pro);
      final analyzer = AnalyzerController()..status = AnalyzerStatus.running;
      analyzer.frame = const AnalyzerFrame(
        sampleRate: 48000,
        spectrum: [0, 0.1],
        peak: [-70, 0],
        rms: [-75, -3],
        clipped: [false, true],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: AnalyzerDisplay(controller: analyzer, deviceController: ctrl),
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        ctrl.set(Adi2Addr.device, DevIdx.meterColor, i);
        await tester.pump();
        final levels = tester
            .widgetList<AnalyzerLevelBar>(find.byType(AnalyzerLevelBar))
            .toList();
        expect(levels.first.color, analyzerColors[i]);
        expect(levels.last.clipped, isTrue);
        final rms = tester.getRect(
          find.byKey(const ValueKey('analyzer-rms-fill')).first,
        );
        expect(rms.width, 0);
        final peak = tester.getRect(
          find.byKey(const ValueKey('analyzer-peak-marker')).first,
        );
        expect(peak.left, rms.left);
        expect(
          tester
              .widget<ColoredBox>(
                find.byKey(const ValueKey('analyzer-peak-marker')).last,
              )
              .color,
          Palette.red,
        );
      }
      await settings.setAnalyzerRange(100);
      await tester.pump();
      final bar = find.byType(AnalyzerLevelBar).first;
      final rms = tester.getRect(
        find.byKey(const ValueKey('analyzer-rms-fill')).first,
      );
      final peak = tester.getRect(
        find.byKey(const ValueKey('analyzer-peak-marker')).first,
      );
      expect(rms.width / tester.getSize(bar).width, closeTo(0.25, 0.001));
      expect(
        (peak.left - rms.left) / (tester.getSize(bar).width - 2),
        closeTo(0.3, 0.001),
      );
      final info = find.text('USB 1/2 · Analogeingang · 48.0 kHz');
      expect(info, findsOneWidget);
      expect(
        tester.getRect(info).top,
        greaterThanOrEqualTo(
          tester
              .getRect(find.byKey(const ValueKey('analyzer-spectrum')))
              .bottom,
        ),
      );
      await tester.pumpWidget(const SizedBox());
      analyzer.dispose();
      ctrl.dispose();
    },
  );
  testWidgets(
    'compact toolbar keeps settings and fullscreen adjacent with source in settings',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      final ctrl = _Device();
      await ctrl.startOffline(Adi2Variant.dac);
      final analyzer = AnalyzerController();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('adi2/analyzer'),
        (_) async => false,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: AnalyzerPanel(controller: analyzer, deviceController: ctrl),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('analyzer-loopback-icon')),
        findsNothing,
      );
      expect(find.byIcon(Icons.input), findsNothing);
      // The capture fake has no data. Supply a display frame for the meter
      // placement checks; the real idle toolbar is checked before this too.
      expect(
        find.byIcon(Icons.settings_outlined).hitTestable(),
        findsOneWidget,
      );
      analyzer.status = AnalyzerStatus.running;
      analyzer.frame = AnalyzerFrame(
        sampleRate: 48000,
        spectrum: List.filled(2049, .1),
        peak: [-20, -20],
        rms: [-24, -24],
        clipped: [false, false],
      );
      analyzer.notifyListeners();
      await tester.pump();
      // Peak hold and Reset share the bottom row below the full-width spectrum.
      expect(
        tester.getSize(find.byKey(const ValueKey('analyzer-peak-hold'))).height,
        greaterThanOrEqualTo(28),
      );
      expect(find.text('Peak hold'), findsOneWidget);
      expect(find.byKey(const ValueKey('analyzer-peak-reset')), findsOneWidget);
      final gear = find.byIcon(Icons.settings_outlined);
      final toolbar = find.byKey(const ValueKey('analyzer-compact-buttons'));
      final toolbarRect = tester.getRect(toolbar);
      expect(
        toolbarRect.top,
        greaterThanOrEqualTo(
          tester
              .getRect(find.byKey(const ValueKey('analyzer-spectrum')))
              .bottom,
        ),
      );
      final fullscreen = find.byIcon(Icons.fullscreen);
      for (final target in [
        find.ancestor(of: gear, matching: find.byType(IconButton)),
        find.ancestor(of: fullscreen, matching: find.byType(IconButton)),
      ]) {
        expect(tester.getSize(target), const Size(44, 32));
        expect(toolbarRect.contains(tester.getCenter(target)), isTrue);
        expect(target.hitTestable(), findsOneWidget);
      }
      expect(tester.getCenter(fullscreen).dx - tester.getCenter(gear).dx, 50);
      ctrl.set(Adi2Addr.line, OutIdx.loopback, 2);
      await tester.pump();
      await tester.tap(gear);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('analyzer-color')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('analyzer-loopback-output')),
        findsNothing,
      );
      expect(
        tester
            .widget<AnalyzerChoices<int>>(
              find.byKey(const ValueKey('analyzer-loopback-tap')),
            )
            .onSelected,
        isNotNull,
      );
      Navigator.of(tester.element(find.byType(AnalyzerColorSetting))).pop();
      await tester.pumpAndSettle();
      await tester.tap(fullscreen);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
      expect(
        find.byKey(const ValueKey('analyzer-loopback-tap')),
        findsOneWidget,
      );
      await tester.tap(find.byIcon(Icons.fullscreen_exit));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      analyzer.dispose();
      ctrl.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('adi2/analyzer'),
        null,
      );
    },
  );

  testWidgets('capture continues while compact settings sheet is open', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    final calls = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('adi2/analyzer'), (
      call,
    ) async {
      calls.add(call.method);
      return call.method == 'permission' ? true : null;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('adi2/analyzer/events'),
      (_) async => null,
    );
    final analyzer = AnalyzerController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: AnalyzerPanel(controller: analyzer)),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls.where((c) => c == 'start').length, 1);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c == 'stop'), isEmpty);
    Navigator.of(tester.element(find.byType(AnalyzerColorSetting))).pop();
    await tester.pumpAndSettle();
    expect(calls.where((c) => c == 'start').length, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(calls.where((c) => c == 'stop').length, 1);
    analyzer.dispose();
    messenger.setMockMethodCallHandler(
      const MethodChannel('adi2/analyzer'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('adi2/analyzer/events'),
      null,
    );
  });
  testWidgets(
    'automatic routing survives compact, fullscreen, hidden controls and settings',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      await settings.setAutoFullscreenEq(false);
      await settings.confirmAnalyzerLoopback();
      await settings.setAnalyzerRouting(output: 0, tap: 3);
      final ctrl = _Device();
      await ctrl.startOffline(Adi2Variant.pro);
      ctrl.state = ConnState.connected;
      ctrl.status = Adi2Status([0]);
      ctrl.selectedOutput = Adi2Addr.line;
      final analyzer = AnalyzerController();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('adi2/analyzer'),
        (_) async => false,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: AnalyzerPanel(controller: analyzer, deviceController: ctrl),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(ctrl.writes, isEmpty);
      await tester.tap(find.byIcon(Icons.fullscreen));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(740, 360);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Nur Spektrum'));
      await tester.pumpAndSettle();
      ctrl.writes.clear();
      ctrl.status = Adi2Status([1]);
      ctrl.selectedOutput = Adi2Addr.ph34;
      ctrl.notifyListeners();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(ctrl.writes, [(Adi2Addr.ph34, OutIdx.loopback, 3)]);
      await tester.tap(find.byTooltip('Bedienleiste anzeigen'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.settings_outlined).last);
      await tester.pumpAndSettle();
      ctrl.writes.clear();
      ctrl.status = Adi2Status([2]);
      ctrl.selectedOutput = Adi2Addr.line;
      ctrl.notifyListeners();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(ctrl.writes, [
        (Adi2Addr.ph34, OutIdx.loopback, 0),
        (Adi2Addr.line, OutIdx.loopback, 3),
      ]);
      expect(find.byType(AlertDialog), findsNothing);
      Navigator.of(tester.element(find.byType(AnalyzerColorSetting))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.fullscreen_exit));
      await tester.pumpAndSettle();
      ctrl.writes.clear();
      ctrl.status = Adi2Status([0]);
      ctrl.selectedOutput = Adi2Addr.ph34;
      ctrl.notifyListeners();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(ctrl.writes, [
        (Adi2Addr.line, OutIdx.loopback, 0),
        (Adi2Addr.ph34, OutIdx.loopback, 3),
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      analyzer.dispose();
      ctrl.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('adi2/analyzer'),
        null,
      );
    },
  );

  for (final fullscreen in [false, true]) {
    testWidgets(
      'routing pauses behind pages and in background, fullscreen=$fullscreen',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 800);
        addTearDown(tester.view.reset);
        await settings.setAutoFullscreenEq(false);
        await settings.confirmAnalyzerLoopback();
        await settings.setAnalyzerRouting(output: 0, tap: 2);
        final ctrl = _Device();
        await ctrl.startOffline(Adi2Variant.pro);
        ctrl.state = ConnState.connected;
        ctrl.status = Adi2Status([0]);
        ctrl.selectedOutput = Adi2Addr.line;
        final analyzer = AnalyzerController();
        final navigator = GlobalKey<NavigatorState>();
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
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: buildTheme(),
            home: Scaffold(
              body: AnalyzerPanel(controller: analyzer, deviceController: ctrl),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (fullscreen) {
          await tester.tap(find.byIcon(Icons.fullscreen));
          await tester.pumpAndSettle();
        }
        // A status change just before navigation must also be cancelled.
        ctrl.status = Adi2Status([1]);
        ctrl.selectedOutput = Adi2Addr.ph34;
        ctrl.notifyListeners();
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Other page')),
          ),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 2));
        expect(ctrl.writes, isEmpty);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 2));
        expect(ctrl.writes, isEmpty);
        ctrl.status = Adi2Status([2]);
        ctrl.selectedOutput = Adi2Addr.line;
        ctrl.notifyListeners();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump(const Duration(seconds: 2));
        expect(ctrl.writes, isEmpty);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 2));
        expect(ctrl.writes, isEmpty);
        ctrl.status = Adi2Status([0]);
        ctrl.selectedOutput = Adi2Addr.ph34;
        ctrl.notifyListeners();
        await tester.pump(const Duration(seconds: 1));
        expect(ctrl.writes, [(Adi2Addr.ph34, OutIdx.loopback, 2)]);
        ctrl.writes.clear();
        ctrl.status = Adi2Status([1]);
        ctrl.selectedOutput = Adi2Addr.line;
        ctrl.notifyListeners();
        ctrl.analyzerSelfTestActive = true;
        await tester.pump(const Duration(seconds: 2));
        ctrl.analyzerSelfTestActive = false;
        await tester.pump(const Duration(seconds: 2));
        expect(ctrl.writes, isEmpty);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        analyzer.dispose();
        ctrl.dispose();
      },
    );
  }

  testWidgets(
    'cancelled first-use consent and detach during consent never route USB',
    (tester) async {
      final ctrl = _Device();
      await ctrl.startOffline(Adi2Variant.pro);
      ctrl.state = ConnState.connected;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(body: AnalyzerLoopbackControls(ctrl: ctrl)),
        ),
      );
      Future<void> chooseTap() async {
        await tester.tap(find.text('post FX').last);
        await tester.pumpAndSettle();
      }

      await chooseTap();
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(ctrl.writes, isEmpty);
      expect(settings.analyzerLoopbackConfirmed, isFalse);
      expect(settings.analyzerLoopbackTap, 0);
      await chooseTap();
      ctrl.state = ConnState.idle;
      ctrl.notifyListeners();
      await tester.tap(find.text('Bestätigen'));
      await tester.pumpAndSettle();
      expect(ctrl.writes, isEmpty);
      expect(settings.analyzerLoopbackTap, 0);
      expect(
        tester
            .widget<AnalyzerChoices<int>>(
              find.byKey(const ValueKey('analyzer-loopback-output')),
            )
            .onSelected,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
      ctrl.dispose();
    },
  );

  testWidgets('Langdruck auf Peak hold setzt die Peak-Marken zurück', (
    tester,
  ) async {
    await settings.setAnalyzerPeakHoldSeconds(0);
    final controller = AnalyzerController();
    addTearDown(controller.dispose);
    final envelope = controller.spectrum;
    envelope.update([-10], .1);
    envelope.update([-50], 5);
    expect(envelope.held.single, -10); // ∞: bleibt stehen
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: AnalyzerPeakHoldChip(controller: controller)),
      ),
    );
    await tester.longPress(find.byKey(const ValueKey('analyzer-peak-hold')));
    await tester.pump();
    expect(envelope.held.single, envelope.values.single);
    expect(envelope.held.single, lessThan(-10));
    final before = controller.peakHold;
    await tester.tap(find.byKey(const ValueKey('analyzer-peak-hold')));
    await tester.pump();
    expect(controller.peakHold, !before);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Kompaktes Peak-hold-Symbol ist 40×40, farbig und behält Tap/Langdruck',
    (tester) async {
      final controller = AnalyzerController();
      addTearDown(controller.dispose);
      controller.setPeakHold(false);
      controller.spectrum.update([-10], .1);
      controller.spectrum.update([-50], 5);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (context, _) =>
                  AnalyzerPeakHoldChip(controller: controller, compact: true),
            ),
          ),
        ),
      );
      final button = find.descendant(
        of: find.byKey(const ValueKey('analyzer-peak-hold')),
        matching: find.byType(IconButton),
      );
      expect(tester.getSize(button), const Size(40, 40));
      expect(tester.widget<IconButton>(button).iconSize, 18);
      expect(find.byType(FilterChip), findsNothing);
      final inactive = tester.widget<IconButton>(button).color;
      await tester.tap(button);
      await tester.pump();
      expect(controller.peakHold, isTrue);
      expect(tester.widget<IconButton>(button).color, isNot(inactive));
      expect(
        find.byTooltip(tr('Peak hold – lang drücken: zurücksetzen')),
        findsOneWidget,
      );
      await tester.longPress(button);
      await tester.pump();
      expect(controller.spectrum.held, controller.spectrum.values);
      expect(controller.peakHold, isTrue);
      expect(find.byType(SnackBar), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
