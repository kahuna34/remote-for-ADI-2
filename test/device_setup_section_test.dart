import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/device_setup_section.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/param_tile.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends Adi2Controller {
  int volume = 0;
  final loaded = <int>[];
  final saved = <int>[];
  int factories = 0;
  (int, String)? renamed;
  @override
  Adi2Variant get variant => Adi2Variant.dac;
  @override
  int? value(int address, int index) =>
      address == Adi2Addr.device && index == DevIdx.loadVolumeWithSetup
      ? volume
      : null;
  @override
  int valueOr(int address, int index, int fallback) =>
      value(address, index) ?? fallback;

  @override
  void set(int address, int index, int raw) {
    volume = raw;
    notifyListeners();
  }

  @override
  void loadSetup(int n) => loaded.add(n);
  @override
  void saveSetup(int n) => saved.add(n);
  @override
  void loadFactory() => factories++;
  @override
  void renameSetup(int n, String name) {
    renamed = (n, name);
    names[0x20 + n] = name;
    notifyListeners();
  }
}

void main() {
  late _Controller c;
  late AppLanguage previous;
  setUp(() {
    previous = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    c = _Controller();
  });
  tearDown(() {
    c.dispose();
    AppLang.instance.language = previous;
  });

  Future<void> show(WidgetTester tester, {bool wholePage = false}) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: wholePage
              ? DevicePage(ctrl: c)
              : SingleChildScrollView(child: DeviceSetupSection(ctrl: c)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('Geräteseite endet mit Setup und zeigt Parameter nur dort', (
    tester,
  ) async {
    await show(tester, wholePage: true);
    await tester.scrollUntilVisible(
      find.byType(DeviceSetupSection),
      600,
      scrollable: find.byType(Scrollable).first,
    );
    final tiles = tester
        .widgetList<ParamTile>(find.byType(ParamTile))
        .where((t) => t.def.index == DevIdx.loadVolumeWithSetup);
    expect(tiles, hasLength(1));
    expect(
      find.descendant(
        of: find.byType(DeviceSetupSection),
        matching: find.text('Lautstärke mit Setup laden'),
      ),
      findsOneWidget,
    );
    final list = tester.widget<ListView>(find.byType(ListView).first);
    final children =
        (list.childrenDelegate as SliverChildListDelegate).children;
    expect(children.last, isA<Padding>());
    expect((children.last as Padding).child, isA<DeviceSetupSection>());
  });

  testWidgets('Neun Kacheln in 3 × 3, Namen und Laden der Auswahl', (
    tester,
  ) async {
    c.names[0x25] = 'Kopfhörer';
    await show(tester);
    final grid = tester.widget<GridView>(find.byType(GridView));
    expect(
      (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      3,
    );
    expect(find.byType(InkWell), findsAtLeastNWidgets(9));
    expect(find.text('Setup 9'), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('device-setup-5')));
    expect(
      tester.widget<Text>(find.text('Kopfhörer')).style!.color,
      Palette.amber,
    );
    await tap(tester, find.text('Laden'));
    expect(c.loaded, [5]);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Lautstärkewarnung lässt sich abbrechen und bestätigen', (
    tester,
  ) async {
    c.volume = 1;
    await show(tester);
    await tap(tester, find.text('Laden'));
    expect(
      find.text(
        'Die Lautstärke wird mit dem Setup geladen und kann lauter werden.',
      ),
      findsOneWidget,
    );
    expect(c.loaded, isEmpty);
    await tap(tester, find.text('Abbrechen'));
    expect(c.loaded, isEmpty);
    await tap(tester, find.text('Laden'));
    await tap(tester, find.widgetWithText(FilledButton, 'Laden'));
    expect(c.loaded, [1]);
  });

  testWidgets('Speichern und Factory brauchen Bestätigung, Factory rot', (
    tester,
  ) async {
    await show(tester);
    await tap(tester, find.byKey(const ValueKey('device-setup-9')));
    await tap(tester, find.text('Speichern'));
    expect(find.text('Setup 9 überschreiben?'), findsOneWidget);
    await tap(tester, find.text('Abbrechen'));
    expect(c.saved, isEmpty);
    await tap(tester, find.text('Speichern'));
    await tap(tester, find.widgetWithText(FilledButton, 'Speichern'));
    expect(c.saved, [9]);
    await tap(tester, find.text('Werkseinstellung'));
    expect(
      find.text(
        'Alle aktuellen Einstellungen des Geräts werden auf Werkseinstellung gesetzt.',
      ),
      findsOneWidget,
    );
    final button = find.widgetWithText(FilledButton, 'Werkseinstellung');
    expect(
      tester.widget<FilledButton>(button).style!.backgroundColor!.resolve({}),
      Palette.red,
    );
    await tap(tester, find.text('Abbrechen'));
    expect(c.factories, 0);
    await tap(tester, find.text('Werkseinstellung'));
    await tap(tester, button);
    expect(c.factories, 1);
  });

  testWidgets('Offline nur Parameter und keine Geräteaktionen', (tester) async {
    c.state = ConnState.offline;
    await show(tester);
    expect(find.text('Setup'), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    for (final label in ['Laden', 'Speichern', 'Werkseinstellung']) {
      expect(find.text(label), findsNothing);
    }
    await tap(tester, find.byType(SwitchListTile));
    expect(c.volume, 1);
  });

  testWidgets('Langer Druck benennt Setup mit maximal 14 Zeichen um', (
    tester,
  ) async {
    await show(tester);
    await tester.longPress(find.byKey(const ValueKey('device-setup-3')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).maxLength, 14);
    await tester.enterText(find.byType(TextFormField), 'Abend');
    await tap(tester, find.widgetWithText(FilledButton, 'Speichern'));
    expect(c.renamed, (3, 'Abend'));
    expect(find.text('Abend'), findsOneWidget);
  });

  testWidgets('Englisch passt im Handy-Hochformat', (tester) async {
    AppLang.instance.language = AppLanguage.en;
    await show(tester);
    for (final label in ['Setup', 'Load', 'Save', 'Factory']) {
      expect(find.text(label), findsOneWidget);
    }
    await tap(tester, find.text('Factory'));
    expect(
      find.text(
        'All current device settings will be reset to factory settings.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
