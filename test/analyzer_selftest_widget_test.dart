import 'dart:async';

import 'package:adi2_remote/dev/analyzer_selftest.dart';
import 'package:adi2_remote/dev/analyzer_selftest_page.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'analyzer_selftest_test.dart' show TestSelfTestDevice, TestSelfTestAudio;

void main() {
  // Scroll the page directly: dragging its centre can scroll the nested history
  // instead, especially now that successful bands also include both deviations.
  Future<void> reveal(WidgetTester tester, Finder target) async {
    final outer = find.byElementPredicate(
      (element) =>
          element.widget is Scrollable &&
          element.findAncestorWidgetOfExactType<Viewport>() == null &&
          element.findAncestorWidgetOfExactType<SingleChildScrollView>() ==
              null,
    );
    final position = tester.state<ScrollableState>(outer).position;
    for (var i = 0; target.evaluate().isEmpty && i < 50; i++) {
      position.jumpTo(
        (position.pixels + 200).clamp(0, position.maxScrollExtent),
      );
      await tester.pump();
    }
    expect(target, findsWidgets);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  late TestSelfTestDevice device;
  late TestSelfTestAudio audio;
  late AnalyzerSelfTest session;
  setUp(() {
    final events = <String>[];
    device = TestSelfTestDevice(events);
    audio = TestSelfTestAudio(events);
    session = AnalyzerSelfTest(device, audio, silence: Duration.zero);
  });
  tearDown(() {
    session.dispose();
  });
  Future<void> show(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(home: AnalyzerSelfTestPage(session: session)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('selftest-start')));
    await tester.pumpAndSettle();
    expect(find.text('Sicherheitsbestätigung'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('selftest-confirm')));
    await tester.pump();
  }

  testWidgets('oversized historical report shows discard notice', (
    tester,
  ) async {
    audio.lastResultNotice =
        '1 Selbsttest-Ergebnisdatei(en) zu groß, verworfen.';
    await show(tester);
    expect(find.textContaining('zu groß, verworfen'), findsOneWidget);
    expect(find.byKey(const ValueKey('selftest-last-result')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final aborted in [false, true]) {
    testWidgets(
      'rebuild loads ${aborted ? 'aborted' : 'complete'} report and copies it',
      (tester) async {
        if (aborted) {
          audio.onTone = (_, _) async {
            session.cancelled = true;
            throw PlatformException(code: 'cancelled');
          };
        }
        await tester.runAsync(() => session.run(device.outputs.first));
        final savedReport = session.report;
        session.dispose();
        session = AnalyzerSelfTest(device, audio, silence: Duration.zero);
        final writes = device.writes.length;
        await show(tester);
        final result = tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('selftest-last-result')),
            )
            .data!;
        expect(result, contains('Letzter Test:'));
        expect(result, contains('Status: ${savedReport['grade']}'));
        expect(result, contains('Oktave   OK   Abw. Offen'));
        expect(result, contains('1/3'));
        expect(result, contains('1/6'));
        expect(result, contains('1/12'));
        expect(result, contains('Diagnose:'));
        expect(device.writes.length, writes);
        expect(session.results, isEmpty);
        expect(session.restored, isTrue);

        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.tap(find.byKey(const ValueKey('selftest-copy-result')));
        await tester.pumpAndSettle();
        expect(copied, result);
        expect(tester.takeException(), isNull);
        // Recreate the page and session once more from the same stored JSON.
        await tester.pumpWidget(const SizedBox());
        session.dispose();
        session = AnalyzerSelfTest(device, audio);
        await show(tester);
        expect(
          find.byKey(const ValueKey('selftest-last-result')),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets('emergency button resets routing and keeps Mute and volume', (
    tester,
  ) async {
    final original = Map.of(device.values);
    await show(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('selftest-reset-state')),
    );
    await tester.tap(find.byKey(const ValueKey('selftest-reset-state')));
    await tester.pumpAndSettle();
    expect(session.status, 'Testzustand aufgehoben. Mute am Gerät prüfen');
    expect(find.textContaining('Mute am Gerät prüfen'), findsWidgets);
    for (final a in device.outputs) {
      expect(
        device.values[a << 8 | OutIdx.mute],
        original[a << 8 | OutIdx.mute],
      );
      expect(
        device.values[a << 8 | OutIdx.volume],
        original[a << 8 | OutIdx.volume],
      );
    }
    expect(
      device.writes.single.keys.every(
        (key) => !original.containsKey(key) || device.values[key] == 0,
      ),
      isTrue,
    );
  });

  testWidgets('pending recovery hides emergency reset', (tester) async {
    audio.journal = {
      'device': device.identity,
      'values': {for (final e in device.values.entries) '${e.key}': e.value},
    };
    await show(tester);
    expect(find.text('Wiederherstellung erneut starten'), findsOneWidget);
    expect(find.byKey(const ValueKey('selftest-reset-state')), findsNothing);
  });

  testWidgets('five version taps open developer page; four do not', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AnalyzerSelfTestEntry(child: Text('Version 1.1.0')),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('Version 1.1.0'));
    }
    await tester.pump();
    expect(find.text('Entwickler: Analyzer-Selbsttest'), findsNothing);
    await tester.tap(find.text('Version 1.1.0'));
    await tester.pumpAndSettle();
    expect(find.text('Entwickler: Analyzer-Selbsttest'), findsOneWidget);
    expect(audio.tones, 0);
  });
  testWidgets('confirmation cancellation changes no device settings', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('selftest-start')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Kopfhörer abnehmen'), findsOneWidget);
    await tester.tap(find.text('Zurück'));
    await tester.pumpAndSettle();
    expect(device.writes, isEmpty);
    expect(audio.tones, 0);
  });
  testWidgets(
    'confirmed complete sweep shows table, export and exact restoration',
    (tester) async {
      final original = Map.of(device.values);
      await show(tester);
      await confirm(tester);
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(session.results.length, 206);
      expect(device.values, original);
      expect(session.restored, isTrue);
      await reveal(tester, find.text('Gesamtnote: OK'));
      expect(find.text('Gesamtnote: OK'), findsOneWidget);
      await reveal(tester, find.text('Oktave'));
      expect(find.text('Oktave'), findsOneWidget);
      await reveal(tester, find.text('JSON teilen/exportieren'));
      expect(find.text('CSV teilen/exportieren'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'busy result displays German levels and source without exception wrapper',
    (tester) async {
      audio.onTone = (_, _) async => throw PlatformException(
        code: 'signalBusy',
        details: {'peakDbfs': -42.0, 'rmsDbfs': -50.0},
      );
      await show(tester);
      await confirm(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('−42.0 dBFS Peak'), findsWidgets);
      expect(find.textContaining('Quelle des Ausgangs: USB 1/2'), findsWidgets);
      expect(find.textContaining('PlatformException'), findsNothing);
      expect(session.restored, isTrue);
    },
  );
  testWidgets('normal playback shows warning and both deviations in results', (
    tester,
  ) async {
    audio.preparation = {
      'sampleRate': 48000,
      'playback': {'bitPerfect': false},
    };
    audio.onTone = (r, i) async =>
        TestSelfTestAudio.measurement(r, i, gain: 14);
    await tester.runAsync(() => session.run(6));
    await show(tester);
    final history = tester
        .widget<SelectableText>(
          find.byKey(const ValueKey('selftest-last-result')),
        )
        .data!;
    expect(history, contains('Wiedergabe: normal + Effekte'));
    expect(
      history,
      contains('System-Klangeffekte können die Messung verfälschen'),
    );
    expect(history, contains('Δ absolut 14.0 dB; Δ relativ 0.0 dB'));
    await reveal(tester, find.text('Alle Bandmessungen'));
    await tester.tap(find.text('Alle Bandmessungen'));
    await tester.pumpAndSettle();
    await reveal(
      tester,
      find.textContaining('Δ absolut 14.00 dB; Δ relativ 0.00 dB').first,
    );
    expect(
      find.textContaining('Δ absolut 14.00 dB; Δ relativ 0.00 dB'),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed preparation shows routed device and formats in result', (
    tester,
  ) async {
    audio.prepareError = PlatformException(
      code: 'routeMismatch',
      details: {
        'diagnostics': {
          'capture': {
            'routedDevice': {'name': 'Handy-Mikrofon', 'type': 15, 'id': 8},
            'requestedFormat': {
              'sampleRate': 48000,
              'channels': 2,
              'encoding': 4,
            },
            'actualFormat': {'sampleRate': 48000, 'channels': 2, 'encoding': 4},
            'audioSource': 6,
          },
        },
      },
    );
    await show(tester);
    await confirm(tester);
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const ValueKey('selftest-diagnostics')));
    expect(find.byKey(const ValueKey('selftest-diagnostics')), findsOneWidget);
    expect(find.textContaining('Typ 15, ID 8'), findsOneWidget);
    const failure = 'Aufnahme läuft über Handy-Mikrofon statt über den ADI-2';
    expect(session.lastResult!.text, contains(failure));
    expect(session.error, contains(failure));
    expect(audio.tones, 0);
    expect(session.restored, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final background in [false, true]) {
    testWidgets(
      '${background ? 'background' : 'cancel button'} stops tone and restores Mute/Volume/Loopback',
      (tester) async {
        final original = Map.of(device.values);
        final pending = Completer<Map<String, dynamic>>();
        audio.onTone = (_, _) => pending.future;
        await show(tester);
        await confirm(tester);
        for (var i = 0; i < 10 && audio.tones == 0; i++) {
          await tester.pump();
        }
        expect(session.running, isTrue);
        expect(audio.tones, 1);
        if (background) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        } else {
          await tester.tap(find.byKey(const ValueKey('selftest-cancel')));
        }
        await tester.pump();
        expect(audio.stops, greaterThan(0));
        pending.completeError(PlatformException(code: 'cancelled'));
        await tester.pumpAndSettle();
        expect(session.cancelled, isTrue);
        expect(session.restored, isTrue);
        expect(device.values, original);
        expect(session.report['grade'], 'Abgebrochen');
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      },
    );
  }
}
