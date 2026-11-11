import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../easy/easy_layout.dart';
import '../l10n/l10n.dart';
import 'easy_tile_grid.dart';
import 'theme.dart';

Future<bool> confirmEasyAction(
  BuildContext context,
  String title, {
  String? message,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: message == null ? null : Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Abbrechen')),
          ),
          FilledButton(
            key: const ValueKey('easy-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Bestätigen')),
          ),
        ],
      ),
    ) ??
    false;

class EasySlotPreview extends StatelessWidget {
  const EasySlotPreview({
    super.key,
    required this.index,
    required this.layout,
    this.name,
    this.active = false,
    required this.onTap,
  });
  final int index;
  final EasyLayout? layout;
  final String? name;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: active,
    label: trf('Eigene Ansicht {n}', {'n': index + 1}),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? Palette.amber : Palette.line,
            width: active ? 2 : 1,
          ),
        ),
        child: Opacity(
          opacity: active ? 1 : 0.55,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 22,
                child: active
                    ? Tooltip(
                        message: tr('Aktiv'),
                        child: Icon(
                          Icons.check_circle,
                          key: ValueKey('easy-slot-active-$index'),
                          color: Palette.amber,
                          size: 18,
                        ),
                      )
                    : null,
              ),
              Text(
                trf('Slot {n}', {'n': index + 1}),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts(11),
              ),
              const SizedBox(height: 4),
              if (layout != null)
                EasyLayoutPreview(layout: layout!)
              else
                CustomPaint(
                  painter: _DashedFrame(),
                  child: SizedBox(
                    height: 64,
                    width: double.infinity,
                    child: Center(
                      child: Text(
                        tr('leer'),
                        style: ts(11, color: Palette.muted),
                      ),
                    ),
                  ),
                ),
              if (name != null)
                Text(
                  name!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts(11),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _DashedFrame extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Palette.muted
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 7) {
      final end = math.min(x + 4, size.width);
      canvas.drawLine(Offset(x, 0), Offset(end, 0), paint);
      canvas.drawLine(Offset(x, size.height), Offset(end, size.height), paint);
    }
    for (double y = 0; y < size.height; y += 7) {
      final end = math.min(y + 4, size.height);
      canvas.drawLine(Offset(0, y), Offset(0, end), paint);
      canvas.drawLine(Offset(size.width, y), Offset(size.width, end), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DashedFrame oldDelegate) => false;
}

/// Decorative miniature using the same placement and colors as the editor.
class EasyLayoutPreview extends StatelessWidget {
  const EasyLayoutPreview({super.key, required this.layout});
  final EasyLayout layout;

  @override
  Widget build(BuildContext context) {
    final placements = packEasyTiles(layout.tiles);
    final bottom = placements.fold<int>(
      1,
      (extent, p) => math.max(extent, p.y + p.height),
    );
    return ExcludeSemantics(
      child: SizedBox(
        height: 64,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Vertical units are half a quarter-width; horizontal units sixtieths.
            final unit = math.min(
              constraints.maxWidth / easyGridUnits,
              64 / (bottom * easyQuarterUnits / 2),
            );
            return Stack(
              children: [
                for (final p in placements)
                  Positioned(
                    left: p.x * unit,
                    top: p.y * unit * easyQuarterUnits / 2,
                    width: p.width * unit,
                    height: p.height * unit * easyQuarterUnits / 2,
                    child: Padding(
                      padding: const EdgeInsets.all(1.5),
                      child: DecoratedBox(
                        key: ValueKey('easy-settings-preview-${p.index}'),
                        decoration: BoxDecoration(
                          color: easyTileBackground(
                            layout.tiles[p.index].color ?? layout.defaultColor,
                          ),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Palette.line),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
