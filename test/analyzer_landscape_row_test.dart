import 'package:adi2_remote/analyzer/analyzer_controller.dart';
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final language in AppLanguage.values) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('Tablet landscape header $language text scale $scale', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        await AppSettings.instance.load();
        await AppSettings.instance.setAutoFullscreenEq(false);
        final previous = AppLang.instance.language;
        AppLang.instance.language = language;
        addTearDown(() => AppLang.instance.language = previous);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);
        final controller = AnalyzerController();
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Row(
                children: [
                  const Expanded(child: SizedBox()),
                  Expanded(
                    child: AnalyzerPanel(
                      controller: controller,
                      expanded: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        controller.frame = AnalyzerFrame(
          sampleRate: 48000,
          spectrum: List.filled(2049, 0.1),
          peak: [-6, -6],
          rms: [-12, -12],
          clipped: [false, false],
        );
        controller.status = AnalyzerStatus.running;
        controller.notifyListeners();
        await tester.pump();

        void checkHeader(IconData fullscreen) {
          final tool = find.byKey(const ValueKey('analyzer-tool'));
          final settings = find.byIcon(Icons.settings_outlined);
          final expand = find.byIcon(fullscreen);
          expect(
            tester.getCenter(tool).dy,
            closeTo(tester.getCenter(settings).dy, .01),
          );
          expect(
            tester.getCenter(tool).dy,
            closeTo(tester.getCenter(expand).dy, .01),
          );
          expect(
            tester.getRect(tool).right,
            lessThanOrEqualTo(tester.getRect(settings).left),
          );
          for (final icon in [settings, expand]) {
            final button = find.ancestor(
              of: icon,
              matching: find.byType(IconButton),
            );
            expect(tester.getSize(button), const Size(40, 40));
            expect(tester.widget<IconButton>(button).iconSize, 18);
          }
          final levels = find.byKey(
            const ValueKey('analyzer-fullscreen-levels'),
          );
          expect(
            tester
                .getRect(
                  find.ancestor(of: expand, matching: find.byType(IconButton)),
                )
                .right,
            closeTo(tester.getRect(levels).right, .01),
          );
          final resetSize = tester.getSize(
            find.byKey(const ValueKey('analyzer-peak-reset')),
          );
          final peakSize = tester.getSize(
            find.byKey(const ValueKey('analyzer-peak-hold')),
          );
          expect(resetSize.height, peakSize.height);
          expect(resetSize.width, isNot(peakSize.width));
          expect(tester.takeException(), isNull);
        }

        checkHeader(Icons.fullscreen);
        await tester.tap(find.byIcon(Icons.fullscreen));
        await tester.pumpAndSettle();
        checkHeader(Icons.fullscreen_exit);
        await tester.pumpWidget(const SizedBox());
        // Nachlauf des Analyzers (500 ms) ablaufen lassen.
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
      });
    }
  }
}
