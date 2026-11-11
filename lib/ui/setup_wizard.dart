import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_settings.dart';
import '../device/adi2_controller.dart';
import '../l10n/l10n.dart';
import '../media/now_playing.dart';
import '../update/app_updates.dart';
import 'host_connect_page.dart';
import 'privacy_page.dart';
import 'theme.dart';

/// Keeps the home page (and its dialogs) out of the initial setup flow.
class SetupGate extends StatefulWidget {
  const SetupGate({
    super.key,
    required this.ctrl,
    required this.np,
    required this.child,
  });
  final Adi2Controller ctrl;
  final NowPlaying np;
  final Widget child;
  @override
  State<SetupGate> createState() => _SetupGateState();
}

class _SetupGateState extends State<SetupGate> {
  bool? _done;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _done = prefs.getBool('setup_done') ?? false);
  }

  @override
  Widget build(BuildContext context) => _done == null
      ? const Scaffold(body: Center(child: CircularProgressIndicator()))
      : _done!
      ? widget.child
      : SetupWizard(
          ctrl: widget.ctrl,
          np: widget.np,
          onDone: () => setState(() => _done = true),
        );
}

class SetupWizard extends StatefulWidget {
  const SetupWizard({
    super.key,
    this.ctrl,
    required this.np,
    required this.onDone,
  });
  final Adi2Controller? ctrl;
  final NowPlaying np;
  final VoidCallback onDone;
  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<SetupWizard> {
  int _step = 0;
  bool _saving = false;
  final _scroll = ScrollController();
  late final AppLifecycleListener _life;
  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(onResume: widget.np.refreshAccess);
    widget.np.refreshAccess();
  }

  @override
  void dispose() {
    _life.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool('setup_done', true)) throw StateError('setup');
      if (mounted) widget.onDone();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                'Einrichtung konnte nicht gespeichert werden. Bitte erneut versuchen.',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _next() {
    _scroll.jumpTo(0);
    setState(() => _step = _step == 0 && !widget.np.supported ? 2 : _step + 1);
  }

  Widget _text(String value) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Text(value, style: ts(16, height: 1.5)),
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      ?widget.ctrl,
      widget.np,
      AppSettings.instance,
      AppLang.instance,
    ]),
    builder: (context, _) {
      final connected = widget.ctrl?.state == ConnState.connected;
      final complete =
          _step == 0 && connected || _step == 1 && widget.np.access;
      final title = switch (_step) {
        0 => tr('ADI-2 anschließen'),
        1 => tr('Laufenden Titel anzeigen (optional)'),
        2 => tr('Updates'),
        _ => tr('Fertig'),
      };
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _finish();
        },
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: Text(tr('Einrichtung')),
            actions: [
              TextButton(
                onPressed: _saving ? null : _finish,
                child: Text(tr('Überspringen')),
              ),
            ],
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(24),
                  children: [
                    Icon(
                      complete
                          ? Icons.check_circle
                          : switch (_step) {
                              0 => Icons.usb,
                              1 => Icons.music_note,
                              2 => Icons.system_update,
                              _ => Icons.check_circle_outline,
                            },
                      key: ValueKey(
                        complete ? 'setup-complete' : 'setup-step-icon',
                      ),
                      size: 72,
                      color: complete ? Palette.green : Palette.amber,
                    ),
                    const SizedBox(height: 24),
                    Text(title, style: ts(26, weight: 650)),
                    const SizedBox(height: 20),
                    if (_step == 0) ...[
                      if (connected)
                        _text(widget.ctrl!.deviceLabel)
                      else ...[
                        _text(
                          tr(
                            'Verbinde den ADI-2 per USB-OTG-Kabel. Aktiviere MIDI Control → ON: DAC: SETUP → Options → Remap Keys / Diag; Pro und ADI-2/4 Pro: SETUP → Options → Device Mode / DSD.',
                          ),
                        ),
                        _text(
                          tr('Du kannst das Gerät auch später anschließen.'),
                        ),
                        if (widget.ctrl != null)
                          OutlinedButton(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    HostConnectPage(ctrl: widget.ctrl!),
                              ),
                            ),
                            child: Text(tr('Über Host verbinden')),
                          ),
                      ],
                    ],
                    if (_step == 1) ...[
                      _text(
                        tr(
                          'Zeige Titel, Interpret und Cover des laufenden Android-Players und steuere die Wiedergabe.',
                        ),
                      ),
                      if (widget.np.access)
                        _text(tr('Zugriff erteilt'))
                      else ...[
                        if (widget.np.restricted) ...[
                          _text(
                            tr(
                              '1. Einmal „Erlauben“ versuchen. Dann App-Infos → ⋮ → „Eingeschränkte Einstellungen zulassen“.',
                            ),
                          ),
                          OutlinedButton(
                            onPressed: widget.np.openAppDetails,
                            child: Text(tr('App-Infos')),
                          ),
                          _text(
                            tr(
                              '2. Zurückkehren und den Benachrichtigungszugriff mit „Erlauben“ freigeben.',
                            ),
                          ),
                        ],
                        OutlinedButton(
                          onPressed: widget.np.openAccessSettings,
                          child: Text(tr('Erlauben')),
                        ),
                      ],
                    ],
                    if (_step == 2) ...[
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        key: const ValueKey('setup-update-check'),
                        title: Text(tr('Automatisch nach Updates suchen')),
                        value: AppSettings.instance.updateCheck,
                        onChanged: (value) async {
                          await AppSettings.instance.setUpdateCheck(value);
                          AppUpdates.instance.settingsChanged();
                        },
                      ),
                      _text(
                        tr(
                          'Einmal täglich wird api.github.com nach der neuesten Version gefragt; GitHub sieht dabei deine IP-Adresse.',
                        ),
                      ),
                    ],
                    if (_step == 3) ...[
                      _text(
                        tr(
                          'Die Einrichtung ist abgeschlossen. Alle Optionen bleiben in den App-Einstellungen erreichbar.',
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const PrivacyPage(),
                          ),
                        ),
                        child: Text(tr('Datenschutzerklärung')),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _saving
                          ? null
                          : _step == 3
                          ? _finish
                          : _next,
                      child: Text(
                        _step == 3 ? tr('Los geht\'s') : tr('Weiter'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
