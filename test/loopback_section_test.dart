import 'dart:convert';

import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/backup.dart';
import 'package:adi2_remote/device/usb_cc_mode.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/loopback_section.dart';
import 'package:adi2_remote/ui/outputs_page.dart';
import 'package:adi2_remote/ui/param_tile.dart';
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
  final writes = <(int, int, int)>[];
  UsbCcMode mode = UsbCcMode.unknown;

  @override
  UsbCcMode get ccMode => mode;

  void updateMode(UsbCcMode value) {
    mode = value;
    notifyListeners();
  }

  @override
  void set(int address, int index, int value) {
    writes.add((address, index, value));
    super.set(address, index, value);
  }

  @override
  Future<List<EqPresetData>> readEqPresets({
    void Function(double)? progress,
  }) async => [];
}

class _SettingsController extends Adi2Controller {
  _SettingsController(this.variant) : super(midi: _Midi());

  @override
  final Adi2Variant variant;

  @override
  int? value(int address, int index) => index == OutIdx.loopback ? 1 : null;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<_Controller> show(
    WidgetTester tester,
    Adi2Variant variant, {
    AppLanguage language = AppLanguage.de,
    bool wholePage = false,
  }) async {
    final previous = AppLang.instance.language;
    AppLang.instance.language = language;
    addTearDown(() => AppLang.instance.language = previous);
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ctrl = _Controller();
    await ctrl.startOffline(variant);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: wholePage
              ? DevicePage(ctrl: ctrl)
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: LoopbackSection(ctrl: ctrl),
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ctrl;
  }

  Finder row(int address) => find.byKey(ValueKey('loopback-$address'));
  Finder choice(int address, String label) =>
      find.descendant(of: row(address), matching: find.text(tr(label)));

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  for (final variant in Adi2Variant.values) {
    for (final language in AppLanguage.values) {
      testWidgets(
        'Loopback schreibt Rohwerte ${variant.name} ${language.name}',
        (tester) async {
          final ctrl = await show(tester, variant, language: language);
          try {
            if (variant == Adi2Variant.pro) {
              expect(row(Adi2Addr.ph12), findsNothing);
              expect(row(Adi2Addr.line), findsOneWidget);
              expect(row(Adi2Addr.ph34), findsOneWidget);
            }
            for (final output
                in (variant.isDac
                    ? [outputsFor(variant).first]
                    : outputsFor(variant).where(
                        (o) => ctrl.value(o.address, OutIdx.loopback) != null,
                      ))) {
              expect(
                find.descendant(
                  of: row(output.address),
                  matching: find.text(
                    variant.isDac ? tr('Loopback-Quelle') : output.name,
                  ),
                ),
                findsOneWidget,
              );
              expect(choice(output.address, '1/2'), findsNothing);
              expect(choice(output.address, 'USB-Ziel'), findsNothing);
              expect(choice(output.address, 'Abgriff'), findsNothing);
              // Alle Abgriffe und alle USB-Paare über die normale Bedienung.
              for (var pair = 0; pair < (variant.hasInput ? 3 : 1); pair++) {
                const taps = ['pre FX', 'post FX', 'post −6 dB'];
                await tap(tester, choice(output.address, taps[0]));
                expect(
                  choice(output.address, 'USB-Ziel'),
                  variant.hasInput ? findsOneWidget : findsNothing,
                );
                if (variant.hasInput) {
                  await tap(
                    tester,
                    choice(output.address, ['1/2', '3/4', '5/6'][pair]),
                  );
                }
                for (var tapIndex = 0; tapIndex < taps.length; tapIndex++) {
                  await tap(tester, choice(output.address, taps[tapIndex]));
                  expect(
                    ctrl.value(output.address, OutIdx.loopback),
                    3 * pair + tapIndex + 1,
                  );
                  expect(ctrl.writes.last, (
                    output.address,
                    OutIdx.loopback,
                    3 * pair + tapIndex + 1,
                  ));
                }
              }
              await tap(tester, choice(output.address, 'Aus'));
              expect(ctrl.writes.last, (output.address, OutIdx.loopback, 0));
              expect(choice(output.address, '1/2'), findsNothing);
            }
            expect(tester.takeException(), isNull);
          } finally {
            ctrl.dispose();
          }
        },
      );
    }
  }

  testWidgets('Geräteseite enthält Panel und übersetzte Erklärung', (
    tester,
  ) async {
    final ctrl = await show(
      tester,
      Adi2Variant.pro,
      wholePage: true,
      language: AppLanguage.en,
    );
    try {
      expect(find.byType(LoopbackSection), findsOneWidget);
      await tap(tester, find.byTooltip(tr('Info')));
      expect(find.byType(BottomSheet), findsOneWidget);
      for (final text in [
        'Record the output signal on the computer via USB.',
        'pre FX = before EQ/effects',
        'post FX = after EQ/effects',
        'post −6 dB = after EQ/effects with 6 dB of headroom',
        'USB target = recording channels on the computer',
        '5/6 requires CC mode Multi-channel. Change it on the device under SETUP → Options → Device Mode / DSD → CC-Mode with USB disconnected.',
      ]) {
        expect(find.text(text), findsOneWidget);
      }
      await tap(tester, find.text(tr('Schließen')));
      expect(find.byType(BottomSheet), findsNothing);
    } finally {
      ctrl.dispose();
    }
  });

  for (final mode in UsbCcMode.values) {
    testWidgets('USB 5/6 Auswahl bei ${mode.name}', (tester) async {
      final ctrl = await show(tester, Adi2Variant.pro);
      try {
        ctrl.updateMode(mode);
        await tap(tester, choice(Adi2Addr.line, 'pre FX'));
        final choices = find.descendant(
          of: row(Adi2Addr.line),
          matching: find.byType(ParamChoices),
        );
        expect(tester.widget<ParamChoices>(choices.at(1)).markedIndices, {2});
        final fiveSix = choice(Adi2Addr.line, '5/6');
        final tile = find
            .ancestor(of: fiveSix, matching: find.byType(InkWell))
            .first;
        expect(
          tester.widget<InkWell>(tile).onTap == null,
          mode == UsbCcMode.stereo,
        );
        await tap(tester, fiveSix);
        expect(
          ctrl.value(Adi2Addr.line, OutIdx.loopback),
          mode == UsbCcMode.stereo ? 1 : 7,
        );
        expect(
          choice(
            Adi2Addr.line,
            '5/6 nur mit CC-Modus Multi-channel (am Gerät ohne USB-Verbindung umstellen).',
          ),
          findsOneWidget,
        );
        if (mode == UsbCcMode.stereo) {
          ctrl.set(Adi2Addr.line, OutIdx.loopback, 8);
          await tester.pumpAndSettle();
          expect(
            choice(Adi2Addr.line, '5/6 (im Stereo-Modus nicht verfügbar)'),
            findsOneWidget,
          );
          expect(tester.widget<ParamChoices>(choices.at(1)).selected, 2);
          await tap(tester, choice(Adi2Addr.line, '3/4'));
          expect(ctrl.value(Adi2Addr.line, OutIdx.loopback), 5);
          expect(
            choice(Adi2Addr.line, '5/6 (im Stereo-Modus nicht verfügbar)'),
            findsNothing,
          );
          ctrl.updateMode(UsbCcMode.multi);
          await tester.pumpAndSettle();
          await tap(tester, fiveSix);
          expect(ctrl.value(Adi2Addr.line, OutIdx.loopback), 8);
        }
        expect(tester.takeException(), isNull);
      } finally {
        ctrl.dispose();
      }
    });
  }

  testWidgets(
    'Externe Werte, Offline-Speicherung und Backup erhalten Rohwerte',
    (tester) async {
      final ctrl = await show(tester, Adi2Variant.pro);
      try {
        ctrl.set(Adi2Addr.line, OutIdx.loopback, 8);
        await tester.pumpAndSettle();
        final choices = find.descendant(
          of: row(Adi2Addr.line),
          matching: find.byType(ParamChoices),
        );
        expect(tester.widget<ParamChoices>(choices.at(0)).selected, 2);
        expect(tester.widget<ParamChoices>(choices.at(1)).selected, 2);
        await tap(tester, choice(Adi2Addr.line, 'post −6 dB'));
        await tester.pump(const Duration(milliseconds: 600));
        final prefs = await SharedPreferences.getInstance();
        final saved =
            jsonDecode(prefs.getString('offline_pro')!) as Map<String, dynamic>;
        expect(saved['${Adi2Addr.line << 8 | OutIdx.loopback}'], 9);
        await ctrl.startOffline(Adi2Variant.pro);
        expect(ctrl.value(Adi2Addr.line, OutIdx.loopback), 9);

        ctrl.state = ConnState.connected;
        final pendingBackup = ctrl.createBackup();
        await tester.pump(const Duration(milliseconds: 700));
        final backup = Adi2Backup.decode((await pendingBackup)!.encode());
        expect(backup.values[Adi2Addr.line << 8 | OutIdx.loopback], 9);
        ctrl.set(Adi2Addr.line, OutIdx.loopback, 1);
        expect(await ctrl.restoreBackup(backup), 1);
        await tester.pump(const Duration(milliseconds: 600));
        expect(ctrl.value(Adi2Addr.line, OutIdx.loopback), 9);
        expect(tester.takeException(), isNull);
      } finally {
        ctrl.dispose();
      }
    },
  );

  for (final variant in Adi2Variant.values) {
    testWidgets('Kanaleinstellungen ohne Loopback ${variant.name}', (
      tester,
    ) async {
      final ctrl = _SettingsController(variant);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: OutputSettingsPage(ctrl: ctrl, out: outputsFor(variant).first),
        ),
      );
      final list = tester.widget<ListView>(find.byType(ListView));
      final children =
          (list.childrenDelegate as SliverChildListDelegate).children;
      final panel = children.single as Panel;
      final column = (panel.child as Material).child! as Column;
      final tiles = column.children.whereType<ParamTile>();
      expect(tiles.any((tile) => tile.def.index == OutIdx.loopback), isFalse);
      expect(tiles, isNotEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
