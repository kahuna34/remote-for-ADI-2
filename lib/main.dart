import 'package:flutter/material.dart';

import 'update/app_updates.dart';
import 'device/adi2_controller.dart';
import 'l10n/l10n.dart';
import 'media/now_playing.dart';
import 'ui/start_animation.dart';
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
  const Adi2RemoteApp({super.key});

  @override
  State<Adi2RemoteApp> createState() => _Adi2RemoteAppState();
}

class _Adi2RemoteAppState extends State<Adi2RemoteApp> {
  final Adi2Controller _ctrl = Adi2Controller();
  final NowPlaying _np = NowPlaying();
  late final AppLifecycleListener _life;
  bool _animationDone = false;

  @override
  void initState() {
    super.initState();
    AppLang.instance.load();
    AppUpdates.instance.initialize();
    _ctrl.start();
    _np.start();
    // Sicherheit: Sobald die App nicht mehr im Vordergrund ist, wird jede
    // laufende Lautstärke-Anhebung gestoppt.
    _life = AppLifecycleListener(
      // Inaktiv ist auch ein kurzer Zwischenzustand (Drehen, Benachrichtigungs-
      // leiste): Anhebungen stoppen, die Host-Sitzung aber behalten. Erst
      // Ausblenden/Pausieren gibt sie frei.
      onInactive: _ctrl.stopAllVolumeRamps,
      onHide: () => _ctrl.setHostForeground(false),
      onPause: () => _ctrl.setHostForeground(false),
      onResume: () => _ctrl.setHostForeground(true),
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
    return ListenableBuilder(
      listenable: AppLang.instance,
      builder: (context, _) => MaterialApp(
        title: 'Remote for ADI-2',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        builder: (context, child) => TabletOrientation(child: child!),
        home: StartAnimation(
          onComplete: () {
            if (mounted) setState(() => _animationDone = true);
          },
          child: _animationDone
              ? SetupGate(
                  ctrl: _ctrl,
                  np: _np,
                  child: HomePage(ctrl: _ctrl, np: _np),
                )
              : const Scaffold(),
        ),
      ),
    );
  }
}
