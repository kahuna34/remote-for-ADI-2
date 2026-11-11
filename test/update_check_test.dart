import 'dart:convert';

import 'package:adi2_remote/update/update_check.dart';
import 'package:flutter_test/flutter_test.dart';

String release({String tag = 'v1.2.0', bool assets = true}) => jsonEncode({
  'tag_name': tag,
  'html_url': 'https://github.com/kahuna34/remote-for-ADI-2/releases/tag/$tag',
  'assets': assets
      ? [
          for (final name in [
            'Android.apk',
            'Host-macOS.zip',
            'Host-Windows-x64.zip',
          ])
            {
              'name': 'Remote-for-ADI-2-$name',
              'browser_download_url': 'https://github.com/download/$name',
            },
        ]
      : [],
});

void main() {
  test('semantic versions ignore v and build, reject invalid tags', () {
    for (final (tag, expected) in [
      ('v1.2.0', true),
      ('v1.1.0', false),
      ('v1.0.9', false),
      ('v2.0.0', true),
      ('invalid', false),
      ('1.1', false),
      ('v1.1.0+99', false),
      ('v1.2.0+3', true),
      ('1.2.0-beta', false),
      ('999999999999999999999999.0.0', false),
    ]) {
      expect(isNewerVersion('1.1.0 (2)', tag), expected, reason: tag);
    }
    expect(isNewerVersion('broken', '1.2.0'), false);
    expect(isNewerVersion('1.9.0+2', '1.10.0'), true);
  });

  test('selects platform assets and falls back to release page', () async {
    for (final (platform, suffix) in [
      (UpdatePlatform.android, 'Android.apk'),
      (UpdatePlatform.macos, 'Host-macOS.zip'),
      (UpdatePlatform.windows, 'Host-Windows-x64.zip'),
    ]) {
      final check = UpdateCheck(
        installedVersion: '1.1.0',
        platform: platform,
        fetcher: () async => release(),
      );
      final result = await check.check();
      expect(result.status, UpdateStatus.available);
      expect(result.version, '1.2.0');
      expect(result.url.toString(), 'https://github.com/download/$suffix');
      final fallback = UpdateCheck(
        installedVersion: '1.1.0',
        platform: platform,
        fetcher: () async => release(assets: false),
      );
      expect(
        (await fallback.check()).url.toString(),
        contains('/releases/tag/v1.2.0'),
      );
    }
  });

  test(
    'automatic checks throttle for 24 hours; disabled checks never fetch',
    () async {
      var now = DateTime.utc(2026, 11, 11);
      var calls = 0, saves = 0;
      final check = UpdateCheck(
        installedVersion: '1.1.0',
        platform: UpdatePlatform.android,
        clock: () => now,
        fetcher: () async {
          calls++;
          return release();
        },
        onState: () async {
          saves++;
        },
      );
      await check.check();
      expect(calls, 1);
      now = now.add(const Duration(hours: 23, minutes: 59));
      expect((await check.check()).status, UpdateStatus.skipped);
      now = now.add(const Duration(minutes: 1));
      await check.check();
      expect(calls, 2);
      check.enabled = false;
      now = now.add(const Duration(days: 2));
      await check.check();
      expect(calls, 2);
      await check.check(manual: true);
      expect(calls, 3);
      expect(saves, greaterThan(0));
      expect(check.resultWasAutomatic, false);
    },
  );

  test(
    'network errors, rate limits, invalid JSON and URLs return errors',
    () async {
      for (final fetcher in <ReleaseFetcher>[
        () async => throw Exception('offline'),
        () async => throw Exception('HTTP 403'),
        () async => '{',
        () async => '{}',
        () async =>
            jsonEncode({'tag_name': '1.2.0', 'html_url': 'file:///tmp/foo'}),
      ]) {
        final check = UpdateCheck(
          installedVersion: '1.1.0',
          platform: UpdatePlatform.android,
          fetcher: fetcher,
        );
        expect((await check.check()).status, UpdateStatus.error);
        expect((await check.check()).status, UpdateStatus.skipped);
      }
    },
  );

  test('invalid release tag means no update', () async {
    final check = UpdateCheck(
      installedVersion: '1.1.0',
      platform: UpdatePlatform.android,
      fetcher: () async => release(tag: 'bad'),
    );
    expect((await check.check()).status, UpdateStatus.current);
  });

  test(
    'Later suppresses the same version but allows a newer version',
    () async {
      final check = UpdateCheck(
        installedVersion: '1.1.0',
        platform: UpdatePlatform.android,
        fetcher: () async => release(),
      );
      final result = await check.check();
      expect(check.shouldNotify(result), true);
      await check.skip('v1.2.0');
      expect(check.shouldNotify(result), false);
      expect(
        check.shouldNotify(
          UpdateResult(
            UpdateStatus.available,
            version: '1.3.0',
            url: result.url,
          ),
        ),
        true,
      );
      expect(check.result?.status, UpdateStatus.available);
    },
  );
}
