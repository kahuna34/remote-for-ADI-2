import 'package:adi2_remote/ui/player_bar.dart';
import 'package:adi2_remote/analyzer/header_content.dart';
import 'package:adi2_remote/analyzer/analyzer_controller.dart';
import 'package:adi2_remote/media/now_playing.dart' as npm;
import 'package:adi2_remote/protocol/adi2_status.dart' as st;
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/host/host_client.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:adi2_remote/host/host_analyzer_protocol.dart';

import 'host_analyzer_protocol_test.dart' show transportFrame;

import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/desktop/desktop_windows.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:adi2_remote/ui/app_settings_page.dart';
import 'package:adi2_remote/ui/eq_page.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/player_window_view.dart';
import 'package:adi2_remote/ui/responsive_layout.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:adi2_remote/ui/volume_ring.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Windows extends DesktopWindows {
  final opened = <AuxiliaryWindow>[];
  bool analyzerOpen = false;
  @override
  bool isOpen(AuxiliaryWindow kind) =>
      kind == AuxiliaryWindow.analyzer && analyzerOpen;
  void setAnalyzerOpen(bool value) {
    analyzerOpen = value;
    notifyListeners();
  }

  @override
  Future<void> open(AuxiliaryWindow kind) async => opened.add(kind);
}

class _Controller extends Adi2Controller {
  _Controller({this.embeddedHost = true, super.host}) {
    state = ConnState.connected;
  }
  @override
  final bool embeddedHost;
  bool hostMode = false;
  @override
  bool get usesLocalHost => embeddedHost && !hostMode;
  @override
  bool get viaHost => hostMode;
  @override
  Adi2Variant get variant => Adi2Variant.dac;
  final values = offlineDefaults(Adi2Variant.dac);
  @override
  int? value(int a, int i) => values[a << 8 | i];
  @override
  int valueOr(int a, int i, int fallback) => value(a, i) ?? fallback;
  @override
  int? eqValue(int a, int i) => value(a, i);
}

class _PlayerHost extends HostClient {
  @override
  bool get connected => true;
  final sent = <(String, Map<String, dynamic>)>[];
  @override
  void send(String type, [Map<String, dynamic> payload = const {}]) {
    sent.add((type, payload));
  }
}

void main() {
  late _Controller ctrl;
  late NowPlaying np;
  late _Windows windows;
  late AppLanguage previousLanguage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
    previousLanguage = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    ctrl = _Controller();
    np = NowPlaying(hostOnly: true);
    windows = _Windows();
  });
  tearDown(() {
    ctrl.dispose();
    np.dispose();
    AppLang.instance.language = previousLanguage;
  });

  Future<void> pump(
    WidgetTester tester, {
    Widget? child,
    Size size = const Size(1200, 800),
    bool scope = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    Widget app = MaterialApp(
      theme: buildTheme(),
      builder: (context, child) => TabletOrientation(child: child!),
      home: child ?? HomePage(ctrl: ctrl, np: np, updatesReady: false),
    );
    if (scope) app = DesktopWindowScope(windows: windows, child: app);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
  }

  Finder key(String name) => find.byKey(ValueKey(name));
  Finder rail(String label) => find.descendant(
    of: find.byType(NavigationRail),
    matching: find.text(label),
  );

  test(
    'Linux analyzer frame rate defaults to 30, validates and persists 60',
    () async {
      expect(AppSettings.instance.linuxAnalyzerFps, 30);
      await AppSettings.instance.setLinuxAnalyzerFps(60);
      await AppSettings.instance.load(reload: true);
      expect(AppSettings.instance.linuxAnalyzerFps, 60);
      await AppSettings.instance.setLinuxAnalyzerFps(15);
      expect(AppSettings.instance.linuxAnalyzerFps, 60);
    },
  );

  testWidgets(
    'Desktop frame-rate setting offers 30/60; test signals remain Linux-only',
    (tester) async {
      await pump(
        tester,
        child: AppSettingsPage(ctrl: ctrl, np: np),
      );
      await tester.scrollUntilVisible(key('linux-analyzer-fps-setting'), 200);
      final dropdown = find.descendant(
        of: key('linux-analyzer-fps-setting'),
        matching: find.byType(DropdownButton<int>),
      );
      expect(tester.widget<DropdownButton<int>>(dropdown).value, 30);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('60 fps').last);
      await tester.pumpAndSettle();
      expect(AppSettings.instance.linuxAnalyzerFps, 60);
      expect(
        key('test-signals-open'),
        defaultTargetPlatform == TargetPlatform.linux
            ? findsOneWidget
            : findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Analyzer window replaces the visible slot in landscape and compact modes and exit restores it',
    (tester) async {
      AppSettings.instance.tabletExtraContent = TabletExtraContent.analyzer;
      for (final compact in [false, true]) {
        AppSettings.instance.linuxCompact = compact;
        await pump(tester);
        expect(find.byType(AnalyzerPanel), findsOneWidget);
        windows.setAnalyzerOpen(true);
        await tester.pumpAndSettle();
        expect(find.byType(AnalyzerPanel), findsNothing);
        expect(key('analyzer-window-placeholder'), findsOneWidget);
        windows.setAnalyzerOpen(false);
        await tester.pumpAndSettle();
        expect(find.byType(AnalyzerPanel), findsOneWidget);
        expect(key('analyzer-window-placeholder'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Host frames keep HomePage and plot layout stable; detaching stops its subscription immediately',
    (tester) async {
      final host = _PlayerHost()
        ..analyzerAvailable = true
        ..analyzerVersion = 2
        ..analyzerPlatform = 'linux'
        ..credentials = const HostCredentials(
          HostEndpoint(
            id: 'local',
            name: 'Local',
            address: '127.0.0.1',
            port: hostDefaultPort,
          ),
          'ui',
          'key',
        );
      ctrl.dispose();
      ctrl = _Controller(host: host);
      AppSettings.instance.tabletExtraContent = TabletExtraContent.analyzer;
      await pump(tester);
      expect(host.sent.any((m) => m.$1 == 'analyzer_start'), true);
      host.analyzerEvents.add({
        'type': 'analyzer_metadata',
        'v': 2,
        'sampleRate': 48000,
      });
      void audioFrame() => host.analyzerEvents.add({
        'type': 'analyzer_frame',
        ...encodeHostAnalyzerFrameV2(
          transportFrame(48000, AnalyzerBandResolution.third),
          bars: true,
        ),
      });
      audioFrame();
      await tester.pumpAndSettle();
      final panel = tester.widget<AnalyzerPanel>(find.byType(AnalyzerPanel));
      final painter = tester
          .widget<CustomPaint>(key('analyzer-spectrum'))
          .painter;
      for (var i = 0; i < 8; i++) {
        audioFrame();
        await tester.pump(const Duration(milliseconds: 34));
        expect(
          identical(
            tester.widget<AnalyzerPanel>(find.byType(AnalyzerPanel)),
            panel,
          ),
          true,
        );
        expect(
          identical(
            tester.widget<CustomPaint>(key('analyzer-spectrum')).painter,
            painter,
          ),
          true,
        );
      }
      final before = host.sent.where((m) => m.$1 == 'analyzer_start').length;
      windows.setAnalyzerOpen(true);
      await tester.pump();
      await tester.pump();
      expect(key('analyzer-window-placeholder'), findsOneWidget);
      expect(host.sent.last.$1, 'analyzer_stop');
      audioFrame();
      await tester.pump();
      expect(host.sent.where((m) => m.$1 == 'analyzer_start').length, before);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  test('Linux extra-area preference defaults on and survives reload', () async {
    expect(AppSettings.instance.linuxLandscapeExtra, isTrue);
    await AppSettings.instance.setLinuxLandscapeExtra(false);
    expect(
      (await SharedPreferences.getInstance()).getBool('linux_landscape_extra'),
      isFalse,
    );
    AppSettings.instance.linuxLandscapeExtra = true;
    await AppSettings.instance.load(reload: true);
    expect(AppSettings.instance.linuxLandscapeExtra, isFalse);
  });

  test(
    'Reload applies auxiliary analyzer preferences to an existing controller',
    () async {
      final analyzer = AnalyzerController();
      addTearDown(analyzer.dispose);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('analyzer_bars', false);
      await prefs.setBool('analyzer_peak_hold', false);
      await prefs.setString(
        'analyzer_ballistics',
        AnalyzerBallistics.slow.name,
      );
      await AppSettings.instance.load(reload: true);
      expect(analyzer.bars, isFalse);
      expect(analyzer.peakHold, isFalse);
      expect(analyzer.ballistics, AnalyzerBallistics.slow);
    },
  );

  void platformTest(
    String description,
    WidgetTesterCallback callback, {
    TargetPlatform? platform,
  }) {
    testWidgets(
      description,
      callback,
      variant: platform == null
          ? TargetPlatformVariant({
              TargetPlatform.linux,
              TargetPlatform.macOS,
              TargetPlatform.windows,
            })
          : TargetPlatformVariant.only(platform),
    );
  }

  platformTest(
    'Device only keeps output tabs on top and navigates to EQ and status',
    (tester) async {
      await pump(tester);
      expect(key('tablet-extra-area'), findsOneWidget);
      await tester.tap(key('desktop-extra-toggle'));
      await tester.pumpAndSettle();
      expect(key('tablet-extra-area'), findsNothing);
      expect(key('tablet-output-columns'), findsNothing);
      expect(key('desktop-device-only-columns'), findsNothing);
      await tester.tap(find.text('Line Out').first);
      await tester.pumpAndSettle();
      expect(ctrl.selectedOutput, Adi2Addr.line);
      await tester.tap(rail('EQ'));
      await tester.pumpAndSettle();
      expect(find.byType(EqPage), findsOneWidget);
      await tester.tap(rail('Status'));
      await tester.pumpAndSettle();
      expect(find.byType(StatusPage), findsOneWidget);
      await tester.tap(key('desktop-extra-toggle'));
      await tester.pumpAndSettle();
      expect(key('tablet-extra-area'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  platformTest('Header and extra area open either window in both modes', (
    tester,
  ) async {
    await pump(tester);
    for (var mode = 0; mode < 2; mode++) {
      await tester.tap(key('desktop-window-analyzer'));
      await tester.tap(key('desktop-window-player'));
      if (mode == 0) {
        await tester.tap(key('tablet-extra-analyzer'));
        await tester.pumpAndSettle();
        await tester.tap(key('desktop-extra-open-window'));
        await tester.tap(key('tablet-extra-player'));
        await tester.pumpAndSettle();
        await tester.tap(key('desktop-extra-open-window'));
        await tester.tap(key('desktop-extra-toggle'));
        await tester.pumpAndSettle();
      }
    }
    expect(windows.opened, [
      AuxiliaryWindow.analyzer,
      AuxiliaryWindow.player,
      AuxiliaryWindow.analyzer,
      AuxiliaryWindow.player,
      AuxiliaryWindow.analyzer,
      AuxiliaryWindow.player,
    ]);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(960, 600), const Size(640, 525)]) {
    platformTest('Device-only controls fit smaller Linux window $size', (
      tester,
    ) async {
      await AppSettings.instance.setLinuxLandscapeExtra(false);
      await pump(tester, size: size);
      expect(key('tablet-extra-area'), findsNothing);
      expect(rail('EQ'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  platformTest('Desktop view scales the outputs page uniformly', (
    tester,
  ) async {
    await AppSettings.instance.setLinuxLandscapeExtra(false);
    await pump(tester, size: const Size(1200, 800));
    expect(key('desktop-output-scale'), findsOneWidget);
    double ring() => tester.getRect(find.byType(VolumeRing)).height;
    double tiles() => tester.getRect(key('output-tiles')).height;
    final ringLarge = ring(), tilesLarge = tiles();
    await pump(tester, size: const Size(900, 640));
    expect(ring() / ringLarge, closeTo(tiles() / tilesLarge, 0.01));
    expect(ring(), lessThan(ringLarge));
    await pump(tester, size: const Size(1200, 800));
    await AppSettings.instance.setLinuxCompact(true);
    await tester.pumpAndSettle();
    expect(key('desktop-output-scale'), findsNothing);
    await AppSettings.instance.setLinuxCompact(false);
    expect(tester.takeException(), isNull);
  });

  platformTest(
    'Compact view in a short window scrolls instead of overflowing',
    (tester) async {
      await AppSettings.instance.setLinuxCompact(true);
      for (final size in [const Size(900, 640), const Size(1200, 600)]) {
        await pump(tester, size: size);
        expect(tester.takeException(), isNull);
      }
      await AppSettings.instance.setLinuxCompact(false);
    },
  );

  platformTest('Compact toggle shows the phone layout in a wide window', (
    tester,
  ) async {
    await pump(tester, size: const Size(1280, 800));
    expect(key('desktop-extra-toggle'), findsOneWidget);
    await tester.tap(key('desktop-compact-toggle'));
    await tester.pumpAndSettle();
    expect(AppSettings.instance.linuxCompact, isTrue);
    expect(key('tablet-extra-area'), findsNothing);
    expect(key('desktop-extra-toggle'), findsNothing);
    expect(
      (await SharedPreferences.getInstance()).getBool('linux_compact'),
      isTrue,
    );
    await tester.tap(key('desktop-compact-toggle'));
    await tester.pumpAndSettle();
    expect(AppSettings.instance.linuxCompact, isFalse);
    expect(tester.takeException(), isNull);
  });

  platformTest('Linux setting changes and persists the mode', (tester) async {
    await pump(tester, child: AppSettingsPage(ctrl: ctrl));
    final setting = key('linux-landscape-extra-setting');
    await tester.ensureVisible(setting);
    await tester.tap(setting);
    await tester.pumpAndSettle();
    expect(AppSettings.instance.linuxLandscapeExtra, isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool('linux_landscape_extra'),
      isFalse,
    );
  });

  platformTest('Standalone Linux has no desktop window buttons or setting', (
    tester,
  ) async {
    ctrl.dispose();
    ctrl = _Controller(embeddedHost: false);
    await pump(tester);
    expect(key('desktop-window-analyzer'), findsNothing);
    expect(key('desktop-extra-toggle'), findsNothing);
    expect(key('tablet-extra-area'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await pump(tester, child: AppSettingsPage(ctrl: ctrl));
    expect(key('linux-landscape-extra-setting'), findsNothing);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    platformTest('Desktop controls remain absent on $platform', (tester) async {
      await AppSettings.instance.setLinuxLandscapeExtra(false);
      await pump(tester);
      expect(key('desktop-window-analyzer'), findsNothing);
      expect(key('desktop-window-player'), findsNothing);
      expect(key('desktop-extra-toggle'), findsNothing);
      expect(key('tablet-extra-area'), findsOneWidget);
    }, platform: platform);
  }

  platformTest(
    'Dedicated analyzer has settings but no fullscreen action or route',
    (tester) async {
      await pump(
        tester,
        size: const Size(640, 360),
        child: Scaffold(
          body: AnalyzerPanel(
            deviceController: ctrl,
            expanded: true,
            allowFullscreen: false,
          ),
        ),
      );
      expect(find.byTooltip('Analyzer-Einstellungen'), findsOneWidget);
      expect(find.byTooltip('Vollbild'), findsNothing);
      await tester.tapAt(tester.getCenter(find.byType(AnalyzerDisplay)));
      await tester.pumpAndSettle();
      expect(find.byType(AnalyzerPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  platformTest(
    'Player window provides a full-size empty state without prompts',
    (tester) async {
      await pump(
        tester,
        child: Scaffold(body: PlayerWindowView(controller: ctrl)),
      );
      expect(find.text('Kein Player aktiv'), findsOneWidget);
      expect(find.text('App-Einstellungen'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  for (final size in [
    const Size(900, 600),
    const Size(400, 700),
    const Size(360, 300),
  ]) {
    platformTest(
      'Player artwork and host controls fit $size and survive focus loss',
      (tester) async {
        final host = _PlayerHost()
          ..playerAvailable = true
          ..playerInfo = NowPlayingInfo(
            title: 'A long track title',
            artist: 'Artist',
            album: 'Album',
            playing: true,
            art: Uint8List.fromList([0]),
          );
        ctrl.dispose();
        ctrl = _Controller(host: host)..hostMode = true;
        await pump(
          tester,
          size: size,
          child: Scaffold(body: PlayerWindowView(controller: ctrl)),
        );
        expect(find.text('A long track title'), findsOneWidget);
        expect(find.byType(Image), findsOneWidget);
        await tester.tap(find.byIcon(Icons.pause));
        await tester.pump();
        expect(
          host.sent.any(
            (call) =>
                call.$1 == 'player_command' && call.$2['command'] == 'pause',
          ),
          isTrue,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump(const Duration(seconds: 1));
        expect(
          host.sent.where((call) => call.$1 == 'player_unsubscribe'),
          isEmpty,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      },
    );
  }

  platformTest('Desktop header: status, player and analyzer equally tall', (
    tester,
  ) async {
    await AppSettings.instance.setLinuxCompact(true);
    np.info = const npm.NowPlayingInfo(
      title: 'Titel',
      artist: 'Kuenstler',
      playing: true,
    );
    ctrl.status = st.Adi2Status([0x30, 0x7E, 0x08, 0, 0, 0, 2, 4, 1, 0x11, 0]);
    final heights = <double>{};
    final boxes = <Rect>{};
    for (final content in [
      HeaderContent.player,
      HeaderContent.status,
      HeaderContent.analyzer,
    ]) {
      await AppSettings.instance.setHeaderContent(content);
      await pump(tester, size: const Size(624, 761));
      heights.add(tester.getRect(key('header-swipe')).height);
      // Der sichtbare Kasten (erste Fläche mit runden Ecken im Kopfbereich).
      boxes.add(
        tester.getRect(
          find
              .descendant(
                of: key('header-swipe'),
                matching: find.byWidgetPredicate(
                  (w) =>
                      (w is Material && w.borderRadius != null) || w is Panel,
                ),
              )
              .first,
        ),
      );
      expect(tester.takeException(), isNull);
    }
    expect(heights, {desktopHeaderHeight});
    expect(boxes, hasLength(1));
    await AppSettings.instance.setLinuxCompact(false);
  });

  platformTest('Desktop analyzer header fits levels, peak controls and icons', (
    tester,
  ) async {
    await AppSettings.instance.setAnalyzerMainView(AnalyzerMainView.both);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(624, 761);
    addTearDown(tester.view.reset);
    final analyzer = AnalyzerController()..status = AnalyzerStatus.running;
    addTearDown(analyzer.dispose);
    analyzer.frame = AnalyzerFrame(
      sampleRate: 48000,
      spectrum: List.filled(1025, -24),
      peak: [-6, -6],
      rms: [-18, -18],
      clipped: [false, false],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 592,
              height: desktopHeaderHeight - 8,
              child: AnalyzerDisplay(
                controller: analyzer,
                compact: true,
                actions: const SizedBox(width: 56, height: 28),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final box = tester.getRect(find.byType(AnalyzerDisplay));
    expect(
      tester.getRect(key('analyzer-side-controls')).bottom,
      lessThanOrEqualTo(box.bottom - 8),
    );
    expect(tester.takeException(), isNull);
  }, platform: TargetPlatform.windows);
}
