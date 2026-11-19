import 'package:flutter/material.dart';

import '../analyzer/header_content.dart';
import 'theme.dart';

/// Kopfbereich zum Durchblättern: Der Inhalt folgt dem Finger wie eine Seite,
/// die Nachbarseite schiebt sich daneben herein. Beim Loslassen wird ab einem
/// Drittel der Breite oder bei schnellem Wischen umgeschaltet, sonst federt
/// der Bereich zurück. Nur waagerechte Gesten; senkrechtes Scrollen und
/// Tipps auf Knöpfe bleiben unberührt.
class HeaderSwipe extends StatefulWidget {
  const HeaderSwipe({
    super.key,
    required this.content,
    required this.onChanged,
    required this.child,
    this.preview,
  });
  final HeaderContent content;
  final ValueChanged<HeaderContent> onChanged;
  final Widget child;

  /// Vorschau der Nachbarseite während des Ziehens. Ohne Vorschau erscheint
  /// eine leere Fläche.
  final Widget Function(HeaderContent content)? preview;

  static const order = [
    HeaderContent.status,
    HeaderContent.player,
    HeaderContent.analyzer,
  ];

  @override
  State<HeaderSwipe> createState() => _HeaderSwipeState();
}

class _HeaderSwipeState extends State<HeaderSwipe>
    with SingleTickerProviderStateMixin {
  late final AnimationController _settle = AnimationController.unbounded(
    vsync: this,
  )..addListener(() => setState(() => _dx = _settle.value));
  double _dx = 0;
  double _width = 1;

  HeaderContent? _neighbor(int direction) {
    final index = HeaderSwipe.order.indexOf(widget.content);
    if (index < 0) return null;
    final next = index + direction;
    if (next < 0 || next >= HeaderSwipe.order.length) return null;
    return HeaderSwipe.order[next];
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    _settle.stop();
    var dx = _dx + (d.primaryDelta ?? 0);
    // Am Ende der Reihe gibt es keine Nachbarseite: nur leicht nachgeben.
    if (_neighbor(dx < 0 ? 1 : -1) == null) {
      dx = dx.clamp(-_width * 0.12, _width * 0.12);
    }
    setState(() => _dx = dx);
  }

  Future<void> _end(DragEndDetails d) async {
    final velocity = d.primaryVelocity ?? 0;
    final direction = _dx < 0 ? 1 : -1;
    final next = _neighbor(direction);
    final flick = velocity.abs() > 500 && (velocity < 0) == (direction == 1);
    if (next != null && (_dx.abs() > _width / 3 || flick)) {
      await _animateTo(-direction * _width);
      if (!mounted) return;
      widget.onChanged(next);
      setState(() => _dx = 0);
    } else {
      await _animateTo(0);
    }
  }

  Future<void> _animateTo(double target) async {
    _settle.value = _dx;
    await _settle.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      _width = box.maxWidth.isFinite && box.maxWidth > 0 ? box.maxWidth : 1;
      final neighbor = _dx == 0 ? null : _neighbor(_dx < 0 ? 1 : -1);
      return GestureDetector(
        key: const ValueKey('header-swipe'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: _update,
        onHorizontalDragEnd: _end,
        onHorizontalDragCancel: () => _animateTo(0),
        child: ClipRect(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Transform.translate(
                offset: Offset(_dx, 0),
                child: KeyedSubtree(
                  key: ValueKey(widget.content),
                  child: widget.child,
                ),
              ),
              if (neighbor != null)
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: _dx < 0 ? _width + _dx : _dx - _width,
                  width: _width,
                  child: IgnorePointer(
                    child: KeyedSubtree(
                      key: ValueKey('preview-${neighbor.name}'),
                      child: widget.preview?.call(neighbor) ?? const SizedBox(),
                    ),
                  ),
                ),
              // Die Bereiche lassen unten acht Pixel frei; dort sitzen die
              // Punkte, damit auf kurzen Telefonen nichts schrumpft.
              Positioned(
                left: 0,
                right: 0,
                bottom: 1,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final content in HeaderSwipe.order)
                      Container(
                        key: ValueKey('header-dot-${content.name}'),
                        width: 4,
                        height: 4,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: content == widget.content
                              ? Palette.amber
                              : Palette.muted.withValues(alpha: 0.4),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
