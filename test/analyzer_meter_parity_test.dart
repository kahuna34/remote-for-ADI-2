import 'dart:ui' as ui;

import 'package:adi2_remote/analyzer/analyzer_controller.dart';
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:adi2_remote/ui/analyzer_controls.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/analyzer_meter_reference.dart';

void main() {
  for (final compact in [true, false]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets(
        'Meter pixels match widget reference compact=$compact scale=$scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          await AppSettings.instance.load();
          await AppSettings.instance.setAnalyzerMainView(
            AnalyzerMainView.levels,
          );
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(1280, 800);
          addTearDown(tester.view.reset);
          final controller = AnalyzerController()
            ..status = AnalyzerStatus.running;
          addTearDown(controller.dispose);
          final referenceKey = GlobalKey();
          var mounted = false;
          for (final range in [60, 100]) {
            await AppSettings.instance.setAnalyzerRange(range);
            for (final peak in [-120.0, -9.9, 0.0]) {
              controller.frame = AnalyzerFrame(
                sampleRate: 48000,
                spectrum: List.filled(1025, -24),
                peak: [peak, -6],
                rms: [peak - 12, -18],
                clipped: [peak == 0, false],
              );
              controller.notifyListeners();
              if (!mounted) {
                mounted = true;
                await tester.pumpWidget(
                  MaterialApp(
                    theme: buildTheme(),
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: TextScaler.linear(scale)),
                      child: child!,
                    ),
                    home: Scaffold(
                      body: Column(
                        children: [
                          SizedBox(
                            width: 740,
                            height: compact ? 172 : 360,
                            child: AnalyzerDisplay(
                              controller: controller,
                              compact: compact,
                            ),
                          ),
                          RepaintBoundary(
                            key: referenceKey,
                            child: SizedBox(
                              width: compact ? 724 : 346,
                              height: compact ? 120 : null,
                              child: compact
                                  ? ReferenceCompactLevels(
                                      controller: controller,
                                      color: analyzerColors.first,
                                    )
                                  : ReferenceHorizontalLevels(
                                      controller: controller,
                                      color: analyzerColors.first,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }
              await tester.pumpAndSettle();
              final meter = find.byKey(
                ValueKey(
                  compact
                      ? 'analyzer-compact-levels'
                      : 'analyzer-fullscreen-levels',
                ),
              );
              final boundary =
                  tester.renderObject<RenderBox>(meter).parent!
                      as RenderRepaintBoundary;
              final reference =
                  referenceKey.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              await tester.runAsync(() async {
                final actualImage = await boundary.toImage();
                final referenceImage = await reference.toImage();
                try {
                  expect(actualImage.width, referenceImage.width);
                  expect(actualImage.height, referenceImage.height);
                  final actual = await actualImage.toByteData(
                    format: ui.ImageByteFormat.rawRgba,
                  );
                  final expected = await referenceImage.toByteData(
                    format: ui.ImageByteFormat.rawRgba,
                  );
                  expect(
                    actual!.buffer.asUint8List(),
                    expected!.buffer.asUint8List(),
                    reason: 'range=$range peak=$peak',
                  );
                } finally {
                  actualImage.dispose();
                  referenceImage.dispose();
                }
              });
            }
          }
        },
      );
    }
  }
}
