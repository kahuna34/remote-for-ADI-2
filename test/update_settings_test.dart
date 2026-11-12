import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/ui/app_settings_page.dart';
import 'package:adi2_remote/ui/update_settings.dart';
import 'package:adi2_remote/update/update_check.dart';
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
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
    AppLang.instance.language = AppLanguage.en;
  });

  testWidgets('settings page contains update switch and manual check entry', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AppSettingsPage()));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('update-check-switch')),
      300,
      scrollable: _vertical,
    );
    expect(find.text('Check for updates automatically'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-check-switch')));
    await tester.pumpAndSettle();
    expect(AppSettings.instance.updateCheck, false);
    expect(
      (await SharedPreferences.getInstance()).getBool('update_check'),
      false,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('update-check-now')),
      100,
      scrollable: _vertical,
    );
    expect(find.text('Check for updates now'), findsOneWidget);
  });

  testWidgets('manual check works when disabled and displays each result', (
    tester,
  ) async {
    await AppSettings.instance.setUpdateCheck(false);
    for (final status in [
      UpdateStatus.current,
      UpdateStatus.error,
      UpdateStatus.available,
    ]) {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UpdateSettings(
              key: ValueKey(status),
              check: () async {
                calls++;
                return UpdateResult(
                  status,
                  version: '1.2.0',
                  url: Uri.https('github.com', '/download'),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('update-check-now')));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(
        find.text(switch (status) {
          UpdateStatus.current => 'The app is up to date',
          UpdateStatus.error => 'Cannot connect to GitHub',
          _ => 'Version 1.2.0 available',
        }),
        findsOneWidget,
      );
      if (status == UpdateStatus.available) {
        expect(find.text('Download'), findsOneWidget);
      }
    }
  });
}
