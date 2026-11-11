import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/outputs_page.dart';
import 'package:adi2_remote/ui/player_bar.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends Adi2Controller {
  _Controller(this.variant) : values = offlineDefaults(variant) {
    state = ConnState.connected;
  }

  @override
  final Adi2Variant variant;
  final Map<int, int> values;

  @override
  int? value(int address, int index) => values[address << 8 | index];
  @override
  int valueOr(int address, int index, int fallback) =>
      value(address, index) ?? fallback;

  void connection(ConnState next) {
    state = next;
    notifyListeners();
  }
}

void main() {
  for (final variant in Adi2Variant.values) {
    testWidgets('Reiter, Start und Wiederverbinden ${variant.name}', (
      tester,
    ) async {
      final previous = AppLang.instance.language;
      AppLang.instance.language = AppLanguage.de;
      addTearDown(() => AppLang.instance.language = previous);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final ctrl = _Controller(variant);
      final np = NowPlaying();
      addTearDown(ctrl.dispose);
      addTearDown(np.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: HomePage(ctrl: ctrl, np: np),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<NavigationDestination>(
              find.byType(NavigationDestination),
            )
            .map((d) => d.label),
        [
          if (variant.hasInput) 'Eingang',
          'Ausgänge',
          'Gerät',
          'Setups',
          'Status',
        ],
      );
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        variant.hasInput ? 1 : 0,
      );
      expect(find.byType(OutputsPage), findsOneWidget);
      expect(find.byType(PlayerBar), findsOneWidget);
      if (variant.hasInput) {
        final destination = find.widgetWithText(
          NavigationDestination,
          'Eingang',
        );
        expect(
          find.descendant(of: destination, matching: find.byIcon(Icons.input)),
          findsWidgets,
        );
        await tester.tap(destination);
        await tester.pumpAndSettle();
        expect(find.byType(InputPage), findsOneWidget);
        expect(find.byType(PlayerBar), findsNothing);
        await tester.tap(
          find.widgetWithText(NavigationDestination, 'Ausgänge'),
        );
        await tester.pumpAndSettle();
      }
      // Die digitale Mini-Anzeige im Fallback der Player-Leiste öffnet Status.
      final mini = find
          .descendant(
            of: find.byType(PlayerBar),
            matching: find.byType(InkWell),
          )
          .first;
      await tester.tap(mini);
      await tester.pumpAndSettle();
      expect(find.byType(StatusPage), findsOneWidget);
      expect(find.byType(PlayerBar), findsNothing);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        variant.hasInput ? 4 : 3,
      );
      ctrl.connection(ConnState.searching);
      await tester.pumpAndSettle();
      expect(find.byType(ConnectPage), findsOneWidget);
      ctrl.connection(ConnState.connected);
      await tester.pumpAndSettle();
      expect(find.byType(OutputsPage), findsOneWidget);
      expect(find.byType(PlayerBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
