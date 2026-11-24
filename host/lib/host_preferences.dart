import 'package:adi2_remote/desktop/host_interface.dart';

import 'package:shared_preferences/shared_preferences.dart';

/// The desktop host shares one preference file with the embedded app. Keep host settings
/// separate and copy legacy values once, without deleting app/shared values.
class HostPreferences {
  HostPreferences(this.prefs, {bool linux = false, String? platform})
    : prefix = hostPreferencePrefixFor(platform ?? (linux ? 'linux' : 'other'));
  final String prefix;
  final SharedPreferences prefs;
  static const legacyKeys = [
    'host_id',
    'paired_devices',
    'autostart_default_applied',
    'host_update_check',
    'host_last_update_check',
    'host_available_update_version',
    'host_available_update_url',
    'host_update_asset_format',
  ];
  String _key(String key) => '$prefix$key';
  Future<void> migrate() async {
    if (prefix.isEmpty) return;
    for (final key in legacyKeys) {
      if (prefs.containsKey(_key(key))) continue;
      final value = prefs.get(key);
      final bool saved;
      if (value is String) {
        saved = await prefs.setString(_key(key), value);
      } else if (value is bool) {
        saved = await prefs.setBool(_key(key), value);
      } else if (value is int) {
        saved = await prefs.setInt(_key(key), value);
      } else {
        continue;
      }
      if (!saved) throw StateError('Host preference migration: $key');
    }
  }

  String? getString(String key) => prefs.getString(_key(key));
  bool? getBool(String key) => prefs.getBool(_key(key));
  int? getInt(String key) => prefs.getInt(_key(key));
  Future<bool> setString(String key, String value) =>
      prefs.setString(_key(key), value);
  Future<bool> setBool(String key, bool value) =>
      prefs.setBool(_key(key), value);
  Future<bool> setInt(String key, int value) => prefs.setInt(_key(key), value);
  Future<bool> remove(String key) => prefs.remove(_key(key));
}
