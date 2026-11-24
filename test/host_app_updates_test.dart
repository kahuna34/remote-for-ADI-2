import 'dart:convert';

import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/update/app_updates.dart';
import 'package:adi2_remote/update/update_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in [UpdatePlatform.macos, UpdatePlatform.other]) {
    test(
      'Embedded $platform uses the existing host updater, version and preferences',
      () async {
        SharedPreferences.setMockInitialValues({'update_check': true});
        await AppSettings.instance.load(reload: true);
        var fetches = 0;
        final enabled = <bool>[];
        final checker = UpdateCheck(
          installedVersion: '1.2.3',
          platform: platform,
          host: true,
          enabled: false,
          fetcher: () async {
            fetches++;
            return jsonEncode({
              'tag_name': 'v1.2.4',
              'html_url': 'https://example.com/host-setup.exe',
              'assets': [],
            });
          },
        );
        final updates = AppUpdates.forTesting();
        updates.useHostChecker(
          Future.value(checker),
          onEnabledChanged: (value) async {
            enabled.add(value);
          },
        );
        await updates.initialize();
        expect(identical(updates.checker, checker), true);
        expect(fetches, 0);
        expect(updates.automaticEnabled, false);
        expect(AppSettings.instance.updateCheck, true);
        expect(
          (await updates.checkNow()).url.toString(),
          'https://example.com/host-setup.exe',
        );
        expect(fetches, 1);
        await updates.setAutomaticEnabled(true);
        expect(enabled, [true]);
        expect(checker.enabled, true);
        expect(
          (await SharedPreferences.getInstance()).getBool('update_check'),
          true,
        );
        checker.stop();
        updates.dispose();
      },
    );
  }
}
