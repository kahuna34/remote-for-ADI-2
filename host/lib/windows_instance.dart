import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:adi2_remote/desktop/desktop_windows.dart';

import 'linux_instance.dart';

/// Only a port on literal IPv4 loopback is accepted, never an address or URL
/// supplied by the rendezvous file. The token is freshly generated per owner.
class WindowsInstanceEndpoint {
  WindowsInstanceEndpoint(this.port, this.token);
  final int port;
  final String token;
  static WindowsInstanceEndpoint parse(String source) {
    if (source.length > 1024) throw const FormatException('Instance file size');
    final data = jsonDecode(source);
    if (data is! Map ||
        data.length != 3 ||
        data['version'] != 1 ||
        data['port'] is! int ||
        (data['port'] as int) < 1 ||
        (data['port'] as int) > 65535 ||
        data['token'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(data['token'] as String)) {
      throw const FormatException('Invalid instance file');
    }
    return WindowsInstanceEndpoint(
      data['port'] as int,
      data['token'] as String,
    );
  }

  String encode() => jsonEncode({'version': 1, 'port': port, 'token': token});
}

class WindowsInstance {
  WindowsInstance._(this._lock, this._server, this._endpointFile);
  final RandomAccessFile _lock;
  final ServerSocket _server;
  final File _endpointFile;
  final _clients = <Socket>{};

  /// Replace the DACL with a protected, current-user-only ACL. The path is data
  /// in an environment variable, never interpolated into PowerShell code.
  /// SetAccessControl writes only owner and DACL; Set-Acl also touched the SACL
  /// and failed without SeSecurityPrivilege once the directory was protected
  /// (every start after the first).
  static Future<void> protectDirectory(String path) async {
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'''$ErrorActionPreference = 'Stop';
$p = $env:ADI2_INSTANCE_DIRECTORY;
$i = Get-Item -LiteralPath $p -Force;
if (($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse point' };
$u = [Security.Principal.WindowsIdentity]::GetCurrent().User;
$a = New-Object Security.AccessControl.DirectorySecurity;
$a.SetOwner($u);
$a.SetAccessRuleProtection($true, $false);
$r = New-Object Security.AccessControl.FileSystemAccessRule($u, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow');
$a.AddAccessRule($r);
$i.SetAccessControl($a);''',
      ],
      environment: {'ADI2_INSTANCE_DIRECTORY': path},
    );
    if (result.exitCode != 0) throw StateError('Private instance directory');
  }

  static Future<void> _regularFile(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const FormatException('Unsafe instance file');
    }
  }

  static Future<WindowsInstanceEndpoint> readEndpoint(String directory) async {
    final file = File('$directory/instance.json');
    await _regularFile(file.path);
    if (await file.length() > 1024) {
      throw const FormatException('Instance file size');
    }
    return WindowsInstanceEndpoint.parse(await file.readAsString());
  }

  static Future<String> _line(
    Socket socket,
    int limit, {
    Duration timeout = const Duration(seconds: 2),
  }) {
    var length = 0;
    return socket
        .map((chunk) {
          length += chunk.length;
          if (length > limit) {
            throw const FormatException('Instance message size');
          }
          return chunk;
        })
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(timeout);
  }

  /// Separated from socket handling so forged tokens cannot reach either action.
  static Future<Object?> dispatch(
    String line,
    String token, {
    required Future<void> Function() onShow,
    Future<Object?> Function(AuxiliaryWindow, Map<String, dynamic>)?
    onWindowRequest,
  }) async {
    final data = jsonDecode(line);
    if (data is! Map<String, dynamic> || data['token'] != token) {
      throw const FormatException('Instance authentication');
    }
    if (data['type'] == 'adi2-instance-v1') {
      final action = parseInstanceMessage('adi2-instance-v1 ${data['action']}');
      if (action == 'show') await onShow();
      return null;
    }
    if (onWindowRequest == null) throw const FormatException('Window service');
    return LinuxInstance.dispatchWindowRequest(
      jsonEncode(data),
      onWindowRequest,
    );
  }

  static Future<Object?> request(
    String directory,
    Map<String, dynamic> data,
  ) async {
    Socket? socket;
    try {
      final endpoint = await readEndpoint(directory);
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        endpoint.port,
        timeout: const Duration(milliseconds: 400),
      );
      socket.writeln(jsonEncode({...data, 'token': endpoint.token}));
      await socket.flush();
      final response = jsonDecode(
        await _line(socket, 1048576, timeout: const Duration(seconds: 15)),
      );
      if (response is! Map ||
          response['ok'] != true ||
          response['token'] != endpoint.token) {
        throw const FormatException('Instance response');
      }
      return response['result'];
    } catch (_) {
      // Responses may contain the local pairing key. Never include their text.
      throw StateError('Local window service unavailable');
    } finally {
      socket?.destroy();
    }
  }

  static Future<WindowsInstance?> acquire({
    required String directory,
    required bool show,
    required Future<void> Function() onShow,
    Future<Object?> Function(AuxiliaryWindow, Map<String, dynamic>)?
    onWindowRequest,
    Future<void> Function(String)? protect,
  }) async {
    final dir = Directory(directory);
    if (await FileSystemEntity.type(directory, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('Unsafe instance directory');
    }
    await dir.create(recursive: true);
    await (protect ?? protectDirectory)(directory);
    final lockPath = '$directory/instance.lock';
    await _regularFile(lockPath);
    final lock = await File(lockPath).open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
    } on FileSystemException {
      await lock.close();
      for (var attempt = 0; attempt < 40; attempt++) {
        try {
          await request(directory, {
            'type': 'adi2-instance-v1',
            'action': show ? 'show' : 'ping',
          });
          return null;
        } catch (_) {
          if (attempt == 39) {
            throw StateError('Running instance did not respond');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      throw StateError('Running instance unavailable');
    }
    ServerSocket? server;
    try {
      // A stale or forged rendezvous file is replaced only by the lock owner.
      final file = File('$directory/instance.json');
      await _regularFile(file.path);
      await _regularFile('$directory/instance.tmp');
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final random = Random.secure();
      final token = List.generate(
        32,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final owner = WindowsInstance._(lock, server, file);
      server.listen((client) async {
        owner._clients.add(client);
        try {
          final result = await dispatch(
            await _line(client, 65536),
            token,
            onShow: onShow,
            onWindowRequest: onWindowRequest,
          );
          client.writeln(
            jsonEncode({'ok': true, 'token': token, 'result': result}),
          );
          await client.flush();
        } catch (_) {
          // Invalid clients receive neither the token nor credentials.
        } finally {
          owner._clients.remove(client);
          client.destroy();
        }
      });
      final temporary = File('$directory/instance.tmp');
      // Delete stale files before creating new ones so inherited ACLs are used.
      if (await temporary.exists()) await temporary.delete();
      await temporary.writeAsString(
        WindowsInstanceEndpoint(server.port, token).encode(),
        flush: true,
      );
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
      return owner;
    } catch (_) {
      await server?.close();
      await lock.close();
      rethrow;
    }
  }

  Future<void> close() async {
    await _server.close();
    for (final client in _clients.toList()) {
      client.destroy();
    }
    try {
      if (await _endpointFile.exists()) await _endpointFile.delete();
    } finally {
      await _lock.close();
    }
  }
}
