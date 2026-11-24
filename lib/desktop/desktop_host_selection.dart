import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../host/host_client.dart';
import '../l10n/l10n.dart';

/// The main process owns the desktop route, including while its UI is hidden.
/// Only paired credentials or the host's private loopback credential are used.
class DesktopHostSelection extends ChangeNotifier {
  DesktopHostSelection(this.local) : _current = local;
  static const preferenceKey = 'desktop_host_selection_v1';
  final HostCredentials local;
  HostCredentials? _current;
  HostCredentials? get current => _current;
  bool get isLocal => _current?.host.id == local.host.id;
  bool loaded = false;

  Future<void> load() async {
    if (loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(preferenceKey);
    if (id != null && id != local.host.id) {
      // A missing/corrupt pairing must never silently select another computer.
      _current = null;
      try {
        final saved =
            jsonDecode(prefs.getString('paired_hosts_v1') ?? '[]') as List;
        _current = saved
            .map((j) => HostCredentials.fromJson(j as Map<String, dynamic>))
            .where((c) => c.host.id == id)
            .firstOrNull;
      } catch (_) {}
    }
    loaded = true;
  }

  Future<void> _pending = Future.value();
  Future<void> select(HostCredentials credentials) {
    final result = _pending.then((_) async {
      if (jsonEncode(_current?.toJson()) == jsonEncode(credentials.toJson())) {
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(preferenceKey, credentials.host.id)) {
        throw StateError(tr('Verbindungswahl konnte nicht gespeichert werden'));
      }
      updateEndpoint(credentials);
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Discovery may update the address without changing the persisted host ID.
  void updateEndpoint(HostCredentials credentials) {
    if (jsonEncode(_current?.toJson()) == jsonEncode(credentials.toJson())) {
      return;
    }
    _current = credentials;
    notifyListeners();
  }

  void forget(String id) {
    if (_current?.host.id != id || isLocal) return;
    _current = null;
    notifyListeners();
  }

  Map<String, dynamic> windowCredentials() {
    final credentials = _current;
    if (credentials == null) throw StateError('Selected host pairing missing');
    return {...credentials.toJson(), 'local': isLocal};
  }
}
