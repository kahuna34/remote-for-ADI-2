import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/desktop/desktop_compact_scale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
  });

  testWidgets(
    'Kompakt am Desktop: feste Grundgröße, mittig, gleichmäßig skaliert',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 761);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      Size? seen;
      await AppSettings.instance.setLinuxCompact(true);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => DesktopCompactScale(child: child!),
          home: Builder(
            builder: (context) {
              seen = MediaQuery.sizeOf(context);
              return const SizedBox.expand(key: ValueKey('page'));
            },
          ),
        ),
      );
      expect(seen, desktopCompactSize);
      expect(
        tester.getSize(find.byKey(const ValueKey('desktop-compact-scale'))),
        const Size(1000, 761),
      );
      final page = tester.getRect(find.byKey(const ValueKey('page')));
      expect(page.size, desktopCompactSize);
      expect(page.center.dx, closeTo(500, 0.01));

      tester.view.physicalSize = const Size(1000, 380.5);
      await tester.pump();
      final half = tester.getRect(find.byKey(const ValueKey('page')));
      expect(half.height, closeTo(desktopCompactSize.height / 2, 0.01));
      expect(half.width, closeTo(desktopCompactSize.width / 2, 0.01));

      await AppSettings.instance.setLinuxCompact(false);
      await tester.pump();
      expect(find.byKey(const ValueKey('desktop-compact-scale')), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
