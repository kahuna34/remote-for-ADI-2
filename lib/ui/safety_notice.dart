import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../l10n/l10n.dart';

Future<void> showSafetyNotice(
  BuildContext context, {
  required bool requireAcceptance,
}) => showDialog<void>(
  context: context,
  barrierDismissible: !requireAcceptance,
  builder: (_) => _SafetyNotice(requireAcceptance: requireAcceptance),
);

class _SafetyNotice extends StatefulWidget {
  const _SafetyNotice({required this.requireAcceptance});
  final bool requireAcceptance;

  @override
  State<_SafetyNotice> createState() => _SafetyNoticeState();
}

class _SafetyNoticeState extends State<_SafetyNotice> {
  bool _saving = false;

  Future<void> _close() async {
    if (_saving) return;
    if (widget.requireAcceptance) {
      setState(() => _saving = true);
      try {
        await AppSettings.instance.acceptSafetyNotice();
      } catch (_) {
        if (mounted) {
          setState(() => _saving = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tr('Vorgang konnte nicht abgeschlossen werden.')),
            ),
          );
        }
        return;
      }
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !widget.requireAcceptance,
    child: Dialog.fullscreen(
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('Wichtiger Hinweis zur Lautstärke'),
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 24),
                      Text(
                        tr(
                          'Diese App verändert Einstellungen deines ADI-2, auch die Lautstärke. Bedienfehler, Übertragungs- oder Softwarefehler sowie unerwartetes Verhalten von Gerät, Verbindung oder Host können zu plötzlich hoher Lautstärke führen. Zu hohe Lautstärke kann das Gehör dauerhaft schädigen und Kopfhörer, Lautsprecher, Verstärker oder andere Geräte beschädigen.\n\n• Beginne immer mit niedriger Lautstärke und nutze den Lautstärkeschutz mit einer passenden Obergrenze.\n• Setze Kopfhörer erst auf, wenn die Verbindung steht und die Lautstärke geprüft ist.\n• Prüfe wichtige Änderungen direkt am Gerät.\n\nDie App ist kostenlose Software und wird ohne Gewährleistung bereitgestellt (GPL-3.0). Die Nutzung erfolgt auf eigene Verantwortung. Soweit gesetzlich zulässig, ist die Haftung des Entwicklers für Schäden aus der Nutzung der App ausgeschlossen, insbesondere für Hör- und andere Gesundheitsschäden, Schäden an Geräten sowie Datenverlust. Unberührt bleibt die Haftung für Vorsatz und grobe Fahrlässigkeit sowie jede Haftung, die gesetzlich nicht ausgeschlossen werden kann, etwa für Schäden aus der Verletzung des Lebens, des Körpers oder der Gesundheit.',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  onPressed: _saving ? null : _close,
                  child: Text(
                    widget.requireAcceptance
                        ? tr('Verstanden und akzeptiert')
                        : tr('Schließen'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Builds setup and starts connection services only after saved acceptance.
class SafetyGate extends StatefulWidget {
  const SafetyGate({
    super.key,
    required this.child,
    required this.onReady,
    this.requireNotice = false,
  });
  final Widget child;
  final VoidCallback onReady;

  /// Seit 24.11.2026 standardmäßig kein Hinweis beim Start (Wunsch des Nutzers);
  /// der Hinweis bleibt in den App-Einstellungen unter „Sicherheit und Haftung“.
  final bool requireNotice;

  @override
  State<SafetyGate> createState() => _SafetyGateState();
}

class _SafetyGateState extends State<SafetyGate> {
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    try {
      // Erst die gespeicherte Sprache laden, sonst erscheint der Hinweis
      // beim Start in der Standardsprache Englisch.
      await AppLang.instance.load();
      if (!widget.requireNotice) {
        widget.onReady();
        if (mounted) setState(() => _ready = true);
        return;
      }
      await AppSettings.instance.loadSafetyNotice();
      if (!mounted) return;
      if (AppSettings.instance.safetyNoticeAccepted <
          AppSettings.safetyNoticeVersion) {
        await showSafetyNotice(context, requireAcceptance: true);
      }
      if (!mounted) return;
      if (AppSettings.instance.safetyNoticeAccepted <
          AppSettings.safetyNoticeVersion) {
        return;
      }
      widget.onReady();
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) => _ready
      ? widget.child
      : Scaffold(
          body: Center(
            child: _failed
                ? TextButton(
                    onPressed: () {
                      setState(() => _failed = false);
                      _check();
                    },
                    child: Text(tr('Erneut versuchen')),
                  )
                : const SizedBox.shrink(),
          ),
        );
}
