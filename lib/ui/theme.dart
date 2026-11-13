// Gestaltung: anodisiertes Graphit, ein Akzent (Signal-Bernstein), Rot nur
// für Grenzen und Mute. Schrift: Archivo (variabel: Breite + Stärke).

import 'package:flutter/material.dart';

import 'responsive_layout.dart';

abstract final class Palette {
  static const bg = Color(0xFF1D2329);
  static const surf = Color(0xFF272E36);
  static const surf2 = Color(0xFF313943);
  static const line = Color(0xFF3A434D);
  static const text = Color(0xFFE6E9EC);
  static const muted = Color(0xFF98A2AD);
  static const amber = Color(0xFFF0A73A);
  static const green = Color(0xFF8FCB6B);
  static const red = Color(0xFFE5484D);

  /// EQ-Bänder 1–5, Bass, Treble.
  static const bands = [
    Color(0xFFEF8E5B),
    Color(0xFFE8C547),
    Color(0xFF8FCB6B),
    Color(0xFF4CC3B8),
    Color(0xFF6AA6F2),
    Color(0xFFA48CF0),
    Color(0xFFE58BC4),
  ];
}

/// Textstil mit Archivo-Achsen (Stärke 100–900, Breite 62–125).
TextStyle ts(
  double size, {
  double weight = 400,
  double width = 100,
  Color color = Palette.text,
  bool narrow = false,
  double? height,
  double? spacing,
}) {
  return TextStyle(
    fontFamily: narrow ? 'ArchivoNarrow' : 'Archivo',
    fontSize: size,
    color: color,
    height: height,
    letterSpacing: spacing,
    fontWeight: _w(weight),
    fontFeatures: const [FontFeature.tabularFigures()],
    fontVariations: [
      FontVariation('wght', weight),
      if (!narrow) FontVariation('wdth', width),
    ],
  );
}

/// Einheitliche Beschriftung der Bedientasten auf der Hauptansicht.
TextStyle buttonLabelStyle(BuildContext context) =>
    ts(isTablet(context) ? 15 : 14, weight: 600);

/// Zweite Zeile: neutrale Statusangabe oder aktiver/eingestellter Wert.
TextStyle buttonStatusStyle(BuildContext context, {bool active = false}) => ts(
  isTablet(context) ? 13 : 12,
  weight: 600,
  narrow: true,
  color: active ? Palette.amber : Palette.text,
);

FontWeight _w(double w) =>
    FontWeight.values[((w / 100).round() - 1).clamp(0, 8)];

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    surface: Palette.bg,
    primary: Palette.amber,
    onPrimary: Palette.bg,
    secondary: Palette.amber,
    error: Palette.red,
    onSurface: Palette.text,
    surfaceContainerHighest: Palette.surf2,
    surfaceContainer: Palette.surf,
    outline: Palette.line,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: Palette.bg,
    textTheme: base.textTheme.apply(
      fontFamily: 'Archivo',
      bodyColor: Palette.text,
      displayColor: Palette.text,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Palette.bg,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: ts(20, weight: 600),
    ),
    navigationBarTheme: NavigationBarThemeData(
      // Niedriger als der Standard (80), damit über der Leiste Platz für
      // einen Abstand zu den Knöpfen bleibt.
      height: 64,
      backgroundColor: Palette.surf,
      indicatorColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          color: s.contains(WidgetState.selected)
              ? Palette.amber
              : Palette.muted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => ts(
          12,
          weight: s.contains(WidgetState.selected) ? 600 : 500,
          color: s.contains(WidgetState.selected)
              ? Palette.text
              : Palette.muted,
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(
      titleTextStyle: ts(15, weight: 500),
      subtitleTextStyle: ts(13, color: Palette.muted),
      iconColor: Palette.muted,
    ),
    dividerTheme: const DividerThemeData(color: Palette.line, space: 1),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Palette.bg : Palette.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Palette.amber : Palette.surf2,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: Palette.amber,
      inactiveTrackColor: Palette.surf2,
      thumbColor: Palette.amber,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Palette.surf,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: Palette.line,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Palette.surf,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: ts(20, weight: 600),
      contentTextStyle: ts(15, color: Palette.muted, height: 1.4),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Palette.amber,
        foregroundColor: Palette.bg,
        textStyle: ts(15, weight: 600),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Palette.text,
        textStyle: ts(15, weight: 600),
      ),
    ),
  );
}

/// Fläche mit Rundung, wie die Karten im Entwurf.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Palette.surf,
      borderRadius: BorderRadius.circular(14),
    ),
    padding: padding,
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}
