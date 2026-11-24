import 'dart:io';

import 'package:adi2_remote/desktop/host_interface.dart';
import 'package:adi2_remote/desktop/desktop_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'desktop_instance.dart';

typedef WindowRequest = Future<Object?> Function(Map<String, dynamic> request);

/// The main process owns the only disk store. Each child writes a separate
/// namespace for geometry and private settings. The main store also serializes
/// the existing shared analyzer settings; children never open the disk backend.
class WindowPreferenceService {
  WindowPreferenceService(this.store, {String? platform})
    : prefix = hostPreferencePrefixFor(platform ?? Platform.operatingSystem);
  final String prefix;
  final SharedPreferencesStorePlatform store;
  static const _sharedAnalyzerKeys = {
    'flutter.linux_analyzer_fps',
    'flutter.analyzer_bands_per_octave',
    'flutter.analyzer_main_view',
    'flutter.analyzer_player_on_tap',
    'flutter.analyzer_peak_hold_seconds',
    'flutter.analyzer_bars',
    'flutter.analyzer_peak_hold',
    'flutter.analyzer_ballistics',
    'flutter.analyzer_loopback_output',
    'flutter.analyzer_loopback_tap',
    'flutter.analyzer_color',
    'flutter.analyzer_range',
    'flutter.analyzer_loopback_confirmed',
  };
  Future<void> _pending = Future.value();

  Future<Object?> handle(AuxiliaryWindow kind, Map<String, dynamic> request) {
    final result = _pending.then((_) async {
      final windowPrefix = 'flutter.$prefix${kind.name}_preferences.';
      final bounds = 'flutter.$prefix${kind.name}_window_bounds';
      String ownedKey(String key) =>
          key == bounds ||
              (kind == AuxiliaryWindow.analyzer &&
                  _sharedAnalyzerKeys.contains(key))
          ? key
          : '$windowPrefix${key.substring('flutter.'.length)}';
      switch (request['method']) {
        case 'getAll':
          final all = await store.getAll();
          final visible = <String, Object>{
            for (final entry in all.entries)
              if (!entry.key.startsWith('flutter.$prefix') ||
                  entry.key == bounds)
                entry.key: entry.value,
          };
          for (final entry in all.entries) {
            if (entry.key.startsWith(windowPrefix)) {
              visible['flutter.${entry.key.substring(windowPrefix.length)}'] =
                  entry.value;
            }
          }
          return visible;
        case 'setValue':
        case 'remove':
          final key = request['key'] as String;
          if (!key.startsWith('flutter.') ||
              key.length > 256 ||
              (key.startsWith('flutter.$prefix') && key != bounds)) {
            throw const FormatException('Invalid window preference key');
          }
          if (request['method'] == 'remove') return store.remove(ownedKey(key));
          final type = request['valueType'] as String;
          final value = request['value'];
          if (![
            'String',
            'StringList',
            'Bool',
            'Int',
            'Double',
          ].contains(type)) {
            throw const FormatException('Invalid preference type');
          }
          return store.setValue(
            type,
            ownedKey(key),
            type == 'StringList'
                ? (value as List).cast<String>()
                : value as Object,
          );
        default:
          throw const FormatException('Unknown preference request');
      }
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

class WindowPreferences extends SharedPreferencesStorePlatform {
  WindowPreferences({
    required this.kind,
    required String runtimeDirectory,
    WindowRequest? request,
  }) : _request =
           request ??
           ((data) => DesktopInstance.request(runtimeDirectory, {
             'window': kind.name,
             ...data,
           }));
  final AuxiliaryWindow kind;
  final WindowRequest _request;

  @override
  Future<Map<String, Object>> getAll() async =>
      Map<String, Object>.from((await _request({'method': 'getAll'})) as Map);
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      await _request({
        'method': 'setValue',
        'valueType': valueType,
        'key': key,
        'value': value,
      }) as bool;
  @override
  Future<bool> remove(String key) async =>
      await _request({'method': 'remove', 'key': key}) as bool;
  @override
  Future<bool> clear() async => false;
}
