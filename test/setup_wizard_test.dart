import 'dart:io';

import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/ui/app_settings_page.dart';
import 'package:adi2_remote/ui/privacy_page.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/setup_wizard.dart';
import 'package:adi2_remote/ui/start_animation.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Midi implements MidiCommand {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Controller extends Adi2Controller {
  _Controller() : super(midi: _Midi());
  void changeState(ConnState value) {
    state = value;
    notifyListeners();
  }
}

class _Player extends NowPlaying {
  int refreshes = 0;
  bool grantOnResume = false;
  @override
  Future<void> refreshAccess() async {
    refreshes++;
    if (grantOnResume) access = true;
    notifyListeners();
  }

  void grant() {
    access = true;
    notifyListeners();
  }
}

Future<void> _tap(WidgetTester tester, String text) async {
  if (find.text(text).evaluate().isEmpty) {
    await tester.scrollUntilVisible(find.text(text), 180);
  }
  await tester.ensureVisible(find.text(text));
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppLang.instance.language = AppLanguage.en;
    await AppSettings.instance.load();
  });

  testWidgets(
    'animation then first setup; skip persists across second launch',
    (tester) async {
      final ctrl = _Controller();
      final np = _Player();
      addTearDown(ctrl.dispose);
      addTearDown(np.dispose);
      Widget launch() => MaterialApp(
        theme: buildTheme(),
        home: _Launch(ctrl: ctrl, np: np),
      );
      await tester.pumpWidget(launch());
      expect(find.text('Setup'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('Setup'), findsOneWidget);
      expect(find.text('home'), findsNothing);
      await _tap(tester, 'Skip');
      expect(
        (await SharedPreferences.getInstance()).getBool('setup_done'),
        true,
      );
      expect(find.text('home'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(launch());
      await tester.pumpAndSettle();
      expect(find.text('Setup'), findsNothing);
      expect(find.text('home'), findsOneWidget);
    },
  );

  testWidgets('restricted player buttons, resumed permission and checkmark', (
    tester,
  ) async {
    final np = _Player()
      ..supported = true
      ..restricted = true;
    addTearDown(np.dispose);
    final methods = <String>[];
    const channel = MethodChannel('adi2/media');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      methods.add(call.method);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: SetupWizard(np: np, onDone: () {}),
      ),
    );
    await _tap(tester, 'Next');
    expect(find.text('App info'), findsOneWidget);
    await _tap(tester, 'App info');
    await _tap(tester, 'Allow');
    expect(methods, ['openAppDetails', 'openAccessSettings']);
    final before = np.refreshes;
    np.grantOnResume = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(np.refreshes, greaterThan(before));
    expect(find.byKey(const ValueKey('setup-complete')), findsOneWidget);
    expect(find.text('Access granted'), findsOneWidget);
    expect(find.text('App info'), findsNothing);
  });

  testWidgets('already granted player access confirms immediately', (
    tester,
  ) async {
    final np = _Player()
      ..supported = true
      ..access = true;
    addTearDown(np.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SetupWizard(np: np, onDone: () {}),
      ),
    );
    await _tap(tester, 'Next');
    expect(find.byKey(const ValueKey('setup-complete')), findsOneWidget);
  });

  testWidgets('live connection confirms model; offline does not count', (
    tester,
  ) async {
    final ctrl = _Controller();
    final np = _Player();
    addTearDown(ctrl.dispose);
    addTearDown(np.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SetupWizard(ctrl: ctrl, np: np, onDone: () {}),
      ),
    );
    expect(find.text('Connect via host'), findsOneWidget);
    ctrl.changeState(ConnState.offline);
    await tester.pump();
    expect(find.byKey(const ValueKey('setup-complete')), findsNothing);
    ctrl.changeState(ConnState.connected);
    await tester.pump();
    expect(find.byKey(const ValueKey('setup-complete')), findsOneWidget);
    expect(find.text(ctrl.deviceLabel), findsOneWidget);
  });

  testWidgets(
    'non-Android skips player; switch persists; finish opens privacy',
    (tester) async {
      final np = _Player();
      addTearDown(np.dispose);
      var finished = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: SetupWizard(np: np, onDone: () => finished = true),
        ),
      );
      await _tap(tester, 'Next');
      expect(find.text('Updates'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('setup-update-check')));
      await tester.pumpAndSettle();
      expect(AppSettings.instance.updateCheck, false);
      expect(
        (await SharedPreferences.getInstance()).getBool('update_check'),
        false,
      );
      await _tap(tester, 'Next');
      await _tap(tester, 'Privacy policy');
      expect(find.byType(PrivacyPage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await _tap(tester, 'Get started');
      expect(finished, true);
      expect(
        (await SharedPreferences.getInstance()).getBool('setup_done'),
        true,
      );
    },
  );

  testWidgets('settings entries open privacy and repeat setup', (tester) async {
    final np = _Player();
    addTearDown(np.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: AppSettingsPage(np: np),
      ),
    );
    await tester.scrollUntilVisible(find.text('Privacy'), 300);
    await _tap(tester, 'Privacy');
    expect(find.byType(PrivacyPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await _tap(tester, 'Restart setup');
    expect(find.byType(SetupWizard), findsOneWidget);
    await _tap(tester, 'Skip');
    expect(find.byType(AppSettingsPage), findsOneWidget);
  });

  testWidgets('connection settings reuse the active player listener', (
    tester,
  ) async {
    final ctrl = _Controller();
    final np = _Player();
    addTearDown(ctrl.dispose);
    addTearDown(np.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: ConnectPage(ctrl: ctrl, np: np),
      ),
    );
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppSettingsPage>(find.byType(AppSettingsPage)).np,
      same(np),
    );
  });

  for (final size in [
    const Size(320, 640),
    const Size(640, 320),
    const Size(1024, 768),
  ]) {
    testWidgets('all setup steps fit and scroll at $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final np = _Player()
        ..supported = true
        ..restricted = true;
      addTearDown(np.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: SetupWizard(np: np, onDone: () {}),
        ),
      );
      for (var i = 0; i < 3; i++) {
        await _tap(tester, 'Next');
        expect(tester.takeException(), isNull);
      }
      await _tap(tester, 'Get started');
      expect(tester.takeException(), isNull);
    });
  }

  test('privacy wording matches both repository notices', () {
    for (final language in AppLanguage.values) {
      AppLang.instance.language = language;
      final file = File(
        language == AppLanguage.de ? 'docs/DATENSCHUTZ.md' : 'PRIVACY.md',
      ).readAsStringSync();
      for (final paragraph in privacyParagraphs()) {
        expect(file, contains(paragraph));
      }
    }
  });
}

class _Launch extends StatefulWidget {
  const _Launch({required this.ctrl, required this.np});
  final Adi2Controller ctrl;
  final NowPlaying np;
  @override
  State<_Launch> createState() => _LaunchState();
}

class _LaunchState extends State<_Launch> {
  bool done = false;
  @override
  Widget build(BuildContext context) => StartAnimation(
    onComplete: () => setState(() => done = true),
    child: done
        ? SetupGate(
            ctrl: widget.ctrl,
            np: widget.np,
            child: const Scaffold(body: Text('home')),
          )
        : const Scaffold(),
  );
}
