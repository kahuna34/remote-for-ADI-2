import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adi2_remote/desktop/desktop_windows.dart';

/// A deliberately small, versioned, newline-delimited activation protocol.
String parseInstanceMessage(String line) {
  if (line == 'adi2-instance-v1 show' || line == 'adi2-instance-v1 ping') {
    return line.endsWith('show') ? 'show' : 'ping';
  }
  throw const FormatException('Unknown instance message');
}

class LinuxInstance {
  LinuxInstance._(this._lock, this._server, this._path);
  final RandomAccessFile _lock;
  final ServerSocket _server;
  final String _path;

  static String get runtimeDirectory =>
      Platform.environment['XDG_RUNTIME_DIR'] ??
      '${Directory.systemTemp.path}/adi2-${Platform.environment['USER'] ?? 'user'}';

  /// One bounded request per connection, over the existing user-private socket.
  static Future<Object?> request(
    String runtimeDirectory,
    Map<String, dynamic> request,
  ) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress(
          '$runtimeDirectory/adi2-remote/instance.sock',
          type: InternetAddressType.unix,
        ),
        0,
      ).timeout(const Duration(seconds: 2));
      socket.write('${jsonEncode({'type': 'adi2-window-v1', ...request})}\n');
      await socket.flush();
      final response = jsonDecode(await _line(socket));
      if (response is! Map || response['ok'] != true) {
        throw const FormatException();
      }
      return response['result'];
    } catch (_) {
      // Never expose a response (which can contain the local pairing key).
      throw StateError('Local window service unavailable');
    } finally {
      socket?.destroy();
    }
  }

  static Future<String> _line(Socket socket, {int limit = 1048576}) {
    var bytes = 0;
    return socket
        .map((chunk) {
          bytes += chunk.length;
          if (bytes > limit) {
            throw const FormatException('Instance message too large');
          }
          return chunk;
        })
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 15));
  }

  /// Kept separate so malformed requests can be tested without native sockets.
  static Future<Object?> dispatchWindowRequest(
    String line,
    Future<Object?> Function(AuxiliaryWindow, Map<String, dynamic>) handler,
  ) {
    try {
      final request = jsonDecode(line) as Map<String, dynamic>;
      if (request['type'] != 'adi2-window-v1') throw const FormatException();
      final kind = AuxiliaryWindow.values.byName(request['window'] as String);
      return handler(kind, request);
    } catch (_) {
      throw const FormatException('Invalid window request');
    }
  }

  /// The lock is held for the full process lifetime. Only its owner may unlink
  /// a stale socket. A second launch waits for the first launch to finish setup.
  static Future<LinuxInstance?> acquire({
    required String runtimeDirectory,
    required bool show,
    required Future<void> Function() onShow,
    Future<Object?> Function(AuxiliaryWindow, Map<String, dynamic>)?
    onWindowRequest,
  }) async {
    final directory = Directory('$runtimeDirectory/adi2-remote');
    await directory.create(recursive: true);
    // Runtime directories are user-owned; restrict the fallback directory too.
    final mode = await Process.run('chmod', ['700', directory.path]);
    if (mode.exitCode != 0) throw StateError('Private runtime directory');
    final path = '${directory.path}/instance.sock';
    final lock = await File('${directory.path}/instance.lock')
        .open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
    } on FileSystemException {
      await lock.close();
      Object? lastError;
      for (var attempt = 0; attempt < 100; attempt++) {
        Socket? socket;
        try {
          socket = await Socket.connect(
            InternetAddress(path, type: InternetAddressType.unix),
            0,
          );
          socket.write('adi2-instance-v1 ${show ? 'show' : 'ping'}\n');
          await socket.flush();
          final ack = await socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 15));
          if (ack != 'ok') {
            throw const FormatException('Instance acknowledgement');
          }
          return null;
        } catch (error) {
          lastError = error;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        } finally {
          socket?.destroy();
        }
      }
      throw StateError('Running instance did not respond: $lastError');
    }
    try {
      final socketFile = File(path);
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await socketFile.delete();
      }
      final server = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      server.listen((client) async {
        try {
          final line = await _line(
            client,
            limit: 65536,
          ).timeout(const Duration(seconds: 2));
          if (line.startsWith('{') && onWindowRequest != null) {
            final result = await dispatchWindowRequest(line, onWindowRequest);
            client.write('${jsonEncode({'ok': true, 'result': result})}\n');
          } else {
            if (parseInstanceMessage(line) == 'show') await onShow();
            client.write('ok\n');
          }
          await client.flush();
          await client.close();
        } catch (_) {
          client.destroy();
        }
      });
      return LinuxInstance._(lock, server, path);
    } catch (_) {
      await lock.close();
      rethrow;
    }
  }

  Future<void> close() async {
    await _server.close();
    final file = File(_path);
    if (await file.exists()) await file.delete();
    await _lock.close();
  }
}
