import 'dart:convert';

import 'package:adi2_remote/update/update_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Linux app selects only its AppImage and compares the asset version',
    () async {
      final release = jsonEncode({
        'tag_name': 'v9.0.0',
        'html_url': 'https://example.com/release',
        'assets': [
          {
            'name': 'Remote-for-ADI-2-Host-Linux-3.0.0.AppImage',
            'browser_download_url': 'https://example.com/host',
          },
          {
            'name': 'Remote-for-ADI-2-Linux-2.0.0.AppImage',
            'browser_download_url': 'https://example.com/app',
          },
        ],
      });
      final result = await UpdateCheck(
        installedVersion: '1.0.0',
        platform: UpdatePlatform.linux,
        fetcher: () async => release,
      ).check();
      expect(result.version, '2.0.0');
      expect(result.url.toString(), 'https://example.com/app');
      expect(
        (await UpdateCheck(
          installedVersion: '2.0.0',
          platform: UpdatePlatform.linux,
          fetcher: () async => release,
        ).check()).status,
        UpdateStatus.current,
      );
    },
  );
  test('missing Linux AppImage falls back to release page', () async {
    final result = await UpdateCheck(
      installedVersion: '1.0.0',
      platform: UpdatePlatform.linux,
      fetcher: () async => jsonEncode({
        'tag_name': 'v2.0.0',
        'html_url': 'https://example.com/release',
      }),
    ).check();
    expect(result.url.toString(), 'https://example.com/release');
  });
}
