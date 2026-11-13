import 'dart:convert';

import 'package:adi2_remote/analyzer/header_content.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/host/host_client.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/media/player_source.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/player_bar.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Host extends HostClient {
  final sent = <String>[];
  bool online = true;
  @override
  bool get connected => online;
  @override
  void send(String type, [Map<String, dynamic> payload = const {}]) {
    sent.add('$type:${payload['command'] ?? ''}');
  }

  void update() => notifyListeners();
}

class _Device extends Adi2Controller {
  _Device(_Host host) : super(host: host) {
    state = ConnState.connected;
  }
  bool remote = true;
  final values = offlineDefaults(Adi2Variant.dac);
  @override
  bool get viaHost => remote;
  @override
  Adi2Variant get variant => Adi2Variant.dac;
  @override
  int? value(int address, int index) => values[address << 8 | index];
  void local() {
    remote = false;
    notifyListeners();
  }
}

class _Phone extends NowPlaying {
  _Phone() {
    supported = access = true;
    info = const NowPlayingInfo(
      title: 'Phone song',
      artist: 'Phone artist',
      app: 'Phone app',
    );
  }
  final commands = <String>[];
  @override
  Future<void> command(String command) async {
    commands.add(command);
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
    AppLang.instance.language = AppLanguage.de;
  });

  for (final extra in [false, true]) {
    testWidgets(
      'host data and commands in ${extra ? 'landscape extra pane' : 'bar'}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = extra
            ? const Size(1280, 800)
            : const Size(400, 800);
        addTearDown(tester.view.reset);
        final host = _Host()..playerAvailable = true;
        final device = _Device(host);
        final phone = _Phone()..access = false;
        host.playerInfo = NowPlayingInfo(
          title: 'Host song',
          artist: 'Host artist',
          app: 'Host app',
          playing: true,
          art: base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
        );
        await AppSettings.instance.setHeaderContent(HeaderContent.none);
        await AppSettings.instance.setTabletExtraContent(
          TabletExtraContent.player,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: extra
                ? HomePage(ctrl: device, np: phone)
                : Scaffold(
                    body: PlayerBar(np: phone, deviceController: device),
                  ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Host song', findRichText: true),
          findsOneWidget,
        );
        expect(
          find.textContaining('Host artist', findRichText: true),
          findsOneWidget,
        );
        expect(find.text('über Host app'), findsOneWidget);
        expect(find.byType(Image), findsOneWidget);
        expect(find.text('Erlauben'), findsNothing);
        for (final icon in [
          Icons.skip_previous,
          Icons.pause,
          Icons.skip_next,
        ]) {
          await tester.tap(find.byIcon(icon));
          await tester.pump();
        }
        expect(host.sent, [
          'player_subscribe:',
          'player_command:previous',
          'player_command:pause',
          'player_command:next',
        ]);
        expect(phone.commands, isEmpty);
        host.playerInfo = const NowPlayingInfo(title: 'Changed host song');
        host.update();
        await tester.pump();
        expect(
          find.textContaining('Changed host song', findRichText: true),
          findsOneWidget,
        );
        host.online = false;
        host.setReconnecting(true);
        await tester.pump();
        expect(
          find.textContaining('Changed host song', findRichText: true),
          findsOneWidget,
        );
        expect(
          find.textContaining('Phone song', findRichText: true),
          findsNothing,
        );
        final before = host.sent.length;
        final source = PlayerSource(np: phone, deviceController: device);
        expect(source.controlsEnabled, isFalse);
        await source.command('play');
        host.playerCommand('play');
        expect(host.sent, hasLength(before));
        expect(phone.commands, isEmpty);
        source.dispose();
        host.online = true;
        host.setReconnecting(false);
        await tester.pump();
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 500));
        expect(host.sent.last, 'player_unsubscribe:');
        device.dispose();
        phone.dispose();
      },
    );
  }

  testWidgets('phone fallback, old host hint and source changes', (
    tester,
  ) async {
    final host = _Host();
    final device = _Device(host);
    final phone = _Phone();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerBar(np: phone, deviceController: device),
        ),
      ),
    );
    expect(
      find.textContaining('Phone song', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('Host aktualisieren'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.play_arrow));
    expect(phone.commands, ['play']);
    expect(host.sent, isEmpty);
    host.playerAvailable = true;
    host.playerInfo = const NowPlayingInfo(title: 'Host song');
    host.update();
    await tester.pump();
    expect(
      find.textContaining('Host song', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('Host aktualisieren'), findsNothing);
    device.local();
    await tester.pump();
    expect(
      find.textContaining('Phone song', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('Host aktualisieren'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
    device.dispose();
    phone.dispose();
  });

  testWidgets('shared owner count, 500 ms grace and quick reappearance', (
    tester,
  ) async {
    final host = _Host()..playerAvailable = true;
    final device = _Device(host);
    final phone = _Phone();
    final a = PlayerSource(np: phone, deviceController: device);
    final b = PlayerSource(np: phone, deviceController: device);
    a.setActive(true);
    b.setActive(true);
    expect(host.sent, ['player_subscribe:']);
    a.setActive(false);
    await tester.pump(const Duration(seconds: 1));
    expect(host.sent, ['player_subscribe:']);
    b.setActive(false);
    await tester.pump(const Duration(milliseconds: 499));
    expect(host.sent, ['player_subscribe:']);
    a.setActive(true);
    await tester.pump(const Duration(milliseconds: 1));
    expect(host.sent, ['player_subscribe:']);
    a.dispose();
    b.dispose();
    await tester.pump(const Duration(milliseconds: 499));
    expect(host.sent, ['player_subscribe:']);
    await tester.pump(const Duration(milliseconds: 1));
    expect(host.sent, ['player_subscribe:', 'player_unsubscribe:']);
    device.dispose();
    phone.dispose();
  });

  testWidgets('covered route and background release a visible player owner', (
    tester,
  ) async {
    final host = _Host()..playerAvailable = true;
    final device = _Device(host);
    final phone = _Phone();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: PlayerBar(np: phone, deviceController: device),
        ),
      ),
    );
    expect(host.sent, ['player_subscribe:']);
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(host.sent.last, 'player_unsubscribe:');
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(host.sent.last, 'player_subscribe:');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(host.sent.last, 'player_unsubscribe:');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(host.sent.last, 'player_subscribe:');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
    device.dispose();
    phone.dispose();
  });
}
