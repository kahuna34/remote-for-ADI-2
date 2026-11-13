import 'dart:convert';

import 'package:adi2_remote/analyzer/analyzer_controller.dart';
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/host/host_client.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:adi2_remote/ui/analyzer_controls.dart';
import 'package:adi2_remote/ui/analyzer_player_overlay.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Player extends NowPlaying {
  final commands = <String>[];
  _Player() {
    supported = access = true;
    info = const NowPlayingInfo(title: 'Track', artist: 'Artist', app: 'Local');
  }
  @override
  Future<void> command(String command) async {
    commands.add(command);
  }
}

class _Host extends HostClient {
  final sent = <String>[];
  _Host() {
    playerAvailable = true;
  }
  @override
  bool get connected => true;
  @override
  void send(String type, [Map<String, dynamic> payload = const {}]) {
    sent.add('$type:${payload['command'] ?? ''}');
  }
}

class _Device extends Adi2Controller {
  _Device({super.host});
  bool remote = false;
  @override
  bool get viaHost => remote;
  @override
  Adi2Variant get variant => Adi2Variant.dac;
  @override
  int? value(int address, int index) => index == OutIdx.source
      ? 1
      : index == OutIdx.loopback
      ? 0
      : null;
}

class _Analyzer extends AnalyzerController {
  @override
  Future<void> setActiveFor(Object owner, bool active) async {}
}

void main() {
  final settings = AppSettings.instance;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
    AppLang.instance.language = AppLanguage.de;
  });
  for (final presentation in ['compact', 'extra', 'fullscreen']) {
    final sizes = presentation == 'extra'
        ? [const Size(800, 1000), const Size(1280, 800)]
        : [
            const Size(360, 800),
            const Size(740, 360),
            const Size(800, 1000),
            const Size(1280, 800),
          ];
    for (final size in sizes) {
      for (final textScale in [1.0, 2.0]) {
        testWidgets(
          'player equals painted plot: $presentation $size text $textScale',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = size;
            addTearDown(tester.view.reset);
            await settings.setAutoFullscreenEq(false);
            await settings.setAnalyzerPlayerOnTap(true);
            final controller = _Analyzer()..status = AnalyzerStatus.running;
            controller.frame = AnalyzerFrame(
              sampleRate: 48000,
              spectrum: List.filled(2049, .1),
              peak: [-20, -21],
              rms: [-23, -24],
              clipped: [false, false],
            );
            final player = _Player();
            player.info = NowPlayingInfo(
              title: 'A long track title to test ellipsis in a narrow graph',
              artist: 'Artist',
              app: 'Local',
              art: base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
              ),
            );
            addTearDown(controller.dispose);
            addTearDown(player.dispose);
            await tester.pumpWidget(
              MaterialApp(
                theme: buildTheme(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.topRight,
                    child: SizedBox(
                      width: presentation == 'extra' ? 480 : null,
                      height: presentation == 'extra' ? 600 : null,
                      child: AnalyzerPanel(
                        controller: controller,
                        np: player,
                        expanded: presentation == 'extra',
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            if (presentation == 'fullscreen') {
              await tester.tap(find.byTooltip('Vollbild'));
              await tester.pumpAndSettle();
            }
            final spectrum = tester.getRect(
              find.byKey(const ValueKey('analyzer-spectrum')),
            );
            final scale = AnalyzerSpectrumScale(
              size: spectrum.size,
              compact: presentation == 'compact',
              range: settings.analyzerRange,
              bars: controller.bars,
              resolution: controller.bandResolution,
            );
            final plot = tester.getRect(
              find.byKey(const ValueKey('analyzer-plot')),
            );
            expect(plot, scale.area.shift(spectrum.topLeft));
            await tester.tap(find.byKey(const ValueKey('analyzer-plot')));
            await tester.pump();
            final overlay = tester.getRect(
              find.byKey(const ValueKey('analyzer-player-overlay')),
            );
            expect(overlay, plot);
            expect(find.text('Artist · Local'), findsOneWidget);
            if (plot.height < 76 && plot.width >= 180) {
              final title = tester.getRect(find.text(player.info!.title!));
              expect(title.height, greaterThan(12));
              expect(
                title.right,
                lessThan(
                  tester
                      .getRect(
                        find.byKey(const ValueKey('analyzer-player-previous')),
                      )
                      .left,
                ),
              );
            }
            for (final command in ['previous', 'play', 'next']) {
              final button = tester.getRect(
                find.byKey(ValueKey('analyzer-player-$command')),
              );
              // Rect.contains schließt den rechten/unteren Rand aus.
              final area = overlay.inflate(.01);
              expect(area.contains(button.topLeft), isTrue);
              expect(area.contains(button.bottomRight), isTrue);
              // Größere Knöpfe; bei wenig Platz verkleinert FittedBox sie.
              final maxSize = plot.height < 176 ? 44.0 : 56.0;
              expect(button.width, lessThanOrEqualTo(maxSize + .001));
              expect(button.width, greaterThanOrEqualTo(20));
              expect(button.height, closeTo(button.width, .001));
            }
            final cover = find.byKey(const ValueKey('analyzer-player-cover'));
            expect(cover, plot.height < 176 ? findsNothing : findsOneWidget);
            if (plot.height >= 176) {
              expect(tester.getSize(cover).width, lessThanOrEqualTo(64));
            }
            for (final key in [
              'analyzer-meter-column',
              'analyzer-fullscreen-levels',
              'analyzer-info-summary',
              'analyzer-diagnostics',
            ]) {
              for (final element in find.byKey(ValueKey(key)).evaluate()) {
                final rect = tester.getRect(find.byWidget(element.widget));
                expect(overlay.overlaps(rect), isFalse);
              }
            }
            expect(tester.takeException(), isNull);
            await tester.tap(
              find.byKey(const ValueKey('analyzer-player-play')),
            );
            await tester.pump();
            expect(player.commands, ['play']);
            await tester.pumpWidget(const SizedBox());
            await tester.pumpAndSettle();
          },
        );
      }
    }
  }
  testWidgets(
    'disabled graph opens fullscreen and compact overlay buttons stay visible',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      final c = _Analyzer()..status = AnalyzerStatus.running;
      c.frame = AnalyzerFrame(
        sampleRate: 48000,
        spectrum: List.filled(2049, .1),
        peak: [-20, -21],
        rms: [-23, -24],
        clipped: [false, false],
      );
      final np = _Player();
      addTearDown(c.dispose);
      addTearDown(np.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: AnalyzerPanel(controller: c, np: np),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('analyzer-compact-levels')),
        findsNothing,
      );
      final spectrum = tester.getRect(
        find.byKey(const ValueKey('analyzer-spectrum')),
      );
      final fullscreen = tester.getRect(find.byTooltip('Vollbild'));
      final buttons = tester.getRect(
        find.byKey(const ValueKey('analyzer-compact-buttons')),
      );
      expect(fullscreen.size, const Size(44, 32));
      expect(buttons.contains(fullscreen.topLeft), isTrue);
      expect(fullscreen.right, lessThanOrEqualTo(buttons.right));
      expect(fullscreen.bottom, lessThanOrEqualTo(buttons.bottom));
      expect(find.byTooltip('Vollbild').hitTestable(), findsOneWidget);
      expect(buttons.top, greaterThanOrEqualTo(spectrum.bottom));
      expect(buttons.width, closeTo(spectrum.width, .1));
      await tester.tap(find.byKey(const ValueKey('analyzer-plot')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
      expect(
        find.byKey(const ValueKey('analyzer-player-overlay')),
        findsNothing,
      );
      await tester.tap(find.byIcon(Icons.fullscreen_exit));
      await tester.pumpAndSettle();
      await settings.setAnalyzerPlayerOnTap(true);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('analyzer-plot')));
      await tester.pump();
      final graph = tester.getRect(
        find.byKey(const ValueKey('analyzer-player-graph')),
      );
      final play = tester.getRect(
        find.byKey(const ValueKey('analyzer-player-play')),
      );
      expect(graph.contains(play.topLeft), true);
      expect(graph.contains(play.bottomRight), true);
      await tester.tap(find.byKey(const ValueKey('analyzer-player-play')));
      await tester.pump();
      expect(np.commands, ['play']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'setting defaults off and survives reload through settings switch',
    (tester) async {
      final c = AnalyzerController();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAnalyzerSettings(context, c, null),
              child: const Text('Settings'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('analyzer-player-setting'));
      expect(tester.widget<SwitchListTile>(toggle).value, false);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(settings.analyzerPlayerOnTap, true);
      await settings.load();
      expect(settings.analyzerPlayerOnTap, true);
    },
  );
  testWidgets(
    'graph opt in, local commands, non USB hint, dismiss and idle reset',
    (tester) async {
      final np = _Player(), device = _Device();
      addTearDown(np.dispose);
      addTearDown(device.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 180,
              child: AnalyzerPlayerOverlay(
                np: np,
                deviceController: device,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('analyzer-player-graph')), findsNothing);
      await settings.setAnalyzerPlayerOnTap(true);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('analyzer-player-graph')));
      await tester.pump();
      expect(find.text('Track'), findsOneWidget);
      expect(find.text('Quelle ist nicht USB'), findsOneWidget);
      for (final command in ['previous', 'play', 'next']) {
        await tester.tap(find.byKey(ValueKey('analyzer-player-$command')));
        await tester.pump();
      }
      expect(np.commands, ['previous', 'play', 'next']);
      await tester.pump(const Duration(seconds: 4));
      await tester.tap(find.byKey(const ValueKey('analyzer-player-play')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(
        find.byKey(const ValueKey('analyzer-player-overlay')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.byKey(const ValueKey('analyzer-player-overlay')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('analyzer-player-graph')));
      await tester.pump();
      await tester.tapAt(const Offset(305, 5));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('analyzer-player-overlay')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('analyzer-player-graph')));
      await tester.pump();
      await settings.setAnalyzerPlayerOnTap(false);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('analyzer-player-overlay')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'host overlay subscribes, commands host, clears subscription on removal',
    (tester) async {
      final np = _Player(), host = _Host();
      final device = _Device(host: host)..remote = true;
      addTearDown(device.dispose);
      addTearDown(np.dispose);
      host.playerInfo = const NowPlayingInfo(
        title: 'Computer track',
        playing: true,
      );
      await settings.setAnalyzerPlayerOnTap(true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnalyzerPlayerOverlay(
              np: np,
              deviceController: device,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('analyzer-player-graph')));
      await tester.pump();
      expect(find.text('Computer track'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('analyzer-player-pause')));
      await tester.pump();
      expect(host.sent, ['player_subscribe:', 'player_command:pause']);
      host.setReconnecting(true);
      await tester.pump(const Duration(seconds: 6));
      expect(
        find.byKey(const ValueKey('analyzer-player-overlay')),
        findsOneWidget,
      );
      expect(find.text('Computer track'), findsOneWidget);
      host.playerCommand('next');
      expect(host.sent, ['player_subscribe:', 'player_command:pause']);
      host.setReconnecting(false);
      await tester.pump();

      expect(np.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
      expect(host.sent.last, 'player_unsubscribe:');
    },
  );
  testWidgets(
    'compact geometry and graph/fullscreen gestures preserve controls',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1000);
      addTearDown(tester.view.reset);
      final c = _Analyzer()..status = AnalyzerStatus.running;
      c.frame = AnalyzerFrame(
        sampleRate: 48000,
        spectrum: List.filled(2049, .1),
        peak: [-20, -21],
        rms: [-23, -24],
        clipped: [false, false],
      );
      addTearDown(c.dispose);
      final np = _Player();
      addTearDown(np.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(
                size: Size(800, 1000),
                textScaler: TextScaler.linear(2),
              ),
              child: Align(
                alignment: Alignment.topCenter,
                child: AnalyzerPanel(controller: c, np: np),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final meter = tester.getRect(
        find.byKey(const ValueKey('analyzer-meter-column')),
      );
      final spectrum = tester.getRect(
        find.byKey(const ValueKey('analyzer-spectrum')),
      );
      final buttons = tester.getRect(
        find.byKey(const ValueKey('analyzer-compact-buttons')),
      );
      final settingsButton = tester.getRect(
        find.byTooltip('Analyzer-Einstellungen'),
      );
      final fullscreen = tester.getRect(find.byTooltip('Vollbild'));
      expect(buttons.center.dx, closeTo((spectrum.left + meter.right) / 2, .1));
      expect(buttons.width, closeTo(spectrum.width + meter.width, .1));
      expect(fullscreen.right, closeTo(meter.right, .1));
      expect(settingsButton.top, fullscreen.top);
      expect(fullscreen.size, const Size(44, 32));
      expect(settingsButton.size, const Size(44, 32));
      expect(buttons.center.dy, fullscreen.center.dy);
      final levels = tester.getRect(
        find.byKey(const ValueKey('analyzer-compact-levels')),
      );
      expect(buttons.top, greaterThanOrEqualTo(levels.bottom));
      expect(levels.center.dx, closeTo(meter.center.dx, .1));
      final hold = find.descendant(
        of: find.byKey(const ValueKey('analyzer-peak-hold')),
        matching: find.byType(OutlinedButton),
      );
      final reset = find.descendant(
        of: find.byKey(const ValueKey('analyzer-peak-reset')),
        matching: find.byType(OutlinedButton),
      );
      expect(
        tester.widget<OutlinedButton>(hold).style!.backgroundColor!.resolve({}),
        Palette.amber,
      );
      expect(tester.widget<OutlinedButton>(reset).onPressed, isNotNull);
      await tester.tap(hold);
      await tester.pump();
      expect(tester.widget<OutlinedButton>(reset).onPressed, isNull);
      await tester.tap(hold);
      await tester.pump();
      expect(
        tester.getRect(find.byKey(const ValueKey('analyzer-spectrum'))).right,
        lessThanOrEqualTo(settingsButton.left),
      );
      expect(tester.takeException(), isNull);
      await settings.setAnalyzerPlayerOnTap(true);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('analyzer-plot')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('analyzer-player-overlay')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.fullscreen_exit), findsNothing);
      await tester.tap(find.byTooltip('Vollbild'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
      // Opening fullscreen also ends the compact route's hidden overlay.
      expect(
        find.byKey(
          const ValueKey('analyzer-player-overlay'),
          skipOffstage: false,
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('analyzer-plot')).last);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('analyzer-player-overlay')).last,
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 5));
      expect(
        find.byKey(const ValueKey('analyzer-player-overlay')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
