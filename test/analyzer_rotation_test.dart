import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/analyzer/header_content.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/host/host_analyzer_protocol.dart';
import 'package:adi2_remote/host/host_client.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/ui/analyzer_controls.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:adi2_remote/ui/eq_display_mode.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/responsive_layout.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Host extends HostClient {
  _Host() {
    analyzerAvailable = true;
    analyzerVersion = 2;
  }
  final calls = <String>[];
  @override
  bool get connected => true;
  @override
  void send(String type, [Map<String, dynamic> payload = const {}]) =>
      calls.add(type);
}

class _Device extends Adi2Controller {
  _Device(this.source) : super(host: source) {
    state = ConnState.connected;
    values[Adi2Addr.device << 8 | DevIdx.meterColor] = 4;
  }
  final _Host? source;
  final values = offlineDefaults(Adi2Variant.dac);
  @override
  bool get viaHost => source != null;
  @override
  Adi2Variant get variant => Adi2Variant.dac;
  @override
  int? value(int address, int index) => values[address << 8 | index];
  @override
  int valueOr(int address, int index, int fallback) =>
      value(address, index) ?? fallback;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
    await AppSettings.instance.setHeaderContent(HeaderContent.analyzer);
    await AppSettings.instance.setTabletExtraContent(
      TabletExtraContent.analyzer,
    );
    await AppSettings.instance.setAnalyzerPeakHoldSeconds(0);
    await AppSettings.instance.setAutoFullscreenEq(false);
  });

  for (final hostSource in [true, false]) {
    for (final color in [4, -1]) {
      testWidgets('Tablet hoch/quer/hoch: Farbe $color, Host=$hostSource', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(800, 1280);
        addTearDown(tester.view.reset);
        addTearDown(() => EqDisplayMode.setTablet(false));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await AppSettings.instance.setAnalyzerColor(color);
        final host = hostSource ? _Host() : null;
        final device = _Device(host);
        final np = NowPlaying();
        final native = <String>[];
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          const MethodChannel('adi2/analyzer'),
          (call) async {
            native.add(call.method);
            return call.method == 'permission' ? true : null;
          },
        );
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
          device.dispose();
          np.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            builder: (context, child) => TabletOrientation(child: child!),
            home: HomePage(ctrl: device, np: np),
          ),
        );
        await tester.pumpAndSettle();
        final controller = tester
            .widget<AnalyzerPanel>(find.byType(AnalyzerPanel))
            .controller!;
        final frame = AnalyzerFrame(
          sampleRate: 48000,
          spectrum: List.filled(1025, .1),
          bassSpectrum: List.filled(4097, .1),
          bassBinHz: 48000 / 8192,
          bandLevels: List.filled(controller.bandResolution.count, -20),
          peak: const [-20, -20],
          rms: const [-23, -23],
          clipped: const [false, false],
        );
        void send() {
          if (host != null) {
            host.analyzerEvents.add({
              'type': 'analyzer_frame',
              ...encodeHostAnalyzerFrameV2(frame, bars: controller.bars),
            });
          } else {
            messenger.handlePlatformMessage(
              'adi2/analyzer/events',
              const StandardMethodCodec().encodeSuccessEnvelope({
                'sampleRate': 48000,
                'spectrum': frame.spectrum,
                'bassSpectrum': frame.bassSpectrum,
                'bassBinHz': frame.bassBinHz,
                'peak': frame.peak,
                'rms': frame.rms,
                'clipped': frame.clipped,
                'seconds': frame.seconds,
              }),
              (_) {},
            );
          }
        }

        if (host != null) {
          host.analyzerEvents.add({
            'type': 'analyzer_metadata',
            'v': 2,
            'sampleRate': 48000,
            'device': 'ADI-2 DAC',
          });
        }
        send();
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 100));
        final held = List.of(controller.spectrum.held);
        final bassHeld = List.of(controller.bassSpectrum.held);
        final bandsHeld = List.of(controller.bands.held);
        expect(held, isNotEmpty);
        void check() {
          final displays = tester.widgetList<AnalyzerDisplay>(
            find.byType(AnalyzerDisplay),
          );
          expect(displays, isNotEmpty);
          for (final display in displays) {
            expect(display.controller, same(controller));
            expect(display.deviceController, same(device));
          }
          final plots = tester.widgetList<CustomPaint>(
            find.byKey(const ValueKey('analyzer-spectrum')),
          );
          expect(plots, isNotEmpty);
          for (final plot in plots) {
            expect((plot.painter as dynamic).color, analyzerColors[4]);
          }
          for (final bar in tester.widgetList<AnalyzerLevelBar>(
            find.byType(AnalyzerLevelBar),
          )) {
            expect(bar.color, analyzerColors[4]);
          }
          expect(controller.spectrum.held, held);
          expect(controller.bassSpectrum.held, bassHeld);
          expect(controller.bands.held, bandsHeld);
          expect(
            host?.calls.where((c) => c == 'analyzer_start') ??
                native.where((c) => c == 'start'),
            hasLength(1),
          );
          expect(
            host?.calls.where((c) => c == 'analyzer_stop') ??
                native.where((c) => c == 'stop'),
            isEmpty,
          );
          expect(tester.takeException(), isNull);
        }

        check();
        for (final size in [const Size(1280, 800), const Size(800, 1280)]) {
          tester.view.physicalSize = size;
          // Inspect every rendered frame, including the layout replacement and
          // well beyond the visibility grace period, without fresh input.
          for (var i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 16));
            check();
          }
        }
        // No visible analyzer: capture really stops after the grace period.
        await AppSettings.instance.setHeaderContent(HeaderContent.none);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 499));
        expect(controller.frame, isNotNull);
        await AppSettings.instance.setHeaderContent(HeaderContent.analyzer);
        await tester.pump();
        check();
        await tester.pump(const Duration(milliseconds: 600));
        check();
        await AppSettings.instance.setHeaderContent(HeaderContent.none);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(controller.frame, isNull);
        expect(
          host?.calls.where((c) => c == 'analyzer_stop') ??
              native.where((c) => c == 'stop'),
          hasLength(1),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }
  }
}
