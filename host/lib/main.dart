// Die kompatible API der bereits eingetragenen Desktop-Pakete hält alle
// Fenster- und Tray-Aufrufe an einer Stelle.
// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bonsoir/bonsoir.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tray_manager/legacy.dart';
import 'package:window_manager/legacy.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:adi2_remote/host/host_pairing.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/ui/theme.dart' show buildTheme;

import 'package:adi2_remote/update/update_check.dart';
import 'package:adi2_remote/update/open_update.dart';

import 'package:adi2_remote/analyzer/linux_test_signal.dart';
import 'package:adi2_remote/main.dart' show Adi2RemoteApp;
import 'package:adi2_remote/host/host_client.dart';
import 'package:adi2_remote/app_info.dart';
import 'package:adi2_remote/ui/eq_display_mode.dart';
import 'package:adi2_remote/ui/responsive_layout.dart';

import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:adi2_remote/app_settings.dart';

import 'auxiliary_window_arguments.dart';

import 'auxiliary_windows.dart';
import 'window_preferences.dart';

import 'host_preferences.dart';

import 'package:adi2_remote/desktop/host_interface.dart';
import 'package:adi2_remote/desktop/desktop_host_selection.dart';

import 'desktop_activation.dart';
import 'desktop_instance.dart';
import 'host_startup.dart';
import 'host_info.dart';

import 'host_menu.dart';
import 'host_update.dart';

import 'package:adi2_remote/update/app_updates.dart';

import 'autostart.dart';
import 'desktop_midi.dart';
import 'host_log.dart';
import 'host_server.dart';

final _hostAppKey = GlobalKey<_HostAppState>();
final _windowReady = Completer<void>();
final _appMounted = Completer<void>();
DesktopInstance? _instance;
final _surfaceUpdates = Completer<UpdateCheck>();
bool get _usesHostUpdates => Platform.isMacOS || Platform.isWindows;
final _hostSelection = Completer<DesktopHostSelection>();
String get _releaseVersion => Platform.isLinux ? appVersion : hostVersion;
Future<HostPreferences> _preferences() async => HostPreferences(
  await SharedPreferences.getInstance(),
  platform: Platform.operatingSystem,
);

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (hostHasInterface) {
    AuxiliaryWindowArguments? window;
    try {
      window = AuxiliaryWindowArguments.parse(arguments);
    } on FormatException {
      stderr.writeln('Invalid auxiliary window arguments');
      exit(64);
    }
    if (window != null) {
      try {
        await runAuxiliaryWindow(window);
      } catch (_) {
        // Do not leave an invisible Flutter process after a failed handshake,
        // and never print socket responses or local credentials.
        stderr.writeln('Local auxiliary window startup failed');
        exit(1);
      }
      return;
    }
    final windowPreferences = WindowPreferenceService(
      SharedPreferencesStorePlatform.instance,
    );
    _instance = await DesktopInstance.acquire(
      runtimeDirectory: DesktopInstance.runtimeDirectory,
      onWindowRequest: (kind, request) async {
        if (request['method'] == 'credentials') {
          final selection = await _hostSelection.future.timeout(
            const Duration(seconds: 15),
          );
          return selection.windowCredentials();
        }
        return windowPreferences.handle(kind, request);
      },
      show: opensSurfaceAtStartup(arguments),
      onShow: () async {
        await _windowReady.future;
        await _hostAppKey.currentState?._openSurface();
      },
    );
    if (_instance == null) exit(0);
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    EqDisplayMode.setTablet(
      view.physicalSize.shortestSide / view.devicePixelRatio >=
          tabletBreakpoint,
    );
    EqDisplayMode.initialize();
  }
  HostLog.write(
    'Start $_releaseVersion ${Platform.operatingSystem} args=$arguments',
  );
  FlutterError.onError = (details) {
    HostLog.write('Flutter-Fehler: ${details.exceptionAsString()}');
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    HostLog.write('Fehler: $error');
    return false;
  };
  await AppLang.instance.load();
  final prefs = await _preferences();
  await prefs.migrate();
  var id = prefs.getString('host_id');
  if (id == null) {
    id = randomToken(16);
    if (!await prefs.setString('host_id', id)) throw StateError('Host-ID');
  }
  final pairing = HostPairing();
  final saved = jsonDecode(prefs.getString('paired_devices') ?? '[]') as List;
  for (final data in saved) {
    final device = PairedDevice.fromJson(data as Map<String, dynamic>);
    pairing.devices[device.id] = device;
  }
  final midi = DesktopMidi();
  final server = HostServer(
    id: id,
    name: Platform.localHostname,
    pairing: pairing,
    midi: midi,
    persist: () async {
      if (!await prefs.setString(
        'paired_devices',
        jsonEncode(pairing.devices.values.map((d) => d.toJson()).toList()),
      )) {
        throw StateError('Persistenz');
      }
    },
  );
  HostCredentials? localHost;
  if (hostHasInterface) {
    final local = pairing.ensureLocal();
    await server.persist();
    // The actual (possibly fallback) TCP port is filled after server.start().
    localHost = HostCredentials(
      HostEndpoint(id: id, name: server.name, address: '127.0.0.1', port: 0),
      local.id,
      local.key,
    );
  }
  midi.onLost = server.usbLost;
  String? discoveryError;
  try {
    await server.start();
  } on SocketException catch (error) {
    // Auch wenn der Ausweichport nicht gebunden werden kann, bleibt das
    // Tray-Menü zum Anzeigen des Fehlers und zum Beenden verfügbar.
    discoveryError = trf('Host-Fehler {fehler}', {'fehler': error});
    server.status = discoveryError;
  }
  final broadcast = BonsoirBroadcast(
    printLogs: false,
    service: BonsoirService(
      name: server.name,
      type: hostServiceType,
      port: server.port,
      attributes: {'id': id, 'version': '1'},
    ),
  );
  if (server.port != 0) {
    try {
      await broadcast.initialize().timeout(const Duration(seconds: 5));
      await broadcast.start().timeout(const Duration(seconds: 5));
    } catch (_) {
      discoveryError = Platform.isLinux
          ? tr(
              'Netzwerksuche fehlgeschlagen. avahi-daemon installieren und starten; manuelle Adresse verwenden.',
            )
          : tr('Netzwerksuche fehlgeschlagen. Manuelle Adresse verwenden.');
    }
  }
  if (localHost != null) {
    localHost = HostCredentials(
      HostEndpoint(
        id: id,
        name: server.name,
        address: '127.0.0.1',
        port: server.port,
      ),
      localHost.deviceId,
      localHost.key,
    );
    final selection = DesktopHostSelection(localHost);
    await selection.load();
    _hostSelection.complete(selection);
  }
  if (_usesHostUpdates) {
    AppUpdates.instance.useHostChecker(
      _surfaceUpdates.future,
      onEnabledChanged: (value) async {
        await (await _preferences()).setBool('host_update_check', value);
        await _hostAppKey.currentState?._menu();
      },
    );
  }
  runApp(
    HostApp(
      key: _hostAppKey,
      localHost: localHost,
      desktopSelection: hostHasInterface ? await _hostSelection.future : null,
      server: server,
      midi: midi,
      broadcast: broadcast,
      discoveryError: discoveryError,
    ),
  );
  // Das Fenster erst nach dem Start des Servers einrichten: Auf macOS kann das
  // Fenster-Plugin vor dem ersten Frame warten.
  unawaited(() async {
    await _setupWindow();
    await _appMounted.future;
    _windowReady.complete();
    if (hostHasInterface && opensSurfaceAtStartup(arguments)) {
      await _hostAppKey.currentState?._openSurface();
    }
  }());
}

Future<void> _setupWindow() async {
  try {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setTitle('Remote for ADI-2');
    if (hostHasInterface) {
      // Mindesthöhe 560: Am Desktop gilt ab 600 px Breite immer die
      // Tablet-Geometrie (kein Umschalten nach der Höhe); sie braucht in
      // „Nur Gerät“ etwa 510 px Innenhöhe.
      await windowManager.setMinimumSize(const Size(640, 560));
      final prefs = await _preferences();
      dynamic bounds;
      try {
        bounds = jsonDecode(prefs.getString('window_bounds') ?? 'null');
      } on FormatException {
        // Fall back to the default geometry after an interrupted preferences write.
      }
      if (bounds is List &&
          bounds.length == 4 &&
          bounds.every((v) => v is num && v.isFinite) &&
          bounds[2] >= 640 &&
          bounds[3] >= 560) {
        await windowManager.setBounds(
          Rect.fromLTWH(
            (bounds[0] as num).toDouble(),
            (bounds[1] as num).toDouble(),
            (bounds[2] as num).toDouble(),
            (bounds[3] as num).toDouble(),
          ),
        );
      } else {
        await windowManager.setSize(const Size(1200, 800));
        await windowManager.center();
      }
    } else {
      await windowManager.setSize(const Size(440, 600));
    }
    await windowManager.hide();
  } catch (_) {
    // Ohne Fensterfunktionen bleibt der Host über das Menü erreichbar.
  }
}

class HostApp extends StatefulWidget {
  const HostApp({
    super.key,
    required this.server,
    required this.midi,
    required this.broadcast,
    this.discoveryError,
    this.localHost,
    this.desktopSelection,
  });
  final HostCredentials? localHost;
  final DesktopHostSelection? desktopSelection;
  final HostServer server;
  final DesktopMidi midi;
  final BonsoirBroadcast broadcast;
  final String? discoveryError;
  @override
  State<HostApp> createState() => _HostAppState();
}

class _HostAppState extends State<HostApp> with TrayListener, WindowListener {
  late final DesktopAuxiliaryWindows? _desktopWindows =
      hostHasInterface && widget.localHost != null
      ? DesktopAuxiliaryWindows()
      : null;
  late final HostAutostart _autostart;
  bool _automatic = false;
  bool _surfaceCreated = false, _management = true, _windowVisible = false;
  Timer? _geometrySave;

  int _analyzerFps = AppSettings.instance.linuxAnalyzerFps;
  void _analyzerSettingsChanged() {
    final fps = AppSettings.instance.linuxAnalyzerFps;
    if (_analyzerFps == fps) return;
    _analyzerFps = fps;
    unawaited(_desktopWindows?.refreshPreferences());
  }

  void _hostSelectionChanged() {
    if (Platform.isLinux) unawaited(LinuxTestSignalPlayer.instance.stop());
    unawaited(_desktopWindows?.refreshConnection());
  }

  Future<void> _openSurface() async {
    if (!hostHasInterface || !mounted) return;
    if (_surfaceCreated) await AppSettings.instance.load(reload: true);
    if (!mounted) return;
    setState(() {
      _surfaceCreated = true;
      _management = false;
      _windowVisible = true;
    });
    _countdown?.cancel();
    await windowManager.setSkipTaskbar(false);
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
    await DesktopActivation.present();
    await _menu();
  }

  Future<void> _hideWindow() async {
    if (Platform.isLinux) await LinuxTestSignalPlayer.instance.stop();
    if (hostHasInterface && mounted) setState(() => _windowVisible = false);
    _countdown?.cancel();
    await windowManager.hide();
    await DesktopActivation.hide();
    if (hostHasInterface) {
      await windowManager.setSkipTaskbar(true);
      await _menu();
    }
  }

  void _rememberGeometry() {
    if (!hostHasInterface) return;
    _geometrySave?.cancel();
    _geometrySave = Timer(const Duration(milliseconds: 300), () async {
      try {
        await _storeGeometry();
      } catch (error) {
        HostLog.write(
          'Fensterposition konnte nicht gespeichert werden: $error',
        );
      }
    });
  }

  Future<void> _storeGeometry() async {
    if (!hostHasInterface ||
        await windowManager.isMaximized() ||
        await windowManager.isMinimized()) {
      return;
    }
    final bounds = await windowManager.getBounds();
    final prefs = await _preferences();
    await prefs.setString(
      'window_bounds',
      jsonEncode([bounds.left, bounds.top, bounds.width, bounds.height]),
    );
  }

  @override
  void onWindowMoved() => _rememberGeometry();
  @override
  void onWindowResized() => _rememberGeometry();

  UpdateCheck? _updates;
  UpdateResult? _availableUpdate;
  String? _updateNotice;
  bool _pairing = true;
  String? _error;
  List<String> _addresses = [];
  String? _address;
  Timer? _countdown;
  Timer? _detectTimer, _stallTimer;
  String? _adi2;
  bool _detected = false;
  bool _detecting = false, _exiting = false;
  Future<void> _menuWork = Future.value();
  HostServer get server => widget.server;

  @override
  void initState() {
    super.initState();
    DesktopActivation.onReopen(() async {
      await _windowReady.future;
      await _openSurface();
    });
    AppSettings.instance.addListener(_analyzerSettingsChanged);
    widget.desktopSelection?.addListener(_hostSelectionChanged);
    if (!_appMounted.isCompleted) _appMounted.complete();
    _error = widget.discoveryError;
    _autostart = HostAutostart(
      platform: Platform.operatingSystem,
      executable: Platform.resolvedExecutable,
      appImage: Platform.isLinux ? Platform.environment['APPIMAGE'] : null,
      configHome: Platform.isLinux
          ? Platform.environment['XDG_CONFIG_HOME']
          : null,
      home: Platform.environment['HOME'] ?? '',
    );
    trayManager.addListener(this);
    windowManager.addListener(this);
    server.addListener(_changed);
    unawaited(_detect());
    _detectTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_detect()),
    );
    unawaited(_initialize());
    // Überwachung: Kommt die Ereignisschleife mehr als 3 s zu spät dran
    // (Menüklicks und Exit würden dann nicht reagieren), ins Log schreiben.
    var lastTick = DateTime.now();
    var stalled = false;
    _stallTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      final late = now.difference(lastTick) - const Duration(seconds: 1);
      lastTick = now;
      if (late > const Duration(seconds: 3)) {
        stalled = true;
        HostLog.write(
          'Ereignisschleife blockiert: ${late.inMilliseconds} ms '
          '(Clients ${server.connectedNames.length})',
        );
      } else if (stalled) {
        stalled = false;
        HostLog.write('Ereignisschleife wieder normal');
      }
    });
  }

  Future<void> _initialize() async {
    try {
      // Mac: einfarbiges Vorlagenbild, macOS färbt es wie die anderen
      // Menüleisten-Symbole (weiß bei dunkler, schwarz bei heller Leiste).
      await trayManager.setIcon(
        Platform.isWindows
            ? 'assets/host.ico'
            : Platform.isMacOS
            ? 'assets/host_tray.png'
            : 'assets/images/app_icon.png',
        isTemplate: Platform.isMacOS,
      );
      await trayManager.setToolTip(
        Platform.isLinux ? 'Remote for ADI-2' : 'Remote for ADI-2 Host',
      );
      _automatic = await _autostart.refreshEnabledPath();
      // Windows: Autostart beim ersten Start einschalten (abschaltbar im Menü).
      if (Platform.isWindows && !_automatic) {
        final prefs = await _preferences();
        if (!(prefs.getBool('autostart_default_applied') ?? false)) {
          try {
            await _autostart.setEnabled(true);
            _automatic = await _autostart.enabled();
            HostLog.write('Autostart standardmäßig eingeschaltet');
          } catch (e) {
            HostLog.write('Autostart fehlgeschlagen: $e');
          }
          await prefs.setBool('autostart_default_applied', true);
        }
      } else if (Platform.isWindows) {
        final prefs = await _preferences();
        await prefs.setBool('autostart_default_applied', true);
      }
      _addresses = (await NetworkInterface.list(type: InternetAddressType.IPv4))
          .expand((i) => i.addresses)
          .where((a) => !a.isLoopback)
          .map((a) => a.address)
          .toList();
      _address = _addresses.firstOrNull;
      await _menu();
      try {
        await _initializeUpdates();
      } catch (_) {
        // Automatic update failures stay silent.
      }
      if (mounted) setState(() {});
    } catch (e) {
      await _showError(trf('Host-Fehler {fehler}', {'fehler': e}));
    } finally {
      if (_usesHostUpdates && !_surfaceUpdates.isCompleted) {
        _surfaceUpdates.complete(
          UpdateCheck(
            installedVersion: hostVersion,
            platform: UpdatePlatform.other,
            enabled: false,
            fetcher: () async => throw StateError('Host updates unavailable'),
          ),
        );
      }
    }
  }

  Future<void> _initializeUpdates() async {
    final prefs = await _preferences();
    if (!mounted) return;
    final cachedVersion = prefs.getString('host_available_update_version');
    final cachedUrl = Uri.tryParse(
      prefs.getString('host_available_update_url') ?? '',
    );
    // Ein alter gespeicherter ZIP-Link wird mit den neuen Asset-Regeln geprüft.
    final refreshWindowsUrl =
        Platform.isWindows &&
        cachedVersion != null &&
        prefs.getInt('host_update_asset_format') != 1;
    final refreshLinuxUrl =
        Platform.isLinux && prefs.getInt('host_update_asset_format') != 2;
    if (!refreshWindowsUrl &&
        !refreshLinuxUrl &&
        cachedVersion != null &&
        isNewerVersion(_releaseVersion, cachedVersion) &&
        cachedUrl?.scheme == 'https' &&
        cachedUrl!.host.isNotEmpty) {
      _availableUpdate = UpdateResult(
        UpdateStatus.available,
        version: cachedVersion,
        url: cachedUrl,
      );
    }
    _updates = UpdateCheck(
      installedVersion: _releaseVersion,
      platform: Platform.isMacOS
          ? UpdatePlatform.macos
          : Platform.isLinux
          ? UpdatePlatform.linux
          : UpdatePlatform.other,
      host: true,
      fetcher: Platform.isWindows ? fetchWindowsHostRelease : null,
      enabled: prefs.getBool('host_update_check') ?? true,
      lastCheck: refreshWindowsUrl || refreshLinuxUrl
          ? null
          : DateTime.tryParse(prefs.getString('host_last_update_check') ?? ''),
      onState: () async {
        final last = _updates?.lastCheck;
        if (last != null) {
          await prefs.setString(
            'host_last_update_check',
            last.toIso8601String(),
          );
        }
      },
      onResult: (result) {
        if (_usesHostUpdates) AppUpdates.instance.hostResultChanged();
        if (!mounted) return;
        if (result.status == UpdateStatus.available) {
          _availableUpdate = result;
          unawaited(_showUpdateNotice(result));
        } else if (result.status == UpdateStatus.current) {
          _availableUpdate = null;
          unawaited(_clearUpdateNotice());
        }
      },
    );
    await _menu();
    if (_availableUpdate != null) await _showUpdateNotice(_availableUpdate!);
    if (_usesHostUpdates) {
      _updates!.result = _availableUpdate;
      _updates!.resultWasAutomatic = true;
      _surfaceUpdates.complete(_updates!);
    }
    _updates!.start();
  }

  Future<void> _clearUpdateNotice() async {
    try {
      final prefs = await _preferences();
      await prefs.remove('host_available_update_version');
      await prefs.remove('host_available_update_url');
      _updateNotice = null;
      await _menu();
      await trayManager.setToolTip(
        Platform.isLinux ? 'Remote for ADI-2' : 'Remote for ADI-2 Host',
      );
    } catch (_) {}
  }

  Future<void> _showUpdateNotice(UpdateResult result) async {
    try {
      final prefs = await _preferences();
      await prefs.setString('host_available_update_version', result.version!);
      await prefs.setString('host_available_update_url', result.url.toString());
      if (Platform.isWindows) await prefs.setInt('host_update_asset_format', 1);
      if (Platform.isLinux) await prefs.setInt('host_update_asset_format', 2);
      await _menu();
      if (_updateNotice != result.version) {
        _updateNotice = result.version;
        await trayManager.setToolTip(
          '${Platform.isLinux ? 'Remote for ADI-2' : 'Remote for ADI-2 Host'} · ${trf('Version {version} verfügbar', {'version': result.version})}',
        );
      }
    } catch (_) {
      // Update hints never open a window or interrupt the host.
    }
  }

  /// Prüft regelmäßig, ob und welcher ADI-2 angeschlossen ist.
  Future<void> _detect() async {
    if (_detecting || _exiting) return;
    _detecting = true;
    try {
      final found = await widget.midi.detect();
      if (!mounted || _exiting) return;
      if (!_detected || found != _adi2) {
        HostLog.write('Erkennung: ${found ?? 'kein ADI-2'}');
        _detected = true;
        _adi2 = found;
        unawaited(_menu());
      }
    } catch (_) {
      // A failed PnP read is not evidence of removal or a stale WinMM list.
      if (!Platform.isWindows) {
        if (!_detected || _adi2 != null) {
          _detected = true;
          _adi2 = null;
          if (mounted) unawaited(_menu());
        }
      }
    } finally {
      _detecting = false;
    }
  }

  void _changed() {
    if (mounted) setState(() {});
    unawaited(_menu());
  }

  Future<void> _menu() {
    if (_exiting) return Future.value();
    // Jede Aktualisierung hängt an der vorigen. Bleibt ein Aufruf im
    // Menüleisten-Plugin hängen, darf er nicht alle späteren blockieren
    // (Menü zeigte dann dauerhaft „kein ADI-2“ und keine Clients).
    _menuWork = _menuWork
        .timeout(const Duration(seconds: 3), onTimeout: () {})
        .catchError((Object _) {})
        .then(
          (_) => trayManager.setContextMenu(
            Menu(
              items: buildHostMenu(
                clientNames: server.connectedNames,
                rmeDevice: _adi2,
                status: server.status,
                error: _error,
                port: server.port,
                version: _releaseVersion,
                hasInterface: hostHasInterface,
                surfaceOpen: _windowVisible && !_management,
                windows: Platform.isWindows,
                autostart: _automatic,
                updatesEnabled: _updates?.enabled ?? true,
                availableVersion: _availableUpdate?.version,
              ),
            ),
          ),
        );
    return _menuWork;
  }

  Future<void> _show(bool pairing) async {
    if (pairing) server.pairing.issue();
    setState(() {
      _pairing = pairing;
      _management = true;
      _windowVisible = true;
    });
    _countdown?.cancel();
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    try {
      if (hostHasInterface) await windowManager.setSkipTaskbar(false);
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
      await DesktopActivation.present();
    } catch (error) {
      HostLog.write('Fenster öffnen fehlgeschlagen: $error');
    }
  }

  Future<void> _showError(String error) async {
    if (mounted) {
      setState(() {
        _error = error;
        _management = true;
        _windowVisible = true;
      });
    }
    try {
      await _menu();
    } catch (_) {
      // Auch bei ausgefallenem Tray bleibt das Fehlerfenster erreichbar.
    }
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
    await DesktopActivation.present();
  }

  @override
  void onWindowClose() {
    unawaited(_hideWindow());
  }

  @override
  void onTrayIconMouseDown() => unawaited(
    trayLeftClickOpensSurface(defaultTargetPlatform)
        ? _openSurface()
        : _popUpMenu(),
  );
  @override
  void onTrayIconRightMouseDown() => unawaited(_popUpMenu());

  /// Vor dem Öffnen den aktuellen Stand (Gerät, Clients) eintragen.
  Future<void> _popUpMenu() async {
    try {
      await _menu().timeout(const Duration(milliseconds: 500));
    } catch (_) {
      // Lieber das bisherige Menü zeigen als gar keins.
    }
    await trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem item) async {
    switch (item.key) {
      case 'surface':
        if (_windowVisible && !_management) {
          await _hideWindow();
        } else {
          await _openSurface();
        }
      case 'pair':
        await _show(true);
      case 'devices':
        await _show(false);
      case 'autostart':
        try {
          await _autostart.setEnabled(!_automatic);
          _automatic = await _autostart.enabled();
        } catch (e) {
          await _showError(
            trf('Autostart fehlgeschlagen {fehler}', {'fehler': e}),
          );
        }
        await _menu();
      case 'updates':
        final updates = _updates;
        if (updates == null) return;
        updates.enabled = !updates.enabled;
        final prefs = await _preferences();
        await prefs.setBool('host_update_check', updates.enabled);
        if (_usesHostUpdates) AppUpdates.instance.hostResultChanged();
        await _menu();
        if (updates.enabled) await updates.check();
      case 'download-update':
        final url = _availableUpdate?.url;
        if (url != null && !await openUpdate(url)) {
          try {
            await trayManager.setToolTip(
              tr('Download-Link konnte nicht geöffnet werden'),
            );
          } catch (_) {}
        }
      case 'quit':
        _exiting = true;
        _detectTimer?.cancel();
        _stallTimer?.cancel();
        // Beenden darf nie hängen: hält ein Teil (Server, Analyzer, Player,
        // Fenster) beim Aufräumen an, endet der Host trotzdem nach 3 s.
        Timer(const Duration(seconds: 3), () => exit(0));
        Future<void> step(Future<void> Function() f) async {
          try {
            await f().timeout(const Duration(seconds: 2));
          } catch (_) {}
        }

        if (Platform.isLinux) await step(LinuxTestSignalPlayer.instance.stop);
        _geometrySave?.cancel();
        await step(_storeGeometry);
        if (_desktopWindows != null) await step(_desktopWindows.closeAll);
        if (_instance != null) await step(_instance!.close);
        await step(server.stop);
        if (widget.broadcast.isReady) await step(widget.broadcast.stop);
        await step(trayManager.destroy);
        await step(windowManager.destroy);
        exit(0);
    }
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_analyzerSettingsChanged);
    widget.desktopSelection?.removeListener(_hostSelectionChanged);
    _geometrySave?.cancel();
    _updates?.stop();
    _countdown?.cancel();
    _detectTimer?.cancel();
    _stallTimer?.cancel();
    server.removeListener(_changed);
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expires = server.pairing.expires;
    final valid =
        server.pairing.code != null &&
        expires != null &&
        DateTime.now().isBefore(expires);
    final qr = jsonEncode({
      'type': 'adi2-pair-v1',
      'id': server.id,
      'name': server.name,
      'address': _address,
      'port': server.port,
      'code': server.pairing.code,
    });
    final management = MaterialApp(
      title: 'Remote for ADI-2',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: Scaffold(
        appBar: AppBar(
          title: Text(
            _pairing ? tr('Client koppeln…') : tr('Gekoppelte Geräte…'),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              server.connectedNames.isEmpty
                  ? hostStatusText(server.status, server.connectedNames.length)
                  : '${hostStatusText(server.status, server.connectedNames.length)} · ${server.connectedNames.join(', ')}',
            ),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
            if (_pairing) ...[
              if (_addresses.isNotEmpty)
                DropdownButton<String>(
                  value: _address,
                  isExpanded: true,
                  items: _addresses
                      .map((a) => DropdownMenuItem(value: a, child: Text(a)))
                      .toList(),
                  onChanged: (a) => setState(() => _address = a),
                ),
              SelectableText('${_address ?? server.name}:${server.port}'),
              if (valid) ...[
                SelectableText(
                  server.pairing.code!,
                  style: const TextStyle(fontSize: 36, letterSpacing: 8),
                ),
                Text(
                  trf('Noch {n} Sekunden gültig', {
                    'n': expires
                        .difference(DateTime.now())
                        .inSeconds
                        .clamp(0, 120),
                  }),
                ),
                if (_address != null)
                  Center(
                    child: QrImageView(
                      data: qr,
                      size: 210,
                      backgroundColor: Colors.white,
                    ),
                  ),
              ] else
                Text(tr('Code abgelaufen oder verwendet')),
              FilledButton(
                onPressed: () => setState(() {
                  server.pairing.issue();
                }),
                child: Text(tr('Neuer Code')),
              ),
              Text(
                tr(
                  'Stufe 1 überträgt im lokalen Netzwerk ohne Verschlüsselung.',
                ),
              ),
            ] else ...[
              for (final device in server.pairing.externalDevices)
                ListTile(
                  title: Text(device.name),
                  trailing: TextButton(
                    onPressed: () async {
                      try {
                        await server.revoke(device.id);
                      } catch (e) {
                        await _showError(
                          trf('Widerruf fehlgeschlagen {fehler}', {
                            'fehler': e,
                          }),
                        );
                      }
                    },
                    child: Text(tr('Widerrufen')),
                  ),
                ),
              if (server.pairing.externalDevices.isEmpty)
                Text(tr('Keine gekoppelten Geräte')),
            ],
          ],
        ),
      ),
    );
    if (!hostHasInterface) return management;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          if (_surfaceCreated)
            Offstage(
              offstage: _management,
              child: TickerMode(
                enabled: !_management && _windowVisible,
                child: Adi2RemoteApp(
                  localHost: widget.localHost,
                  desktopSelection: widget.desktopSelection,
                  desktopWindows: _desktopWindows,
                ),
              ),
            ),
          Offstage(offstage: !_management, child: management),
        ],
      ),
    );
  }
}
