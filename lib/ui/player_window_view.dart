import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../device/adi2_controller.dart';
import '../l10n/l10n.dart';
import '../media/player_source.dart';
import 'theme.dart';

/// A resizable player surface using the same host subscription and commands as
/// PlayerBar. It never starts a local media service.
class PlayerWindowView extends StatelessWidget {
  const PlayerWindowView({super.key, required this.controller});
  final Adi2Controller controller;

  @override
  Widget build(BuildContext context) => PlayerSourceView(
    deviceController: controller,
    builder: (context, source) => LayoutBuilder(
      builder: (context, box) {
        final info = source.info;
        if (info == null || !info.hasContent) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.music_note, size: 80, color: Palette.muted),
                const SizedBox(height: 24),
                Text(
                  tr('Kein Player aktiv'),
                  style: ts(22, color: Palette.muted),
                ),
              ],
            ),
          );
        }
        final horizontal =
            box.maxWidth > 640 && box.maxWidth > box.maxHeight * 1.25;
        final compact = box.maxHeight < 450;
        final artSize = compact
            ? 72.0
            : horizontal
            ? math
                  .min(box.maxWidth * .42, box.maxHeight - 64)
                  .clamp(80.0, 600.0)
            : math
                  .min(box.maxWidth - 64, box.maxHeight - 250)
                  .clamp(80.0, 600.0);
        final art = ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SizedBox.square(
            dimension: artSize,
            child: info.art == null
                ? const ColoredBox(
                    color: Palette.surf2,
                    child: Icon(Icons.album, size: 80, color: Palette.muted),
                  )
                : Image.memory(
                    info.art!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.album, size: 80),
                  ),
          ),
        );
        final details = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: horizontal
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            Text(
              info.title!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: horizontal ? TextAlign.start : TextAlign.center,
              style: ts(
                compact
                    ? 18
                    : horizontal
                    ? 30
                    : 24,
                weight: 600,
              ),
            ),
            if (info.artist?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text(
                info.artist!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ts(compact ? 15 : 19, color: Palette.muted),
              ),
            ],
            if (info.album?.isNotEmpty == true) ...[
              const SizedBox(height: 6),
              Text(
                info.album!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts(15, color: Palette.muted),
              ),
            ],
            SizedBox(height: compact ? 12 : 24),
            Row(
              mainAxisAlignment: horizontal
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: tr('Zurück'),
                  iconSize: 36,
                  onPressed: source.controlsEnabled
                      ? () => source.command('previous')
                      : null,
                  icon: const Icon(Icons.skip_previous),
                ),
                const SizedBox(width: 16),
                FilledButton(
                  style: FilledButton.styleFrom(
                    padding: EdgeInsets.all(compact ? 12 : 20),
                    shape: const CircleBorder(),
                  ),
                  onPressed: source.controlsEnabled
                      ? () => source.command(info.playing ? 'pause' : 'play')
                      : null,
                  child: Icon(
                    info.playing ? Icons.pause : Icons.play_arrow,
                    size: 40,
                    semanticLabel: info.playing ? tr('Pause') : tr('Abspielen'),
                  ),
                ),
                const SizedBox(width: 16),
                IconButton(
                  tooltip: tr('Weiter'),
                  iconSize: 36,
                  onPressed: source.controlsEnabled
                      ? () => source.command('next')
                      : null,
                  icon: const Icon(Icons.skip_next),
                ),
              ],
            ),
          ],
        );
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: Padding(
              padding: EdgeInsets.all(compact ? 16 : 32),
              child: horizontal
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        art,
                        const SizedBox(width: 40),
                        Expanded(child: details),
                      ],
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        art,
                        SizedBox(height: compact ? 12 : 24),
                        details,
                      ],
                    ),
            ),
          ),
        );
      },
    ),
  );
}
