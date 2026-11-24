// Each process has one window, so the legacy window API is safe here.
// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/desktop/desktop_windows.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/host/host_client.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:adi2_remote/ui/player_window_view.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:window_manager/legacy.dart';
import 'package:nativeapi/nativeapi.dart' as native;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'auxiliary_window_arguments.dart';
import 'window_preferences.dart';
import 'desktop_instance.dart';
import 'desktop_activation.dart';

import 'package:adi2_remote/desktop/host_interface.dart';

import 'auxiliary_processes.dart';

export 'auxiliary_processes.dart' show DesktopAuxiliaryWindows;

/// Returns before the instance lock, MIDI, host server, tray and update services.
Future<void> runAuxiliaryWindow(AuxiliaryWindowArguments args) async {
  final runtime = DesktopInstance.runtimeDirectory;
  final response = await DesktopInstance.request(runtime, {
    'window': args.kind.name,
    'method': 'credentials',
  });
  final credentials = decodeWindowCredentials(response);
  final local = (response as Map)['local'] == true;
  SharedPreferencesStorePlatform.instance = WindowPreferences(
    kind: args.kind,
    runtimeDirectory: runtime,
  );
  await AppSettings.instance.load(reload: true);
  await AppLang.instance.load();
  runApp(
    _AuxiliaryApp(kind: args.kind, credentials: credentials, local: local),
  );
}

class _AuxiliaryApp extends StatefulWidget {
  const _AuxiliaryApp({
    required this.kind,
    required this.credentials,
    required this.local,
  });
  final AuxiliaryWindow kind;
  final HostCredentials credentials;
  final bool local;
  @override
  State<_AuxiliaryApp> createState() => _AuxiliaryAppState();
}

class _AuxiliaryAppState extends State<_AuxiliaryApp> with WindowListener {
  late final _ctrl = Adi2Controller(
    windowHost: widget.credentials,
    windowHostLocal: widget.local,
  );
  Timer? _save;
  HostConnectionWatchdog? _watchdog;
  StreamSubscription<String>? _commands;
  Future<void> _controlWork = Future.value();
  bool _closing = false;
  String get _boundsKey =>
      '${hostPreferencePrefixFor(Platform.operatingSystem)}${widget.kind.name}_window_bounds';

  @override
  void initState() {
    super.initState();
    unawaited(
      _initialize().catchError((Object _) {
        // Startup errors must not leave an invisible, untracked process behind.
        exit(1);
      }),
    );
  }

  Future<void> _initialize() async {
    final prefs = await SharedPreferences.getInstance();
    List<double>? bounds;
    try {
      final data = jsonDecode(prefs.getString(_boundsKey) ?? 'null');
      if (data is List &&
          data.length == 4 &&
          data.every((v) => v is num && v.isFinite) &&
          data[2] >= 360 &&
          data[3] >= 300) {
        bounds = data.cast<num>().map((v) => v.toDouble()).toList();
      }
    } on FormatException {
      // Corrupt or interrupted geometry writes fall back to the default size.
    }
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    await windowManager.setTitle(
      widget.kind == AuxiliaryWindow.analyzer
          ? 'Remote for ADI-2 – Analyzer'
          : 'Remote for ADI-2 – Player',
    );
    await windowManager.setMinimumSize(const Size(360, 300));
    final displays = native.DisplayManager.instance.getAll();
    final areas = displays.map((display) {
      final area = display.workArea;
      return Rect.fromLTWH(area.x, area.y, area.width, area.height);
    }).toList();
    final restored = restoreAuxiliaryBounds(bounds, areas);
    if (restored != null) {
      await windowManager.setBounds(restored);
    } else {
      await windowManager.setSize(const Size(900, 600));
      await windowManager.center();
    }
    _watchdog = HostConnectionWatchdog(
      connected: () => _ctrl.host.connected,
      onLost: () => unawaited(_close()),
    );
    unawaited(_ctrl.start());
    _commands = stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            _controlWork = _controlWork
                .then((_) async {
                  if (line == 'adi2-window-v1 present' && !_closing) {
                    if (await windowManager.isMinimized()) {
                      await windowManager.restore();
                    }
                    await windowManager.setSkipTaskbar(false);
                    await windowManager.show();
                    await windowManager.focus();
                    await DesktopActivation.present(auxiliary: true);
                  } else if (line == 'adi2-window-v1 connection' && !_closing) {
                    // Drop the old route before requesting the new one. In
                    // particular a forgotten pairing cannot keep controlling A.
                    _ctrl.disconnect();
                    final response = await DesktopInstance.request(
                      DesktopInstance.runtimeDirectory,
                      {'window': widget.kind.name, 'method': 'credentials'},
                    );
                    await _ctrl.followWindowHost(
                      decodeWindowCredentials(response),
                      local: (response as Map)['local'] == true,
                    );
                  } else if (line == 'adi2-window-v1 preferences' &&
                      !_closing) {
                    await AppSettings.instance.load(reload: true);
                  } else if (line == 'adi2-window-v1 close') {
                    await _close();
                  }
                })
                .catchError((Object _) => exit(1));
          },
          onDone: () => unawaited(_close()),
          onError: (Object _) => unawaited(_close()),
        );
    stdout.writeln('adi2-window-v1 ready');
    await stdout.flush();
  }

  @override
  void onWindowClose() => unawaited(_close());
  @override
  void onWindowMove() => _geometryChanged();
  @override
  void onWindowResize() => _geometryChanged();
  void _geometryChanged() {
    if (_closing) return;
    _save?.cancel();
    _save = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_storeGeometry().catchError((Object _) {})),
    );
  }

  Future<void> _storeGeometry() async {
    final rect = await windowManager.getBounds();
    final bounds = [rect.left, rect.top, rect.width, rect.height];
    if (bounds.any((v) => !v.isFinite) || bounds[2] < 360 || bounds[3] < 300) {
      return;
    }
    await (await SharedPreferences.getInstance()).setString(
      _boundsKey,
      jsonEncode(bounds),
    );
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _save?.cancel();
    try {
      await _storeGeometry().timeout(const Duration(milliseconds: 400));
    } finally {
      exit(0);
    }
  }

  @override
  void dispose() {
    _save?.cancel();
    _watchdog?.dispose();
    unawaited(_commands?.cancel());
    windowManager.removeListener(this);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppLang.instance,
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: Scaffold(
        body: SafeArea(
          child: widget.kind == AuxiliaryWindow.analyzer
              ? AnalyzerPanel(
                  deviceController: _ctrl,
                  expanded: true,
                  allowFullscreen: false,
                )
              : PlayerWindowView(controller: _ctrl),
        ),
      ),
    ),
  );
}

/// Prefer the saved monitor; clamp geometry after a monitor is unplugged.
Rect? restoreAuxiliaryBounds(List<double>? bounds, List<Rect> areas) {
  if (bounds == null || areas.isEmpty) return null;
  final saved = Rect.fromLTWH(bounds[0], bounds[1], bounds[2], bounds[3]);
  final area = areas.where((a) => a.overlaps(saved)).firstOrNull ?? areas.first;
  final width = saved.width.clamp(360.0, area.width < 360 ? 360.0 : area.width);
  final height = saved.height.clamp(
    300.0,
    area.height < 300 ? 300.0 : area.height,
  );
  return Rect.fromLTWH(
    saved.left.clamp(
      area.left,
      area.right - width < area.left ? area.left : area.right - width,
    ),
    saved.top.clamp(
      area.top,
      area.bottom - height < area.top ? area.top : area.bottom - height,
    ),
    width,
    height,
  );
}
