import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/param_tile.dart';
import 'package:adi2_remote/ui/signal_flow.dart';
import 'package:adi2_remote/ui/signal_flow_data.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends Adi2Controller {
  _Controller([this.variant = Adi2Variant.pro]);
  @override
  final Adi2Variant variant;
  final writes = <(int, int, int)>[];
  @override
  int? value(int address, int index) => 0;
  @override
  void set(int address, int index, int raw) =>
      writes.add((address, index, raw));
}

Finder _mode(String label) =>
    find.descendant(of: find.byType(ParamTile), matching: find.text(tr(label)));

void main() {
  setUp(() {
    AppSettings.instance.autoFullscreenEq = true;
  });

  Future<void> prepare(
    WidgetTester tester,
    Widget home, {
    Size size = const Size(360, 740),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(() => AppSettings.instance.autoFullscreenEq = true);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: home),
      ),
    );
    await tester.pumpAndSettle();
  }

  Widget tile(_Controller ctrl, {int index = 6}) => ParamTile(
    ctrl: ctrl,
    address: Adi2Addr.device,
    def: deviceParams(ctrl.variant).firstWhere((d) => d.index == index),
  );

  for (final language in AppLanguage.values) {
    testWidgets('Basic Mode Langdruck, Tippen und Hinweis ${language.name}', (
      tester,
    ) async {
      final previous = AppLang.instance.language;
      AppLang.instance.language = language;
      addTearDown(() => AppLang.instance.language = previous);
      final ctrl = _Controller();
      addTearDown(ctrl.dispose);
      await prepare(tester, tile(ctrl));
      expect(find.text(tr('Gedrückt halten für Info')), findsOneWidget);
      await tester.tap(_mode('AD/DA'));
      await tester.pumpAndSettle();
      expect(ctrl.writes, [(Adi2Addr.device, 6, 1)]);
      expect(find.byType(SignalFlowSheet), findsNothing);
      ctrl.writes.clear();
      for (final mode in SignalFlowMode.values) {
        await tester.longPress(_mode(mode.label));
        await tester.pumpAndSettle();
        expect(
          find.text(trf('Signalplan · {mode}', {'mode': tr(mode.label)})),
          findsOneWidget,
        );
        expect(
          find.byType(SignalFlow),
          mode == SignalFlowMode.auto ? findsNothing : findsOneWidget,
        );
        expect(ctrl.writes, isEmpty);
        if (mode == SignalFlowMode.auto) {
          expect(find.text(tr('USB erkannt → USB')), findsOneWidget);
          expect(
            find.text(tr('Sonst Digitalsignal erkannt → AD/DA')),
            findsOneWidget,
          );
          expect(find.text(tr('Sonst → Preamp')), findsOneWidget);
          expect(find.text(tr('Dig Thru und DAC nur manuell')), findsOneWidget);
        }
        await tester.tap(find.byTooltip(tr('Schließen')));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    });

    for (final size in [const Size(360, 740), const Size(740, 360)]) {
      testWidgets('Alle Pläne ohne Overflow $size ${language.name}', (
        tester,
      ) async {
        final previous = AppLang.instance.language;
        AppLang.instance.language = language;
        addTearDown(() => AppLang.instance.language = previous);
        await prepare(
          tester,
          const SignalFlowSheet(initialMode: SignalFlowMode.auto),
          size: size,
        );
        for (final mode in SignalFlowMode.values) {
          // Die Moduswahl ist innerhalb der Infoansicht und sendet keine Parameter.
          final choice = find.widgetWithText(InkWell, tr(mode.label)).last;
          await tester.ensureVisible(choice);
          await tester.tap(choice);
          await tester.pumpAndSettle();
          final title = trf('Signalplan · {mode}', {'mode': tr(mode.label)});
          expect(
            size.width > size.height ? find.byTooltip(title) : find.text(title),
            findsOneWidget,
          );
          if (mode == SignalFlowMode.usb) {
            await tester.ensureVisible(find.text(tr('Mehrkanal · 6/8')));
            await tester.tap(find.text(tr('Mehrkanal · 6/8')));
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<SignalFlow>(find.byType(SignalFlow))
                  .diagram
                  .nodes
                  .any((n) => n.id == 'usb78'),
              isTrue,
            );
          }
          if (size.width > size.height && mode != SignalFlowMode.auto) {
            final rect = tester.getRect(find.byType(SignalFlow));
            expect(rect.top, greaterThanOrEqualTo(48));
            expect(rect.bottom, lessThanOrEqualTo(size.height));
          }
          final scrollable = find.byType(Scrollable).last;
          await tester.drag(scrollable, const Offset(0, -700));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: mode.name);
        }
        if (size.width > size.height) {
          expect(find.byTooltip(tr('Vollbild schließen')), findsOneWidget);
        }
      });
    }
  }

  testWidgets('Andere Auswahlparameter bekommen keine Info-Geste', (
    tester,
  ) async {
    final ctrl = _Controller();
    addTearDown(ctrl.dispose);
    await prepare(tester, tile(ctrl, index: 7));
    expect(find.text(tr('Gedrückt halten für Info')), findsNothing);
    await tester.longPress(find.text(tr('Main Out')));
    await tester.pumpAndSettle();
    expect(find.byType(SignalFlowSheet), findsNothing);
    final ink = tester.widget<InkWell>(
      find.widgetWithText(InkWell, tr('Main Out')),
    );
    expect(ink.onLongPress, isNull);
  });

  for (final variant in [
    Adi2Variant.pro,
    Adi2Variant.pro4se,
    Adi2Variant.pro4ex,
  ]) {
    testWidgets('Geräteseite öffnet Signalplan ${variant.name}', (
      tester,
    ) async {
      final ctrl = _Controller(variant);
      addTearDown(ctrl.dispose);
      await prepare(tester, DevicePage(ctrl: ctrl));
      await tester.scrollUntilVisible(find.text(tr('Basic Mode')), 180);
      await tester.ensureVisible(_mode('Preamp'));
      await tester.pumpAndSettle();
      await tester.longPress(_mode('Preamp'));
      await tester.pumpAndSettle();
      expect(
        find.text(trf('Signalplan · {mode}', {'mode': 'Preamp'})),
        findsOneWidget,
      );
      expect(ctrl.writes, isEmpty);
    });
  }

  testWidgets(
    'Automatisches Vollbild folgt Drehung und bewahrt Modus/USB-Ansicht',
    (tester) async {
      await prepare(
        tester,
        const SignalFlowSheet(initialMode: SignalFlowMode.usb),
      );
      await tester.ensureVisible(find.text(tr('Mehrkanal · 6/8')));
      await tester.tap(find.text(tr('Mehrkanal · 6/8')));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(740, 360);
      await tester.pumpAndSettle();
      expect(find.byTooltip(tr('Vollbild schließen')), findsOneWidget);
      expect(
        tester
            .widget<SignalFlow>(find.byType(SignalFlow))
            .diagram
            .nodes
            .any((n) => n.id == 'usb78'),
        isTrue,
      );
      tester.view.physicalSize = const Size(360, 740);
      await tester.pumpAndSettle();
      expect(find.byTooltip(tr('Vollbild schließen')), findsNothing);
      expect(
        tester
            .widget<SignalFlow>(find.byType(SignalFlow))
            .diagram
            .nodes
            .any((n) => n.id == 'usb78'),
        isTrue,
      );
      tester.view.physicalSize = const Size(740, 360);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byTooltip(tr('Vollbild schließen')), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byTooltip(tr('Vollbild schließen')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Vollbildknopf funktioniert bei ausgeschalteter Automatik', (
    tester,
  ) async {
    AppSettings.instance.autoFullscreenEq = false;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await prepare(
      tester,
      const SignalFlowSheet(initialMode: SignalFlowMode.adda),
      size: const Size(740, 360),
    );
    expect(find.byTooltip(tr('Vollbild schließen')), findsNothing);
    await tester.tap(find.byTooltip(tr('Vollbild')));
    await tester.pumpAndSettle();
    expect(find.byTooltip(tr('Vollbild schließen')), findsOneWidget);
    expect(
      calls.any(
        (c) =>
            c.method == 'SystemChrome.setEnabledSystemUIMode' &&
            c.arguments == 'SystemUiMode.immersiveSticky',
      ),
      isTrue,
    );
    await tester.tap(find.widgetWithText(InkWell, 'DAC').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(tr('Vollbild schließen')));
    await tester.pumpAndSettle();
    expect(
      find.text(trf('Signalplan · {mode}', {'mode': 'DAC'})),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
