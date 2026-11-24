import 'package:flutter/material.dart';

import '../desktop/host_interface.dart';
import 'eq_display_mode.dart';

const double tabletBreakpoint = 600;
const double tabletContentWidth = 720;
const double tabletColumnsBreakpoint = 760;
const double tabletNavigationRailWidth = 88;

/// Grundgröße der Ausgangsseite im Desktop-Programm (gleichmäßig skaliert).
/// Bei 480 × 760 füllt der Ring die Breite zwischen Bass und Treble fast
/// ganz aus, ohne dass Tasten oder Texte überlaufen.
const Size desktopOutputSize = Size(480, 760);

/// Width of either output column after the rail and central divider.
double tabletOutputColumnWidth(double width) =>
    (width - tabletNavigationRailWidth - 1) / 2;

/// Telefon oder Tablet: am Handy/Tablet nach der kürzeren Seite. Im
/// Desktop-Programm nur nach der Breite – sonst sprang die Ansicht beim
/// Zusammenschieben unter 600 px Höhe auf Telefon-Geometrie (volle Breite)
/// und beim Aufziehen zurück.
bool isTablet(BuildContext context) => hostHasInterface
    ? MediaQuery.sizeOf(context).width >= tabletBreakpoint
    : MediaQuery.sizeOf(context).shortestSide >= tabletBreakpoint;

bool isTabletLandscape(BuildContext context) =>
    isTablet(context) &&
    MediaQuery.orientationOf(context) == Orientation.landscape;

/// Keeps portrait tablet pages readable while retaining the phone geometry.
class TabletContent extends StatelessWidget {
  const TabletContent({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isTablet(context)) return child;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: tabletContentWidth),
        child: child,
      ),
    );
  }
}

/// The same page sections form two independently scrollable tablet columns.
class AdaptivePageList extends StatelessWidget {
  const AdaptivePageList({
    super.key,
    required this.children,
    this.padding,
    this.splitAt,
  });
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;
  final int? splitAt;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (isTabletLandscape(context) &&
          constraints.maxWidth >= tabletColumnsBreakpoint) {
        final split = splitAt ?? (children.length / 2).ceil();
        return Row(
          key: const ValueKey('tablet-page-columns'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ListView(
                padding: padding,
                children: children.take(split).toList(),
              ),
            ),
            Expanded(
              child: ListView(
                padding: padding,
                children: children.skip(split).toList(),
              ),
            ),
          ],
        );
      }
      return TabletContent(
        child: ListView(padding: padding, children: children),
      );
    },
  );
}

/// Applies device-wide orientation policy above all routes and dialogs.
class TabletOrientation extends StatefulWidget {
  const TabletOrientation({super.key, required this.child});
  final Widget child;

  @override
  State<TabletOrientation> createState() => _TabletOrientationState();
}

class _TabletOrientationState extends State<TabletOrientation> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    EqDisplayMode.setTablet(isTablet(context));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
