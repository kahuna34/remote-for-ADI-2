import 'host_interface.dart';

import 'package:flutter/widgets.dart';

enum AuxiliaryWindow { analyzer, player }

/// The UI knows only this capability; engine and platform details live in host/.
abstract class DesktopWindows extends ChangeNotifier {
  bool isOpen(AuxiliaryWindow kind) => false;
  Future<void> open(AuxiliaryWindow kind);
}

class DesktopWindowScope extends InheritedNotifier<DesktopWindows> {
  const DesktopWindowScope({
    super.key,
    required DesktopWindows windows,
    required super.child,
  }) : super(notifier: windows);
  DesktopWindows get windows => notifier!;

  static DesktopWindows? maybeOf(BuildContext context) => hostHasInterface
      ? context
            .dependOnInheritedWidgetOfExactType<DesktopWindowScope>()
            ?.windows
      : null;
}
