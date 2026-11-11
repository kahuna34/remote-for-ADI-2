import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adi2_host/desktop_midi.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> device(String name, String serial) => {
  'name': name,
  'instanceId': 'USB\\VID_ABCD&PID_1234\\$serial',
  'serialNumber': null,
};

class _MidiCommand extends Fake implements MidiCommand {
  List<MidiDevice> ports = [];
  int connections = 0;

  @override
  Future<List<MidiDevice>?> get devices async => ports;

  @override
  void configureTransportPolicy(MidiTransportPolicy policy) {}

  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    Duration? awaitConnectionTimeout = const Duration(seconds: 30),
  }) async => connections++;

  @override
  void disconnectDevice(MidiDevice device) {}

  @override
  Stream<MidiPacket>? get onMidiPacketReceived => null;

  @override
  Stream<MidiSetupChange>? get onMidiSetupChanged => null;
}

MidiDevice portDevice(String id, String name) =>
    MidiDevice(id, name, MidiDeviceType.serial, false);

void main() {
  const port = 'ADI-2 DAC Midi Port 1';
  final dac = device('RME ADI-2 DAC', '99000001');
  final hexDac = {
    ...device('RME ADI-2 DAC', 'A1B2C3D4E5F60708'),
    'instanceId': r'USB\VID_2A39&PID_3FD3\A1B2C3D4E5F60708',
    'usbSerialNumber': null,
  };
  List<String> parse(Object? rows) =>
      DesktopMidi.parseWindowsUsbProductNames(jsonEncode(rows));
  String resolve(Object? rows) =>
      DesktopMidi.withWindowsUsbName(port, parse(rows));

  test(
    'Windows: detect und open teilen den Cache, detect öffnet nie',
    () async {
      final command = _MidiCommand()..ports = [portDevice('adi', port)];
      var queries = 0;
      final midi = DesktopMidi(
        command: command,
        platform: TargetPlatform.windows,
        windowsNameQuery: () async {
          queries++;
          return ['ADI-2 DAC (99000001)'];
        },
        macNameQuery: () async =>
            throw StateError('macOS-Abfrage unter Windows'),
      );
      expect(await midi.detect(), 'ADI-2 DAC (99000001)');
      expect(await midi.detect(), 'ADI-2 DAC (99000001)');
      command.ports = [portDevice('other', 'Babyface'), ...command.ports];
      expect(await midi.detect(), 'ADI-2 DAC (99000001)');
      expect(queries, 1);
      expect(command.connections, 0);
      expect(await midi.open(), 'ADI-2 DAC (99000001)');
      expect(await midi.open(), 'ADI-2 DAC (99000001)');
      expect(queries, 1);
      expect(command.connections, 1);
      await midi.close();
    },
  );

  test(
    'Windows: Änderungen an Kandidaten-ID und -Name erneuern den Cache',
    () async {
      final command = _MidiCommand()..ports = [portDevice('adi', port)];
      var queries = 0;
      final midi = DesktopMidi(
        command: command,
        platform: TargetPlatform.windows,
        windowsNameQuery: () async {
          queries++;
          return ['ADI-2 DAC (99000001)'];
        },
      );
      await midi.detect();
      command.ports = [portDevice('new-id', port)];
      await midi.detect();
      expect(queries, 2);
      command.ports = [portDevice('new-id', 'RME ADI-2 DAC')];
      await midi.detect();
      expect(queries, 3);
      command.ports.add(portDevice('second', port));
      await midi.detect();
      expect(queries, 4);
      command.ports = command.ports.reversed.toList();
      await midi.detect();
      expect(queries, 4);
      command.ports.removeLast();
      await midi.detect();
      expect(queries, 5);
      expect(command.connections, 0);
    },
  );

  test(
    'Windows: Abziehen meldet sofort null ohne PnP; Anstecken fragt neu',
    () async {
      final target = portDevice('adi', port);
      final command = _MidiCommand()..ports = [target];
      var queries = 0;
      final midi = DesktopMidi(
        command: command,
        platform: TargetPlatform.windows,
        windowsNameQuery: () async {
          queries++;
          return ['ADI-2 DAC (99000001)'];
        },
      );
      await midi.detect();
      command.ports = [portDevice('other', 'Babyface')];
      expect(await midi.detect(), isNull);
      expect(await midi.detect(), isNull);
      expect(queries, 1);
      command.ports = [target];
      expect(await midi.detect(), 'ADI-2 DAC (99000001)');
      expect(queries, 2);
      expect(command.connections, 0);
    },
  );

  test('Windows: leere und fehlerhafte Abfragen werden wiederholt', () async {
    final command = _MidiCommand()..ports = [portDevice('adi', port)];
    var queries = 0;
    final midi = DesktopMidi(
      command: command,
      platform: TargetPlatform.windows,
      windowsNameQuery: () async {
        queries++;
        if (queries == 1) return [];
        if (queries == 2) throw StateError('PnP nicht verfügbar');
        return ['ADI-2 DAC (99000001)'];
      },
    );
    expect(await midi.detect(), 'ADI-2 DAC');
    expect(await midi.detect(), 'ADI-2 DAC');
    expect(await midi.detect(), 'ADI-2 DAC (99000001)');
    expect(await midi.detect(), 'ADI-2 DAC (99000001)');
    expect(queries, 3);
    expect(command.connections, 0);
  });

  test(
    'Windows: gleichzeitige Erkennungen teilen eine laufende Abfrage',
    () async {
      final command = _MidiCommand()..ports = [portDevice('adi', port)];
      final result = Completer<List<String>>();
      final started = Completer<void>();
      var queries = 0;
      final midi = DesktopMidi(
        command: command,
        platform: TargetPlatform.windows,
        windowsNameQuery: () {
          queries++;
          started.complete();
          return result.future;
        },
      );
      final first = midi.detect();
      await started.future;
      final second = midi.detect();
      result.complete(['ADI-2 DAC (99000001)']);
      expect(await Future.wait([first, second]), [
        'ADI-2 DAC (99000001)',
        'ADI-2 DAC (99000001)',
      ]);
      expect(queries, 1);
      expect(command.connections, 0);
    },
  );

  test(
    'Windows: Menü entfernt Portzusatz und erkennt Pro EX weiterhin',
    () async {
      final command = _MidiCommand()
        ..ports = [portDevice('adi', 'ADI-2 Pro Midi Port 1')];
      final midi = DesktopMidi(
        command: command,
        platform: TargetPlatform.windows,
        windowsNameQuery: () async => ['ADI-2 Pro (56010000)'],
      );
      expect(await midi.detect(), 'ADI-2 Pro EX (56010000)');
      expect(DesktopMidi.displayName('ADI-2 DAC Midi Port 1'), 'ADI-2 DAC');
      expect(
        DesktopMidi.displayName('ADI-2 Pro (56010000) Port 1'),
        'ADI-2 Pro EX (56010000)',
      );
      expect(
        DesktopMidi.displayName('ADI-2 Pro (99000001) Port 1'),
        'ADI-2 Pro (99000001)',
      );
    },
  );

  test(
    'macOS: generischer Port nutzt unverändert ioreg ohne Windows-Cache',
    () async {
      final command = _MidiCommand()..ports = [portDevice('adi', 'Port 1')];
      var queries = 0;
      final midi = DesktopMidi(
        command: command,
        platform: TargetPlatform.macOS,
        windowsNameQuery: () async =>
            throw StateError('Windows-Abfrage unter macOS'),
        macNameQuery: () async {
          queries++;
          return DesktopMidi.parseUsbProductNames(
            '"USB Product Name" = "ADI-2 DAC (99000001)"',
          );
        },
      );
      expect(await midi.detect(), 'ADI-2 DAC (99000001)');
      expect(await midi.detect(), 'ADI-2 DAC (99000001)');
      expect(queries, 2);
      expect(command.connections, 0);
      expect(await midi.open(), 'ADI-2 DAC (99000001)');
      expect(queries, 3);
      await midi.close();
      expect(
        DesktopMidi.withUsbName('ADI-2 DAC (99000002)', [
          'ADI-2 DAC (99000001)',
        ]),
        'ADI-2 DAC (99000002)',
      );
      expect(
        DesktopMidi.withUsbName('Port 1', [
          'ADI-2 DAC (99000001)',
          'ADI-2 Pro (99000002)',
        ]),
        'Port 1',
      );
    },
  );

  test('Windows: ein DAC mit numerischer USB-Seriennummer', () {
    expect(resolve([dac]), 'ADI-2 DAC (99000001)');
    expect(resolve(dac), 'ADI-2 DAC (99000001)');
    expect(
      DesktopMidi.parseWindowsUsbProductNames('\uFEFF${jsonEncode([dac])}'),
      ['ADI-2 DAC (99000001)'],
    );
  });

  test('Windows: Bus-Gerätename liefert die Nummer bei Hex-Instanz', () {
    for (final busName in <Object>[
      'ADI-2 DAC (12345678)',
      ['ADI-2 DAC (12345678)'],
      ['ADI-2 DAC (12345678)', 'ADI-2 DAC (12345678)'],
      [null, 'ADI-2 DAC (12345678)'],
    ]) {
      final row = {...hexDac, 'busName': busName};
      expect(parse([row]), ['ADI-2 DAC (12345678)']);
      expect(resolve([row]), 'ADI-2 DAC (12345678)');
    }
    expect(
      parse([
        {
          ...hexDac,
          'name': 'RME ADI-2 Pro',
          'busName': 'ADI-2 Pro FS R (12345678)',
        },
      ]),
      ['ADI-2 Pro FS R (12345678)'],
    );
  });

  test('Windows: Hex-Instanz ohne gültigen Bus-Gerätenamen bleibt leer', () {
    expect(parse([hexDac]), isEmpty);
    for (final busName in [
      null,
      'ADI-2 DAC',
      'ADI-2 DAC (A1B2C3D4)',
      'ADI-2 Unknown (12345678)',
      'Babyface Pro (12345678)',
    ]) {
      final rows = [
        {...hexDac, 'busName': busName},
      ];
      expect(parse(rows), isEmpty);
      expect(resolve(rows), port);
    }
  });

  test('Windows: Bus-Gerätename und Seriennummer müssen übereinstimmen', () {
    for (final property in ['serialNumber', 'usbSerialNumber']) {
      expect(
        parse([
          {...hexDac, 'busName': 'ADI-2 DAC (12345678)', property: '99000002'},
        ]),
        isEmpty,
      );
      expect(
        parse([
          {...hexDac, 'busName': 'ADI-2 DAC (12345678)', property: '12345678'},
        ]),
        ['ADI-2 DAC (12345678)'],
      );
    }
    expect(
      parse([
        {...dac, 'busName': 'ADI-2 DAC (12345678)'},
      ]),
      isEmpty,
    );
  });

  test('Windows: widersprüchliche Bus-Gerätenamen bleiben mehrdeutig', () {
    expect(
      parse([
        {
          ...hexDac,
          'busName': ['ADI-2 DAC (12345678)', 'ADI-2 DAC (99000002)'],
        },
      ]),
      isEmpty,
    );
  });

  test('Windows: zwei Geräte mit Bus-Gerätenamen behalten den Portnamen', () {
    final rows = [
      {...hexDac, 'busName': 'ADI-2 DAC (12345678)'},
      {
        ...device('RME ADI-2 DAC', 'B1C2D3E4F5A60708'),
        'busName': ['ADI-2 DAC (99000002)'],
      },
    ];
    expect(parse(rows), ['ADI-2 DAC (12345678)', 'ADI-2 DAC (99000002)']);
    expect(resolve(rows), port);
    expect(
      resolve([rows.first, device('RME Babyface Pro', '99000003')]),
      'ADI-2 DAC (12345678)',
    );
  });

  test('Windows: DAC und Babyface bleiben getrennt', () {
    final rows = [dac, device('RME Babyface Pro', '99000002')];
    expect(resolve(rows), 'ADI-2 DAC (99000001)');
    expect(
      DesktopMidi.withWindowsUsbName('Babyface Pro Midi Port 1', parse(rows)),
      'Babyface Pro Midi Port 1',
    );
    expect(resolve([rows.last]), port);
  });

  test('Windows: zwei ADI-2 sind mehrdeutig, auch bei gleichem Modell', () {
    expect(resolve([dac, device('RME ADI-2 Pro', '99000002')]), port);
    expect(resolve([dac, device('RME ADI-2 DAC', '99000002')]), port);
    expect(resolve([dac, device('RME ADI-2 DAC', '')]), port);
  });

  test(
    'Windows: mehrere MEDIA-Einträge desselben USB-Geräts zählen einmal',
    () {
      expect(resolve([dac, dac]), 'ADI-2 DAC (99000001)');
    },
  );

  test('Windows: Modellname kommt vom Gerät', () {
    for (final model in ['ADI-2 Pro', 'ADI-2 Pro FS R', 'ADI-2/4 Pro SE']) {
      expect(parse([device('RME $model', '99000003')]), ['$model (99000003)']);
    }
    expect(
      DesktopMidi.withWindowsUsbName(
        'ADI-2/4 Pro Midi Port 1',
        parse([device('RME ADI-2/4 Pro SE', '99000003')]),
      ),
      'ADI-2/4 Pro SE (99000003)',
    );
    expect(resolve([device('RME ADI-2 Pro', '99000003')]), port);
  });

  test('Windows: explizite Seriennummer am physischen USB-Gerät', () {
    expect(
      resolve([
        {
          ...dac,
          'instanceId': r'USB\VID_ABCD&PID_1234\opaque',
          'serialNumber': '99000001',
        },
      ]),
      'ADI-2 DAC (99000001)',
    );
    expect(
      resolve([
        {...dac, 'serialNumber': '99000002'},
      ]),
      port,
    );
    expect(
      resolve([
        {...dac, 'usbSerialNumber': '99000001'},
      ]),
      'ADI-2 DAC (99000001)',
    );
    expect(
      resolve([
        {...dac, 'usbSerialNumber': '99000002'},
      ]),
      port,
    );
  });

  test('Windows: erzeugte Interface-Kennung ist keine Seriennummer', () {
    expect(
      resolve([
        {...dac, 'instanceId': r'USB\VID_ABCD&PID_1234&MI_00\99000001'},
      ]),
      port,
    );
    expect(resolve([device('RME ADI-2 DAC', '6&abcdef&0&0000')]), port);
    expect(
      resolve([
        {...dac, 'instanceId': null},
      ]),
      port,
    );
  });

  test('Windows: unbekanntes ADI-Modell macht Treffer mehrdeutig', () {
    expect(resolve([dac, device('RME ADI-2 Unknown', '99000002')]), port);
    expect(
      resolve([
        dac,
        {...dac, 'name': 'RME ADI-2 Pro'},
      ]),
      port,
    );
  });

  test(
    'Windows: vorhandene Seriennummer und fremde Ports bleiben erhalten',
    () {
      expect(
        DesktopMidi.withWindowsUsbName('ADI-2 DAC (99000004)', parse([dac])),
        'ADI-2 DAC (99000004)',
      );
      expect(DesktopMidi.withWindowsUsbName('Port 1', parse([dac])), 'Port 1');
    },
  );

  test(
    'Windows: kein Gerät und fehlerhafte Ausgabe behalten den Portnamen',
    () {
      for (final output in [
        '',
        ' ',
        'not json',
        '{}',
        'null',
        '[]',
        '[null]',
        '[{"name":7}]',
        '{"name":"RME ADI-2 DAC"}',
      ]) {
        expect(
          DesktopMidi.withWindowsUsbName(
            port,
            DesktopMidi.parseWindowsUsbProductNames(output),
          ),
          port,
        );
      }
    },
  );

  test('Windows: erfolgreiche Prozessausgabe wird ausgewertet', () async {
    final names = await DesktopMidi.windowsUsbProductNames(
      query: () async => ProcessResult(1, 0, jsonEncode([dac]), ''),
    );
    expect(DesktopMidi.withWindowsUsbName(port, names), 'ADI-2 DAC (99000001)');
  });

  test(
    'Windows: Prozessfehler, Startfehler und Timeout behalten den Portnamen',
    () async {
      for (final query in <Future<ProcessResult> Function()>[
        () async => ProcessResult(1, 1, jsonEncode([dac]), 'unavailable'),
        () async => throw const ProcessException('powershell.exe', []),
        () => Completer<ProcessResult>().future,
      ]) {
        final names = await DesktopMidi.windowsUsbProductNames(
          query: query,
          timeout: const Duration(milliseconds: 10),
        );
        expect(DesktopMidi.withWindowsUsbName(port, names), port);
      }
    },
  );

  test('Windows: automatische Auswahl erkennt Original- und USB-Namen', () {
    for (final name in [
      port,
      'ADI-2 DAC (99000001)',
      'ADI-2/4 Pro SE (99000003)',
    ]) {
      final target = MidiDevice('adi', name, MidiDeviceType.serial, false);
      final other = MidiDevice(
        'other',
        'Babyface Pro',
        MidiDeviceType.serial,
        false,
      );
      expect(
        Adi2Controller.autoConnectCandidates([
          other,
          target,
        ], TargetPlatform.windows),
        [target],
      );
    }
  });
}
