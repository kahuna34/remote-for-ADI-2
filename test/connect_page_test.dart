import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/supported_models.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/app_settings_page.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Midi implements MidiCommand {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Controller extends Adi2Controller {
  _Controller() : super(midi: _Midi());
  int searches = 0;

  @override
  Future<void> refreshDevices() async => searches++;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final language in AppLanguage.values) {
    testWidgets('Startseite: fünf Modelle und Suche (${language.name})', (
      tester,
    ) async {
      final previousLanguage = AppLang.instance.language;
      AppLang.instance.language = language;
      addTearDown(() => AppLang.instance.language = previousLanguage);
      await tester.binding.setSurfaceSize(const Size(320, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = _Controller();
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: ConnectPage(ctrl: controller),
          ),
        );

        final tiles = find.byWidgetPredicate(
          (widget) =>
              widget is OutlinedButton &&
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('offline-'),
        );
        expect(tiles, findsNWidgets(5));
        expect(
          tester
              .widgetList<OutlinedButton>(tiles)
              .map((tile) => ((tile.child! as FittedBox).child! as Text).data),
          [
            'ADI-2 DAC',
            'ADI-2 Pro',
            'ADI-2 Pro EX',
            'ADI-2/4 Pro SE',
            'ADI-2/4 Pro EX',
          ],
        );
        expect(find.text(tr('Kein ADI-2 verbunden')), findsOneWidget);
        await tester.tap(find.text(tr('Erneut suchen')));
        await tester.pump();
        expect(controller.searches, 1);

        final proEx = find.byKey(const ValueKey('offline-ADI-2 Pro EX'));
        await tester.ensureVisible(proEx);
        await tester.tap(proEx);
        await tester.pumpAndSettle();
        expect(controller.offline, isTrue);
        expect(controller.variant, Adi2Variant.pro);
        expect(controller.deviceLabel, 'ADI-2 Pro EX');
        expect(tester.takeException(), isNull);
      } finally {
        controller.dispose();
      }
    });
  }

  testWidgets('Verbindungshilfe zeigt USB-Adapter und MIDI-Menüpfade', (
    tester,
  ) async {
    final controller = _Controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: ConnectPage(ctrl: controller),
      ),
    );
    await tester.tap(find.text(tr('Verbindungshilfe')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.textContaining('Lightning'), findsOneWidget);
    expect(find.text(tr('Verbindungshilfe')), findsNWidgets(2));
    expect(find.textContaining('Remap Keys / Diag'), findsOneWidget);
    expect(find.textContaining('Device Mode / DSD'), findsOneWidget);
    for (var i = 1; i <= 4; i++) {
      expect(find.text('$i.'), findsOneWidget);
    }
    expect(
      find.text(tr('App-Berechtigung / USB-Dialog bestätigen.')),
      findsOneWidget,
    );
    expect(find.text(tr('„Erneut suchen“ antippen.')), findsOneWidget);
    await tester.tap(find.text(tr('Schließen')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  for (final language in AppLanguage.values) {
    testWidgets('Kompakte Familienzeilen und SafeArea (${language.name})', (
      tester,
    ) async {
      final previousLanguage = AppLang.instance.language;
      AppLang.instance.language = language;
      addTearDown(() => AppLang.instance.language = previousLanguage);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 740);
      tester.view.padding = FakeViewPadding(top: 24, bottom: 24);
      addTearDown(tester.view.reset);
      final controller = _Controller();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: ConnectPage(ctrl: controller),
        ),
      );
      Rect tile(String name) =>
          tester.getRect(find.byKey(ValueKey('offline-$name')));
      final dac = tile('ADI-2 DAC');
      final pro = tile('ADI-2 Pro');
      final proEx = tile('ADI-2 Pro EX');
      final se = tile('ADI-2/4 Pro SE');
      final ex = tile('ADI-2/4 Pro EX');
      expect(dac.left, pro.left);
      expect(dac.top, lessThan(pro.top));
      expect(pro.top, proEx.top);
      expect(se.top, ex.top);
      expect(pro.top, lessThan(se.top));
      expect(proEx.left, ex.left);
      for (final model in supportedModels) {
        expect(tile(model.name).width, dac.width);
        expect(tile(model.name).height, inInclusiveRange(44, 48));
      }
      expect(tester.getSize(find.byType(ListView).first).height, 636);
      await tester.scrollUntilVisible(find.text(tr('Keine gefunden')), 150);
      await tester.ensureVisible(find.text(tr('Keine gefunden')));
      await tester.pumpAndSettle();
      expect(
        tester.getBottomLeft(find.text(tr('Keine gefunden'))).dy,
        lessThanOrEqualTo(716),
      );
      expect(tester.takeException(), isNull);

      // Zusätzliche MIDI-Geräte bleiben vollständig erreichbar.
      controller.devices = List.generate(
        12,
        (i) => MidiDevice('id-$i', 'MIDI $i', MidiDeviceType.unknown, false),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: ConnectPage(ctrl: controller),
        ),
      );
      await tester.scrollUntilVisible(find.text('MIDI 11'), 200);
      await tester.ensureVisible(find.text('MIDI 11'));
      await tester.pumpAndSettle();
      expect(
        tester.getBottomLeft(find.text('MIDI 11')).dy,
        lessThanOrEqualTo(716),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('App-Info nennt alle unterstützten Modelle', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: buildTheme(), home: const AppSettingsPage()),
    );
    await tester.scrollUntilVisible(find.textContaining('ADI-2 Pro EX'), 200);
    final info = tester.widget<Text>(find.textContaining('ADI-2 Pro EX')).data!;
    for (final model in supportedModels) {
      expect(info, contains(model.name));
    }
  });
}
