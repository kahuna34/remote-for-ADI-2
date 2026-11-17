import 'dart:async';
import 'dart:convert';

import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/backup.dart';
import 'package:adi2_remote/device/offline_preparation.dart';
import 'package:adi2_remote/eq/eq_model.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/eq_page.dart';
import 'package:adi2_remote/ui/setups_page.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Same in-process MIDI transport pattern as transfer_volume_limit_test.dart.
// Request-all receives actual protocol packets, not a mocked confirmation bool.
class _Midi implements MidiCommand {
  final packets = StreamController<MidiPacket>.broadcast(sync: true);
  final device = MidiDevice(
    'prepare',
    'ADI-2 Pro',
    MidiDeviceType.serial,
    true,
  );
  final sent = <Uint8List>[];
  final values = <int, int>{};
  final events = <String>[];
  int requests = 0;
  int? stopAnsweringAt;
  int? omittedKey;
  void Function()? onSave;
  void Function(Adi2Param)? onWrite;

  @override
  Future<List<MidiDevice>> get devices async => [];
  @override
  Stream<MidiPacket> get onMidiPacketReceived => packets.stream;

  void reply(Iterable<Adi2Param> params) {
    for (final data in buildSetParams(Adi2Model.pro.id, params.toList())) {
      packets.add(MidiPacket(data, 0, device));
    }
  }

  @override
  void sendData(Uint8List data, {String? deviceId, int? timestamp}) {
    sent.add(data);
    if (listEquals(data, buildRequestAll(Adi2Model.pro.id))) {
      requests++;
      events.add('request');
      if (stopAnsweringAt != null && requests >= stopAnsweringAt!) return;
      events.add('confirm');
      reply([
        for (final e in values.entries)
          if (requests == 1 || e.key != omittedKey)
            Adi2Param(e.key >> 8, e.key & 0xff, e.value),
      ]);
    }
    if (parseSysex(data) case Adi2ParamsMessage(:final params)) {
      for (final p in params) {
        events.add('write:${p.address}:${p.index}:${p.value}');
        if (p.address < Adi2Addr.presetEqL) values[p.key] = p.value;
        onWrite?.call(p);
      }
    }
    for (var n = 1; n <= 9; n++) {
      if (listEquals(data, buildSaveSetup(Adi2Model.pro.id, n))) {
        events.add('save:$n');
        onSave?.call();
      }
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Midi midi;
  late Adi2Controller c;
  late AppLanguage previous;
  var disposed = false;
  const line = Adi2Addr.line;
  const left = Adi2Addr.lineEqL;
  const right = Adi2Addr.lineEqR;
  const gainKey = left << 8 | 4;
  const volumeKey = line << 8 | OutIdx.volume;
  const refKey = line << 8 | OutIdx.refLevel;
  const dualKey = line << 8 | OutIdx.dualEq;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    previous = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    midi = _Midi();
    c = Adi2Controller(midi: midi);
    disposed = false;
  });
  tearDown(() async {
    if (!disposed) c.dispose();
    midi.device.dispose();
    await midi.packets.close();
    AppLang.instance.language = previous;
  });

  Future<void> showSetupsPage(WidgetTester tester) async {
    // These tests use controller storage, not the file-based app library.
    // Resolve the unavailable documents directory in the test zone so the
    // initial library load finishes before interacting with the page.
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: SetupsPage(ctrl: c)),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<InkWell>(find.byKey(const ValueKey('eq-slot-2'))).onTap,
      isNotNull,
    );
  }

  test('Offline Presets beider Speicherwege überleben neuen Controller, Namen gekürzt, Modelle getrennt', () async {
    await c.startOffline(Adi2Variant.pro);
    c.setEq(left, 4, -8);
    await c.storeEqPreset(left, right, 5, 'A very long preset name', false);
    await c.storeEqPresetData(19, {4: -12, 20: 1, 27: 1}, {4: 6}, true, 'Dual');
    expect(c.isPresetPrepared(5), isTrue);
    expect(c.eqPresets!.where((p) => p.empty), hasLength(18));
    expect(midi.sent, isEmpty);
    final next = Adi2Controller(midi: midi);
    try {
      await next.startOffline(Adi2Variant.pro);
      expect(next.names[6], 'A very long pr');
      expect(next.eqPresets![5].left[4], -8);
      expect(next.eqPresets![19].left, {4: -12});
      expect(next.eqPresets![19].dual, isTrue);
      await next.startOffline(Adi2Variant.dac);
      expect(next.eqPresets!.every((p) => p.empty), isTrue);
      expect(next.names, isEmpty);
      await next.startOffline(Adi2Variant.pro);
      expect(next.isPresetPrepared(19), isTrue);
    } finally {
      next.dispose();
    }
  });

  for (final channel in [Adi2Addr.input, line, Adi2Addr.ph12, Adi2Addr.ph34]) {
    test(
      'Offline Laden kopiert Bänder und Dual für Kanal $channel; leer ändert nichts',
      () async {
        await c.startOffline(Adi2Variant.pro);
        final l = channel + 1, r = channel + 2;
        c.set(l, EqIdx2.loadBtWithPreset, 0);
        c.set(l, 21, -2);
        c.set(r, 4, -3);
        await c.storeEqPresetData(3, {4: -10, 21: -8}, {4: -14}, true, 'Dual');
        await c.loadEqPreset(l, 5);
        expect(c.value(l, 4), -10);
        expect(c.value(r, 4), -14);
        expect(c.value(l, 21), -2); // B/T follows the device's load switch.
        expect(c.value(channel, channel == 0 ? 8 : OutIdx.dualEq), 1);
        expect(c.value(l, EqIdx2.presetSelect), 5);
        await c.loadEqPreset(
          l,
          2,
        ); // Empty slot: selection and curve unchanged.
        expect(c.value(l, EqIdx2.presetSelect), 5);
        expect(c.value(l, 4), -10);
        c.set(l, EqIdx2.loadBtWithPreset, 1);
        await c.storeEqPresetData(4, {4: -6, 21: -8}, {4: 10}, false, 'Single');
        await c.loadEqPreset(l, 6);
        expect(c.value(l, 4), -6);
        expect(c.value(l, 21), -8);
        expect(c.value(r, 4), -14); // Never write EqR for a single EQ.
        expect(c.value(channel, channel == 0 ? 8 : OutIdx.dualEq), 0);
      },
    );
  }

  test('Offline Setup speichern, laden, umbenennen und persistieren ohne Preset-Adressen', () async {
    await c.startOffline(Adi2Variant.pro);
    c.setEq(left, 4, -16);
    c.set(Adi2Addr.presetEqL, 4, 99);
    await c.saveSetup(9);
    await c.renameSetup(9, 'A very long setup name');
    c.setEq(left, 4, -2);
    await c.loadSetup(1); // Empty slot is a no-op.
    expect(c.eqValue(left, 4), -2);
    await c.loadSetup(9);
    expect(c.value(left, 4), -16);
    expect(c.value(Adi2Addr.presetEqL, 4), isNull);
    expect(c.names[0x29], 'A very long se');
    final next = Adi2Controller(midi: midi);
    try {
      await next.startOffline(Adi2Variant.pro);
      expect(next.isSetupPrepared(9), isTrue);
      expect(next.names[0x29], 'A very long se');
      next.setEq(left, 4, 0);
      await next.loadSetup(9);
      expect(next.value(left, 4), -16);
    } finally {
      next.dispose();
    }
    expect(midi.sent, isEmpty);
  });

  test('resetOffline löscht vorbereitete Slots und Namen dauerhaft', () async {
    await c.startOffline(Adi2Variant.pro);
    await c.storeEqPresetData(0, {4: -10}, {}, false, 'Preset');
    await c.saveSetup(1);
    await c.renameSetup(1, 'Setup');
    await c.resetOffline();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('offline_presets_pro'), isFalse);
    expect(prefs.containsKey('offline_setups_pro'), isFalse);
    await c.startOffline(Adi2Variant.pro);
    expect(c.eqPresets!.every((p) => p.empty), isTrue);
    expect(c.isSetupPrepared(1), isFalse);
    expect(c.names, isEmpty);
    expect(c.value(left, 4), 0);
  });

  Future<void> connect({
    List<EqPresetData> presets = const [],
    List<OfflineSetupData> setups = const [],
    Map<int, int>? settings,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (settings != null) {
      await prefs.setString(
        'offline_pro',
        jsonEncode({for (final e in settings.entries) '${e.key}': e.value}),
      );
    }
    await prefs.setString(
      'offline_presets_pro',
      jsonEncode([for (final p in presets) p.toJson()]),
    );
    await prefs.setString(
      'offline_setups_pro',
      jsonEncode([for (final s in setups) s.toJson()]),
    );
    await c.start();
    c.device = midi.device;
    c.model = Adi2Model.pro;
    c.state = ConnState.connected;
    midi.values.addAll({gainKey: -2, volumeKey: -100, refKey: 0, dualKey: 0});
    midi.reply([
      for (final e in midi.values.entries)
        Adi2Param(e.key >> 8, e.key & 0xff, e.value),
    ]);
    midi.sent.clear();
    midi.events.clear();
  }

  List<Adi2Param> sentParams() => [
    for (final data in midi.sent)
      if (parseSysex(data) case Adi2ParamsMessage(:final params)) ...params,
  ];

  test('Transfer sendet nur vorbereitete Presets, ohne Live-Wahl und mit Codec-Spiegelung bei Single EQ', () async {
    await connect(
      presets: [
        EqPresetData(
          number: 7,
          name: 'Eight',
          empty: false,
          dual: false,
          left: {4: -8},
          right: {4: 6},
        ),
      ],
    );
    final result = await c.transferPrepared(
      withSettings: false,
      withSetups: false,
    );
    expect(result.presets, 1);
    expect(result.setups, 0);
    final sent = sentParams();
    expect(
      sent
          .where(
            (p) =>
                p.address == Adi2Addr.presetEqL &&
                p.index == presetFlagStoreIdx,
          )
          .map((p) => p.value),
      [7 << 4],
    );
    expect(
      sent
          .where((p) => p.address == Adi2Addr.presetEqR)
          .map((p) => (p.index, p.value)),
      [
        (4, -8),
      ], // The codec mirrors left; the independent right value 6 is ignored.
    );
    expect(sent.where((p) => p.index == EqIdx2.presetSelect), isEmpty);
    expect(c.names[8], 'Eight');
    expect(c.eqPresets!.single.number, 7);
  });

  test('Verbindungsabbruch im Preset-Puffer sendet keine Store-Kennung und keine weiteren Bereiche', () async {
    await connect(
      presets: [
        EqPresetData(
          number: 7,
          name: 'Eight',
          empty: false,
          dual: false,
          left: {4: -8},
        ),
      ],
      setups: [
        OfflineSetupData(number: 1, name: 'One', values: {gainKey: -10}),
      ],
      settings: {gainKey: -20},
    );
    midi.onWrite = (p) {
      if (p.address == Adi2Addr.presetEqL) c.disconnect();
    };
    await expectLater(c.transferPrepared(), throwsStateError);
    expect(
      sentParams().where(
        (p) => p.address == Adi2Addr.presetEqL && p.index == presetFlagStoreIdx,
      ),
      isEmpty,
    );
    expect(midi.events.where((e) => e.startsWith('save:')), isEmpty);
    expect(midi.events, isNot(contains('write:$left:4:-20')));
  });

  test(
    'Ohne bestätigten Ausgangszustand beginnt kein Setup-Transfer',
    () async {
      await connect(
        setups: [
          OfflineSetupData(number: 1, name: 'One', values: {gainKey: -10}),
        ],
      );
      midi.stopAnsweringAt = 1;
      await expectLater(c.transferPrepared(), throwsStateError);
      expect(sentParams(), isEmpty);
      expect(midi.events.where((e) => e.startsWith('save:')), isEmpty);
    },
  );

  test('Transfer-Reihenfolge: Preset → Apply → vollständige Bestätigung → Setup/Name → Offline-Stand; nie lauter', () async {
    await connect(
      presets: [
        EqPresetData(
          number: 2,
          name: 'Three',
          empty: false,
          dual: true,
          left: {4: -8},
          right: {4: -6},
        ),
      ],
      setups: [
        OfflineSetupData(
          number: 3,
          name: 'Quiet',
          values: {
            gainKey: -10,
            volumeKey: -160,
            refKey: 3,
            dualKey: 0,
            right << 8 | 4: 12,
          },
        ),
        OfflineSetupData(
          number: 8,
          name: 'Loud',
          values: {gainKey: -14, volumeKey: -20, refKey: 0, dualKey: 0},
        ),
      ],
      settings: {gainKey: -6, volumeKey: -40},
    );
    final progress = <double>[];
    final result = await c.transferPrepared(progress: progress.add);
    expect((result.presets, result.setups, result.settings), (1, 2, 1));
    final events = midi.events;
    final preset = events.indexWhere((e) => e.startsWith('write:13:2:'));
    final apply = events.indexOf('write:$left:4:-10');
    final confirmation = events.indexOf('confirm', apply);
    final save = events.indexOf('save:3');
    final next = events.indexOf('write:$left:4:-14');
    final last = events.indexOf('write:$left:4:-6');
    expect(preset, lessThan(apply));
    expect(apply, lessThan(confirmation));
    expect(confirmation, lessThan(save));
    expect(save, lessThan(next));
    expect(events.indexOf('save:8'), lessThan(last));
    expect(
      midi.sent.any(
        (m) => listEquals(m, buildSendName(Adi2Model.pro.id, 0x23, 'Quiet')),
      ),
      isTrue,
    );
    final sent = sentParams();
    expect(
      sent
          .where((p) => p.address == line && p.index == OutIdx.volume)
          .map((p) => p.value),
      everyElement(lessThanOrEqualTo(-160)),
    );
    expect(sent.where((p) => p.address == right), isEmpty);
    expect(
      sent.indexWhere((p) => p.address == line && p.index == OutIdx.refLevel),
      lessThan(sent.indexWhere((p) => p.address == left)),
    );
    expect(c.value(left, 4), -6);
    expect(c.value(line, OutIdx.volume), -160);
    expect(progress.first, 0);
    expect(progress.last, 1);
  });

  test('Nur Setups: vorherigen Gerätestand am Ende wiederherstellen, Lautstärke bleibt leiser', () async {
    await connect(
      setups: [
        OfflineSetupData(
          number: 2,
          name: 'Two',
          values: {gainKey: -12, volumeKey: -160},
        ),
      ],
      settings: {gainKey: -22},
    );
    final result = await c.transferPrepared(
      withSettings: false,
      withPresets: false,
    );
    expect(result.setups, 1);
    expect(result.settings, 0);
    expect(c.value(left, 4), -2);
    expect(c.value(line, OutIdx.volume), -160);
    expect(midi.events, contains('save:2'));
  });

  for (final partial in [false, true]) {
    test(
      'Ohne ${partial ? 'vollständige' : 'jede'} Bestätigung kein saveSetup und Wiederherstellung',
      () async {
        await connect(
          setups: [
            OfflineSetupData(
              number: 4,
              name: 'Four',
              values: {gainKey: -12, volumeKey: -160},
            ),
          ],
        );
        if (partial) {
          midi.omittedKey = gainKey;
        } else {
          midi.stopAnsweringAt = 2; // The initial device snapshot is confirmed.
        }
        await expectLater(
          c.transferPrepared(withSettings: false),
          throwsStateError,
        );
        expect(midi.events.where((e) => e.startsWith('save:')), isEmpty);
        expect(c.value(left, 4), -2);
        expect(c.value(line, OutIdx.volume), -160);
      },
    );
  }

  test('Nicht angekreuzte Bereiche senden keine Daten', () async {
    await connect(
      presets: [
        EqPresetData(
          number: 0,
          name: 'One',
          empty: false,
          dual: false,
          left: {4: -8},
        ),
      ],
      setups: [
        OfflineSetupData(number: 1, name: 'One', values: {gainKey: -12}),
      ],
      settings: {gainKey: -6},
    );
    final result = await c.transferPrepared(
      withPresets: false,
      withSetups: false,
    );
    expect((result.presets, result.setups, result.settings), (0, 0, 1));
    expect(sentParams().every((p) => p.address == left), isTrue);
    expect(midi.events.where((e) => e.startsWith('save:')), isEmpty);
    final before = midi.sent.length;
    await c.transferPrepared(
      withSettings: false,
      withPresets: false,
      withSetups: false,
    );
    expect(midi.sent.length, before);
  });

  test('Verbindungsabbruch stoppt vor nächstem Setup, Umbenennen und Schlussübertragung', () async {
    await connect(
      setups: [
        OfflineSetupData(number: 1, name: 'One', values: {gainKey: -10}),
        OfflineSetupData(number: 2, name: 'Two', values: {gainKey: -12}),
      ],
      settings: {gainKey: -20},
    );
    midi.onSave = c.disconnect;
    await expectLater(c.transferPrepared(), throwsStateError);
    expect(midi.events.where((e) => e.startsWith('save:')), ['save:1']);
    expect(midi.events, isNot(contains('write:$left:4:-20')));
    expect(
      midi.sent.any(
        (m) => listEquals(m, buildSendName(Adi2Model.pro.id, 0x21, 'One')),
      ),
      isFalse,
    );
  });

  testWidgets(
    'Offline Setups sichtbar, leeres Laden deaktiviert, Speichern/Umbenennen aktiv',
    (tester) async {
      tester.view.physicalSize = const Size(390, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await c.startOffline(Adi2Variant.pro);
      await showSetupsPage(tester);
      final title = find.text('Geräte-Setups 1–9');
      await tester.ensureVisible(title);
      await tester.pumpAndSettle();
      final row = find
          .ancestor(of: find.text('Setup 1'), matching: find.byType(Row))
          .last;
      final load = find.descendant(
        of: row,
        matching: find.widgetWithText(TextButton, 'Laden'),
      );
      expect(tester.widget<TextButton>(load).onPressed, isNull);
      final save = find.descendant(
        of: row,
        matching: find.widgetWithText(TextButton, 'Speichern'),
      );
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
      await tester.pumpAndSettle();
      expect(c.isSetupPrepared(1), isTrue);
      expect(tester.widget<TextButton>(load).onPressed, isNotNull);
      await tester.tap(find.text('Setup 1'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Prepared');
      await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
      await tester.pumpAndSettle();
      expect(c.names[0x21], 'Prepared');
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      disposed = true;
    },
  );

  testWidgets(
    'Offline Setups-Editor lädt vorbereiteten Slot und speichert bearbeitete Daten in der App',
    (tester) async {
      tester.view.physicalSize = const Size(700, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await c.startOffline(Adi2Variant.pro);
      await c.storeEqPresetData(2, {4: -8}, {4: 6}, true, 'Three');
      await showSetupsPage(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('eq-slot-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('eq-slot-2')));
      await tester.pumpAndSettle();
      final controls = tester.widget<EqBandControls>(
        find.byType(EqBandControls),
      );
      expect(controls.read(Adi2Addr.presetEqL, 4), -8);
      expect(controls.read(Adi2Addr.presetEqR, 4), 6);
      final plus = find
          .descendant(
            of: find.byType(EqBandControls),
            matching: find.byIcon(Icons.add),
          )
          .first;
      await tester.tap(plus);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'In App speichern'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Stored offline');
      await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
      await tester.pumpAndSettle();
      expect(c.eqPresets![2].left[4], -7);
      expect(c.eqPresets![2].right[4], 6);
      expect(c.names[3], 'Stored offline');
      expect(find.text('In der App gespeichert als Preset 3'), findsOneWidget);
      expect(
        c.value(left, 4),
        0,
      ); // Listen stays off; the live EQ is independent.
      expect(midi.sent, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      disposed = true;
    },
  );

  testWidgets(
    'Offline EQ speichert wirklich, schlägt Lücke vor und zeigt erst dann App-Erfolg',
    (tester) async {
      await c.startOffline(Adi2Variant.pro);
      await c.storeEqPresetData(0, {4: -4}, {}, false, 'One');
      await c.storeEqPresetData(2, {4: -6}, {}, false, 'Three');
      c.setEq(left, 4, -12);
      tester.view.physicalSize = const Size(600, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: EqPage(ctrl: c, channelAddr: line, title: 'EQ'),
        ),
      );
      await tester.pumpAndSettle();
      final store = find.widgetWithText(FilledButton, 'Als Preset speichern');
      await tester.ensureVisible(store);
      await tester.tap(store);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
            .value,
        1,
      );
      expect(
        find.textContaining('In der App gespeichert als Preset'),
        findsNothing,
      );
      await tester.enterText(find.byType(TextField), 'Two');
      await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      expect(c.isPresetPrepared(1), isTrue);
      expect(c.eqPresets![1].left[4], -12);
      expect(find.text('In der App gespeichert als Preset 2'), findsOneWidget);
      expect(midi.sent, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      disposed = true;
    },
  );
}
