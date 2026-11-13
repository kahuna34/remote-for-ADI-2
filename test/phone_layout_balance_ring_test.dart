import 'dart:math' as math;

import 'package:adi2_remote/analyzer/header_content.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/outputs_page.dart';
import 'package:adi2_remote/ui/player_bar.dart';
import 'package:adi2_remote/ui/responsive_layout.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:adi2_remote/ui/volume_ring.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final (size, inset) in [
    (const Size(360, 740), 0.0),
    (const Size(412, 915), 0.0),
    (const Size(600, 960), 0.0),
    (const Size(960, 600), 0.0),
    (const Size(800, 1280), 0.0),
    (const Size(1280, 800), 0.0),
    (const Size(360, 740), 58.0),
    (const Size(412, 915), 58.0),
  ]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets(
        'Header and ring allocation $size scale=$scale inset=$inset',
        (tester) async {
          await tester.runAsync(() async {
            for (final family in ['Archivo', 'ArchivoNarrow']) {
              await (FontLoader(
                family,
              )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
            }
          });
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          if (inset > 0) {
            tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
            tester.view.viewPadding = const FakeViewPadding(
              top: 24,
              bottom: 34,
            );
          }
          addTearDown(tester.view.reset);
          SharedPreferences.setMockInitialValues({});
          final settings = AppSettings.instance;
          await settings.load();
          await settings.setEasyMode(false);
          await settings.setAutoFullscreenEq(false);
          final previousLanguage = AppLang.instance.language;
          AppLang.instance.language = AppLanguage.de;
          addTearDown(() => AppLang.instance.language = previousLanguage);
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('adi2/analyzer'),
            (_) async => false,
          );
          addTearDown(
            () =>
                tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
                  const MethodChannel('adi2/analyzer'),
                  null,
                ),
          );
          final controller = Adi2Controller();
          await controller.startOffline(Adi2Variant.dac);
          final player = NowPlaying()
            ..supported = true
            ..access = true
            ..info = const NowPlayingInfo(title: 'Track', artist: 'Artist');
          try {
            final phone = size.shortestSide < tabletBreakpoint;
            final originalDiameter = math.min(size.width - 160, 300.0);
            final expectedHeader = phone
                ? 120 +
                      originalDiameter *
                          .15 *
                          .83 *
                          ((size.height - inset - 680) / 60).clamp(0.0, 1.0)
                : 180.0;
            final layouts = <List<Rect>>[];
            for (final header in [
              HeaderContent.player,
              HeaderContent.status,
              HeaderContent.analyzer,
            ]) {
              await settings.setHeaderContent(header);
              await tester.pumpWidget(
                MaterialApp(
                  theme: buildTheme(),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: HomePage(ctrl: controller, np: player),
                ),
              );
              await tester.pumpAndSettle();
              final context = tester.element(find.byType(OutputsPage));
              expect(headerSlotHeight(context), closeTo(expectedHeader, .01));
              if (phone) {
                final slot = switch (header) {
                  HeaderContent.player => find.byType(PlayerBar),
                  HeaderContent.status => find.byKey(
                    const ValueKey('digital-mini'),
                  ),
                  _ => find.byType(AnalyzerPanel),
                };
                expect(
                  tester.getSize(slot).height,
                  closeTo(expectedHeader, .01),
                );
              }
              final ring = find.descendant(
                of: find.byType(OutputsPage),
                matching: find.byType(RawGestureDetector),
              );
              final paintedRing = find.descendant(
                of: find.byType(VolumeRing),
                matching: find.byType(RawGestureDetector),
              );
              expect(paintedRing, findsOneWidget);
              final ringRect = tester.getRect(paintedRing);
              expect(ringRect.width, greaterThan(100));
              expect(ringRect.height, closeTo(ringRect.width * .83, .01));
              if (phone) {
                expect(
                  ringRect.width,
                  lessThanOrEqualTo(originalDiameter * .85 + .1),
                );
                final controls = [
                  for (final name in [
                    'Balance-tile',
                    'output-ref-level',
                    'output-da-filter',
                    'output-volume-buttons',
                    'output-function-keys',
                    'output-tiles',
                  ])
                    tester.getRect(find.byKey(ValueKey(name))),
                ];
                layouts.add(controls);
                if (layouts.length > 1) {
                  expect(
                    controls,
                    layouts.first,
                    reason: 'Changing the header must preserve output geometry',
                  );
                }
                for (final name in ['Bass', 'Treble']) {
                  for (final direction in ['minus', 'plus']) {
                    final button = find.byKey(ValueKey('$name-$direction'));
                    final rect = Rect.fromPoints(
                      tester.getTopLeft(button),
                      tester.getBottomRight(button),
                    );
                    // Bass/Treble so breit wie Lock/Link.
                    final lockWidth = tester
                        .getSize(find.byKey(const ValueKey('output-lock')))
                        .width;
                    expect(rect.width, closeTo(lockWidth, .01));
                    expect(rect.height, closeTo(48, .01));
                    expect(button.hitTestable(), findsOneWidget);
                  }
                }
              } else {
                expect(ringRect.width, lessThanOrEqualTo(420));
              }
              expect(ring, findsWidgets);
              expect(tester.takeException(), isNull);
            }
          } finally {
            await tester.pumpWidget(const SizedBox());
            await tester.pumpAndSettle();
            controller.dispose();
            player.dispose();
          }
        },
      );
    }
  }
}
