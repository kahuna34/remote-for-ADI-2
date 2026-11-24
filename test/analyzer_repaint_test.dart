import 'package:adi2_remote/analyzer/analyzer_controller.dart';
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

AnalyzerFrame _frame(double value, {int sampleRate = 48000}) => AnalyzerFrame(
  sampleRate: sampleRate,
  spectrum: List.filled(1025, value),
  peak: [value, value - 6],
  rms: [value - 12, value - 18],
  clipped: [value >= 0, false],
);

void main() {
  for (final mode in [
    'compact',
    'header',
    'extra',
    'fullscreen',
    'spectrumOnly',
  ]) {
    testWidgets('30 audio frames only paint: $mode', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.instance.load();
      await AppSettings.instance.setAutoFullscreenEq(false);
      await AppSettings.instance.setAnalyzerMainView(AnalyzerMainView.both);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.reset);
      final controller = AnalyzerController()
        ..status = AnalyzerStatus.running
        ..frame = _frame(-20);
      addTearDown(controller.dispose);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: mode != 'compact'
                ? SizedBox(
                    height: mode == 'header' ? 172 : 600,
                    child: AnalyzerPanel(
                      controller: controller,
                      expanded: mode == 'extra',
                    ),
                  )
                : SizedBox(
                    height: 172,
                    child: AnalyzerDisplay(
                      controller: controller,
                      compact: true,
                    ),
                  ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (mode == 'fullscreen' || mode == 'spectrumOnly') {
        await tester.tap(find.byIcon(Icons.fullscreen));
        await tester.pumpAndSettle();
        if (mode == 'spectrumOnly') {
          await tester.tap(find.byIcon(Icons.hide_source));
          await tester.pumpAndSettle();
        }
      }
      // Panel startup is allowed to change status; establish steady-state data.
      controller.status = AnalyzerStatus.running;
      controller.frame = _frame(-20);
      controller.notifyListeners();
      await tester.pumpAndSettle();
      final plot = find.byKey(const ValueKey('analyzer-spectrum'));
      final grid = find.byKey(const ValueKey('analyzer-spectrum-grid'));
      final plotPainter = tester.widget<CustomPaint>(plot).painter!;
      final gridPainter = tester.widget<CustomPaint>(grid).painter!;
      final scale = (plotPainter as dynamic).scale;
      final gridRender = tester.renderObject(grid);
      final moving = <RenderObject>{tester.renderObject(plot)};
      for (final bar in find.byType(AnalyzerLevelBar).evaluate()) {
        moving.add(
          tester.renderObject(
            find.descendant(
              of: find.byWidget(bar.widget),
              matching: find.byType(CustomPaint),
            ),
          ),
        );
      }
      for (var channel = 0; channel < 2; channel++) {
        for (var metric = 0; metric < 2; metric++) {
          final number = find.byKey(
            ValueKey('analyzer-number-$channel-$metric'),
          );
          if (number.evaluate().isNotEmpty) {
            moving.add(
              tester.renderObject(
                find.descendant(of: number, matching: find.byType(CustomPaint)),
              ),
            );
          }
        }
      }
      final builds = <String, int>{};
      var layouts = 0, gridPaints = 0, semanticsUpdates = 0;
      final paints = <RenderObject, int>{};
      final previousBuild = debugOnRebuildDirtyWidget;
      final previousPaint = debugOnProfilePaint;
      final previousPrint = debugPrint;
      final previousLayouts = debugPrintLayouts;
      final semanticsOwner =
          tester.binding.rootPipelineOwner.semanticsOwner ??
          tester.binding.renderViews.first.owner!.semanticsOwner!;
      void onSemantics() => semanticsUpdates++;
      semanticsOwner.addListener(onSemantics);
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        final name = element.widget.runtimeType.toString();
        builds.update(name, (count) => count + 1, ifAbsent: () => 1);
      };
      debugOnProfilePaint = (renderObject) {
        paints.update(renderObject, (count) => count + 1, ifAbsent: () => 1);
        if (renderObject == gridRender) {
          gridPaints++;
        }
      };
      debugPrintLayouts = true;
      debugPrint = (message, {wrapWidth}) {
        if (message?.startsWith('Laying out') == true) {
          layouts++;
        } else {
          previousPrint(message, wrapWidth: wrapWidth);
        }
      };
      try {
        for (var i = 0; i < 30; i++) {
          // Include clipping and differing string widths; none may affect layout.
          controller.frame = _frame(i.isEven ? -120 : i.toDouble() - 20);
          controller.spectrum.update(controller.frame!.spectrum, 1 / 30);
          controller.bands.update(
            List.filled(controller.bandResolution.count, -i.toDouble()),
            1 / 30,
          );
          controller.diagnostics = {'message': 'Capture frame $i'};
          controller.notifyListeners();
          await tester.pump(const Duration(milliseconds: 34));
          expect(
            identical(tester.widget<CustomPaint>(plot).painter, plotPainter),
            isTrue,
          );
          expect(
            identical(tester.widget<CustomPaint>(grid).painter, gridPainter),
            isTrue,
          );
        }
        expect(builds, isEmpty, reason: 'Audio rebuilt widgets: $builds');
        expect(layouts, 0);
        expect(semanticsUpdates, 0);
        expect(gridPaints, 0);
        for (final renderObject in moving) {
          expect(paints[renderObject], 30, reason: '$renderObject');
        }
      } finally {
        debugOnRebuildDirtyWidget = previousBuild;
        debugOnProfilePaint = previousPaint;
        debugPrintLayouts = previousLayouts;
        debugPrint = previousPrint;
        semanticsOwner.removeListener(onSemantics);
      }
      // Status changes keep cached axes; geometry/settings changes invalidate them.
      controller.status = AnalyzerStatus.silent;
      controller.notifyListeners();
      await tester.pump();
      expect(
        identical(
          (tester.widget<CustomPaint>(plot).painter as dynamic).scale,
          scale,
        ),
        isTrue,
      );
      await AppSettings.instance.setAnalyzerRange(100);
      await tester.pump();
      final nextScale =
          (tester.widget<CustomPaint>(plot).painter as dynamic).scale;
      expect(identical(nextScale, scale), isFalse);
      tester.view.physicalSize = const Size(1200, 800);
      await tester.pumpAndSettle();
      expect(
        identical(
          (tester.widget<CustomPaint>(plot).painter as dynamic).scale,
          nextScale,
        ),
        isFalse,
      );
      final resizedScale =
          (tester.widget<CustomPaint>(plot).painter as dynamic).scale;
      controller.setBars(!controller.bars);
      await tester.pump();
      final barScale =
          (tester.widget<CustomPaint>(plot).painter as dynamic).scale;
      expect(identical(barScale, resizedScale), isFalse);
      await controller.setBandResolution(AnalyzerBandResolution.twelfth);
      await tester.pump();
      expect(
        identical(
          (tester.widget<CustomPaint>(plot).painter as dynamic).scale,
          barScale,
        ),
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      semantics.dispose();
    });
  }
}
