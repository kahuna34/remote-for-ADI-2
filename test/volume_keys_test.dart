import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/volume_keys.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Device extends Adi2Controller {
  _Device() {
    state = ConnState.connected;
  }
  int raw = -300;
  bool locked = false;
  final requests = <(int, int)>[];
  @override
  Adi2Variant get variant => Adi2Variant.dac;
  @override
  int? value(int a, int i) => i == OutIdx.volume
      ? raw
      : i == OutIdx.lockVolume
      ? (locked ? 1 : 0)
      : null;
  @override
  int valueOr(int a, int i, int fallback) => value(a, i) ?? fallback;
  @override
  void setVolume(int a, int raw, {bool followLink = true}) {
    requests.add((a, raw));
    super.setVolume(a, raw, followLink: followLink);
  }

  @override
  void requestAll() {}
  void connection(ConnState next) {
    state = next;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('adi2/volume_keys');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<bool> enabled;
  Future<void> step(int direction) => messenger.handlePlatformMessage(
    channel.name,
    const StandardMethodCodec().encodeMethodCall(MethodCall('step', direction)),
    (_) {},
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
    enabled = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'setEnabled');
      enabled.add(call.arguments as bool);
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Schritte, Gerätewert statt Rampenziel, Sperre und Drossel', () async {
    final c = _Device();
    var now = DateTime(2026);
    var output = Adi2Addr.line;
    final keys = VolumeKeys(
      controller: c,
      output: () => output,
      now: () => now,
    );
    addTearDown(c.dispose);
    addTearDown(keys.dispose);
    keys.update(foreground: true, current: true);
    await step(-1);
    expect(c.requests.last, (output, -305));
    await step(-1);
    expect(c.requests, hasLength(1));
    now = now.add(const Duration(milliseconds: 100));
    await step(-1);
    expect(c.requests.last, (output, -310)); // quieter pending target wins
    await step(1);
    expect(c.requests.last, (output, -295));
    now = now.add(const Duration(milliseconds: 249));
    await step(1);
    expect(c.requests, hasLength(3));
    now = now.add(const Duration(milliseconds: 1));
    await step(1);
    expect(c.requests.last, (output, -295)); // no accumulating upward target
    c.locked = true;
    now = now.add(const Duration(seconds: 1));
    final count = c.requests.length;
    await step(1);
    await step(-1);
    await step(0);
    expect(c.requests, hasLength(count));
    c.locked = false;
    output = Adi2Addr.ph12;
    c.volGuard.setLimit(output, -298);
    await step(1);
    expect(c.volumeTarget(output), -298);
    expect(c.volGuard.tick((_) => c.raw)[output], lessThanOrEqualTo(-298));
  });

  test(
    'Vordergrund, Route, Einstellung, Offline und Wiederverbindung',
    () async {
      final c = _Device();
      final keys = VolumeKeys(controller: c, output: () => Adi2Addr.line);
      addTearDown(c.dispose);
      addTearDown(keys.dispose);
      keys.update(foreground: true, current: true);
      expect(enabled, [true]);
      keys.update(foreground: false, current: true);
      await step(-1);
      expect(c.requests, isEmpty);
      keys.update(foreground: true, current: false);
      keys.update(foreground: true, current: true);
      await AppSettings.instance.setVolumeKeys(false);
      await step(-1);
      expect(c.requests, isEmpty);
      await AppSettings.instance.setVolumeKeys(true);
      c.connection(ConnState.offline);
      c.connection(ConnState.connected);
      c.connection(ConnState.reconnecting);
      await step(1);
      expect(c.requests, isEmpty);
      c.connection(ConnState.searching);
      c.connection(ConnState.connected);
      expect(enabled, [
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
      ]);
      await AppSettings.instance.setVolumeKeys(false);
      await AppSettings.instance.load();
      expect(AppSettings.instance.volumeKeys, isFalse);
    },
  );

  testWidgets('HomePage folgt der aktuellen Route und dem Lebenszyklus', (
    tester,
  ) async {
    final c = _Device(), np = NowPlaying();
    addTearDown(c.dispose);
    addTearDown(np.dispose);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: HomePage(ctrl: c, np: np),
      ),
    );
    await tester.pumpAndSettle();
    expect(enabled.last, true);
    nav.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
    expect(enabled.last, false);
    await step(1);
    expect(c.requests, isEmpty);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(enabled.last, true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(enabled.last, false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(enabled.last, true);
    await tester.pumpWidget(const SizedBox());
    expect(enabled.last, false);
  });
}
