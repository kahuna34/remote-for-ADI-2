import 'dart:convert';
import 'dart:io';

import 'package:adi2_host/auxiliary_window_arguments.dart';
import 'package:adi2_host/linux_instance.dart';
import 'package:adi2_host/window_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:adi2_remote/desktop/desktop_windows.dart';
import 'package:adi2_remote/host/host_client.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final credentials = HostCredentials(
    const HostEndpoint(
      id: 'host',
      name: 'Local UI',
      address: '127.0.0.1',
      port: 47322,
    ),
    'local-ui',
    'private-key',
  );
  test(
    'Window request protocol validates type and kind before dispatch',
    () async {
      for (final kind in AuxiliaryWindow.values) {
        final result = await LinuxInstance.dispatchWindowRequest(
          jsonEncode({
            'type': 'adi2-window-v1',
            'window': kind.name,
            'method': 'credentials',
          }),
          (received, request) async {
            expect(received, kind);
            expect(request['method'], 'credentials');
            return credentials.toJson();
          },
        );
        expect(decodeWindowCredentials(result).host.port, 47322);
      }
      for (final line in [
        '',
        '[]',
        '{}',
        '{"type":"adi2-window-v2","window":"player"}',
        '{"type":"adi2-window-v1","window":"other"}',
      ]) {
        expect(
          () => LinuxInstance.dispatchWindowRequest(
            line,
            (_, _) async => fail('Unexpected dispatch'),
          ),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'Linux/macOS credentials travel over private Unix socket; ordinary activation still works',
    () async {
      final runtime = await Directory.systemTemp.createTemp('adi2-window-');
      LinuxInstance? instance;
      var shows = 0;
      final store = InMemorySharedPreferencesStore.empty();
      final preferences = WindowPreferenceService(store, platform: 'linux');
      addTearDown(() async {
        await instance?.close();
        await runtime.delete(recursive: true);
      });
      instance = await LinuxInstance.acquire(
        runtimeDirectory: runtime.path,
        show: true,
        onShow: () async {
          shows++;
        },
        onWindowRequest: (kind, request) async {
          expect(kind, AuxiliaryWindow.player);
          if (request['method'] == 'credentials') return credentials.toJson();
          return preferences.handle(kind, request);
        },
      );
      expect(instance, isNotNull);
      final result = await LinuxInstance.request(runtime.path, {
        'window': 'player',
        'method': 'credentials',
      });
      expect(decodeWindowCredentials(result).toJson(), credentials.toJson());
      final childPreferences = WindowPreferences(
        kind: AuxiliaryWindow.player,
        runtimeDirectory: runtime.path,
      );
      await childPreferences.setValue(
        'String',
        'flutter.linux_host.player_window_bounds',
        '[10,20,900,600]',
      );
      expect(
        (await childPreferences
            .getAll())['flutter.linux_host.player_window_bounds'],
        '[10,20,900,600]',
      );
      expect(
        (await store.getAll())['flutter.linux_host.player_window_bounds'],
        '[10,20,900,600]',
      );
      final socket = await Socket.connect(
        InternetAddress(
          '${runtime.path}/adi2-remote/instance.sock',
          type: InternetAddressType.unix,
        ),
        0,
      );
      socket.writeln('adi2-instance-v1 show');
      await socket.flush();
      expect(
        await socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first,
        'ok',
      );
      socket.destroy();
      expect(shows, 1);
      await expectLater(
        LinuxInstance.request(runtime.path, {
          'window': 'other',
          'method': 'credentials',
        }),
        throwsStateError,
      );
    },
    skip: Platform.isWindows
        ? 'Unix transport; Windows TCP variant has its own suite'
        : false,
  );
}
