import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/offline_defaults.dart';
import 'package:adi2_remote/easy/easy_layout.dart';
import 'package:adi2_remote/easy/easy_long_press.dart';
import 'package:adi2_remote/eq/eq_library.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/eq_page.dart';
import 'package:adi2_remote/ui/outputs_page.dart';
import 'package:adi2_remote/ui/param_tile.dart';
import 'package:adi2_remote/ui/protection_page.dart';
import 'package:adi2_remote/ui/signal_flow.dart';
import 'package:adi2_remote/ui/signal_flow_data.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:adi2_remote/ui/volume_ring.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Controller extends Adi2Controller {
  _Controller(this.variant) : values = offlineDefaults(variant) {
    state = ConnState.connected;
    selectedOutput = Adi2Addr.ph34;
    names[0x24] = 'Studio';
  }
  @override
  final Adi2Variant variant;
  final Map<int, int> values;
  final writes = <(int, int, int)>[];
  final volumes = <(int, int)>[];
  final loads = <int>[];
  final saves = <int>[];
  final renames = <(int, String)>[];
  final stops = <int>[];
  bool isOffline = false;
  @override
  bool get offline => isOffline;
  @override
  int? value(int address, int index) => values[address << 8 | index];
  @override
  int valueOr(int address, int index, int fallback) =>
      value(address, index) ?? fallback;
  @override
  void set(int address, int index, int raw) {
    writes.add((address, index, raw));
    values[address << 8 | index] = raw;
    notifyListeners();
  }

  @override
  void setVolume(int address, int raw, {bool followLink = true}) {
    volumes.add((address, raw));
    values[address << 8 | OutIdx.volume] = raw;
    notifyListeners();
  }

  @override
  int? stopVolumeRamp(int address) {
    stops.add(address);
    return null;
  }

  @override
  void loadSetup(int n) => loads.add(n);
  @override
  void saveSetup(int n) => saves.add(n);
  @override
  void renameSetup(int n, String name) {
    renames.add((n, name));
    names[0x20 + n] = name;
    notifyListeners();
  }

  @override
  Future<void> requestPresetNames() async {}
}

// An explicit expectation for every persisted type, independent of the switch.
const _expected = {
  EasyTileType.volumeRing: EasyLongPressAction.none,
  EasyTileType.volumeDown: EasyLongPressAction.volumeDown,
  EasyTileType.volumeUp: EasyLongPressAction.volumeUp,
  EasyTileType.outputSelect: EasyLongPressAction.phones,
  EasyTileType.mute: EasyLongPressAction.mute,
  EasyTileType.dim: EasyLongPressAction.dimInfo,
  EasyTileType.loudness: EasyLongPressAction.loudness,
  EasyTileType.crossfeed: EasyLongPressAction.crossfeed,
  EasyTileType.recall: EasyLongPressAction.recall,
  EasyTileType.link: EasyLongPressAction.link,
  EasyTileType.lock: EasyLongPressAction.lock,
  EasyTileType.bass: EasyLongPressAction.bass,
  EasyTileType.treble: EasyLongPressAction.treble,
  EasyTileType.balance: EasyLongPressAction.balance,
  EasyTileType.refLevel: EasyLongPressAction.refLevel,
  EasyTileType.daFilter: EasyLongPressAction.daFilter,
  EasyTileType.source: EasyLongPressAction.source,
  EasyTileType.eqEnable: EasyLongPressAction.eq,
  EasyTileType.eqPage: EasyLongPressAction.eq,
  EasyTileType.limit: EasyLongPressAction.limit,
  EasyTileType.outputSettings: EasyLongPressAction.outputSettings,
  EasyTileType.setup: EasyLongPressAction.setup,
  EasyTileType.eqPreset: EasyLongPressAction.eq,
  EasyTileType.sourceDirect: EasyLongPressAction.none,
  EasyTileType.toggleOutputs: EasyLongPressAction.mute,
  EasyTileType.basicMode: EasyLongPressAction.signalFlow,
  EasyTileType.volumeDirect: EasyLongPressAction.none,
  EasyTileType.appPreset: EasyLongPressAction.none,
};

EasyTile _tile(
  EasyTileType type, {
  EasyTileSize size = EasyTileSize.wide,
  double height = 1.5,
}) => EasyTile(
  type: type,
  size: size,
  height: type == EasyTileType.volumeRing ? 2 : height,
  // A fixed output different from the selected output detects wrong routing.
  output: Adi2Addr.line,
  param: switch (type) {
    EasyTileType.setup => 4,
    EasyTileType.eqPreset => 7,
    EasyTileType.basicMode => 3,
    EasyTileType.volumeDirect => -30.0,
    EasyTileType.sourceDirect => 2,
    EasyTileType.appPreset => AppEqPreset(
      name: 'App',
      dual: false,
      left: {3: 0},
      right: {},
    ).toJson(),
    _ => null,
  },
);

void main() {
  late _Controller ctrl;
  late AppLanguage previous;
  setUp(() async {
    previous = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
    ctrl = _Controller(Adi2Variant.pro4ex);
  });
  tearDown(() {
    ctrl.dispose();
    AppLang.instance.language = previous;
  });

  Future<void> show(
    WidgetTester tester,
    EasyTile tile, {
    ValueChanged<int>? onEdit,
    bool movable = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: OutputsPage(
            key: UniqueKey(),
            ctrl: ctrl,
            easyLayout: EasyLayout(tiles: [tile]),
            onEditTile: onEdit,
            onMoveTile: movable ? (_, _, _) {} : null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder getTile() => find.byKey(const ValueKey('easy-tile-0'));
  Future<void> hold(WidgetTester tester) async {
    final gesture = await tester.startGesture(tester.getCenter(getTile()));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 800));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Future<void> menu(WidgetTester tester, String action) async {
    await hold(tester);
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
  }

  test('Central policy explicitly covers every tile type', () {
    expect(_expected.keys.toSet(), EasyTileType.values.toSet());
    for (final e in _expected.entries) {
      expect(easyLongPressAction(e.key), e.value, reason: e.key.name);
    }
  });

  for (final entry in _expected.entries) {
    testWidgets('Operating long press ${entry.key.name}: ${entry.value.name}', (
      tester,
    ) async {
      await show(tester, _tile(entry.key));
      await hold(tester);
      expect(find.byTooltip('Kachel bearbeiten'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(ctrl.loads, isEmpty);
      expect(ctrl.saves, isEmpty);
      expect(ctrl.renames, isEmpty);
      switch (entry.value) {
        case EasyLongPressAction.none:
          expect(find.byType(BottomSheet), findsNothing);
          expect(find.byType(SnackBar), findsNothing);
          expect(find.byType(EqPage), findsNothing);
          expect(find.byType(ProtectionPage), findsNothing);
          expect(find.byType(OutputSettingsPage), findsNothing);
          expect(ctrl.writes, isEmpty);
          expect(ctrl.volumes, isEmpty);
        case EasyLongPressAction.volumeDown || EasyLongPressAction.volumeUp:
          expect(find.byType(BottomSheet), findsNothing);
          expect(find.byType(ProtectionPage), findsNothing);
          expect(ctrl.volumes.length, greaterThan(1));
          final delta = entry.key == EasyTileType.volumeUp ? 5 : -5;
          for (var i = 0; i < ctrl.volumes.length; i++) {
            expect(ctrl.volumes[i].$1, Adi2Addr.line);
            if (i > 0) {
              expect(ctrl.volumes[i].$2 - ctrl.volumes[i - 1].$2, delta);
            }
          }
          if (delta > 0) expect(ctrl.stops, contains(Adi2Addr.line));
          final count = ctrl.volumes.length;
          await tester.pump(const Duration(seconds: 1));
          expect(ctrl.volumes.length, count);
        case EasyLongPressAction.eq:
          final page = tester.widget<EqPage>(find.byType(EqPage));
          expect(page.channelAddr, Adi2Addr.line);
          expect(page.title, 'Line Out');
          expect(find.byType(ProtectionPage), findsNothing);
        case EasyLongPressAction.limit:
          expect(
            tester
                .widget<ProtectionPage>(find.byType(ProtectionPage))
                .out
                .address,
            Adi2Addr.line,
          );
        case EasyLongPressAction.outputSettings:
          expect(
            tester
                .widget<OutputSettingsPage>(find.byType(OutputSettingsPage))
                .out
                .address,
            Adi2Addr.line,
          );
        case EasyLongPressAction.dimInfo:
          expect(find.byType(BottomSheet), findsNothing);
          expect(
            find.text(
              'Dim senkt die Lautstärke um 20 dB. Am Gerät gibt es dafür keine Einstellungen.',
            ),
            findsOneWidget,
          );
          expect(ctrl.writes, isEmpty);
        case EasyLongPressAction.signalFlow:
          expect(
            tester
                .widget<SignalFlowSheet>(find.byType(SignalFlowSheet))
                .initialMode,
            SignalFlowMode.preamp,
          );
          expect(ctrl.writes, isEmpty);
        case EasyLongPressAction.setup:
          expect(find.byType(BottomSheet), findsOneWidget);
          for (final text in [
            'Studio',
            'Laden',
            'Aktuelle Einstellungen hier speichern',
            'Umbenennen',
          ]) {
            expect(
              find.descendant(
                of: find.byType(BottomSheet),
                matching: find.text(text),
              ),
              findsOneWidget,
            );
          }
          expect(find.byType(EqPage), findsNothing);
        default:
          expect(find.byType(BottomSheet), findsOneWidget);
          final title = switch (entry.value) {
            EasyLongPressAction.phones => 'Kopfhörer-Ausgänge',
            EasyLongPressAction.mute => 'Mute und Umschalten',
            EasyLongPressAction.loudness => 'Loudness, Line Out',
            EasyLongPressAction.crossfeed => 'Crossfeed',
            EasyLongPressAction.recall => 'Recall, Line Out',
            EasyLongPressAction.link => 'Link Volume',
            EasyLongPressAction.lock => 'Lock',
            EasyLongPressAction.bass => 'Bass',
            EasyLongPressAction.treble => 'Treble',
            EasyLongPressAction.balance => 'Bal',
            EasyLongPressAction.refLevel => 'Ref Level, Line Out',
            EasyLongPressAction.daFilter => 'DA-Filter',
            EasyLongPressAction.source => 'Quelle',
            _ => throw StateError('Missing widget expectation'),
          };
          expect(
            find.descendant(
              of: find.byType(BottomSheet),
              matching: find.text(title),
            ),
            findsWidgets,
          );
          final paramIndex = switch (entry.key) {
            EasyTileType.balance => OutIdx.balance,
            EasyTileType.lock => OutIdx.lockVolume,
            EasyTileType.loudness => OutIdx.loudness,
            _ => null,
          };
          if (paramIndex != null) {
            final params = tester.widgetList<ParamTile>(find.byType(ParamTile));
            expect(
              params.any(
                (p) => p.address == Adi2Addr.line && p.def.index == paramIndex,
              ),
              isTrue,
            );
          }
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final variant in Adi2Variant.values.where((v) => v.isDac)) {
    testWidgets('DAC output selection has no long press: ${variant.name}', (
      tester,
    ) async {
      ctrl.dispose();
      ctrl = _Controller(variant);
      await show(tester, _tile(EasyTileType.outputSelect));
      final selected = ctrl.selectedOutput;
      final segment = find.byKey(ValueKey('easy-segment-0-${Adi2Addr.line}'));
      await tester.longPress(segment);
      await tester.pumpAndSettle();
      expect(ctrl.selectedOutput, selected);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    });
  }

  testWidgets('Custom volume ring still rotates after holding the band', (
    tester,
  ) async {
    await show(tester, _tile(EasyTileType.volumeRing));
    final ring = find.descendant(
      of: find.byType(VolumeRing),
      matching: find.byType(RawGestureDetector),
    );
    final rect = tester.getRect(ring);
    final center = rect.topLeft + Offset(rect.width / 2, rect.width / 2);
    final radius = rect.width * 0.38;
    final gesture = await tester.startGesture(center + Offset(radius, 0));
    await tester.pump(const Duration(milliseconds: 700));
    expect(ctrl.volumes, isEmpty);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(ProtectionPage), findsNothing);
    await gesture.moveTo(center + Offset(radius * 0.94, -radius * 0.34));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(ctrl.volumes, isNotEmpty);
    expect(ctrl.volumes.every((v) => v.$1 == Adi2Addr.line), isTrue);
    expect(find.byType(ProtectionPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final type in [EasyTileType.volumeUp, EasyTileType.volumeDown]) {
    for (final shape in [
      (EasyTileSize.single, 1.0),
      (EasyTileSize.full, 0.5),
    ]) {
      testWidgets('Hold ${type.name} repeats and stops: $shape', (
        tester,
      ) async {
        await show(tester, _tile(type, size: shape.$1, height: shape.$2));
        await hold(tester);
        expect(ctrl.volumes.length, greaterThan(1));
        final count = ctrl.volumes.length;
        await tester.pump(const Duration(seconds: 1));
        expect(ctrl.volumes.length, count);
        expect(find.byType(ProtectionPage), findsNothing);
      });
    }
    testWidgets('Locked ${type.name} cannot repeat', (tester) async {
      ctrl.values[Adi2Addr.line << 8 | OutIdx.lockVolume] = 1;
      await show(tester, _tile(type, size: EasyTileSize.single, height: 1));
      await hold(tester);
      expect(ctrl.volumes, isEmpty);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(ProtectionPage), findsNothing);
    });
    testWidgets('Cancelled ${type.name} stops repeating', (tester) async {
      await show(tester, _tile(type));
      final gesture = await tester.startGesture(tester.getCenter(getTile()));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 800));
      expect(ctrl.volumes.length, greaterThan(1));
      await gesture.cancel();
      await tester.pump();
      final count = ctrl.volumes.length;
      await tester.pump(const Duration(seconds: 1));
      expect(ctrl.volumes.length, count);
    });
  }

  testWidgets('Setup menu loads only the chosen slot', (tester) async {
    ctrl.values[Adi2Addr.device << 8 | DevIdx.loadVolumeWithSetup] = 0;
    await show(tester, _tile(EasyTileType.setup));
    await menu(tester, 'Laden');
    expect(ctrl.loads, [4]);
    expect(ctrl.saves, isEmpty);
  });

  testWidgets('Setup load with volume requires confirmation', (tester) async {
    ctrl.values[Adi2Addr.device << 8 | DevIdx.loadVolumeWithSetup] = 1;
    await show(tester, _tile(EasyTileType.setup));
    await menu(tester, 'Laden');
    expect(ctrl.loads, isEmpty);
    expect(find.text('Setup laden?'), findsOneWidget);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(ctrl.loads, isEmpty);
    await menu(tester, 'Laden');
    await tester.tap(find.widgetWithText(FilledButton, 'Laden'));
    await tester.pumpAndSettle();
    expect(ctrl.loads, [4]);
  });

  testWidgets('Setup save confirms overwrite and cancellation writes nothing', (
    tester,
  ) async {
    await show(tester, _tile(EasyTileType.setup));
    await menu(tester, 'Aktuelle Einstellungen hier speichern');
    expect(ctrl.saves, isEmpty);
    expect(find.text('Studio überschreiben?'), findsOneWidget);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(ctrl.saves, isEmpty);
    await menu(tester, 'Aktuelle Einstellungen hier speichern');
    await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
    await tester.pumpAndSettle();
    expect(ctrl.saves, [4]);
    expect(ctrl.loads, isEmpty);
  });

  testWidgets('Setup rename validates and updates only the chosen slot', (
    tester,
  ) async {
    await show(tester, _tile(EasyTileType.setup));
    await menu(tester, 'Umbenennen');
    expect(find.byType(EqPage), findsNothing);
    await tester.enterText(find.byType(TextFormField), '   ');
    await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
    await tester.pumpAndSettle();
    expect(find.text('Bitte einen Namen eingeben.'), findsOneWidget);
    expect(ctrl.renames, isEmpty);
    await tester.enterText(find.byType(TextFormField), ' Abends ');
    await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
    await tester.pumpAndSettle();
    expect(ctrl.renames, [(4, 'Abends')]);
    expect(find.text('Abends'), findsOneWidget);
  });

  testWidgets('Offline setup menu disables device writes', (tester) async {
    ctrl.isOffline = true;
    await show(tester, _tile(EasyTileType.setup));
    await hold(tester);
    for (final item in tester.widgetList<ListTile>(find.byType(ListTile))) {
      expect(item.onTap, isNull);
    }
    expect(ctrl.loads, isEmpty);
    expect(ctrl.saves, isEmpty);
    expect(ctrl.renames, isEmpty);
  });

  testWidgets('Unavailable source and filter have no long press action', (
    tester,
  ) async {
    for (final type in [EasyTileType.source, EasyTileType.daFilter]) {
      ctrl.values.remove(
        Adi2Addr.line << 8 |
            (type == EasyTileType.source ? OutIdx.source : OutIdx.daFilter),
      );
      await show(tester, _tile(type));
      await hold(tester);
      expect(find.byType(BottomSheet), findsNothing);
      expect(ctrl.writes, isEmpty);
    }
  });

  testWidgets('Editor long press never runs operating actions or edits', (
    tester,
  ) async {
    final edits = <int>[];
    for (final type in EasyTileType.values) {
      await show(tester, _tile(type), onEdit: edits.add, movable: true);
      await hold(tester);
      expect(edits, isEmpty, reason: type.name);
      expect(find.byType(BottomSheet), findsNothing, reason: type.name);
      expect(find.byType(AlertDialog), findsNothing, reason: type.name);
      expect(find.byType(EqPage), findsNothing, reason: type.name);
      expect(ctrl.volumes, isEmpty, reason: type.name);
      expect(ctrl.writes, isEmpty, reason: type.name);
    }
  });
}
