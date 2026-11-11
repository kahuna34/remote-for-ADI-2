import 'dart:io';

import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/backup.dart';
import 'package:adi2_remote/eq/eq_editor_buffer.dart';
import 'package:adi2_remote/eq/eq_library.dart';
import 'package:adi2_remote/eq/eq_math.dart';
import 'package:adi2_remote/eq/eq_model.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/backup_page.dart';
import 'package:adi2_remote/ui/eq_page.dart';
import 'package:adi2_remote/ui/setups_page.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Finder getCurveSwitch() => find.descendant(
  of: find
      .ancestor(
        of: find.text(tr('Bass/Treble in Kurve')),
        matching: find.byType(Row),
      )
      .first,
  matching: find.byType(Switch),
);

final class _PickedFile extends PlatformFile {
  _PickedFile(String path) : xFile = XFile(path);
  @override
  final XFile xFile;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Picker extends FilePickerPlatform {
  List<PlatformFile> files = [];
  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    expect(type, FileType.custom);
    expect(allowedExtensions, ['json']);
    return files;
  }
}

class _Controller extends Adi2Controller {
  bool isOffline = false;
  final values = <(int, int), int>{};
  final writes = <(int, int, int)>[];
  final eqWrites = <(int, int, int)>[];
  (int, Map<int, int>, Map<int, int>, bool, String)? storedPreset;
  List<EqPresetData>? cache;
  int reads = 0;
  bool failRead = false;
  final loadedSetups = <int>[];
  final savedSetups = <int>[];
  bool offlineData = true;
  int offlineChecks = 0;
  int transfers = 0;
  int transferred = 3;
  int resets = 0;
  int backups = 0;

  @override
  void loadSetup(int n) => loadedSetups.add(n);
  @override
  void saveSetup(int n) => savedSetups.add(n);
  @override
  Future<bool> hasOfflineData() async {
    offlineChecks++;
    return offlineData;
  }

  @override
  Future<int> transferOffline() async {
    transfers++;
    return transferred;
  }

  @override
  Future<void> resetOffline() async {
    resets++;
  }

  @override
  Future<Adi2Backup?> createBackup({void Function(double)? progress}) async {
    backups++;
    return Adi2Backup(
      variant: 'pro',
      label: 'Test Pro',
      created: DateTime(2026, 11, 6),
      values: {},
      presets: [],
      setupNames: {},
    );
  }

  @override
  List<EqPresetData>? get eqPresets => cache;

  @override
  Future<List<EqPresetData>> readEqPresets({
    void Function(double)? progress,
  }) async {
    reads++;
    progress?.call(0.5);
    if (failRead) throw StateError('Read failed');
    cache = [
      for (var n = 0; n < 20; n++)
        EqPresetData(
          number: n,
          name: 'Device ${n + 1}',
          empty: false,
          dual: true,
          left: {4: n + 1},
          right: {4: -n - 1},
        ),
    ];
    progress?.call(1);
    return cache!;
  }

  @override
  Future<void> storeEqPresetData(
    int n,
    Map<int, int> left,
    Map<int, int> right,
    bool dual,
    String name,
  ) async {
    storedPreset = (n, Map.of(left), Map.of(right), dual, name);
  }

  @override
  Adi2Variant get variant => Adi2Variant.pro;
  @override
  bool get offline => isOffline;
  @override
  int? value(int address, int index) => values[(address, index)];
  @override
  int valueOr(int address, int index, int fallback) =>
      value(address, index) ?? fallback;
  @override
  void set(int address, int index, int raw) {
    writes.add((address, index, raw));
    values[(address, index)] = raw;
    notifyListeners();
  }

  @override
  void setEq(int address, int index, int raw) {
    eqWrites.add((address, index, raw));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _Controller controller;
  late AppLanguage previousLanguage;
  late FilePickerPlatform previousPicker;
  late _Picker picker;
  late List<MethodCall> shares;

  setUp(() async {
    previousLanguage = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    directory = await Directory.systemTemp.createTemp('adi2_setups_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    controller = _Controller();
    previousPicker = FilePickerPlatform.instance;
    picker = _Picker();
    FilePickerPlatform.instance = picker;
    shares = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/share'),
          (call) async {
            shares.add(call);
            return 'dev.fluttercommunity.plus/share/unavailable';
          },
        );
  });

  tearDown(() async {
    controller.dispose();
    FilePickerPlatform.instance = previousPicker;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/share'),
          null,
        );
    AppLang.instance.language = previousLanguage;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await directory.delete(recursive: true);
  });

  Future<void> showPage(
    WidgetTester tester, {
    Size size = const Size(700, 3000),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.physicalSize = size * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(body: SetupsPage(ctrl: controller)),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> fileMenu(WidgetTester tester, String entry) async {
    await tap(tester, find.byTooltip('Datei'));
    await tap(tester, find.text(entry));
  }

  testWidgets(
    'Slots laden nur in den Editor und werden einmal automatisch gelesen',
    (tester) async {
      controller.selectedOutput = Adi2Addr.ph12;
      await showPage(tester);
      expect(controller.reads, 1);
      await tap(tester, find.byKey(const ValueKey('eq-slot-19')));
      expect(find.text('+10,0 dB'), findsOneWidget);
      expect(controller.writes, isEmpty);
      expect(controller.eqWrites, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await showPage(tester);
      expect(controller.reads, 1);
    },
  );

  testWidgets(
    'Listen überträgt komplett, Änderungen einzeln und stoppt beim Ausschalten',
    (tester) async {
      await showPage(tester);
      await tap(tester, find.byKey(const ValueKey('eq-slot-1')));
      await tap(tester, find.widgetWithText(OutlinedButton, 'Eingang'));
      await tap(tester, find.byKey(const ValueKey('eq-listen')));
      expect(controller.eqWrites, contains((1, 4, 2)));
      expect(controller.eqWrites, contains((2, 4, -2)));
      expect(controller.writes, [(0, 8, 1)]);
      final count = controller.eqWrites.length;
      await tap(
        tester,
        find
            .descendant(
              of: find.byType(EqBandControls),
              matching: find.byIcon(Icons.add),
            )
            .first,
      );
      expect(controller.eqWrites.length, count + 1);
      expect(controller.eqWrites.last, (1, 4, 3));
      await tap(tester, find.byKey(const ValueKey('eq-listen')));
      final stopped = controller.eqWrites.length;
      await tap(
        tester,
        find
            .descendant(
              of: find.byType(EqBandControls),
              matching: find.byIcon(Icons.add),
            )
            .first,
      );
      expect(controller.eqWrites.length, stopped);
      expect(controller.writes, [(0, 8, 1)]);
    },
  );

  testWidgets('Zielwechsel, L/R und Anzeige-Schalter beachten Listen', (
    tester,
  ) async {
    await showPage(tester);
    await tap(tester, find.byKey(const ValueKey('eq-listen')));
    await tap(tester, find.widgetWithText(OutlinedButton, 'Eingang'));
    expect(controller.eqWrites.last.$1, 2);
    await tap(
      tester,
      find.descendant(
        of: find
            .ancestor(of: find.text('Dual EQ'), matching: find.byType(Row))
            .first,
        matching: find.byType(Switch),
      ),
    );
    expect(controller.writes.last, (0, 8, 1));
    await tap(tester, find.text('Rechts'));
    await tap(
      tester,
      find
          .descendant(
            of: find.byType(EqBandControls),
            matching: find.byIcon(Icons.add),
          )
          .first,
    );
    expect(controller.eqWrites.last, (2, 4, 1));
    final count = controller.eqWrites.length;
    await tap(tester, getCurveSwitch());
    expect(controller.eqWrites.length, count);
    await tap(
      tester,
      find.descendant(
        of: find
            .ancestor(of: find.text('Dual EQ'), matching: find.byType(Row))
            .first,
        matching: find.byType(Switch),
      ),
    );
    expect(controller.writes.last, (0, 8, 0));
  });

  testWidgets(
    'Kopieren und Einfügen gehen über den Editor auf den gewählten Slot',
    (tester) async {
      await showPage(tester);
      await tap(tester, find.byKey(const ValueKey('eq-slot-19')));
      await tap(tester, find.text('Kopieren'));
      await tap(tester, find.byKey(const ValueKey('eq-slot-0')));
      await tap(tester, find.text('Einfügen'));
      await tap(tester, find.text('Ins Gerät speichern'));
      expect(controller.storedPreset, isNull);
      await tap(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(controller.storedPreset!.$1, 0);
      expect(controller.storedPreset!.$2[4], 20);
      expect(controller.storedPreset!.$3[4], -20);
      expect(controller.storedPreset!.$4, isTrue);
      expect(controller.storedPreset!.$5, 'Device 20');
      final expected = EqEditorBuffer()
        ..loadDevicePreset(controller.cache!.last);
      expect(controller.storedPreset!.$2, expected.left);
      expect(controller.storedPreset!.$3, expected.right);
      expect(controller.writes, isEmpty);
      expect(controller.eqWrites, isEmpty);
    },
  );

  testWidgets(
    'Umbenennen begrenzt Namen auf 14 Zeichen und schreibt erst beim Store',
    (tester) async {
      await showPage(tester);
      await tester.longPress(find.byKey(const ValueKey('eq-slot-0')));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.maxLength, 14);
      await tester.enterText(
        find.byType(TextFormField),
        '12345678901234567890',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '12345678901234',
      );
      await tester.enterText(find.byType(TextFormField), 'Headphones');
      await tap(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(controller.storedPreset, isNull);
      expect(find.text('1  Headphones'), findsOneWidget);
      await tap(tester, find.text('Ins Gerät speichern'));
      await tap(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(controller.storedPreset!.$5, 'Headphones');
    },
  );

  testWidgets('Neu einlesen aktualisiert Slotnamen und erhält den Editor', (
    tester,
  ) async {
    await showPage(tester);
    await tap(tester, find.byKey(const ValueKey('eq-slot-19')));
    await tester.longPress(find.byKey(const ValueKey('eq-slot-0')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Renamed');
    await tap(tester, find.widgetWithText(FilledButton, 'Speichern'));
    expect(find.text('1  Renamed'), findsOneWidget);
    await tap(tester, find.text('Neu einlesen'));
    expect(find.text('1  Device 1'), findsOneWidget);
    expect(find.text('+10,0 dB'), findsOneWidget);
    expect(controller.reads, 2);
    expect(controller.eqWrites, isEmpty);
  });

  testWidgets('Clear bestätigt und setzt den Editor zurück', (tester) async {
    await showPage(tester);
    await tap(tester, find.byKey(const ValueKey('eq-slot-19')));
    await tap(tester, find.widgetWithText(OutlinedButton, 'Clear'));
    await tap(tester, find.text('Abbrechen'));
    expect(find.text('+10,0 dB'), findsOneWidget);
    await tap(tester, find.widgetWithText(OutlinedButton, 'Clear'));
    await tap(tester, find.widgetWithText(FilledButton, 'Clear'));
    expect(find.text('0,0 dB'), findsOneWidget);
    expect(find.text('Device 20'), findsNothing);
    expect(controller.eqWrites, isEmpty);
  });

  testWidgets(
    'Offline sind Editor und Bibliothek verfügbar, Geräteaktionen verborgen',
    (tester) async {
      controller.isOffline = true;
      await tester.runAsync(
        () => EqLibrary.save([
          AppEqPreset(name: 'Offline EQ', dual: false, left: {4: 2}, right: {}),
        ]),
      );
      await showPage(tester);
      expect(controller.reads, 0);
      expect(find.text('Ins Gerät speichern'), findsNothing);
      expect(find.text('Neu einlesen'), findsNothing);
      expect(find.text('Geräte-Setups 1–9'), findsNothing);
      await fileMenu(tester, 'Aus App-Bibliothek laden');
      await tap(tester, find.text('Offline EQ'));
      expect(find.text('+1,0 dB'), findsOneWidget);
      expect(controller.eqWrites, isEmpty);
      await fileMenu(tester, 'In App-Bibliothek speichern');
      await tester.enterText(find.byType(TextFormField), 'Saved editor');
      await tap(tester, find.widgetWithText(FilledButton, 'Speichern'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      final items = await tester.runAsync(EqLibrary.load);
      expect(items!.last.name, 'Saved editor');
      expect(items.last.left[4], 2);
      expect(items.last.left.keys, isNot(contains(20)));
      expect(items.last.right.keys, isNot(contains(21)));
    },
  );

  testWidgets(
    'Lesefehler lässt Editor nutzbar und meldet nicht eingelesene Slots',
    (tester) async {
      controller.failRead = true;
      await showPage(tester);
      expect(
        find.text('Vorgang konnte nicht abgeschlossen werden.'),
        findsOneWidget,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tap(tester, find.byKey(const ValueKey('eq-slot-1')));
      expect(controller.writes, isEmpty);
      expect(controller.eqWrites, isEmpty);
      expect(find.text('Nicht eingelesen'), findsWidgets);
      controller.failRead = false;
      await tap(tester, find.text('Neu einlesen'));
      expect(controller.reads, 2);
      expect(find.text('2  Device 2'), findsOneWidget);
    },
  );

  Future<void> finishIo(WidgetTester tester, {Finder? until}) async {
    // Dateizugriffe wechseln zwischen echten I/O-Ereignissen und Test-Microtasks.
    for (var n = 0; n < 50; n++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pumpAndSettle();
      if (until != null) {
        if (until.evaluate().isNotEmpty) return;
      } else {
        final clear = find.widgetWithText(OutlinedButton, tr('Clear'));
        if (tester.widget<OutlinedButton>(clear).onPressed != null) return;
      }
    }
    fail('Dateiaktion wurde nicht abgeschlossen.');
  }

  Finder getDualSwitch() => find.descendant(
    of: find
        .ancestor(of: find.text('Dual EQ'), matching: find.byType(Row))
        .first,
    matching: find.byType(Switch),
  );

  Finder bandChip(String label) =>
      find.descendant(of: find.byType(EqBandChips), matching: find.text(label));

  Finder plus(int n) => find
      .descendant(
        of: find.byType(EqBandControls),
        matching: find.byIcon(Icons.add),
      )
      .at(n);

  void expectBuffer(EqEditorBuffer buffer, int target) {
    expect(controller.eqWrites, [
      for (final e in buffer.left.entries) (target + 1, e.key, e.value),
      for (final e in buffer.right.entries) (target + 2, e.key, e.value),
    ]);
  }

  for (final target in [
    Adi2Addr.input,
    Adi2Addr.line,
    Adi2Addr.ph12,
    Adi2Addr.ph34,
  ]) {
    testWidgets('Listen sendet vollständigen Puffer an Ziel $target', (
      tester,
    ) async {
      controller.selectedOutput = target;
      await showPage(tester);
      await tap(tester, find.byKey(const ValueKey('eq-slot-19')));
      final buffer = EqEditorBuffer()..loadDevicePreset(controller.cache!.last);
      await tap(tester, find.byKey(const ValueKey('eq-listen')));
      expectBuffer(buffer, target);
      expect(controller.writes, [(target, target == 0 ? 8 : OutIdx.dualEq, 1)]);
      controller.eqWrites.clear();
      controller.writes.clear();
      await tap(
        tester,
        find.widgetWithText(
          OutlinedButton,
          target == 0 ? 'Line Out' : 'Eingang',
        ),
      );
      final nextTarget = target == 0 ? Adi2Addr.line : Adi2Addr.input;
      expectBuffer(buffer, nextTarget);
      expect(controller.writes, [
        (nextTarget, nextTarget == 0 ? 8 : OutIdx.dualEq, 1),
      ]);
    });
  }

  testWidgets('Regler, Typ und L/R schreiben jeden Wert über setEq', (
    tester,
  ) async {
    await showPage(tester);
    await tap(tester, find.byKey(const ValueKey('eq-listen')));
    await tap(tester, getDualSwitch());
    for (final (side, address) in [
      ('Rechts', Adi2Addr.lineEqR),
      ('Links', Adi2Addr.lineEqL),
    ]) {
      controller.eqWrites.clear();
      await tap(tester, find.text(side));
      expect(controller.eqWrites, isEmpty);
      for (var n = 0; n < 3; n++) {
        final sliders = find.descendant(
          of: find.byType(EqBandControls),
          matching: find.byType(Slider),
        );
        final slider = sliders.at(n);
        await tester.ensureVisible(slider);
        await tester.drag(slider, const Offset(60, 0));
        await tester.pumpAndSettle();
        expect(controller.eqWrites.last.$1, address);
        expect(controller.eqWrites.last.$2, [4, 5, 6][n]);
        final controls = tester.widget<EqBandControls>(
          find.byType(EqBandControls),
        );
        expect(
          controller.eqWrites.last.$3,
          controls.read(controls.address, [4, 5, 6][n]),
        );
      }
      await tap(
        tester,
        find.descendant(
          of: find.byType(EqTypeTiles),
          matching: find.text('Peak'),
        ),
      );
      expect(controller.eqWrites.last, (address, 3, 0));
      await tap(
        tester,
        find.descendant(
          of: find.byType(EqTypeTiles),
          matching: find.text('Shelf'),
        ),
      );
      expect(controller.eqWrites.last, (address, 3, 1));
    }
    await tap(tester, find.text('Rechts'));
    for (final (label, gain) in [('Bass', 21), ('Treble', 24)]) {
      await tap(tester, bandChip(label));
      await tap(tester, plus(0));
      expect(controller.eqWrites.last, (Adi2Addr.lineEqL, gain, 1));
    }
    await tap(tester, getDualSwitch());
    expect(controller.writes.last, (Adi2Addr.line, OutIdx.dualEq, 0));
    expect(find.text('Rechts'), findsNothing);
    await tap(tester, find.byKey(const ValueKey('eq-listen')));
    controller.eqWrites.clear();
    controller.writes.clear();
    await tap(tester, plus(0));
    await tap(tester, getDualSwitch());
    await tap(tester, find.text('Rechts'));
    await tap(tester, find.widgetWithText(OutlinedButton, 'Eingang'));
    await tap(tester, bandChip('1'));
    await tap(
      tester,
      find.descendant(
        of: find.byType(EqTypeTiles),
        matching: find.text('Peak'),
      ),
    );
    expect(controller.eqWrites, isEmpty);
    expect(controller.writes, isEmpty);
  });

  testWidgets(
    'Punktziehen im Editor sendet Frequenz und Gain der gewählten Seite',
    (tester) async {
      await showPage(tester);
      await tap(tester, getDualSwitch());
      await tap(tester, find.text('Rechts'));
      await tap(tester, find.byKey(const ValueKey('eq-listen')));
      controller.eqWrites.clear();
      final plot = find.byType(EqPlot);
      final size = tester.getSize(plot);
      final origin = tester.getTopLeft(plot);
      final point =
          origin +
          Offset(
            36 + freqToX(1000) * (size.width - 50),
            16 + (size.height - 42) / 2,
          );
      await tester.dragFrom(point, const Offset(35, -35));
      await tester.pumpAndSettle();
      expect(controller.eqWrites, isNotEmpty);
      expect(
        controller.eqWrites.every(
          (w) => w.$1 == Adi2Addr.lineEqR && [10, 11].contains(w.$2),
        ),
        isTrue,
      );
      expect(controller.eqWrites.last.$3, greaterThan(0));
      await tap(tester, find.byKey(const ValueKey('eq-listen')));
      controller.eqWrites.clear();
      final controls = tester.widget<EqBandControls>(
        find.byType(EqBandControls),
      );
      expect(controls.band, 2);
      final newPoint =
          origin +
          Offset(
            36 +
                freqToX(controls.read(controls.address, 11)!.toDouble()) *
                    (size.width - 50),
            point.dy - 35,
          );
      await tester.dragFrom(newPoint, const Offset(-20, 20));
      await tester.pumpAndSettle();
      expect(controller.eqWrites, isEmpty);
    },
  );

  testWidgets('Clear sendet erst nach Bestätigung alle Werkswerte bei Listen', (
    tester,
  ) async {
    await showPage(tester);
    await tap(tester, find.byKey(const ValueKey('eq-slot-19')));
    await tap(tester, find.text('Rechts'));
    await tap(tester, find.byKey(const ValueKey('eq-listen')));
    controller.eqWrites.clear();
    controller.writes.clear();
    await tap(tester, find.widgetWithText(OutlinedButton, 'Clear'));
    await tap(tester, find.text('Abbrechen'));
    expect(controller.eqWrites, isEmpty);
    await tap(tester, find.widgetWithText(OutlinedButton, 'Clear'));
    await tap(tester, find.widgetWithText(FilledButton, 'Clear'));
    expectBuffer(EqEditorBuffer(), Adi2Addr.line);
    expect(controller.writes, [(Adi2Addr.line, OutIdx.dualEq, 0)]);
    expect(find.text('Rechts'), findsNothing);
    expect(find.text('Device 20'), findsNothing);
  });

  testWidgets(
    'Alle 20 Plätze laden beide Seiten, Name und Dual ohne Live-Schreiben',
    (tester) async {
      await showPage(tester);
      for (var n = 0; n < 20; n++) {
        await tap(tester, find.byKey(ValueKey('eq-slot-$n')));
        final controls = tester.widget<EqBandControls>(
          find.byType(EqBandControls),
        );
        final buffer = EqEditorBuffer()..loadDevicePreset(controller.cache![n]);
        expect(controls.read(Adi2Addr.presetEqL, 4), n + 1);
        expect(controls.read(Adi2Addr.presetEqR, 4), -n - 1);
        for (final band in eqBands) {
          expect(
            controls.read(Adi2Addr.presetEqL, band.freqIdx),
            buffer.left[band.freqIdx],
          );
        }
        expect(tester.widget<Switch>(getDualSwitch()).value, isTrue);
        expect(find.text('Device ${n + 1}'), findsOneWidget);
      }
      expect(controller.eqWrites, isEmpty);
      expect(controller.writes, isEmpty);
    },
  );

  testWidgets('Datei speichert, lädt, benennt um, teilt und löscht dauerhaft', (
    tester,
  ) async {
    await showPage(tester);
    await tap(tester, find.byKey(const ValueKey('eq-slot-19')));
    final expected = EqEditorBuffer()..loadDevicePreset(controller.cache!.last);
    await fileMenu(tester, 'In App-Bibliothek speichern');
    await tester.enterText(find.byType(TextFormField), 'Library Test');
    await tap(tester, find.widgetWithText(FilledButton, 'Speichern'));
    await finishIo(tester);
    var items = (await tester.runAsync(EqLibrary.load))!;
    expect(
      items.single.toJson(),
      expected.toAppPreset(name: 'Library Test').toJson(),
    );
    await fileMenu(tester, 'Aus App-Bibliothek laden');
    await tap(
      tester,
      find.descendant(
        of: find.byType(ListTile),
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    await tap(tester, find.text('Umbenennen'));
    await tester.enterText(find.byType(TextFormField), 'Renamed Library');
    await tap(tester, find.widgetWithText(FilledButton, 'Speichern'));
    await finishIo(tester);
    expect(find.text('Renamed Library'), findsOneWidget);
    items = (await tester.runAsync(EqLibrary.load))!;
    expect(items.single.name, 'Renamed Library');
    expect(items.single.left, expected.left);
    await tap(
      tester,
      find.descendant(
        of: find.byType(ListTile),
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    await tap(tester, find.text('Teilen'));
    await finishIo(tester);
    expect(shares.single.method, 'share');
    final args = shares.single.arguments as Map;
    expect(args['subject'], 'Renamed Library');
    expect(args['mimeTypes'], ['application/json']);
    final exported = await tester.runAsync(
      () async => AppEqPreset.decode(
        await File((args['paths'] as List).single as String).readAsString(),
      ),
    );
    expect(exported!.toJson(), items.single.toJson());
    await tap(tester, find.text('Renamed Library'));
    expect(find.text('+10,0 dB'), findsOneWidget);
    await fileMenu(tester, 'Teilen');
    await finishIo(tester);
    expect(shares, hasLength(2));
    await fileMenu(tester, 'Aus App-Bibliothek laden');
    await tap(
      tester,
      find.descendant(
        of: find.byType(ListTile),
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    await tap(tester, find.text('Löschen'));
    await tap(tester, find.text('Abbrechen'));
    expect((await tester.runAsync(EqLibrary.load))!, hasLength(1));
    await tap(
      tester,
      find.descendant(
        of: find.byType(ListTile),
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    await tap(tester, find.text('Löschen'));
    await tap(tester, find.widgetWithText(FilledButton, 'Löschen'));
    await finishIo(tester);
    expect(find.text('Noch keine EQ-Presets gesichert.'), findsOneWidget);
    expect((await tester.runAsync(EqLibrary.load))!, isEmpty);
    expect(controller.eqWrites, isEmpty);
    expect(controller.writes, isEmpty);
  });

  testWidgets(
    'Import behandelt Abbruch, kaputte Datei und gültige Datei mit Listen',
    (tester) async {
      await showPage(tester);
      await fileMenu(tester, 'Importieren');
      expect(find.text('Datei ist kein EQ-Preset.'), findsNothing);
      final file = File('${directory.path}/import.json');
      await tester.runAsync(() => file.writeAsString('{invalid'));
      picker.files = [_PickedFile(file.path)];
      await fileMenu(tester, 'Importieren');
      await finishIo(tester);
      expect(find.text('Datei ist kein EQ-Preset.'), findsOneWidget);
      expect((await tester.runAsync(EqLibrary.load))!, isEmpty);
      final preset = AppEqPreset(
        name: 'Imported',
        dual: true,
        left: {4: 6, 21: -2},
        right: {4: -8},
      );
      await tester.runAsync(() => file.writeAsString(preset.encode()));
      await tap(tester, find.byKey(const ValueKey('eq-listen')));
      controller.eqWrites.clear();
      controller.writes.clear();
      await fileMenu(tester, 'Importieren');
      await finishIo(tester);
      expect(find.text('Imported'), findsOneWidget);
      expectBuffer(EqEditorBuffer()..loadAppPreset(preset), Adi2Addr.line);
      expect(controller.writes, [(Adi2Addr.line, OutIdx.dualEq, 1)]);
      expect(
        (await tester.runAsync(EqLibrary.load))!.single.toJson(),
        preset.toJson(),
      );
    },
  );

  testWidgets('Geräte-Setups 1–9 laden direkt und speichern nach Bestätigung', (
    tester,
  ) async {
    controller.names[0x25] = 'Named Setup';
    await showPage(tester);
    for (var n = 1; n <= 9; n++) {
      final row = find
          .ancestor(
            of: find.text(n == 5 ? 'Named Setup' : 'Setup $n'),
            matching: find.byType(Row),
          )
          .last;
      await tap(
        tester,
        find.descendant(
          of: row,
          matching: find.widgetWithText(TextButton, 'Laden'),
        ),
      );
      expect(controller.loadedSetups.last, n);
      final save = find.descendant(
        of: row,
        matching: find.widgetWithText(TextButton, 'Speichern'),
      );
      await tap(tester, save);
      await tap(tester, find.text('Abbrechen'));
      expect(controller.savedSetups.length, n - 1);
      await tap(tester, save);
      await tap(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(controller.savedSetups.last, n);
    }
    expect(controller.loadedSetups, [for (var n = 1; n <= 9; n++) n]);
    expect(controller.savedSetups, controller.loadedSetups);
  });

  for (final language in AppLanguage.values) {
    testWidgets(
      'Transfer-Info öffnet ohne Übertragung, Eintrag bestätigt weiter (${language.name})',
      (tester) async {
        AppLang.instance.language = language;
        await showPage(tester, size: const Size(390, 844));
        final title = tr('Offline-Einstellungen übertragen');
        await tester.scrollUntilVisible(
          find.text(title),
          400,
          scrollable: find.byType(Scrollable).first,
        );
        final info = find.byTooltip(tr('Info'));
        expect(
          find.descendant(of: info, matching: find.byIcon(Icons.info_outline)),
          findsOneWidget,
        );
        await tap(tester, info);
        final sheet = find.byType(BottomSheet);
        expect(sheet, findsOneWidget);
        expect(
          find.descendant(of: sheet, matching: find.text(title)),
          findsOneWidget,
        );
        for (final prefix
            in language == AppLanguage.de
                ? [
                    'Was es ist:',
                    'Was übertragen wird:',
                    'Sicherheit:',
                    'Was unverändert bleibt:',
                    'Tipp:',
                  ]
                : [
                    'What it is:',
                    'What is transferred:',
                    'Safety:',
                    'What stays unchanged:',
                    'Tip:',
                  ]) {
          expect(
            find.descendant(of: sheet, matching: find.textContaining(prefix)),
            findsOneWidget,
          );
        }
        expect(controller.offlineChecks, 0);
        expect(controller.transfers, 0);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(
          find.descendant(
            of: sheet,
            matching: find.textContaining(
              language == AppLanguage.de ? 'Tipp:' : 'Tip:',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        Navigator.of(tester.element(sheet)).pop();
        await tester.pumpAndSettle();
        await tap(tester, find.text(title));
        expect(find.byType(BottomSheet), findsNothing);
        expect(
          find.text(tr('Offline-Einstellungen übertragen?')),
          findsOneWidget,
        );
        expect(controller.offlineChecks, 1);
        expect(controller.transfers, 0);
        expect(
          find.textContaining(
            tr(
              'Ein höherer Ref Level kann den Ausgang lauter machen, auch wenn die Lautstärke nicht steigt. Ausgänge vorher leiser stellen oder eine Obergrenze aktivieren.',
            ),
          ),
          findsOneWidget,
        );
        await tap(tester, find.widgetWithText(FilledButton, tr('Übertragen')));
        expect(controller.transfers, 1);
      },
    );
  }

  testWidgets(
    'Weiteres prüft Offline-Daten, bestätigt Transfer und meldet Ergebnis',
    (tester) async {
      await showPage(tester);
      controller.offlineData = false;
      await tap(tester, find.text('Offline-Einstellungen übertragen'));
      expect(controller.offlineChecks, 1);
      expect(
        find.text('Für dieses Modell gibt es keinen Offline-Stand.'),
        findsOneWidget,
      );
      expect(controller.transfers, 0);
      controller.offlineData = true;
      await tap(tester, find.text('Offline-Einstellungen übertragen'));
      await tap(tester, find.text('Abbrechen'));
      expect(controller.transfers, 0);
      await tap(tester, find.text('Offline-Einstellungen übertragen'));
      await tap(tester, find.widgetWithText(FilledButton, 'Übertragen'));
      expect(controller.transfers, 1);
      expect(find.text('3 Einstellungen übertragen.'), findsOneWidget);
      controller.transferred = 0;
      await tap(tester, find.text('Offline-Einstellungen übertragen'));
      await tap(tester, find.widgetWithText(FilledButton, 'Übertragen'));
      expect(controller.transfers, 2);
      expect(
        find.text('Gerät entspricht bereits dem Offline-Stand.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('Backup-Eintrag öffnet BackupPage mit demselben Controller', (
    tester,
  ) async {
    await showPage(tester);
    await tap(tester, find.text('Backup sichern / laden'));
    await finishIo(tester, until: find.text('Noch keine.'));
    expect(
      tester.widget<BackupPage>(find.byType(BackupPage)).ctrl,
      same(controller),
    );
    await tap(tester, find.text('Jetzt sichern'));
    await finishIo(tester, until: find.textContaining('Backup gespeichert'));
    expect(controller.backups, 1);
    final backups = await tester.runAsync(BackupStore.list);
    expect(backups, hasLength(1));
    expect(backups!.single.$2.label, 'Test Pro');
  });

  for (final language in AppLanguage.values) {
    for (final withOutput in [false, true]) {
      testWidgets(
        'Backup-Dialog Ref-Level-Warnung nur mit Ausgang (${language.name}, $withOutput)',
        (tester) async {
          AppLang.instance.language = language;
          await tester.runAsync(
            () => BackupStore.save(
              Adi2Backup(
                variant: 'pro',
                label: 'Test Pro',
                created: DateTime(2026, 11, 6),
                values: {
                  (withOutput ? Adi2Addr.line : Adi2Addr.device) << 8: 0,
                },
                presets: [],
                setupNames: {},
              ),
            ),
          );
          await showPage(tester);
          await tap(tester, find.text(tr('Backup sichern / laden')));
          await finishIo(tester, until: find.textContaining('Test Pro,'));
          await tap(tester, find.textContaining('Test Pro,'));
          expect(find.text(tr('Backup wiederherstellen?')), findsOneWidget);
          expect(
            find.text(
              tr(
                'Ein höherer Ref Level kann den Ausgang lauter machen, auch wenn die Lautstärke nicht steigt. Ausgänge vorher leiser stellen oder eine Obergrenze aktivieren.',
              ),
            ),
            withOutput ? findsOneWidget : findsNothing,
          );
          await tap(tester, find.text(tr('Abbrechen')));
        },
      );
    }
  }

  testWidgets(
    'Offline-Editor bearbeitet Werte und setzt Offline-Stand zurück',
    (tester) async {
      controller.isOffline = true;
      await showPage(tester);
      await tap(tester, plus(0));
      expect(find.text('+0,5 dB'), findsOneWidget);
      await tap(tester, getDualSwitch());
      await tap(tester, find.text('Rechts'));
      await tap(tester, plus(0));
      expect(controller.eqWrites, isEmpty);
      expect(controller.writes, isEmpty);
      expect(find.text('Backup sichern / laden'), findsNothing);
      expect(find.text('Offline-Einstellungen übertragen'), findsNothing);
      await tap(tester, find.text('Offline-Stand auf Werkseinstellung'));
      expect(controller.resets, 1);
    },
  );

  testWidgets(
    'Slotwahl und Einfügen senden mit Listen den gesamten unabhängigen Puffer',
    (tester) async {
      await showPage(tester);
      await tap(tester, find.byKey(const ValueKey('eq-slot-19')));
      final copied = EqEditorBuffer()..loadDevicePreset(controller.cache!.last);
      await tap(tester, find.text('Kopieren'));
      await tap(tester, plus(0));
      await tap(tester, find.byKey(const ValueKey('eq-listen')));
      controller.eqWrites.clear();
      await tap(tester, find.byKey(const ValueKey('eq-slot-0')));
      expectBuffer(
        EqEditorBuffer()..loadDevicePreset(controller.cache!.first),
        Adi2Addr.line,
      );
      controller.eqWrites.clear();
      await tap(tester, find.text('Einfügen'));
      expectBuffer(copied, Adi2Addr.line);
      expect(find.text('Device 20'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('eq-listen')));
      controller.eqWrites.clear();
      await tap(tester, find.byKey(const ValueKey('eq-slot-0')));
      await tap(tester, find.text('Einfügen'));
      expect(controller.eqWrites, isEmpty);
    },
  );

  testWidgets(
    'App-Bibliothek lädt bei Listen vollständig und setzt die Seite auf Links',
    (tester) async {
      final preset = AppEqPreset(
        name: 'Listen library',
        dual: true,
        left: {4: 6, 21: -2},
        right: {4: -8},
      );
      await tester.runAsync(() => EqLibrary.save([preset]));
      await showPage(tester);
      await tap(tester, getDualSwitch());
      await tap(tester, find.text('Rechts'));
      await tap(tester, find.byKey(const ValueKey('eq-listen')));
      controller.eqWrites.clear();
      await fileMenu(tester, 'Aus App-Bibliothek laden');
      await tap(tester, find.text('Listen library'));
      expectBuffer(EqEditorBuffer()..loadAppPreset(preset), Adi2Addr.line);
      expect(
        tester.widget<EqSideSwitch>(find.byType(EqSideSwitch)).right,
        isFalse,
      );
    },
  );

  testWidgets('Store übergibt bearbeitete Seiten, Dual und bestätigten Namen', (
    tester,
  ) async {
    await showPage(tester);
    await tap(tester, find.byKey(const ValueKey('eq-slot-9')));
    await tap(tester, plus(0));
    await tap(tester, find.text('Rechts'));
    await tap(tester, plus(1));
    await tap(tester, bandChip('Treble'));
    await tap(tester, plus(0));
    final controls = tester.widget<EqBandControls>(find.byType(EqBandControls));
    final expected = EqEditorBuffer()..loadDevicePreset(controller.cache![9]);
    expected.set(Adi2Addr.presetEqL, 4, 11);
    expected.set(Adi2Addr.presetEqR, 5, controls.read(Adi2Addr.presetEqR, 5)!);
    expected.set(Adi2Addr.presetEqL, 24, 1);
    await tap(tester, find.text('Ins Gerät speichern'));
    await tap(tester, find.text('Abbrechen'));
    expect(controller.storedPreset, isNull);
    await tap(tester, find.text('Ins Gerät speichern'));
    await tester.enterText(find.byType(TextFormField), '');
    await tap(tester, find.widgetWithText(FilledButton, 'Speichern'));
    expect(find.text('Bitte einen Namen eingeben.'), findsOneWidget);
    expect(controller.storedPreset, isNull);
    await tester.enterText(find.byType(TextFormField), 'Edited preset');
    await tap(tester, find.widgetWithText(FilledButton, 'Speichern'));
    expect(controller.storedPreset!.$1, 9);
    expect(controller.storedPreset!.$2, expected.left);
    expect(controller.storedPreset!.$3, expected.right);
    expect(controller.storedPreset!.$4, isTrue);
    expect(controller.storedPreset!.$5, 'Edited preset');
    expect(controller.writes, isEmpty);
    expect(controller.eqWrites, isEmpty);
  });

  for (final language in AppLanguage.values) {
    testWidgets(
      'Handy-Hochformat bleibt ohne Layoutfehler (${language.name})',
      (tester) async {
        AppLang.instance.language = language;
        controller.isOffline = true;
        await showPage(tester, size: const Size(320, 800));
        expect(tester.takeException(), isNull);
        expect(find.text(tr('Ziel-EQ')), findsNothing);
        final file = find.byTooltip(tr('Datei'));
        final clear = find.widgetWithText(OutlinedButton, tr('Clear'));
        expect(find.byIcon(Icons.backspace_outlined), findsNothing);
        expect(find.byIcon(Icons.multiline_chart), findsNothing);
        expect(
          tester.getCenter(clear).dy,
          tester.getCenter(getDualSwitch()).dy,
        );
        expect(
          tester.getBottomRight(clear).dx,
          tester.getBottomRight(find.byType(EqPlot)).dx,
        );
        expect(
          tester.getBottomRight(clear).dy,
          lessThanOrEqualTo(tester.getTopLeft(find.byType(EqPlot)).dy),
        );
        final curveRow = find
            .ancestor(of: getCurveSwitch(), matching: find.byType(Row))
            .first;
        expect(tester.getSize(curveRow).height, 36);
        expect(
          tester.getTopLeft(curveRow).dx,
          tester.getTopLeft(find.byType(EqPlot)).dx,
        );
        // Zeile sitzt direkt unter den Bandreglern (unter Q).
        expect(
          tester.getTopLeft(curveRow).dy,
          greaterThanOrEqualTo(
            tester.getBottomRight(find.byType(EqBandControls)).dy,
          ),
        );
        expect(
          tester.getTopLeft(file).dy,
          lessThan(
            tester.getTopLeft(find.byKey(const ValueKey('eq-listen'))).dy,
          ),
        );
        final targetButtons = [
          for (final address in [
            Adi2Addr.line,
            Adi2Addr.ph12,
            Adi2Addr.ph34,
            0,
          ])
            find.byKey(ValueKey('eq-target-$address')),
        ];
        final firstSize = tester.getSize(targetButtons.first);
        final firstTop = tester.getTopLeft(targetButtons.first).dy;
        for (final target in targetButtons) {
          expect(tester.getSize(target).width, closeTo(firstSize.width, 0.01));
          expect(tester.getTopLeft(target).dy, firstTop);
        }
        final listen = find.byKey(const ValueKey('eq-listen'));
        expect(
          find.text(trf('Auf {output} anhören', {'output': 'Line Out'})),
          findsOneWidget,
        );
        await tap(tester, listen);
        expect(
          find.text(trf('Anhören auf {output}', {'output': 'Line Out'})),
          findsOneWidget,
        );
        expect(
          tester
              .widget<OutlinedButton>(listen)
              .style!
              .backgroundColor!
              .resolve({}),
          Palette.amber,
        );
        await tap(tester, targetButtons[1]);
        expect(
          find.text(trf('Anhören auf {output}', {'output': 'Phones 1/2'})),
          findsOneWidget,
        );
        await tester.ensureVisible(getDualSwitch());
        await tester.pumpAndSettle();
        final clearPosition = tester.getTopLeft(clear);
        final clearSize = tester.getSize(clear);
        final plotPosition = tester.getTopLeft(find.byType(EqPlot));
        await tester.tap(getDualSwitch());
        await tester.pumpAndSettle();
        expect(find.byType(EqSideSwitch), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(tester.getTopLeft(clear), clearPosition);
        expect(tester.getSize(clear), clearSize);
        expect(tester.getTopLeft(find.byType(EqPlot)), plotPosition);
        expect(
          tester.getCenter(clear).dy,
          tester.getCenter(getDualSwitch()).dy,
        );
        expect(
          tester.getBottomRight(clear).dx,
          tester.getBottomRight(find.byType(EqPlot)).dx,
        );
        expect(
          tester.getBottomRight(find.byType(EqSideSwitch)).dx,
          lessThan(tester.getTopLeft(clear).dx),
        );
        await tester.tap(getDualSwitch());
        await tester.pumpAndSettle();
        expect(find.byType(EqSideSwitch), findsNothing);
        expect(tester.getTopLeft(clear), clearPosition);
        expect(tester.getTopLeft(find.byType(EqPlot)), plotPosition);
        final curve = getCurveSwitch();
        expect(find.byType(EqCurveControls), findsOneWidget);
        final writesBeforeCurve = List.of(controller.writes);
        await tap(tester, curve);
        expect(
          tester.widget<EqPlot>(find.byType(EqPlot)).includeBassTreble,
          isFalse,
        );
        await tap(tester, curve);
        expect(
          tester.widget<EqPlot>(find.byType(EqPlot)).includeBassTreble,
          isTrue,
        );
        expect(controller.writes, writesBeforeCurve);
        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(ListView).first, const Offset(0, -650));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
