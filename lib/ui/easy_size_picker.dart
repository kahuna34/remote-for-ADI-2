import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../easy/easy_layout.dart';
import '../l10n/l10n.dart';
import 'theme.dart';

/// A shared, responsive scale keeps all size previews comparable.
class EasySizePicker extends StatefulWidget {
  const EasySizePicker({
    super.key,
    required this.type,
    required this.size,
    required this.height,
    required this.onChanged,
    this.previewBuilder,
  });
  final Widget Function(EasyTileSize, double)? previewBuilder;
  final EasyTileType type;
  final EasyTileSize size;
  final double height;
  final void Function(EasyTileSize, double) onChanged;

  @override
  State<EasySizePicker> createState() => _EasySizePickerState();
}

class _EasySizePickerState extends State<EasySizePicker> {
  final ScrollController _widths = ScrollController();
  bool _positioned = false;
  final GlobalKey _selection = GlobalKey();

  void _showSelection(double columnWidth) {
    if (_positioned) return;
    _positioned = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_widths.hasClients) return;
      final position = _widths.position;
      // Align to column boundaries so two complete options remain visible.
      final target = 40 + (widget.size.index - 1) * columnWidth;
      _widths.jumpTo(target.clamp(0.0, position.maxScrollExtent));
      final selectionContext = _selection.currentContext;
      if (selectionContext != null) {
        Scrollable.ensureVisible(
          selectionContext,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      }
    });
  }

  @override
  void dispose() {
    _widths.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, available) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('Quadrat = ¼ Breite · Höhe 1'),
            style: ts(12, color: Palette.muted),
          ),
          const SizedBox(height: 8),
          if (available.hasBoundedHeight) Expanded(child: _matrix(context)),
          if (!available.hasBoundedHeight) _matrix(context),
          const SizedBox(height: 4),
          Text(
            tr('Breiten: seitlich wischen'),
            style: ts(11, color: Palette.muted),
          ),
        ],
      ),
    );
  }

  Widget _matrix(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columnWidth = constraints.maxWidth * 0.4;
      // Reserve room for column labels, cell padding and the scrollbar.
      // Keep touch targets usable when the screen is too short.
      final headerHeight =
          32.0 * MediaQuery.textScalerOf(context).scale(12) / 12;
      final rowHeight = constraints.hasBoundedHeight
          ? math.max(64.0, (constraints.maxHeight - headerHeight - 12) / 4)
          : columnWidth * 0.6;
      _showSelection(columnWidth);
      return Stack(
        fit: constraints.hasBoundedHeight ? StackFit.expand : StackFit.loose,
        children: [
          ScrollbarTheme(
            data: ScrollbarThemeData(
              thumbColor: WidgetStatePropertyAll(
                Palette.amber.withValues(alpha: 0.7),
              ),
              trackColor: const WidgetStatePropertyAll(Palette.line),
            ),
            child: Scrollbar(
              controller: _widths,
              thumbVisibility: true,
              trackVisibility: true,
              thickness: 5,
              radius: const Radius.circular(3),
              scrollbarOrientation: ScrollbarOrientation.bottom,
              child: SingleChildScrollView(
                key: const ValueKey('easy-size-scroll'),
                scrollDirection: Axis.horizontal,
                controller: _widths,
                padding: const EdgeInsets.only(bottom: 12),
                child: SingleChildScrollView(
                  key: const ValueKey('easy-size-vertical-scroll'),
                  child: Column(
                    children: [
                      SizedBox(
                        height: headerHeight,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 40,
                              child: Text(
                                tr('Höhe'),
                                style: ts(11),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            for (final size in EasyTileSize.values)
                              SizedBox(
                                width: columnWidth,
                                child: Center(
                                  child: Text(
                                    size == EasyTileSize.full
                                        ? tr('voll')
                                        : size.fraction,
                                    style: ts(12),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      for (final h in const [0.5, 1.0, 1.5, 2.0])
                        Row(
                          key: ValueKey('easy-size-row-$h'),
                          children: [
                            SizedBox(
                              width: 40,
                              child: Text('$h', style: ts(12)),
                            ),
                            for (final s in EasyTileSize.values)
                              _cell(s, h, columnWidth - 4, rowHeight - 4),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            bottom: 12,
            width: 20,
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _widths,
                builder: (context, child) => Opacity(
                  opacity:
                      !_widths.hasClients ||
                          !_widths.position.hasContentDimensions ||
                          _widths.position.extentAfter > 1
                      ? 1
                      : 0,
                  child: child,
                ),
                child: const DecoratedBox(
                  key: ValueKey('easy-size-scroll-hint'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.transparent, Palette.surf],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _cell(EasyTileSize s, double h, double width, double cellHeight) {
    final enabled =
        EasyTile.heightsFor(widget.type).contains(h) &&
        EasyTile.supportsShape(widget.type, s, h);
    final selected = enabled && widget.size == s && widget.height == h;
    final label = trf('Breite {w} · Höhe {h}', {
      'w': s == EasyTileSize.full ? tr('voll') : s.fraction,
      'h': h,
    });
    return Semantics(
      label: label,
      button: true,
      enabled: enabled,
      selected: selected,
      child: Tooltip(
        message: enabled ? label : '$label · ${tr('Nicht verfügbar')}',
        child: Padding(
          key: selected ? _selection : null,
          padding: const EdgeInsets.all(2),
          child: InkWell(
            key: ValueKey('easy-size-${s.name}-$h'),
            onTap: enabled ? () => widget.onChanged(s, h) : null,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: width,
              height: cellHeight,
              decoration: BoxDecoration(
                color: selected ? Palette.amber.withValues(alpha: 0.12) : null,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: selected ? Palette.amber : Palette.line,
                  width: selected ? 2 : 1,
                ),
              ),
              child: Center(
                child: enabled && widget.previewBuilder != null
                    ? SizedBox(
                        key: ValueKey('easy-size-shape-${s.name}-$h'),
                        width: width * 0.9,
                        height: math.min(width * 0.45, cellHeight * 0.9),
                        child: widget.previewBuilder!(s, h),
                      )
                    : CustomPaint(
                        key: ValueKey('easy-size-shape-${s.name}-$h'),
                        size: Size(
                          width * 0.9,
                          math.min(width * 0.45, cellHeight * 0.9),
                        ),
                        painter: _SizeShapePainter(s.units, h, enabled),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SizeShapePainter extends CustomPainter {
  const _SizeShapePainter(this.width, this.height, this.enabled);
  final bool enabled;
  final int width;
  final double height;
  @override
  void paint(Canvas canvas, Size size) {
    final guide = Paint()
      ..color = Palette.line
      ..strokeWidth = 0.5;
    for (var x = 0; x <= 4; x++) {
      canvas.drawLine(
        Offset(size.width * x / 4, 0),
        Offset(size.width * x / 4, size.height),
        guide,
      );
    }
    for (var y = 0; y <= 4; y++) {
      canvas.drawLine(
        Offset(0, size.height * y / 4),
        Offset(size.width, size.height * y / 4),
        guide,
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          0,
          0,
          size.width * width / easyGridUnits,
          size.width / 4 * height,
        ),
        const Radius.circular(2),
      ),
      Paint()
        ..color = enabled
            ? Palette.amber.withValues(alpha: 0.8)
            : Palette.muted.withValues(alpha: 0.3),
    );
  }

  @override
  bool shouldRepaint(_SizeShapePainter old) =>
      width != old.width || height != old.height || enabled != old.enabled;
}
