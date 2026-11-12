import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adi2_host/desktop_midi.dart';
import 'package:adi2_host/host_server.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'midi_process_fake.dart';

void main() {
  late FakeMidiProcesses helpers;
  late DesktopMidi midi;
  var lost = 0;
  setUp(() {
    helpers = FakeMidiProcesses();
    lost = 0;
    midi = DesktopMidi(
      platform: TargetPlatform.windows,
      processStarter: helpers.start,
      helperExecutable: r'C:\Remote for ADI-2 Host\adi2_midi.exe',
      windowsNameQuery: () async => ['ADI-2 DAC (99000001)'],
    )..onLost = () => lost++;
  });
  tearDown(() => midi.close());

  test(
    'open uses adjacent executable, returns USB name and shares opening',
    () async {
      final results = await Future.wait([midi.open(), midi.open()]);
      expect(results, everyElement('ADI-2 DAC (99000001)'));
      expect(midi.portInUse, isTrue);
      expect(helpers.calls, [
        [r'C:\Remote for ADI-2 Host\adi2_midi.exe', 'list'],
        [
          r'C:\Remote for ADI-2 Host\adi2_midi.exe',
          'open',
          'ADI-2 DAC Midi Port 1',
        ],
      ]);
    },
  );

  for (final code in ['busy', 'missing']) {
    test('error $code maps to usb_$code and closes the child', () async {
      helpers.response = 'error $code Port unavailable';
      await expectLater(
        midi.open(),
        throwsA(
          isA<HostUsbException>().having((e) => e.type, 'code', 'usb_$code'),
        ),
      );
      expect(midi.portInUse, isFalse);
      expect(helpers.sessions.single.stdinClosed, isTrue);
      expect(lost, 0);
    });
  }

  test(
    'busy reply survives an exit notification before buffered stdout',
    () async {
      final process = FakeMidiProcess();
      midi = DesktopMidi(
        platform: TargetPlatform.windows,
        windowsNameQuery: () async => ['ADI-2 DAC'],
        processStarter: (exe, args) async {
          if (args.first == 'list') return helpers.start(exe, args);
          process.finished.complete(1);
          Timer.run(() {
            process.line('error busy Port already open');
            unawaited(process.output.close());
            unawaited(process.errors.close());
          });
          return process;
        },
      );
      await expectLater(
        midi.open(),
        throwsA(
          isA<HostUsbException>().having((e) => e.type, 'type', 'usb_busy'),
        ),
      );
      expect(midi.portInUse, isFalse);
    },
  );

  test(
    'no matching input/output reports usb_missing without opening',
    () async {
      helpers.ports = ['Microsoft GS Wavetable Synth', 'Babyface Midi Port 1'];
      await expectLater(
        midi.open(),
        throwsA(
          isA<HostUsbException>().having((e) => e.type, 'code', 'usb_missing'),
        ),
      );
      expect(helpers.sessions, isEmpty);
    },
  );

  test(
    'send writes hex; fragmented stdout yields SysEx and short packets',
    () async {
      await midi.open();
      final packets = <Uint8List>[];
      final subscription = midi.packets.listen(packets.add);
      final process = helpers.sessions.single;
      midi.send(Uint8List.fromList([0xf0, 0, 0x20, 0xf7]));
      await Future<void>.delayed(Duration.zero);
      expect(utf8.decode(process.written), 'f00020f7\n');
      process.output.add(utf8.encode('f000'));
      process.output.add(utf8.encode('20f7\nf001f7\n903c7f\nf8\n'));
      await Future<void>.delayed(Duration.zero);
      expect(packets, [
        [0xf0, 0, 0x20, 0xf7],
        [0xf0, 1, 0xf7],
        [0x90, 60, 127],
        [0xf8],
      ]);
      await subscription.cancel();
    },
  );

  test(
    'unexpected exit reports loss once and permits a fresh session',
    () async {
      await midi.open();
      helpers.sessions.single.finish(7);
      await Future<void>.delayed(Duration.zero);
      expect(lost, 1);
      expect(midi.portInUse, isFalse);
      await midi.open();
      expect(helpers.sessions, hasLength(2));
      expect(midi.portInUse, isTrue);
    },
  );

  test(
    'lost closes stdin and duplicate exit never duplicates onLost',
    () async {
      await midi.open();
      final process = helpers.sessions.single;
      process.line('lost WinMM device removed');
      await Future<void>.delayed(Duration.zero);
      expect(lost, 1);
      expect(process.stdinClosed, isTrue);
      expect(midi.portInUse, isFalse);
    },
  );

  test('malformed data reports loss', () async {
    await midi.open();
    helpers.sessions.single.line('not hex');
    await Future<void>.delayed(Duration.zero);
    expect(lost, 1);
  });

  test('close ends stdin, suppresses loss and reopens a fresh child', () async {
    await midi.open();
    final first = helpers.sessions.single;
    await midi.close();
    expect(first.stdinClosed, isTrue);
    expect(first.finished.isCompleted, isTrue);
    expect(first.killed, isFalse);
    expect(lost, 0);
    await midi.open();
    expect(helpers.calls.where((c) => c[1] == 'list'), hasLength(2));
    expect(helpers.sessions, hasLength(2));
  });

  test('close kills a child that ignores EOF after two seconds', () async {
    helpers.exitOnStdinClose = false;
    await midi.open();
    final process = helpers.sessions.single;
    final watch = Stopwatch()..start();
    await midi.close();
    expect(watch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 2)));
    expect(process.killed, isTrue);
    expect(lost, 0);
  });

  test(
    'close during list cancels opening without starting a session',
    () async {
      final listed = Completer<Process>();
      final started = Completer<void>();
      midi = DesktopMidi(
        platform: TargetPlatform.windows,
        windowsNameQuery: () async => ['ADI-2 DAC'],
        processStarter: (exe, args) {
          started.complete();
          return listed.future;
        },
      );
      final opening = expectLater(
        midi.open(),
        throwsA(isA<HostUsbException>()),
      );
      await started.future;
      await midi.close();
      listed.complete(await helpers.start('helper', ['list']));
      await opening;
      expect(helpers.sessions, isEmpty);
      expect(midi.portInUse, isFalse);
    },
  );

  test(
    'close during handshake cancels open and closes the new child',
    () async {
      final process = FakeMidiProcess();
      final starting = Completer<void>();
      midi = DesktopMidi(
        platform: TargetPlatform.windows,
        windowsNameQuery: () async => ['ADI-2 DAC'],
        processStarter: (exe, args) async {
          if (args.first == 'list') return helpers.start(exe, args);
          starting.complete();
          return process;
        },
      );
      final opening = expectLater(
        midi.open(),
        throwsA(isA<HostUsbException>()),
      );
      await starting.future;
      await Future<void>.delayed(Duration.zero);
      await midi.close();
      await opening;
      expect(process.stdinClosed, isTrue);
      expect(midi.portInUse, isFalse);
      expect(lost, 0);
    },
  );

  test('list failure never opens a port', () async {
    final process = FakeMidiProcess();
    process.line('invalid json');
    process.finish();
    midi = DesktopMidi(
      platform: TargetPlatform.windows,
      windowsNameQuery: () async => ['ADI-2 DAC'],
      processStarter: (exe, args) async => process,
    );
    await expectLater(midi.open(), throwsA(isA<HostUsbException>()));
    expect(process.killed, isTrue);
    expect(midi.portInUse, isFalse);
  });

  test('missing helper executable reports usb_missing', () async {
    midi = DesktopMidi(
      platform: TargetPlatform.windows,
      windowsNameQuery: () async => [],
      processStarter: (exe, args) async => throw ProcessException(exe, args),
    );
    await expectLater(
      midi.open(),
      throwsA(
        isA<HostUsbException>().having((e) => e.type, 'code', 'usb_missing'),
      ),
    );
  });

  test('unreliable PnP cannot prevent helper detection or opening', () async {
    var fails = false;
    midi = DesktopMidi(
      platform: TargetPlatform.windows,
      processStarter: helpers.start,
      windowsNameQuery: () async {
        if (fails) throw StateError('PnP unavailable');
        return [];
      },
    );
    expect(await midi.detect(), 'ADI-2 DAC');
    expect(midi.windowsPnpUnreliable, isTrue);
    fails = true;
    expect(await midi.detect(), 'ADI-2 DAC');
    expect(await midi.open(), 'ADI-2 DAC Midi Port 1');
  });

  test(
    'PnP fallback stays fresh after a hotplug long after host startup',
    () async {
      helpers.ports = [];
      midi = DesktopMidi(
        platform: TargetPlatform.windows,
        processStarter: helpers.start,
        windowsNameQuery: () async => [],
      );
      expect(await midi.detect(), isNull);
      helpers.ports = ['ADI-2 Pro Midi Port 1'];
      expect(await midi.detect(), 'ADI-2 Pro');
      expect(midi.windowsPnpUnreliable, isTrue);
      helpers.ports = [];
      expect(await midi.detect(), isNull);
      expect(helpers.calls, hasLength(3));
      expect(helpers.sessions, isEmpty);
    },
  );

  test(
    'schnelle Folge von Nachrichten verliert den Hilfsprozess nicht',
    () async {
      await midi.open();
      final process = helpers.sessions.single;
      for (var i = 0; i < 200; i++) {
        midi.send(Uint8List.fromList([0xf0, 0, i & 0x7f, 0xf7]));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(lost, 0);
      expect(
        utf8.decode(process.written).split('\n').where((l) => l.isNotEmpty),
        hasLength(200),
      );
    },
  );
}
