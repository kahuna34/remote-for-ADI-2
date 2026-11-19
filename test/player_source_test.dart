import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/host/host_client.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/media/player_source.dart';
import 'package:flutter_test/flutter_test.dart';

class _Host extends HostClient {
  final sent = <String>[];
  @override
  bool get connected => true;
  @override
  void send(String type, [Map<String, dynamic> payload = const {}]) =>
      sent.add('$type:${payload['command'] ?? ''}');
  void playing(bool value) {
    playerInfo = NowPlayingInfo(title: 'Host song', playing: value);
    notifyListeners();
  }
}

class _Device extends Adi2Controller {
  _Device(HostClient host) : super(host: host);
  @override
  bool get viaHost => true;
}

class _Phone extends NowPlaying {
  final sent = <String>[];
  @override
  Future<void> command(String c) async => sent.add(c);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'lokal spielend + Host pausiert → lokal, beide spielend → Host; Abo bleibt aktiv',
    (tester) async {
      final host = _Host()..playerAvailable = true;
      final device = _Device(host);
      final phone = _Phone()
        ..supported = true
        ..access = true
        ..info = const NowPlayingInfo(title: 'Local song', playing: true);
      final source = PlayerSource(np: phone, deviceController: device)
        ..setActive(true);
      host.playing(false);
      expect(source.usesHost, false);
      expect(source.info?.title, 'Local song');
      expect(source.visible, true);
      await source.command('pause');
      expect(phone.sent, ['pause']);
      expect(host.sent, ['player_subscribe:']);
      host.playing(true);
      expect(source.usesHost, true);
      expect(source.info?.title, 'Host song');
      await source.command('next');
      expect(host.sent.last, 'player_command:next');
      phone.info = const NowPlayingInfo(title: 'Local song');
      host.playing(false);
      expect(source.usesHost, true); // both paused: existing host preference
      source.dispose();
      await tester.pump(const Duration(milliseconds: 500));
      device.dispose();
      phone.dispose();
    },
  );
}
