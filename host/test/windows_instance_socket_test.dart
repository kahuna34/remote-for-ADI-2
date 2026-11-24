import 'dart:convert';
import 'dart:io';

import 'package:adi2_host/windows_instance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows transport: stale file, loopback, token, show/ping and window credentials', () async {
    final dir = await Directory.systemTemp.createTemp('adi2-tcp-');
    WindowsInstance? owner;
    addTearDown(() async {
      await owner?.close();
      await dir.delete(recursive: true);
    });
    // The ACL itself must be verified on Windows; the same TCP protocol runs
    // on every test OS with a temporary, already user-private directory.
    await File('${dir.path}/instance.json').writeAsString('forged/stale');
    var shows = 0;
    owner = await WindowsInstance.acquire(
      directory: dir.path,
      show: true,
      protect: Platform.isWindows ? null : (_) async {},
      onShow: () async {
        shows++;
      },
      onWindowRequest: (_, request) async => {
        'key': 'private',
        'method': request['method'],
      },
    );
    if (Platform.isWindows) {
      // Windows file locks are mandatory across handles, including this process.
      // A manual second launch shows the owner; autostart only pings it.
      final second = await WindowsInstance.acquire(
        directory: dir.path,
        show: true,
        onShow: () async => fail('Second instance must not own a server'),
      );
      expect(second, null);
      expect(shows, 1);
      final automatic = await WindowsInstance.acquire(
        directory: dir.path,
        show: false,
        onShow: () async => fail('Autostart must not own a server'),
      );
      expect(automatic, null);
      expect(shows, 1);
      shows = 0;
    }
    final endpoint = await WindowsInstance.readEndpoint(dir.path);
    expect(endpoint.token.length, 64);
    expect(
      await WindowsInstance.request(dir.path, {
        'type': 'adi2-instance-v1',
        'action': 'ping',
      }),
      null,
    );
    await WindowsInstance.request(dir.path, {
      'type': 'adi2-instance-v1',
      'action': 'show',
    });
    expect(shows, 1);
    expect(
      await WindowsInstance.request(dir.path, {
        'type': 'adi2-window-v1',
        'window': 'player',
        'method': 'credentials',
      }),
      {'key': 'private', 'method': 'credentials'},
    );
    final forged = await Socket.connect(
      InternetAddress.loopbackIPv4,
      endpoint.port,
    );
    forged.writeln(
      jsonEncode({
        'type': 'adi2-instance-v1',
        'action': 'show',
        'token': 'b' * 64,
      }),
    );
    await forged.flush();
    expect(
      await forged.cast<List<int>>().transform(utf8.decoder).join(),
      isEmpty,
    );
    forged.destroy();
    expect(shows, 1);
    await owner!.close();
    owner = null;
    expect(await File('${dir.path}/instance.json').exists(), false);
  });
}
