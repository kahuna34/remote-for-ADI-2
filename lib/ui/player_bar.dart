import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../media/now_playing.dart';
import '../media/player_source.dart';
import '../device/adi2_controller.dart';
import 'theme.dart';
import 'responsive_layout.dart';

/// Leiste mit dem aktuell spielenden Titel und den Abspieltasten.
/// Ohne Freigabe: einmaliger Hinweis zum Einschalten.
/// Feste Höhe des Player-Bereichs, damit die Ansicht darunter nicht springt.
const double playerSlotHeight = 120;

double headerSlotHeight(BuildContext context) {
  if (isTablet(context)) return 180;
  if (MediaQuery.orientationOf(context) != Orientation.portrait) {
    return playerSlotHeight;
  }
  // The output ring loses 15% of its diameter; the header gains that height.
  final ringDiameter = math.min(MediaQuery.sizeOf(context).width - 160, 300.0);
  // Short screens also need room for the taller balance row and 48 dp tone
  // buttons. Transfer only the height that fits after the system insets.
  final view = View.of(context);
  final systemInsets =
      (view.viewPadding.top + view.viewPadding.bottom) / view.devicePixelRatio;
  final usableHeight = MediaQuery.sizeOf(context).height - systemInsets;
  final growth = ((usableHeight - 680) / 60).clamp(0.0, 1.0);
  return playerSlotHeight + math.max(0, ringDiameter) * 0.15 * 0.83 * growth;
}

class PlayerBar extends StatelessWidget {
  const PlayerBar({
    super.key,
    required this.np,
    this.fallback,
    this.deviceController,
    this.collapseWhenEmpty = false,
  });
  final bool collapseWhenEmpty;
  final NowPlaying np;
  final Adi2Controller? deviceController;

  /// Wird angezeigt, wenn kein Player aktiv ist (z. B. Digital-Eingänge).
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    return PlayerSourceView(
      np: np,
      deviceController: deviceController,
      builder: (context, source) {
        final visible = source.visible;
        if (collapseWhenEmpty && !visible && fallback == null) {
          return const SizedBox.shrink();
        }
        if (isTablet(context) || source.needsHostUpdate) {
          // Der Tablet-Player ist nur so hoch wie sein Inhalt; die größere
          // Kopfzeilenhöhe braucht nur der Analyzer.
          return visible ? _content(source) : _empty();
        }
        final slot = headerSlotHeight(context);
        return SizedBox(
          height: slot,
          child: Align(
            alignment: Alignment.topCenter,
            // Hohe Kopfzeile am Smartphone: Player nutzt den Platz.
            child: _content(source, large: slot >= 144),
          ),
        );
      },
    );
  }

  Widget _empty() => fallback ?? const SizedBox.shrink();

  Widget _content(PlayerSource source, {bool large = false}) {
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) {
        final content = _playerContent(source, large: large);
        if (!source.needsHostUpdate) return content;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Text(
                tr(
                  'Dieser Host unterstützt den Player noch nicht. Host aktualisieren.',
                ),
                style: ts(12, color: Palette.amber),
              ),
            ),
            content,
          ],
        );
      },
    );
  }

  Widget _playerContent(PlayerSource source, {bool large = false}) {
    final art = large ? 60.0 : 48.0;
    if (source.showPrompt) return _prompt();
    if (!source.available) return _empty();
    final i = source.info;
    if (i == null || !i.hasContent) return _empty();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Panel(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: source.usesHost ? null : source.openPlayer,
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: art,
                      height: art,
                      child: i.art != null
                          ? Image.memory(
                              i.art!,
                              key: ValueKey((i.app, i.title, i.artist)),
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              errorBuilder: (_, _, _) =>
                                  const Icon(Icons.music_note),
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
                                style: ts(large ? 17 : 15, weight: 600),
                              ),
                              if ((i.artist ?? '').isNotEmpty)
                                TextSpan(
                                  text: '  –  ${i.artist}',
                                  style: ts(
                                    large ? 17 : 15,
                                    color: Palette.muted,
                                  ),
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
                    () => source.command('previous'),
                    large: large,
                  ),
                ),
                Expanded(
                  child: Center(child: _main(i.playing, source, large: large)),
                ),
                Expanded(
                  child: _btn(
                    Icons.skip_next,
                    () => source.command('next'),
                    large: large,
                  ),
                ),
                if (!source.usesHost)
                  Expanded(
                    child: _btn(
                      Icons.stop,
                      () => source.command('stop'),
                      size: large ? 26 : 22,
                      large: large,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _btn(
    IconData icon,
    VoidCallback onTap, {
    double size = 28,
    bool large = false,
  }) => SizedBox(
    height: large ? 52 : 48,
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Center(
        child: Icon(
          icon,
          size: large && size == 28 ? 32 : size,
          color: Palette.text,
        ),
      ),
    ),
  );

  Widget _main(bool playing, PlayerSource source, {bool large = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Material(
          color: Palette.text,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => source.command(playing ? 'pause' : 'play'),
            child: SizedBox(
              width: large ? 52 : 46,
              height: large ? 52 : 46,
              child: Icon(
                playing ? Icons.pause : Icons.play_arrow,
                color: Palette.bg,
                size: large ? 32 : 28,
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
