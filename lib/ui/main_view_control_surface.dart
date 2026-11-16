import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../easy/easy_layout.dart';
import '../main_view_colors.dart';
import 'easy_tile_grid.dart';
import 'theme.dart';

/// Only the color editor installs this scope. Gestures never reach device controls.
class MainViewColorScope extends InheritedWidget {
  const MainViewColorScope({
    super.key,
    required this.onSelect,
    required this.onOutputSelected,
    required super.child,
  });

  final ValueChanged<MainViewControl> onSelect;
  final ValueChanged<int> onOutputSelected;

  static MainViewColorScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MainViewColorScope>();

  @override
  bool updateShouldNotify(MainViewColorScope oldWidget) =>
      oldWidget.onSelect != onSelect ||
      oldWidget.onOutputSelected != onOutputSelected;
}

/// Keeps each real control's geometry, typography and active-state styling.
class MainViewControlSurface extends StatelessWidget {
  const MainViewControlSurface({
    super.key,
    required this.id,
    this.materialKey,
    required this.color,
    required this.shape,
    this.clipBehavior = Clip.none,
    required this.child,
  });

  final MainViewControl? id;
  final Key? materialKey;
  final Color color;
  final RoundedRectangleBorder shape;
  final Clip clipBehavior;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final custom = id == null
        ? EasyTileColor.graphite
        : AppSettings.instance.mainViewColor(id!);
    final tinted = custom != EasyTileColor.graphite;
    final base = easyTileBackground(custom);
    // Active red/amber outlines retain priority over the chosen tint.
    final active = shape.side.color != Palette.line;
    final material = Material(
      key: materialKey,
      color: tinted
          ? (active
                ? Color.alphaBlend(
                    shape.side.color.withValues(alpha: 0.14),
                    base,
                  )
                : base)
          : color,
      shape: tinted && !active
          ? shape.copyWith(
              side: BorderSide(color: Color.lerp(base, Colors.white, 0.22)!),
            )
          : shape,
      clipBehavior: clipBehavior,
      child: child,
    );
    final editor = MainViewColorScope.maybeOf(context);
    if (id == null || editor == null) return material;
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => editor.onSelect(id!),
        child: IgnorePointer(child: material),
      ),
    );
  }
}
