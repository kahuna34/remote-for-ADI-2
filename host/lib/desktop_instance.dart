import 'dart:io';

import 'package:adi2_remote/desktop/desktop_windows.dart';

import 'linux_instance.dart';
import 'windows_instance.dart';

/// Linux's accepted transport and directory layout remain unchanged.
class DesktopInstance {
  DesktopInstance._(this._close);
  final Future<void> Function() _close;
  Future<void> close() => _close();

  static String runtimeDirectoryFor(
    String platform,
    Map<String, String> env,
    String temporaryDirectory,
  ) => switch (platform) {
    'windows' =>
      '${env['LOCALAPPDATA'] ?? (throw StateError('LOCALAPPDATA unavailable'))}/Remote for ADI-2 Host/instance',
    'macos' => '$temporaryDirectory/adi2-host-macos',
    _ =>
      env['XDG_RUNTIME_DIR'] ??
          '$temporaryDirectory/adi2-${env['USER'] ?? 'user'}',
  };

  static String get runtimeDirectory => runtimeDirectoryFor(
    Platform.operatingSystem,
    Platform.environment,
    Directory.systemTemp.path,
  );

  static Future<Object?> request(String directory, Map<String, dynamic> data) =>
      Platform.isWindows
      ? WindowsInstance.request(directory, {'type': 'adi2-window-v1', ...data})
      : LinuxInstance.request(directory, data);

  static Future<DesktopInstance?> acquire({
    required String runtimeDirectory,
    required bool show,
    required Future<void> Function() onShow,
    Future<Object?> Function(AuxiliaryWindow, Map<String, dynamic>)?
    onWindowRequest,
  }) async {
    if (Platform.isWindows) {
      final instance = await WindowsInstance.acquire(
        directory: runtimeDirectory,
        show: show,
        onShow: onShow,
        onWindowRequest: onWindowRequest,
      );
      return instance == null ? null : DesktopInstance._(instance.close);
    }
    final instance = await LinuxInstance.acquire(
      runtimeDirectory: runtimeDirectory,
      show: show,
      onShow: onShow,
      onWindowRequest: onWindowRequest,
    );
    return instance == null ? null : DesktopInstance._(instance.close);
  }
}
