import 'desktop/desktop_compact_scale.dart';
import 'desktop/host_interface.dart';
import 'desktop/desktop_host_selection.dart';

import 'app_settings.dart';
import 'desktop/desktop_windows.dart';

import 'package:flutter/material.dart';

import 'update/app_updates.dart';
import 'host/host_client.dart';
import 'device/adi2_controller.dart';
import 'l10n/l10n.dart';
import 'media/now_playing.dart';
import 'ui/start_animation.dart';
import 'ui/safety_notice.dart';
import 'ui/setup_wizard.dart';
import 'ui/home_page.dart';
import 'ui/eq_display_mode.dart';
import 'ui/theme.dart';
import 'ui/responsive_layout.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  EqDisplayMode.setTablet(
    view.physicalSize.shortestSide / view.devicePixelRatio >= tabletBreakpoint,
  );
  EqDisplayMode.initialize();
  runApp(const Adi2RemoteApp());
}

class Adi2RemoteApp extends StatefulWidget {
  const Adi2RemoteApp({
    super.key,
    this.localHost,
    this.desktopWindows,
    this.desktopSelection,
  });
  final HostCredentials? localHost;
  final DesktopHostSelection? desktopSelection;
  final DesktopWindows? desktopWindows;

  @override
  State<Adi2RemoteApp> createState() => _Adi2RemoteAppState();
}

class _Adi2RemoteAppState extends State<Adi2RemoteApp> {
  late final Adi2Controller _ctrl = Adi2Controller(
    localHost: widget.localHost,
    desktopSelection: widget.desktopSelection,
  );
  late final NowPlaying _np = NowPlaying(hostOnly: widget.localHost != null);
  late final AppLifecycleListener _life;
  bool _animationDone = false;
  bool _servicesStarted = false;

  @override
  void initState() {
    super.initState();
    AppLang.instance.load();
    AppUpdates.instance.initialize();

    // Sicherheit: Sobald die App nicht mehr im Vordergrund ist, wird jede
    // laufende Lautstärke-Anhebung gestoppt.
    _life = AppLifecycleListener(
      // Inaktiv ist auch ein kurzer Zwischenzustand (Drehen, Benachrichtigungs-
      // leiste): Anhebungen stoppen, die Host-Sitzung aber behalten. Erst
      // Ausblenden/Pausieren gibt sie frei.
      onInactive: _ctrl.stopAllVolumeRamps,
      onHide: () {
        if (_servicesStarted) _ctrl.setHostForeground(false);
      },
      onPause: () {
        if (_servicesStarted) _ctrl.setHostForeground(false);
      },
      onResume: () {
        if (widget.localHost != null && hostHasInterface) {
          AppSettings.instance.load(reload: true);
        }
        if (_servicesStarted) _ctrl.setHostForeground(true);
      },
    );
  }

  @override
  void dispose() {
    AppUpdates.instance.checker?.stop();
    _life.dispose();
    _np.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = ListenableBuilder(
      listenable: AppLang.instance,
      builder: (context, _) => MaterialApp(
        title: 'Remote for ADI-2',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        builder: (context, child) =>
            DesktopCompactScale(child: TabletOrientation(child: child!)),
        home: SafetyGate(
          onReady: () {
            _servicesStarted = true;
            _ctrl.start();
            _np.start();
          },
          child: StartAnimation(
            onComplete: () {
              if (mounted) setState(() => _animationDone = true);
            },
            child: _animationDone
                ? widget.localHost != null
                      ? HomePage(ctrl: _ctrl, np: _np)
                      : SetupGate(
                          ctrl: _ctrl,
                          np: _np,
                          child: HomePage(ctrl: _ctrl, np: _np),
                        )
                : const Scaffold(),
          ),
        ),
      ),
    );
    return widget.localHost != null &&
            widget.desktopWindows != null &&
            hostHasInterface
        ? DesktopWindowScope(windows: widget.desktopWindows!, child: app)
        : app;
  }
}
