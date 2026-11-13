import 'dart:async';
import 'dart:convert';

import 'package:adi2_remote/host/host_player_protocol.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:flutter/services.dart';

abstract class HostPlayerSource {
  Future<NowPlayingInfo> read();
  Future<void> command(String command);
}

class NativeHostPlayerSource implements HostPlayerSource {
  static const _channel = MethodChannel('adi2/host_player');
  @override
  Future<NowPlayingInfo> read() async {
    final state = await _channel.invokeMapMethod<String, dynamic>('state');
    return decodeHostPlayerState(state ?? {'playing': false}, null);
  }

  @override
  Future<void> command(String command) =>
      _channel.invokeMethod('command', command);
}

/// One bounded polling source, with a separate artwork cache for each client.
/// No poll or platform access runs without an authenticated subscriber.
class HostPlayer {
  HostPlayer({required this.source});
  final HostPlayerSource source;
  final _clients = <Object, void Function(String, Map<String, dynamic>)>{};
  final _last = <Object, String>{};
  final _artwork = <Object, String?>{};
  Timer? _timer;
  bool _reading = false, _disposed = false;
  Future<void> _commands = Future.value();

  void subscribe(
    Object peer,
    void Function(String, Map<String, dynamic>) send,
  ) {
    if (_disposed || _clients.containsKey(peer)) return;
    _clients[peer] = send;
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => refresh());
    unawaited(refresh());
  }

  void unsubscribe(Object peer) {
    _clients.remove(peer);
    _last.remove(peer);
    _artwork.remove(peer);
    if (_clients.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> refresh() async {
    if (_reading || _disposed || _clients.isEmpty) return;
    _reading = true;
    try {
      NowPlayingInfo info;
      try {
        info = await source.read().timeout(const Duration(seconds: 4));
      } catch (_) {
        info = const NowPlayingInfo();
      }
      if (_disposed) return;
      final state = encodeHostPlayerState(info);
      final signature = jsonEncode(state);
      for (final peer in _clients.keys.toList()) {
        if (_last[peer] == signature) continue;
        final payload = Map<String, dynamic>.of(state);
        if (_artwork.containsKey(peer) && _artwork[peer] == state['artwork']) {
          payload.remove('artwork');
        }
        _artwork[peer] = state['artwork'] as String?;
        _last[peer] = signature;
        _clients[peer]?.call('player_state', payload);
      }
    } finally {
      _reading = false;
    }
  }

  void command(Object peer, Object? command) {
    if (!_clients.containsKey(peer) || !hostPlayerCommands.contains(command)) {
      return;
    }
    _commands = _commands.then((_) async {
      if (_disposed || !_clients.containsKey(peer)) return;
      try {
        await source
            .command(command as String)
            .timeout(const Duration(seconds: 4));
      } catch (_) {
        // A missing player or denied automation must not terminate the session.
      }
      await refresh();
    });
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    _clients.clear();
    _artwork.clear();
    _last.clear();
  }
}
