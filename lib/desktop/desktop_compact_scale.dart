import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../ui/theme.dart';
import 'host_interface.dart';

/// Grundgröße der Kompakt-Ansicht im Desktop-Programm (Inhalt eines
/// 640 × 800-Fensters unter Windows, vom Nutzer als passend gewählt).
const Size desktopCompactSize = Size(624, 761);

/// Kompakt-Ansicht am Desktop: Die ganze Oberfläche wird in einer festen
/// Grundgröße aufgebaut und als Ganzes gleichmäßig auf das Fenster skaliert –
/// Kopfbereich, Ring, Tasten, Schrift und Leiste im selben Verhältnis. Beim
/// Ziehen der Fenstergröße ändert sich nur der Maßstab, nicht die Anordnung.
class DesktopCompactScale extends StatelessWidget {
  const DesktopCompactScale({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppSettings.instance,
    builder: (context, _) {
      if (!hostHasInterface || !AppSettings.instance.linuxCompact) {
        return child;
      }
      final media = MediaQuery.of(context);
      // Ganze Fensterfläche füllen; der Inhalt steht mittig.
      return SizedBox.expand(
        child: ColoredBox(
          color: Palette.bg,
          child: FittedBox(
            key: const ValueKey('desktop-compact-scale'),
            child: SizedBox.fromSize(
              size: desktopCompactSize,
              child: MediaQuery(
                data: media.copyWith(
                  size: desktopCompactSize,
                  padding: EdgeInsets.zero,
                  viewPadding: EdgeInsets.zero,
                  viewInsets: EdgeInsets.zero,
                ),
                child: child,
              ),
            ),
          ),
        ),
      );
    },
  );
}
