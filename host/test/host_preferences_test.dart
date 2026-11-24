import 'dart:convert';

import 'package:adi2_host/host_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Linux migration copies legacy host settings, preserves app and newer values', () async {
    SharedPreferences.setMockInitialValues({
      'host_id': 'old-id',
      'paired_devices': '["phone"]',
      'host_update_check': false,
      'host_update_asset_format': 1,
      'app_language': 'de',
      'paired_hosts_v1': 'app-hosts',
      'linux_host.host_id': 'new-id',
    });
    final raw = await SharedPreferences.getInstance();
    final prefs = HostPreferences(raw, linux: true);
    await prefs.migrate();
    expect(prefs.getString('host_id'), 'new-id');
    expect(prefs.getString('paired_devices'), '["phone"]');
    expect(prefs.getBool('host_update_check'), isFalse);
    expect(prefs.getInt('host_update_asset_format'), 1);
    await prefs.setString('paired_devices', '[]');
    await prefs.migrate();
    expect(prefs.getString('paired_devices'), '[]');
    expect(raw.getString('paired_devices'), '["phone"]');
    expect(raw.getString('app_language'), 'de');
    expect(raw.getString('paired_hosts_v1'), 'app-hosts');
  });
  test('Other platforms retain the original host preference keys', () async {
    SharedPreferences.setMockInitialValues({'host_id': 'same'});
    final raw = await SharedPreferences.getInstance();
    final prefs = HostPreferences(raw, linux: false);
    await prefs.migrate();
    await prefs.setBool('host_update_check', false);
    expect(prefs.getString('host_id'), 'same');
    expect(raw.getBool('host_update_check'), isFalse);
    expect(raw.getKeys().any((k) => k.startsWith('linux_host.')), isFalse);
  });
  for (final platform in ['macos', 'windows']) {
    test(
      '$platform preserves real legacy host data across migration and restart',
      () async {
        final paired = jsonEncode([
          {
            'id': 'phone-123',
            'name': 'iPhone von Anna',
            'key': '0123456789abcdef0123456789abcdef',
          },
        ]);
        final old = <String, Object>{
          'host_id': 'persisted-host-0123456789',
          'paired_devices': paired,
          'autostart_default_applied': true,
          'host_update_check': false,
          'host_last_update_check': '2026-11-19T12:30:00.000Z',
          'host_available_update_version': '1.2.4',
          'host_available_update_url': platform == 'windows'
              ? 'https://github.com/kahuna34/remote-for-ADI-2/releases/download/v1.2.4/Remote-for-ADI-2-Host-Windows-Setup-1.2.4.exe'
              : 'https://github.com/kahuna34/remote-for-ADI-2/releases/download/v1.2.4/Remote-for-ADI-2-Host-macOS-1.2.4.zip',
          'host_update_asset_format': 1,
          'app_language': 'de',
          'update_check': true,
          'paired_hosts_v1': '[]',
        };
        SharedPreferences.setMockInitialValues(old);
        final raw = await SharedPreferences.getInstance();
        final prefs = HostPreferences(raw, platform: platform);
        await prefs.migrate();
        for (final key in HostPreferences.legacyKeys) {
          expect(raw.get('${platform}_host.$key'), old[key], reason: key);
          expect(raw.get(key), old[key]);
        }
        expect(prefs.getString('paired_devices'), paired);
        expect(prefs.getBool('host_update_check'), false);
        expect(raw.getBool('update_check'), true);
        await prefs.setString('host_id', 'updated-id');
        final restarted = HostPreferences(raw, platform: platform);
        await restarted.migrate();
        expect(restarted.getString('host_id'), 'updated-id');
        expect(raw.getString('app_language'), 'de');
        expect(raw.getString('paired_hosts_v1'), '[]');
      },
    );
  }
}
