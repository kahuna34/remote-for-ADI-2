import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/store_build.dart';
import 'package:adi2_remote/ui/app_settings_page.dart';
import 'package:adi2_remote/ui/privacy_page.dart';
import 'package:adi2_remote/ui/setup_wizard.dart';
import 'package:adi2_remote/ui/update_settings.dart';
import 'package:adi2_remote/update/app_updates.dart';
import 'package:adi2_remote/update/open_update.dart';
import 'package:adi2_remote/update/update_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Player extends NowPlaying {
  @override
  Future<void> refreshAccess() async {}
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'update_check': false,
      'available_update_version': '999.0.0',
      'available_update_url': 'https://github.com/example/releases/app.apk',
    });
    await AppSettings.instance.load();
    AppLang.instance.language = AppLanguage.en;
  });
  tearDown(() => debugPlayStoreBuild = null);

  test('default follows the compile-time flag', () {
    expect(isPlayStoreBuild, playStoreBuild);
  });

  test(
    'Play service never creates checker or exposes cached download',
    () async {
      debugPlayStoreBuild = true;
      final service = AppUpdates.forTesting();
      addTearDown(service.dispose);
      await service.initialize();
      await service.initialize();
      await AppSettings.instance.setUpdateCheck(true);
      service.settingsChanged();
      expect((await service.checkNow()).status, UpdateStatus.skipped);
      expect(service.checker, isNull);
      expect(service.result, isNull);
      expect(await openUpdate(Uri.parse('https://github.com/app.apk')), false);
    },
  );

  test('GitHub service keeps disabled checker and cached update', () async {
    debugPlayStoreBuild = false;
    final service = AppUpdates.forTesting();
    addTearDown(service.dispose);
    await service.initialize();
    addTearDown(service.checker!.stop);
    expect(service.checker, isA<UpdateCheck>());
    expect(service.checker!.enabled, false);
    expect(service.result!.status, UpdateStatus.available);
    expect(service.result!.version, '999.0.0');
  });

  testWidgets('Play settings omit the entire update section', (tester) async {
    debugPlayStoreBuild = true;
    await tester.pumpWidget(const MaterialApp(home: AppSettingsPage()));
    final vertical = find
        .byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        )
        .first;
    // Scan the full lazy list, so an off-screen section cannot pass unnoticed.
    for (var i = 0; i < 15; i++) {
      expect(find.byType(UpdateSettings), findsNothing);
      expect(find.byKey(const ValueKey('update-check-switch')), findsNothing);
      expect(find.byKey(const ValueKey('update-check-now')), findsNothing);
      await tester.drag(vertical, const Offset(0, -250));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('standalone Play update settings are also hidden', (
    tester,
  ) async {
    debugPlayStoreBuild = true;
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: UpdateSettings())),
    );
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.byType(ListTile), findsNothing);
    expect(privacyParagraphs().join('\n'), isNot(contains('api.github.com')));
  });

  for (final play in [false, true]) {
    for (final playerSupported in [false, true]) {
      testWidgets('setup Play=$play player=$playerSupported', (tester) async {
        debugPlayStoreBuild = play;
        final player = _Player()..supported = playerSupported;
        addTearDown(player.dispose);
        var finished = false;
        await tester.pumpWidget(
          MaterialApp(
            home: SetupWizard(np: player, onDone: () => finished = true),
          ),
        );
        Future<void> next() async {
          await tester.ensureVisible(find.text('Next'));
          await tester.tap(find.text('Next'));
          await tester.pumpAndSettle();
        }

        await next();
        if (playerSupported) await next();
        if (play) {
          expect(find.text('Updates'), findsNothing);
          expect(
            find.byKey(const ValueKey('setup-update-check')),
            findsNothing,
          );
          expect(find.textContaining('api.github.com'), findsNothing);
        } else {
          expect(
            find.byKey(const ValueKey('setup-update-check')),
            findsOneWidget,
          );
          await next();
        }
        expect(find.text('Done'), findsOneWidget);
        await tester.ensureVisible(find.text('Get started'));
        await tester.tap(find.text('Get started'));
        await tester.pumpAndSettle();
        expect(finished, true);
      });
    }
  }
}
