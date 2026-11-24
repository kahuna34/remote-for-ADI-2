// ignore_for_file: deprecated_member_use
import 'dart:convert';
import 'dart:io';

import 'package:adi2_host/desktop_instance.dart';
import 'package:adi2_host/host_menu.dart';
import 'package:adi2_host/host_startup.dart';
import 'package:adi2_host/window_preferences.dart';
import 'package:adi2_host/windows_instance.dart';
import 'package:adi2_remote/desktop/desktop_windows.dart';
import 'package:adi2_remote/desktop/host_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _Windows extends DesktopWindows {
  @override
  Future<void> open(AuxiliaryWindow kind) async {}
}

void main() {
  for (final platform in TargetPlatform.values) {
    final desktop = [
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ].contains(platform);
    testWidgets('Desktop scope and interface capability: $platform', (
      tester,
    ) async {
      expect(hostHasInterfaceFor(platform), desktop);
      expect(hostHasInterface, desktop);
      final windows = _Windows();
      addTearDown(windows.dispose);
      await tester.pumpWidget(
        DesktopWindowScope(
          windows: windows,
          child: Builder(
            builder: (context) {
              expect(
                DesktopWindowScope.maybeOf(context),
                desktop ? windows : null,
              );
              return const SizedBox();
            },
          ),
        ),
      );
      expect(
        trayLeftClickOpensSurface(platform),
        desktop && platform != TargetPlatform.linux,
      );
      for (final args in [
        <String>[],
        ['--autostart'],
      ]) {
        expect(opensSurfaceAtStartup(args), args.isEmpty);
      }
    }, variant: TargetPlatformVariant.only(platform));
  }

  for (final platform in ['linux', 'macos', 'windows']) {
    test('Surface toggle and isolated window preferences: $platform', () async {
      final menu = buildHostMenu(
        hasInterface: true,
        version: '1.2.3',
        windows: platform == 'windows',
        autostart: false,
        updatesEnabled: true,
      );
      expect(menu.first.key, 'surface');
      final prefix = hostPreferencePrefixFor(platform);
      final store = InMemorySharedPreferencesStore.withData({
        'flutter.${prefix}host_id': 'private',
        'flutter.${prefix}paired_devices': 'private keys',
        'flutter.${prefix}player_window_bounds': '[1,2,3,4]',
        'flutter.app_language': 'de',
      });
      final service = WindowPreferenceService(store, platform: platform);
      final all = await service.handle(AuxiliaryWindow.analyzer, {
        'method': 'getAll',
      }) as Map;
      expect(all['flutter.app_language'], 'de');
      expect(
        all.keys.any((k) => (k as String).startsWith('flutter.$prefix')),
        false,
      );
      await expectLater(
        service.handle(AuxiliaryWindow.analyzer, {
          'method': 'remove',
          'key': 'flutter.${prefix}paired_devices',
        }),
        throwsFormatException,
      );
      await service.handle(AuxiliaryWindow.analyzer, {
        'method': 'setValue',
        'valueType': 'Int',
        'key': 'flutter.linux_analyzer_fps',
        'value': 60,
      });
      expect((await store.getAll())['flutter.linux_analyzer_fps'], 60);
    });
  }

  test('Instance paths use user locations and preserve Linux layout', () {
    const env = {
      'LOCALAPPDATA': r'C:\Users\A\AppData\Local',
      'XDG_RUNTIME_DIR': '/run/user/1000',
      'USER': 'a',
    };
    expect(
      DesktopInstance.runtimeDirectoryFor('windows', env, '/tmp'),
      startsWith(env['LOCALAPPDATA']!),
    );
    expect(
      () => DesktopInstance.runtimeDirectoryFor('windows', {}, '/tmp'),
      throwsStateError,
    );
    expect(
      DesktopInstance.runtimeDirectoryFor('macos', env, '/user/private/tmp'),
      '/user/private/tmp/adi2-host-macos',
    );
    expect(
      DesktopInstance.runtimeDirectoryFor('linux', env, '/tmp'),
      '/run/user/1000',
    );
    expect(
      DesktopInstance.runtimeDirectoryFor('linux', {'USER': 'a'}, '/tmp'),
      '/tmp/adi2-a',
    );
  });

  final token = 'a' * 64;
  test('Windows rejects forged rendezvous files', () {
    expect(
      WindowsInstanceEndpoint.parse(
        WindowsInstanceEndpoint(12345, token).encode(),
      ).port,
      12345,
    );
    for (final source in [
      '',
      '[]',
      '{}',
      'x' * 1025,
      for (final port in [-1, 0, 65536, '1234', 12.5])
        jsonEncode({'version': 1, 'port': port, 'token': token}),
      jsonEncode({'version': 2, 'port': 1234, 'token': token}),
      jsonEncode({'version': 1, 'port': 1234, 'token': 'short'}),
      jsonEncode({
        'version': 1,
        'port': 1234,
        'token': token,
        'address': 'evil.example',
      }),
    ]) {
      expect(
        () => WindowsInstanceEndpoint.parse(source),
        throwsFormatException,
      );
    }
  });

  test(
    'Windows authenticates activation and credential requests before dispatch',
    () async {
      var shows = 0, windows = 0;
      Future<Object?> dispatch(Map<String, Object> data) =>
          WindowsInstance.dispatch(
            jsonEncode(data),
            token,
            onShow: () async {
              shows++;
            },
            onWindowRequest: (kind, data) async {
              windows++;
              return {'local-key': 'secret'};
            },
          );
      for (final action in ['show', 'ping']) {
        await dispatch({
          'type': 'adi2-instance-v1',
          'action': action,
          'token': token,
        });
      }
      expect(shows, 1);
      expect(
        await dispatch({
          'type': 'adi2-window-v1',
          'window': 'player',
          'method': 'credentials',
          'token': token,
        }),
        {'local-key': 'secret'},
      );
      for (final data in [
        {'type': 'adi2-instance-v1', 'action': 'show', 'token': 'b' * 64},
        {'type': 'adi2-window-v1', 'window': 'player', 'token': 'b' * 64},
        {'type': 'adi2-instance-v1', 'action': 'quit', 'token': token},
        {'type': 'adi2-window-v1', 'window': 'other', 'token': token},
      ]) {
        await expectLater(dispatch(data), throwsFormatException);
      }
      expect(shows, 1);
      expect(windows, 1);
    },
  );

  test('Windows rejects unsafe endpoint files before connecting', () async {
    final dir = await Directory.systemTemp.createTemp('adi2-forged-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/instance.json');
    await file.writeAsString('x' * 1025);
    await expectLater(
      WindowsInstance.readEndpoint(dir.path),
      throwsFormatException,
    );
    await file.delete();
    final directoryAtFilePath = Directory(file.path);
    await directoryAtFilePath.create();
    await expectLater(
      WindowsInstance.readEndpoint(dir.path),
      throwsFormatException,
    );
    await directoryAtFilePath.delete();
    // A Windows symlink requires developer mode or elevated privileges. Its
    // directory/reparse protections are exercised by the native ACL integration.
    if (!Platform.isWindows) {
      final target = File('${dir.path}/target');
      await target.writeAsString(
        WindowsInstanceEndpoint(12345, token).encode(),
      );
      await Link(file.path).create(target.path);
      await expectLater(
        WindowsInstance.readEndpoint(dir.path),
        throwsFormatException,
      );
    }
  });
}
