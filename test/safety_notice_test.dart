import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/l10n/strings_en.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/ui/app_settings_page.dart';
import 'package:adi2_remote/ui/safety_notice.dart';
import 'package:adi2_remote/ui/setup_wizard.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Midi implements MidiCommand {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLang.instance.language = AppLanguage.de;
  });

  testWidgets('Hinweis erscheint in der gespeicherten Sprache', (tester) async {
    SharedPreferences.setMockInitialValues({'app_language': 'de'});
    AppLang.instance.language = AppLanguage.en;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: SafetyGate(onReady: () {}, child: const SizedBox()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Wichtiger Hinweis zur Lautstärke'), findsOneWidget);
    expect(find.text('Important notice about volume'), findsNothing);
    await tester.tap(find.text('Verstanden und akzeptiert'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Erststart sperrt Einrichtung und Verbindung bis zur Speicherung; Neustart ohne Hinweis',
    (tester) async {
      final ctrl = Adi2Controller(midi: _Midi());
      final np = NowPlaying();
      addTearDown(ctrl.dispose);
      addTearDown(np.dispose);
      var starts = 0;
      Widget launch() => MaterialApp(
        theme: buildTheme(),
        home: SafetyGate(
          onReady: () => starts++,
          child: SetupGate(
            ctrl: ctrl,
            np: np,
            child: const Scaffold(body: Text('Verbindungsseite')),
          ),
        ),
      );
      await tester.pumpWidget(launch());
      await tester.pumpAndSettle();
      expect(find.text('Wichtiger Hinweis zur Lautstärke'), findsOneWidget);
      expect(find.byType(SetupWizard), findsNothing);
      expect(find.text('Verbindungsseite'), findsNothing);
      expect(starts, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(find.text('Verstanden und akzeptiert'), findsOneWidget);
      expect(starts, 0);
      await tester.tap(find.text('Verstanden und akzeptiert'));
      await tester.pumpAndSettle();
      expect(starts, 1);
      expect(find.byType(SetupWizard), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt('safety_notice_version'),
        AppSettings.safetyNoticeVersion,
      );
      await prefs.setBool('setup_done', true);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(launch());
      await tester.pumpAndSettle();
      expect(find.text('Wichtiger Hinweis zur Lautstärke'), findsNothing);
      expect(find.text('Verbindungsseite'), findsOneWidget);
      expect(starts, 2);
    },
  );

  testWidgets('Neue Hinweisversion sperrt auch bestehende Nutzer', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'setup_done': true,
      'safety_notice_version': AppSettings.safetyNoticeVersion - 1,
    });
    var started = false;
    await tester.pumpWidget(
      MaterialApp(
        home: SafetyGate(
          onReady: () => started = true,
          child: const Scaffold(body: Text('Verbindungsseite')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(started, isFalse);
    expect(find.text('Verbindungsseite'), findsNothing);
    expect(find.text('Verstanden und akzeptiert'), findsOneWidget);
    await tester.tap(find.text('Verstanden und akzeptiert'));
    await tester.pumpAndSettle();
    expect(started, isTrue);
  });

  testWidgets(
    'Menüeintrag öffnet ohne Pflicht und ohne gespeicherte Akzeptanz',
    (tester) async {
      await AppSettings.instance.load();
      await tester.pumpWidget(
        MaterialApp(theme: buildTheme(), home: const AppSettingsPage()),
      );
      final entry = find.text('Sicherheit und Haftung');
      await tester.scrollUntilVisible(entry, 250);
      await Scrollable.ensureVisible(tester.element(entry));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(entry).dy,
        lessThan(tester.getTopLeft(find.text('Marken und Rechtliches')).dy),
      );
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.text('Schließen'), findsOneWidget);
      expect(find.text('Verstanden und akzeptiert'), findsNothing);
      await tester.tap(find.text('Schließen'));
      await tester.pumpAndSettle();
      expect(find.text('Wichtiger Hinweis zur Lautstärke'), findsNothing);
      expect(
        (await SharedPreferences.getInstance()).getInt('safety_notice_version'),
        isNull,
      );
    },
  );

  for (final language in AppLanguage.values) {
    testWidgets('320×568 mit Textskalierung 1,3: ${language.name}', (
      tester,
    ) async {
      AppLang.instance.language = language;
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: SafetyGate(onReady: () {}, child: const Scaffold()),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final body = tester
          .widgetList<Text>(find.byType(Text))
          .singleWhere(
            (text) =>
                text.data?.startsWith(
                  language == AppLanguage.de ? 'Diese App' : 'This app',
                ) ??
                false,
          )
          .data!;
      expect(body.split('\n\n'), hasLength(3));
      expect(
        body.split('\n').where((line) => line.startsWith('• ')),
        hasLength(3),
      );
      if (language == AppLanguage.en) {
        expect(
          body,
          stringsEn.values.singleWhere(
            (text) => text.startsWith('This app changes'),
          ),
        );
      }
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -3000),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.text(
          language == AppLanguage.de
              ? 'Verstanden und akzeptiert'
              : 'Understood and accepted',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SafetyGate), findsOneWidget);
      expect(
        AppSettings.instance.safetyNoticeAccepted,
        AppSettings.safetyNoticeVersion,
      );
    });
  }
}
