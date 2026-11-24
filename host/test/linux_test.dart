import 'dart:convert';
import 'dart:io';

import 'package:adi2_host/autostart.dart';
import 'package:adi2_remote/update/update_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Linux autostart writes an escaped AppImage path, updates and removes it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'adi2-linux-autostart',
      );
      addTearDown(() => directory.delete(recursive: true));
      final auto = HostAutostart(
        platform: 'linux',
        executable: '/tmp/.mount/host',
        appImage: '/home/user/My App/Host.AppImage',
        home: directory.path,
        configHome: '${directory.path}/config',
      );
      expect(await auto.enabled(), isFalse);
      expect(await auto.refreshEnabledPath(), isFalse);
      await auto.setEnabled(true);
      expect(await auto.enabled(), isTrue);
      final contents = await File(auto.desktopPath).readAsString();
      expect(contents, contains('Exec="/home/user/My App/Host.AppImage"'));
      expect(contents, contains('--autostart'));
      expect(contents, contains('Name=Remote for ADI-2\n'));
      expect(contents, contains('Type=Application'));
      expect(contents, contains('Terminal=false'));
      expect(contents, isNot(contains('/tmp/.mount')));
      expect(await auto.refreshEnabledPath(), isTrue);
      await auto.setEnabled(false);
      expect(await auto.enabled(), isFalse);
      final fallback = HostAutostart(
        platform: 'linux',
        executable: '/opt/host',
        home: directory.path,
        configHome: 'relative',
      );
      expect(
        fallback.desktopPath,
        '${directory.path}/.config/autostart/remote-for-adi2-host.desktop',
      );
      await fallback.setEnabled(true);
      expect(
        await File(fallback.desktopPath).readAsString(),
        contains('Exec="/opt/host"'),
      );
    },
  );

  test('Desktop Entry escaping preserves quotes, backslashes, field codes and shell characters', () {
    final entry = HostAutostart.linuxDesktopEntry(
      r'/tmp/A "B" $x `y` \ 100%/Host',
    );
    expect(
      entry,
      contains(r'Exec="/tmp/A \\"B\\" \\$x \\`y\\` \\\\ 100%%/Host"'),
    );
    expect(
      () => HostAutostart.linuxDesktopEntry('/tmp/bad\npath'),
      throwsFormatException,
    );
  });

  test(
    'Linux host selects the combined AppImage and compares its app version',
    () async {
      final result = await UpdateCheck(
        installedVersion: '1.0.0',
        platform: UpdatePlatform.linux,
        host: true,
        fetcher: () async => jsonEncode({
          'tag_name': 'v9.0.0',
          'html_url': 'https://example.com/release',
          'assets': [
            {
              'name': 'Remote-for-ADI-2-Linux-8.0.0.AppImage',
              'browser_download_url': 'https://example.com/app',
            },
            {
              'name': 'Remote-for-ADI-2-Host-Linux-2.0.0.AppImage',
              'browser_download_url': 'https://example.com/host',
            },
          ],
        }),
      ).check();
      expect(result.version, '8.0.0');
      expect(result.url.toString(), 'https://example.com/app');
    },
  );
}
