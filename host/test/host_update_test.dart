import 'dart:convert';

import 'package:adi2_host/host_update.dart';
import 'package:adi2_remote/update/update_check.dart';
import 'package:flutter_test/flutter_test.dart';

const setup = 'Remote-for-ADI-2-Host-Windows-Setup.exe';
const zip = 'Remote-for-ADI-2-Host-Windows-x64.zip';
const releasePage = 'https://example.com/releases/v2.0.0';

Map<String, String> asset(String name, {String? url}) => {
  'name': name,
  'browser_download_url': url ?? 'https://example.com/download/$name',
};

Future<UpdateResult> check(List<Object> assets, {String page = releasePage}) {
  return UpdateCheck(
    installedVersion: '1.1.1 (3)',
    platform: UpdatePlatform.other,
    fetcher: () => fetchWindowsHostRelease(
      fetcher: () async => jsonEncode({
        'tag_name': 'v2.0.0',
        'html_url': page,
        'assets': assets,
      }),
    ),
  ).check(manual: true);
}

void main() {
  test('Setup wird unabhängig von der Asset-Reihenfolge bevorzugt', () async {
    for (final assets in [
      [asset(zip), asset(setup)],
      [asset(setup), asset(zip)],
    ]) {
      final result = await check(assets);
      expect(result.status, UpdateStatus.available);
      expect(result.version, '2.0.0');
      expect(result.url.toString(), 'https://example.com/download/$setup');
    }
  });

  test('Fehlendes Setup fällt auf ZIP zurück', () async {
    expect(
      (await check([asset(zip)])).url.toString(),
      'https://example.com/download/$zip',
    );
  });

  test('Fehlende Windows-Assets fallen auf Release-Seite zurück', () async {
    expect((await check([asset('unrelated.zip')])).url.toString(), releasePage);
  });

  test(
    'Ungültige Download-URLs fallen auf sichere Alternative zurück',
    () async {
      expect(
        (await check([
          asset(setup, url: 'http://example.com/setup'),
          asset(zip),
        ])).url.toString(),
        'https://example.com/download/$zip',
      );
      expect(
        (await check([asset(setup, url: 'file:///setup.exe')])).url.toString(),
        releasePage,
      );
      expect(
        (await check([], page: 'http://example.com')).status,
        UpdateStatus.error,
      );
    },
  );

  test('Unvollständige Assets werden übersprungen', () async {
    expect(
      (await check([
        {'name': setup},
        'bad asset',
        asset(zip),
      ])).url.toString(),
      'https://example.com/download/$zip',
    );
  });
}
