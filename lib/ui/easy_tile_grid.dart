import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../easy/easy_layout.dart';
import '../l10n/l10n.dart';
import 'theme.dart';

Color easyTileBackground(EasyTileColor color) => switch (color) {
  EasyTileColor.graphite => Palette.surf,
  EasyTileColor.blue => const Color(0xFF293F59),
  EasyTileColor.petrol => const Color(0xFF23464B),
  EasyTileColor.green => const Color(0xFF304B3D),
  EasyTileColor.olive => const Color(0xFF464A31),
  EasyTileColor.amber => const Color(0xFF59462D),
  EasyTileColor.copper => const Color(0xFF584034),
  EasyTileColor.red => const Color(0xFF57343B),
  EasyTileColor.violet => const Color(0xFF443956),
  EasyTileColor.rose => const Color(0xFF543C4C),
};

String easyTileColorName(EasyTileColor color) => switch (color) {
  EasyTileColor.graphite => tr('Graphit'),
  EasyTileColor.blue => tr('Blau'),
  EasyTileColor.petrol => tr('Petrol'),
  EasyTileColor.green => tr('Grün'),
  EasyTileColor.olive => tr('Oliv'),
  EasyTileColor.amber => tr('Bernstein'),
  EasyTileColor.copper => tr('Kupfer'),
  EasyTileColor.red => tr('Rot'),
  EasyTileColor.violet => tr('Violett'),
  EasyTileColor.rose => tr('Rosa'),
};

/// Contrast is calculated against the actual (possibly active-tinted) surface.
Color easyTileForeground(Color background) =>
    background.computeLuminance() > 0.179 ? Colors.black : Colors.white;

class EasyColorPicker extends StatelessWidget {
  const EasyColorPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.inherit = false,
  });
  final EasyTileColor? value;
  final ValueChanged<EasyTileColor?> onChanged;
  final bool inherit;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 4,
    runSpacing: 4,
    children: [
      if (inherit)
        ChoiceChip(
          key: const ValueKey('easy-color-inherit'),
          label: Text(tr('Layoutfarbe')),
          selected: value == null,
          onSelected: (_) => onChanged(null),
        ),
      for (final color in EasyTileColor.values)
        Tooltip(
          message: easyTileColorName(color),
          child: Semantics(
            label: easyTileColorName(color),
            selected: value == color,
            button: true,
            child: InkWell(
              key: ValueKey('easy-color-${color.name}'),
              onTap: () => onChanged(color),
              borderRadius: BorderRadius.circular(24),
              child: Container(
                width: 44,
                height: 44,
                padding: const EdgeInsets.all(4),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: easyTileBackground(color),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: value == color ? Palette.amber : Palette.muted,
                      width: value == color ? 2 : 1,
                    ),
                  ),
                  child: value == color
                      ? Icon(
                          Icons.check,
                          size: 18,
                          color: easyTileForeground(easyTileBackground(color)),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

/// Shared geometry for the editor and the actual panel. Only editor mode
/// enables long-press dragging, live packing, grid guides and drop markers.
class EasyTileGrid extends StatefulWidget {
  const EasyTileGrid({
    super.key,
    required this.layout,
    required this.itemBuilder,
    this.onMove,
    this.availableHeight,
  });

  /// Tablet viewport height, excluding the panel padding. Phones keep their
  /// original geometry; long tablet layouts keep usable targets and scroll.
  final double? availableHeight;
  final EasyLayout layout;
  final Widget Function(BuildContext, int) itemBuilder;
  final void Function(int, int, int)? onMove;

  @override
  State<EasyTileGrid> createState() => _EasyTileGridState();
}

class _EasyDrag {
  const _EasyDrag(this.owner, this.index);
  final Object owner;
  final int index;
}

class _EasyTileGridState extends State<EasyTileGrid> {
  final _surface = GlobalKey();
  int? _dragging;
  (int, int)? _snapTarget;
  Timer? _autoScroll;
  Offset? _pointer;
  Offset _anchor = Offset.zero;
  void Function(Offset)? _hover;

  @override
  void dispose() {
    _autoScroll?.cancel();
    super.dispose();
  }

  void _finish() {
    _autoScroll?.cancel();
    if (mounted) {
      setState(() {
        _dragging = null;
        _snapTarget = null;
        _pointer = null;
      });
    }
  }

  void _scroll() {
    if (!mounted || _pointer == null) return;
    final scroll = Scrollable.maybeOf(context);
    if (scroll == null) return;
    final box = scroll.context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final y = box.globalToLocal(_pointer!).dy;
    final delta = y < 48
        ? -12.0
        : y > box.size.height - 48
        ? 12.0
        : 0.0;
    if (delta == 0) return;
    final position = scroll.position;
    position.jumpTo(
      (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
    _hover?.call(_pointer!);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      const gap = 8.0;
      final pitch = (box.maxWidth + gap) / easyGridUnits;
      // Half-height fifths still need a 44 dp operating target on phones.
      final hasShortFifth = widget.layout.tiles.any(
        (t) => t.size == EasyTileSize.fifth && t.heightUnits == 0.5,
      );
      final naturalRowPitch = math.max(
        pitch * easyQuarterUnits / 2,
        hasShortFifth ? 44 + gap : 0.0,
      );
      final original = packEasyTiles(widget.layout.tiles);
      // Keep each tile's element across hover previews and the saved reorder.
      // The occurrence also supports repeated identical const tile objects.
      final occurrences = <int>[];
      final seen = <EasyTile, int>{};
      for (final tile in widget.layout.tiles) {
        final occurrence = seen[tile] ?? 0;
        occurrences.add(occurrence);
        seen[tile] = occurrence + 1;
      }
      final preview = _dragging != null && _snapTarget != null
          ? widget.layout.moveTile(_dragging!, _snapTarget!.$1, _snapTarget!.$2)
          : widget.layout;
      final packed = packEasyTiles(preview.tiles);
      final rows = packed.fold(
        0,
        (int end, p) => math.max(end, p.y + p.height),
      );
      final minTileRows = original.fold<int>(
        4,
        (height, p) => math.min(height, p.height),
      );
      // Keep the geometry stable while a drag previews additional rows.
      final fittingRows = original.fold(
        0,
        (int end, p) => math.max(end, p.y + p.height),
      );
      final rowPitch = widget.availableHeight != null && fittingRows > 0
          ? math.max(
              (44 + gap) / minTileRows,
              math.min(
                naturalRowPitch,
                (widget.availableHeight! + gap) / fittingRows,
              ),
            )
          : naturalRowPitch;
      // Keep a free drop row reachable while dragging a pin downward.
      final extraRows = _dragging != null ? 4 : 0;
      final height = math.max(48.0, (rows + extraRows) * rowPitch - gap);
      Rect rect(EasyPlacement p) => Rect.fromLTWH(
        p.x * pitch,
        p.y * rowPitch,
        p.width * pitch - gap,
        p.height * rowPitch - gap,
      );
      _hover = (position) {
        if (_dragging == null) return;
        final render = _surface.currentContext!.findRenderObject() as RenderBox;
        final local = render.globalToLocal(position);
        final target = widget.layout.snapTarget(
          _dragging!,
          (local.dx - _anchor.dx) / pitch,
          (local.dy - _anchor.dy) / rowPitch,
        );
        if (target != _snapTarget) {
          HapticFeedback.selectionClick();
          setState(() => _snapTarget = target);
        }
      };
      return DragTarget<_EasyDrag>(
        // Flutter enters the target before calling onDragStarted.
        onWillAcceptWithDetails: (details) =>
            widget.onMove != null &&
            identical(details.data.owner, this) &&
            details.data.index >= 0 &&
            details.data.index < widget.layout.tiles.length,
        onMove: (details) {
          _pointer = details.offset + _anchor;
          _hover?.call(_pointer!);
        },
        onAcceptWithDetails: (_) {
          final from = _dragging;
          final target = _snapTarget;
          _finish();
          if (from != null && target != null) {
            widget.onMove?.call(from, target.$1, target.$2);
          }
        },
        builder: (context, candidates, rejected) => SizedBox(
          key: _surface,
          width: box.maxWidth,
          height: height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (widget.onMove != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(painter: _EasyGuidePainter(rowPitch)),
                  ),
                ),
              for (final p in packed)
                AnimatedPositioned(
                  key: ValueKey((
                    widget.layout.tiles[p.index],
                    occurrences[p.index],
                  )),
                  duration: _dragging == null
                      ? Duration.zero
                      : const Duration(milliseconds: 150),
                  left: rect(p).left,
                  top: rect(p).top,
                  width: rect(p).width,
                  height: rect(p).height,
                  child: Builder(
                    builder: (context) {
                      final index = p.index;
                      final child = widget.itemBuilder(context, index);
                      if (widget.onMove == null) return child;
                      return LongPressDraggable<_EasyDrag>(
                        key: ValueKey('easy-drag-$index'),
                        data: _EasyDrag(this, index),
                        maxSimultaneousDrags: 1,
                        dragAnchorStrategy: (draggable, context, position) {
                          final render =
                              context.findRenderObject() as RenderBox;
                          _anchor = render.globalToLocal(position);
                          return _anchor;
                        },
                        onDragStarted: () {
                          setState(() {
                            _dragging = index;
                            _snapTarget = (
                              original[index].x,
                              original[index].y,
                            );
                          });
                          _autoScroll = Timer.periodic(
                            const Duration(milliseconds: 40),
                            (_) => _scroll(),
                          );
                        },
                        onDragUpdate: (details) =>
                            _pointer = details.globalPosition,
                        onDragEnd: (_) => _finish(),
                        feedback: Material(
                          elevation: 12,
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                          child: SizedBox(
                            width: rect(p).width,
                            height: rect(p).height,
                            child: Opacity(opacity: 0.9, child: child),
                          ),
                        ),
                        childWhenDragging: const SizedBox.shrink(),
                        child: child,
                      );
                    },
                  ),
                ),
              if (_dragging != null && _snapTarget != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      key: const ValueKey('easy-snap-guides'),
                      painter: _EasySnapPainter(rect(packed[_dragging!])),
                    ),
                  ),
                ),
              if (_dragging != null && _snapTarget != null)
                Positioned.fromRect(
                  rect: rect(packed[_dragging!]),
                  child: IgnorePointer(
                    child: Container(
                      key: const ValueKey('easy-drop-position'),
                      decoration: BoxDecoration(
                        color: Palette.amber.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Palette.amber, width: 2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _EasyGuidePainter extends CustomPainter {
  const _EasyGuidePainter(this.rowPitch);
  final double rowPitch;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Palette.line
      ..strokeWidth = 0.5;
    for (final edge in easySnapEdges.skip(1).take(easySnapEdges.length - 2)) {
      final dx = (size.width + 8) * edge / easyGridUnits - 4;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), paint);
    }
    for (var y = rowPitch - 4; y < size.height; y += rowPitch) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        paint..color = Palette.line.withValues(alpha: 0.4),
      );
    }
  }

  @override
  bool shouldRepaint(_EasyGuidePainter old) => old.rowPitch != rowPitch;
}

class _EasySnapPainter extends CustomPainter {
  const _EasySnapPainter(this.target);
  final Rect target;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Palette.amber.withValues(alpha: 0.8)
      ..strokeWidth = 0.75;
    for (final x in [target.left, target.right]) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (final y in [target.top, target.bottom]) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_EasySnapPainter old) => old.target != target;
}
