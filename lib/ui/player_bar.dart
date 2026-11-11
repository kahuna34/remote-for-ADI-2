import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../media/now_playing.dart';
import 'theme.dart';
import 'responsive_layout.dart';

/// Leiste mit dem aktuell spielenden Titel und den Abspieltasten.
/// Ohne Freigabe: einmaliger Hinweis zum Einschalten.
/// Feste Höhe des Player-Bereichs, damit die Ansicht darunter nicht springt.
const double playerSlotHeight = 120;

double headerSlotHeight(BuildContext context) =>
    isTablet(context) ? 180 : playerSlotHeight;

class PlayerBar extends StatelessWidget {
  const PlayerBar({
    super.key,
    required this.np,
    this.fallback,
    this.collapseWhenEmpty = false,
  });
  final bool collapseWhenEmpty;
  final NowPlaying np;

  /// Wird angezeigt, wenn kein Player aktiv ist (z. B. Digital-Eingänge).
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: np,
      builder: (context, _) {
        final visible =
            np.supported &&
            ((!np.access && !np.promptDismissed) ||
                np.access && np.info?.hasContent == true);
        if (collapseWhenEmpty && !visible && fallback == null) {
          return const SizedBox.shrink();
        }
        if (isTablet(context)) {
          // Der Tablet-Player ist nur so hoch wie sein Inhalt; die größere
          // Kopfzeilenhöhe braucht nur der Analyzer.
          return visible ? _content() : _empty();
        }
        return SizedBox(
          height: headerSlotHeight(context),
          child: Align(alignment: Alignment.topCenter, child: _content()),
        );
      },
    );
  }

  Widget _empty() => fallback ?? const SizedBox.shrink();

  Widget _content() {
    return ListenableBuilder(
      listenable: np,
      builder: (context, _) {
        if (!np.supported) return _empty();
        if (!np.access) {
          if (np.promptDismissed) return _empty();
          return _prompt();
        }
        final i = np.info;
        if (i == null || !i.hasContent) return _empty();
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Panel(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Column(
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: np.openPlayer,
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: i.art != null
                              ? Image.memory(
                                  i.art!,
                                  key: ValueKey((i.app, i.title, i.artist)),
                                  fit: BoxFit.cover,
                                  gaplessPlayback: true,
                                )
                              : Container(
                                  color: Palette.surf2,
                                  child: const Icon(
                                    Icons.music_note,
                                    color: Palette.muted,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: i.title ?? '',
                                    style: ts(15, weight: 600),
                                  ),
                                  if ((i.artist ?? '').isNotEmpty)
                                    TextSpan(
                                      text: '  –  ${i.artist}',
                                      style: ts(15, color: Palette.muted),
                                    ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if ((i.app ?? '').isNotEmpty)
                              Text(
                                trf('über {app}', {'app': i.app}),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ts(
                                  12,
                                  weight: 500,
                                  color: Palette.muted,
                                  narrow: true,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: _btn(
                        Icons.skip_previous,
                        () => np.command('previous'),
                      ),
                    ),
                    Expanded(child: Center(child: _main(i.playing))),
                    Expanded(
                      child: _btn(Icons.skip_next, () => np.command('next')),
                    ),
                    Expanded(
                      child: _btn(
                        Icons.stop,
                        () => np.command('stop'),
                        size: 22,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _btn(IconData icon, VoidCallback onTap, {double size = 28}) =>
      SizedBox(
        height: 48,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Center(
            child: Icon(icon, size: size, color: Palette.text),
          ),
        ),
      );

  Widget _main(bool playing) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: Material(
      color: Palette.text,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: np.playPause,
        child: SizedBox(
          width: 46,
          height: 46,
          child: Icon(
            playing ? Icons.pause : Icons.play_arrow,
            color: Palette.bg,
            size: 28,
          ),
        ),
      ),
    ),
  );

  Widget _prompt() => np.restricted ? _restrictedPrompt() : _accessPrompt();

  /// Android sperrt den Benachrichtigungszugriff für Apps aus einer
  /// heruntergeladenen Datei; Freigabe nur über die App-Infos.
  Widget _restrictedPrompt() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
    child: Panel(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.lock_outline, color: Palette.muted, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr(
                    'Android sperrt den Benachrichtigungszugriff für '
                    'heruntergeladene Apps. Einmal „Erlauben“ antippen, dann '
                    'in den App-Infos oben rechts über ⋮ „Eingeschränkte '
                    'Einstellungen zulassen“ wählen und erneut erlauben.',
                  ),
                  style: ts(13, weight: 500, color: Palette.muted),
                ),
              ),
              IconButton(
                tooltip: tr('Nicht mehr fragen'),
                onPressed: np.dismissPrompt,
                icon: const Icon(Icons.close, size: 18, color: Palette.muted),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: const ValueKey('player-app-details'),
                onPressed: np.openAppDetails,
                child: Text(
                  tr('App-Infos'),
                  style: ts(14, weight: 600, color: Palette.amber),
                ),
              ),
              TextButton(
                onPressed: np.openAccessSettings,
                child: Text(
                  tr('Erlauben'),
                  style: ts(14, weight: 600, color: Palette.amber),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _accessPrompt() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
    child: Panel(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          const Icon(Icons.music_note, color: Palette.muted, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              tr('Laufenden Titel anzeigen und steuern?'),
              style: ts(13, weight: 500, color: Palette.muted),
            ),
          ),
          TextButton(
            onPressed: np.openAccessSettings,
            child: Text(
              tr('Erlauben'),
              style: ts(14, weight: 600, color: Palette.amber),
            ),
          ),
          IconButton(
            tooltip: tr('Nicht mehr fragen'),
            onPressed: np.dismissPrompt,
            icon: const Icon(Icons.close, size: 18, color: Palette.muted),
          ),
        ],
      ),
    ),
  );
}
