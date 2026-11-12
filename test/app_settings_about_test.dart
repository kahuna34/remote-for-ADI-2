import 'package:adi2_remote/app_info.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/ui/app_settings_page.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hauptliste der Seite; Knopfreihen scrollen zusätzlich waagerecht.
final _vertical = find
    .byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    )
    .first;

void main() {
  setUp(() async {
    final previous = AppLang.instance.language;
    addTearDown(() => AppLang.instance.language = previous);
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
  });

  for (final size in [
    const Size(360, 740),
    const Size(411, 914),
    const Size(1024, 1366),
  ]) {
    for (final language in AppLanguage.values) {
      for (final bottomInset in [24.0, 48.0]) {
        testWidgets(
          'About card fully visible at $size in $language with $bottomInset system bar',
          (tester) async {
            AppLang.instance.language = language;
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = size;
            tester.view.padding = FakeViewPadding(top: 24, bottom: bottomInset);
            tester.view.viewPadding = FakeViewPadding(
              top: 24,
              bottom: bottomInset,
            );
            addTearDown(tester.view.reset);
            await tester.pumpWidget(
              MaterialApp(theme: buildTheme(), home: const AppSettingsPage()),
            );
            await tester.pumpAndSettle();

            // Reach the end by an actual user scroll, including the trailing padding.
            await tester.fling(
              find.byType(ListView),
              const Offset(0, -2000),
              2000,
            );
            await tester.pumpAndSettle();
            final card = find.byKey(const ValueKey('about-app-card'));
            expect(card, findsOneWidget);
            final rect = tester.getRect(card);
            // Die Karte kann mit den Rechtshinweisen höher als der Bildschirm
            // sein; entscheidend ist, dass ihr Ende erreichbar ist.
            expect(
              rect.bottom,
              lessThanOrEqualTo(size.height - bottomInset - 24),
            );
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(size.width));
            expect(card.hitTestable(), findsOneWidget);

            final texts = language == AppLanguage.de
                ? [
                    'Über die App',
                    'Entwickelt von Markus Rass',
                    'RME, ADI-2 und ADI-2 Remote und weitere genannte Produktnamen sind Marken von RME Intelligent Audio Solutions.',
                  ]
                : [
                    'About the app',
                    'Developed by Markus Rass',
                    'RME, ADI-2 and ADI-2 Remote and other product names mentioned are trademarks of RME Intelligent Audio Solutions.',
                  ];
            for (final text in [
              ...texts,
              'Remote for ADI-2',
              'Version $appVersion',
              '© 2026 Markus Rass',
            ]) {
              final finder = find.descendant(
                of: card,
                matching: find.text(text),
              );
              expect(finder, findsOneWidget);
              final textRect = tester.getRect(finder);
              expect(textRect.top, greaterThanOrEqualTo(rect.top));
              expect(textRect.bottom, lessThanOrEqualTo(rect.bottom));
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
  for (final size in [const Size(360, 740), const Size(1024, 1366)]) {
    for (final language in AppLanguage.values) {
      testWidgets('Legal notices and licenses at $size in $language', (
        tester,
      ) async {
        AppLang.instance.language = language;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(theme: buildTheme(), home: const AppSettingsPage()),
        );
        await tester.pumpAndSettle();

        final legal = find.text(
          language == AppLanguage.de
              ? 'Marken und Rechtliches'
              : 'Trademarks and legal',
        );
        await tester.scrollUntilVisible(legal, 300, scrollable: _vertical);
        await tester.pumpAndSettle();
        await tester.tap(legal);
        await tester.pumpAndSettle();
        expect(find.byType(AppBar), findsOneWidget);
        expect(legal, findsOneWidget);
        expect(tester.takeException(), isNull);

        final notices = language == AppLanguage.de
            ? [
                'RME ist eine eingetragene Marke von RME Intelligent Audio Solutions. ADI-2 Pro ist eine Marke von RME Intelligent Audio Solutions; ADI-2 und ADI-2 Remote sind Produktnamen von RME.',
                'Alesis und ADAT sind eingetragene Marken der Alesis Corp. ADAT optical ist eine Marke der Alesis Corp.',
                'Apple, iPhone und Lightning sind Marken der Apple Inc.',
                'Android ist eine Marke der Google LLC.',
                'Direct Stream Digital und DSD sind Marken der jeweiligen Inhaber (Sony / Philips).',
                'Alle weiteren genannten Marken und Produktnamen sind Eigentum ihrer jeweiligen Inhaber und werden nur zur Bezeichnung der kompatiblen Geräte und Funktionen verwendet.',
              ]
            : [
                'RME is a registered trademark of RME Intelligent Audio Solutions. ADI-2 Pro is a trademark of RME Intelligent Audio Solutions; ADI-2 and ADI-2 Remote are product names of RME.',
                'Alesis and ADAT are registered trademarks of Alesis Corp. ADAT optical is a trademark of Alesis Corp.',
                'Apple, iPhone and Lightning are trademarks of Apple Inc.',
                'Android is a trademark of Google LLC.',
                'Direct Stream Digital and DSD are trademarks of their respective owners (Sony / Philips).',
                'All other trademarks and product names mentioned are the property of their respective owners and are used only to identify compatible devices and functions.',
              ];
        for (final notice in notices) {
          final text = find.text(notice);
          await tester.scrollUntilVisible(text, 150, scrollable: _vertical);
          await tester.ensureVisible(text);
          await tester.pumpAndSettle();
          expect(text.hitTestable(), findsOneWidget);
          final rect = tester.getRect(text);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(
            rect.top,
            greaterThanOrEqualTo(tester.getRect(find.byType(AppBar)).bottom),
          );
          expect(rect.bottom, lessThanOrEqualTo(size.height));
          expect(tester.takeException(), isNull);
        }

        final licenses = find.text(
          language == AppLanguage.de
              ? 'Open-Source-Lizenzen'
              : 'Open-source licenses',
        );
        await tester.scrollUntilVisible(licenses, 150, scrollable: _vertical);
        await tester.pumpAndSettle();
        await tester.tap(licenses);
        await tester.pumpAndSettle();
        expect(find.byType(LicensePage), findsOneWidget);
        final page = tester.widget<LicensePage>(find.byType(LicensePage));
        expect(page.applicationName, 'Remote for ADI-2');
        expect(page.applicationVersion, appVersion);
        expect(find.text('Remote for ADI-2'), findsOneWidget);
        expect(find.text(appVersion), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
