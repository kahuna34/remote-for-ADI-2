import 'dart:async';
import 'dart:convert';

import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/easy/easy_layout.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/outputs_page.dart';
import 'package:adi2_remote/ui/param_tile.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Applies filter writes silently, and only confirms them on request.
_Midi? _currentMidi;

class _Midi implements MidiCommand {
  _Midi({
    this.model = Adi2Model.dac,
    String name = 'ADI-2 DAC (12345678)',
    this.acceptsSdLd = true,
    this.filter = 2,
    this.revision = 0,
  }) : device = MidiDevice('usb', name, MidiDeviceType.serial, true) {
    _currentMidi = this;
  }

  final Adi2Model model;
  MidiDevice device;
  final bool acceptsSdLd;
  final int revision;
  int filter;
  bool answerStatus = true;
  bool answerFilter = true;
  bool omitFilterAfterWrite = false;
  bool ignoreRestore = false;
  bool pendingBeforeFirstWrite = false;
  final writes = <Adi2Param>[];
  final targets = <String?>[];
  final packets = StreamController<MidiPacket>.broadcast(sync: true);

  @override
  Future<List<MidiDevice>> get devices async => [];
  @override
  Stream<MidiPacket> get onMidiPacketReceived => packets.stream;
  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    Duration? awaitConnectionTimeout = const Duration(seconds: 30),
  }) async {}

  void reply() {
    for (final packet in buildSetParams(model.id, [
      const Adi2Param(Adi2Addr.line, OutIdx.mute, 1),
      if (answerFilter && !(omitFilterAfterWrite && writes.isNotEmpty))
        Adi2Param(Adi2Addr.line, OutIdx.daFilter, filter),
    ])) {
      packets.add(MidiPacket(packet, 0, device));
    }
    sendStatus();
  }

  /// The device reports its status about once a second.
  void sendStatus() {
    if (answerStatus) {
      packets.add(
        MidiPacket(
          Uint8List.fromList([
            0xf0,
            ...rmeVendor,
            model.id,
            Adi2Cmd.status,
            revision << 2,
            ...List.filled(12, 0),
            0xf7,
          ]),
          0,
          device,
        ),
      );
    }
  }

  @override
  void sendData(Uint8List data, {String? deviceId, int? timestamp}) {
    if (listEquals(data, buildRequestAll(model.id))) {
      reply();
      return;
    }
    final message = parseSysex(data);
    if (message is! Adi2ParamsMessage) return;
    for (final p in message.params) {
      if (writes.isEmpty) {
        pendingBeforeFirstWrite =
            AppSettings.instance.daFilterProbePending(
              RegExp(r'\((\d+)\)').firstMatch(device.name)?.group(1) ?? '',
            ) !=
            null;
      }
      writes.add(p);
      targets.add(deviceId);
      if (p.address == Adi2Addr.line && p.index == OutIdx.daFilter) {
        if (ignoreRestore && p.value != 5) continue;
        filter = p.value == 5 && !acceptsSdLd ? 4 : p.value;
      }
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Controller extends Adi2Controller {
  _Controller(_Midi midi) : super(midi: midi);

  // The fake has no preset bank. Dedicated tests below exercise that lock.
  @override
  Future<void> requestPresetNames() async {}
}

Future<void> _advance(WidgetTester tester, [int milliseconds = 1200]) async {
  for (var elapsed = 0; elapsed < milliseconds; elapsed += 25) {
    if (elapsed % 250 == 0) _currentMidi?.sendStatus();
    // Settings futures belong to the real zone of setUp.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 25));
  }
}

final live = <Adi2Controller>[];

/// Controllers own periodic timers, so they must go before the fake clock ends.
void _t(String name, WidgetTesterCallback body) =>
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final c in live) {
          c.dispose();
        }
        live.clear();
        await tester.pump(const Duration(seconds: 3));
      }
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const serial = '12345678';
  final settings = AppSettings.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
  });

  Future<_Controller> connect(WidgetTester tester, _Midi midi) async {
    final c = _Controller(midi);
    live.add(c);
    addTearDown(() async {
      midi.device.dispose();
      await midi.packets.close();
    });
    await c.start();
    await c.connect(midi.device);
    await tester.pump();
    return c;
  }

  for (final accepts in [true, false]) {
    _t('SD LD wird ${accepts ? 'angenommen' : 'auf 4 begrenzt'}', (
      tester,
    ) async {
      final midi = _Midi(acceptsSdLd: accepts);
      final c = await connect(tester, midi);
      await _advance(tester);
      expect(settings.daFilterSdLd(serial), accepts);
      expect(midi.writes, [
        const Adi2Param(Adi2Addr.line, OutIdx.daFilter, 5),
        const Adi2Param(Adi2Addr.line, OutIdx.daFilter, 2),
      ]);
      expect(midi.pendingBeforeFirstWrite, isTrue);
      expect(midi.filter, 2);
      expect(c.confirmedValue(Adi2Addr.line, OutIdx.daFilter), 2);
      expect(settings.daFilterProbePending(serial), isNull);
      for (final a in Adi2Controller.volumeAddresses) {
        expect(c.isParamValueDisabled(a, OutIdx.daFilter, 5), !accepts);
        expect(c.isParamValueDisabled(a, OutIdx.daFilter, 4), isFalse);
      }
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString('da_filter_sd_ld')!), {
        serial: accepts,
      });
      expect(jsonDecode(prefs.getString('da_filter_probe_pending')!), isEmpty);
      c.disconnect();
      await tester.runAsync(() => settings.load());
      midi.writes.clear();
      await c.connect(midi.device);
      await _advance(tester);
      expect(midi.writes, isEmpty);
    });
  }

  _t('Ausgangswert 5 bestätigt SD LD ohne Schreiben', (tester) async {
    final midi = _Midi(filter: 5);
    await connect(tester, midi);
    await _advance(tester);
    expect(settings.daFilterSdLd(serial), isTrue);
    expect(settings.daFilterProbePending(serial), isNull);
    expect(midi.writes, isEmpty);
  });

  for (final midiFactory in <String, _Midi Function()>{
    'ohne Seriennummer': () => _Midi(name: 'ADI-2 DAC'),
    'ESS': () => _Midi(revision: 2),
    '2/4 SE': () => _Midi(model: Adi2Model.pro4),
    '2/4 EX': () => _Midi(model: Adi2Model.pro4, revision: 1),
  }.entries) {
    _t('${midiFactory.key} startet keine Prüfung', (tester) async {
      final midi = midiFactory.value();
      await connect(tester, midi);
      await _advance(tester);
      expect(midi.writes, isEmpty);
      expect(settings.daFilterSdLd(serial), isNull);
    });
  }

  _t('Offline schreibt nichts', (tester) async {
    final midi = _Midi();
    final c = _Controller(midi);
    live.add(c);
    addTearDown(midi.device.dispose);
    await c.startOffline(Adi2Variant.dac);
    await _advance(tester);
    expect(midi.writes, isEmpty);
    expect(settings.daFilterSdLd(serial), isNull);
  });

  _t('Wartet auf Status und bestätigten Filter', (tester) async {
    final midi = _Midi()..answerStatus = false;
    await connect(tester, midi);
    await _advance(tester);
    expect(midi.writes, isEmpty);
    midi.answerStatus = true;
    midi.reply();
    await _advance(tester);
    expect(settings.daFilterSdLd(serial), isTrue);
  });

  _t('Optimistischer Filter genügt ohne MIDI-Wert nicht', (tester) async {
    final midi = _Midi()..answerFilter = false;
    final c = await connect(tester, midi);
    c.set(Adi2Addr.line, OutIdx.daFilter, 3);
    midi.writes.clear();
    await _advance(tester);
    expect(c.confirmedValue(Adi2Addr.line, OutIdx.daFilter), isNull);
    expect(midi.writes, isEmpty);
    midi.answerFilter = true;
    midi.reply();
    await _advance(tester);
    expect(midi.writes.last.value, 3);
  });

  _t('Fehlende frische Bestätigung speichert kein Ergebnis', (tester) async {
    final midi = _Midi()..omitFilterAfterWrite = true;
    final c = await connect(tester, midi);
    await _advance(tester, 14000);
    expect(settings.daFilterSdLd(serial), isNull);
    expect(settings.daFilterProbePending(serial), 2);
    expect(midi.writes.map((p) => p.value), [5, 2]);
    // Der Cache enthält weiterhin den Ausgangswert, aber keinen frischen Beleg.
    expect(c.confirmedValue(Adi2Addr.line, OutIdx.daFilter), 2);
    final count = midi.writes.length;
    await _advance(tester, 4000);
    expect(midi.writes.length, count);
  });

  _t('Unbestätigte Rückstellung speichert kein Ergebnis', (tester) async {
    final midi = _Midi()..ignoreRestore = true;
    await connect(tester, midi);
    await _advance(tester, 2000);
    expect(settings.daFilterSdLd(serial), isNull);
    expect(settings.daFilterProbePending(serial), 2);
    expect(midi.writes.map((p) => p.value), [5, 2]);
  });

  _t('Offene Vormerkung muss vor einem neuen Test bestätigt werden', (
    tester,
  ) async {
    await tester.runAsync(() => settings.setDaFilterProbePending(serial, 1));
    final midi = _Midi(filter: 5)..ignoreRestore = true;
    await connect(tester, midi);
    await _advance(tester);
    expect(midi.writes.map((p) => p.value), [1]);
    expect(settings.daFilterProbePending(serial), 1);
    expect(settings.daFilterSdLd(serial), isNull);
  });

  _t('Abbruch stellt beim nächsten Verbinden vor neuem Test zurück', (
    tester,
  ) async {
    final midi = _Midi();
    final c = await connect(tester, midi);
    await _advance(tester, 100);
    expect(midi.writes.map((p) => p.value), [5]);
    c.disconnect();
    await _advance(tester, 700);
    expect(settings.daFilterProbePending(serial), 2);
    expect(settings.daFilterSdLd(serial), isNull);
    // Auch nach erneutem Laden bleibt die Vormerkung erhalten.
    await tester.runAsync(() => settings.load());
    midi.writes.clear();
    await c.connect(midi.device);
    await _advance(tester, 1600);
    expect(midi.writes.map((p) => p.value), [2, 5, 2]);
    expect(settings.daFilterSdLd(serial), isTrue);
    expect(settings.daFilterProbePending(serial), isNull);
  });

  _t('Gerätewechsel schreibt nie die alte Rückstellung aufs neue Gerät', (
    tester,
  ) async {
    final midi = _Midi();
    final c = await connect(tester, midi);
    await _advance(tester, 100);
    c.disconnect();
    final oldDevice = midi.device;
    midi.device = MidiDevice(
      'other',
      'ADI-2 DAC (87654321)',
      MidiDeviceType.serial,
      true,
    );
    addTearDown(oldDevice.dispose);
    midi.filter = 3;
    midi.writes.clear();
    midi.targets.clear();
    await c.connect(midi.device);
    await _advance(tester, 1800);
    expect(midi.writes.map((p) => p.value), [5, 3]);
    expect(midi.targets, everyElement('other'));
    expect(settings.daFilterProbePending(serial), 2);
    expect(settings.daFilterSdLd(serial), isNull);
    expect(settings.daFilterSdLd('87654321'), isTrue);
  });

  _t('Selbsttest verschiebt die Prüfung bis zur Freigabe', (tester) async {
    final midi = _Midi();
    final c = _Controller(midi)..analyzerSelfTestActive = true;
    live.add(c);
    addTearDown(midi.device.dispose);
    await c.start();
    await c.connect(midi.device);
    await _advance(tester);
    expect(midi.writes, isEmpty);
    c.analyzerSelfTestActive = false;
    await _advance(tester);
    expect(midi.writes.map((p) => p.value), [5, 2]);
  });

  _t('Messungs-/Übertragungssperre versucht nach Freigabe erneut', (
    tester,
  ) async {
    final midi = _Midi()..answerStatus = false;
    final c = await connect(tester, midi);
    final done = Completer<void>();
    final operation = c.withDaFilterProbePaused(() => done.future);
    midi.answerStatus = true;
    midi.reply();
    await _advance(tester);
    expect(midi.writes, isEmpty);
    done.complete();
    await operation;
    await _advance(tester);
    expect(midi.writes.map((p) => p.value), [5, 2]);
  });

  _t('Übertragung beginnt erst nach bestätigter Rückstellung', (tester) async {
    final midi = _Midi();
    final c = await connect(tester, midi);
    await _advance(tester, 100);
    final done = Completer<void>();
    int? filterAtStart;
    final operation = c.withDaFilterProbePaused(() async {
      filterAtStart = c.confirmedValue(Adi2Addr.line, OutIdx.daFilter);
      await done.future;
    });
    expect(filterAtStart, isNull);
    await _advance(tester);
    expect(filterAtStart, 2);
    expect(midi.writes.map((p) => p.value), [5, 2]);
    midi.reply();
    await _advance(tester);
    expect(midi.writes.length, 2);
    done.complete();
    await operation;
  });

  _t('ESS und 2/4 behalten Index 5 auch bei gespeichertem false', (
    tester,
  ) async {
    await tester.runAsync(() => settings.setDaFilterSdLd(serial, false));
    for (final midi in [_Midi(revision: 2), _Midi(model: Adi2Model.pro4)]) {
      final c = await connect(tester, midi);
      await _advance(tester);
      expect(
        c.isParamValueDisabled(Adi2Addr.line, OutIdx.daFilter, 5),
        isFalse,
      );
      expect(midi.writes, isEmpty);
      c.disconnect();
    }
  });

  _t('5601 mit fünf Filtern zeigt ADI-2 Pro', (tester) async {
    final midi = _Midi(
      model: Adi2Model.pro,
      name: 'ADI-2 Pro (56010042)',
      acceptsSdLd: false,
    );
    final c = await connect(tester, midi);
    expect(c.deviceLabel, 'ADI-2 Pro EX');
    await _advance(tester);
    expect(c.deviceLabel, 'ADI-2 Pro');
    expect(settings.daFilterSdLd('56010042'), isFalse);
  });

  _t('ParamTile sperrt Index 5 über disabledIndices', (tester) async {
    final midi = _Midi(acceptsSdLd: false);
    final c = await connect(tester, midi);
    await _advance(tester);
    final def = outputParams(
      Adi2Variant.dac,
      phones: false,
    ).firstWhere((d) => d.index == OutIdx.daFilter);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: ParamTile(ctrl: c, address: Adi2Addr.line, def: def),
        ),
      ),
    );
    final choices = tester.widget<ParamChoices>(find.byType(ParamChoices));
    expect(choices.disabledIndices, {5});
    midi.writes.clear();
    await tester.tap(find.text('SD LD'));
    await tester.pump();
    expect(midi.writes, isEmpty);
    c.set(Adi2Addr.line, OutIdx.daFilter, 5);
    expect(midi.writes, isEmpty);
  });

  _t('Eigene Ansicht und Ausgangsmenü sperren SD LD', (tester) async {
    final midi = _Midi(acceptsSdLd: false);
    final c = await connect(tester, midi);
    await _advance(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: OutputsPage(
            ctrl: c,
            easyLayout: EasyLayout(
              tiles: const [
                EasyTile(
                  type: EasyTileType.daFilter,
                  size: EasyTileSize.full,
                  height: 1,
                  output: Adi2Addr.line,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final segment = tester.widget<TextButton>(
      find.byKey(const ValueKey('easy-segment-0-5')),
    );
    expect(segment.onPressed, isNull);
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('easy-segment-0-5')),
              matching: find.byType(Text),
            ),
          )
          .style!
          .color,
      Palette.muted.withValues(alpha: 0.45),
    );
    midi.writes.clear();
    await tester.longPress(find.text(tr('DA-Filter')));
    await _advance(tester, 400);
    final chip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'SD LD'),
    );
    expect(chip.onSelected, isNull);
    expect(chip.labelStyle!.color, Palette.muted.withValues(alpha: 0.45));
    expect(midi.writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
