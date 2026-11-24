import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:adi2_remote/analyzer/linux_test_signal.dart';
import 'package:adi2_remote/analyzer/test_signal.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class _Consumer implements StreamConsumer<List<int>> {
  _Consumer(this.process);
  final _Process process;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      process.bytes.addAll(bytes);
    }
  }

  @override
  Future<void> close() async => process.finish(0);
}

class _Process extends Fake implements Process {
  final bytes = <int>[];
  final exited = Completer<int>();
  late final input = IOSink(_Consumer(this));
  @override
  IOSink get stdin => input;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<int> get exitCode => exited.future;
  void finish(int code) {
    if (!exited.isCompleted) exited.complete(code);
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    finish(0);
    return true;
  }
}

class _AudioServer {
  String name = 'alsa_output.usb-RME_ADI-2', stream = '';
  int rate = 96000, index = 7, routedIndex = 7;
  bool present = true;
  final process = _Process();
  final calls = <List<String>>[];
  Future<ProcessResult> run(String cmd, List<String> args) async {
    calls.add([cmd, ...args]);
    final rows = args.last == 'sinks'
        ? [
            {
              'index': 1,
              'name': 'built-in',
              'sample_specification': 's16le 2ch 48000Hz',
            },
            {
              'index': 2,
              'name': 'RME_Digiface',
              'sample_specification': 's32le 2ch 48000Hz',
            },
            if (present)
              {
                'index': index,
                'name': name,
                'sample_specification': 'float32le 2ch ${rate}Hz',
              },
          ]
        : [
            {
              'sink': routedIndex,
              'properties': {'media.name': stream},
            },
          ];
    return ProcessResult(0, 0, jsonEncode(rows), '');
  }

  Future<Process> start(String cmd, List<String> args) async {
    calls.add([cmd, ...args]);
    stream = args
        .singleWhere((a) => a.startsWith('--stream-name='))
        .substring('--stream-name='.length);
    return process;
  }
}

void _fakeWorker(List<Object> args) async {
  final parent = args[0] as SendPort;
  final commands = ReceivePort();
  parent.send(commands.sendPort);
  parent.send('ready');
  parent.send(const Duration(seconds: 2));
  await commands.first;
  parent.send(['ended', null]);
  commands.close();
}

void _brokenWorker(List<Object> args) => throw StateError('worker failed');

void main() {
  test(
    'isolate settings/status, stop barrier, immediate cancellation and restart',
    () async {
      final player = LinuxTestSignalPlayer(workerMain: _fakeWorker);
      await player.startWorker(TestSignalSettings());
      expect(player.running, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(player.elapsed, const Duration(seconds: 2));
      await player.stop();
      expect(player.running, isFalse);
      expect(player.busy, isFalse);
      final start = player.startWorker(
        TestSignalSettings(signal: TestSignal.white),
      );
      await player.stop();
      await start;
      expect(player.running, isFalse);
      expect(player.busy, isFalse);
      await player.startWorker(TestSignalSettings());
      expect(player.running, isTrue);
      await player.stop();
      player.dispose();
    },
  );

  test('unexpected worker failure leaves stop/restart usable', () async {
    final player = LinuxTestSignalPlayer(workerMain: _brokenWorker);
    await player.startWorker(TestSignalSettings());
    expect(player.error, LinuxSignalError.playbackFailed);
    expect(player.running, isFalse);
    expect(player.busy, isFalse);
    await player.stop();
    await player.startWorker(TestSignalSettings());
    expect(player.error, LinuxSignalError.playbackFailed);
    await player.stop();
    player.dispose();
  });

  test('explicit sink, actual sample rate, 100 ms reserve, timed feed, graceful fade/close', () {
    fakeAsync((clock) {
      final server = _AudioServer();
      final positions = <Duration>[];
      final output = LinuxSignalOutput(
        run: server.run,
        startProcess: server.start,
        elapsed: () => clock.elapsed,
        onPosition: positions.add,
      );
      unawaited(output.start(TestSignalSettings()));
      clock.flushMicrotasks();
      final pacat = server.calls.singleWhere((c) => c.first == 'pacat');
      expect(
        pacat,
        containsAll([
          '--playback',
          '--device=${server.name}',
          '--format=float32le',
          '--channels=2',
          '--rate=96000',
          '--raw',
          '--latency-msec=100',
          '--property=node.dont-fallback=true',
          '--property=node.dont-reconnect=true',
        ]),
      );
      // Initial route-verification silence + exactly 100 ms of signal.
      expect(server.process.bytes.length, (96000 ~/ 50 + 96000 ~/ 10) * 8);
      clock.elapse(const Duration(seconds: 1));
      clock.flushMicrotasks();
      expect(server.process.bytes.length, (96000 ~/ 50 + 96000 * 11 ~/ 10) * 8);
      expect(positions.last.inMilliseconds, inInclusiveRange(900, 1000));
      unawaited(output.stop());
      clock.flushMicrotasks();
      expect(
        server.process.bytes.length,
        (96000 ~/ 50 + 96000 * 11 ~/ 10 + 1920) * 8,
      );
      expect(
        ByteData.sublistView(Uint8List.fromList(server.process.bytes))
            .getFloat32(server.process.bytes.length - 4, Endian.little),
        0,
      );
      expect(server.process.exited.isCompleted, isTrue);
      final count = server.process.bytes.length;
      clock.elapse(const Duration(seconds: 2));
      expect(server.process.bytes.length, count);
      expect(
        server.calls.where((c) => c.any((a) => a.startsWith('set-'))),
        isEmpty,
      );
    });
  });

  test(
    'no ADI-2 or ambiguous sinks never starts pacat or another output',
    () async {
      for (final rows in [
        [],
        [
          {
            'index': 1,
            'name': 'RME Digiface',
            'sample_specification': 's32le 2ch 48000Hz',
          },
        ],
        [
          for (var i = 1; i <= 2; i++)
            {
              'index': i,
              'name': 'ADI-2-$i',
              'sample_specification': 's32le 2ch 48000Hz',
            },
        ],
      ]) {
        LinuxSignalError? error;
        var started = false;
        final output = LinuxSignalOutput(
          run: (_, _) async => ProcessResult(0, 0, jsonEncode(rows), ''),
          startProcess: (_, _) async {
            started = true;
            return _Process();
          },
          onEnd: (e) => error = e,
        );
        await output.start(TestSignalSettings());
        expect(started, isFalse);
        expect(error, isNotNull);
      }
    },
  );

  for (final mode in [
    'disconnect',
    'rate change',
    'moved stream',
    'process failure',
  ]) {
    test('stops on $mode without reopening on default', () {
      fakeAsync((clock) {
        final server = _AudioServer();
        LinuxSignalError? error;
        final output = LinuxSignalOutput(
          run: server.run,
          startProcess: server.start,
          elapsed: () => clock.elapsed,
          onEnd: (e) => error = e,
        );
        unawaited(output.start(TestSignalSettings()));
        clock.flushMicrotasks();
        switch (mode) {
          case 'disconnect':
            server.present = false;
          case 'rate change':
            server.rate = 48000;
          case 'moved stream':
            server.routedIndex = 1;
          case 'process failure':
            server.process.finish(3);
        }
        clock.elapse(const Duration(milliseconds: 300));
        clock.flushMicrotasks();
        expect(error, isNotNull);
        expect(server.process.exited.isCompleted, isTrue);
        expect(server.calls.where((c) => c.first == 'pacat').length, 1);
      });
    });
  }

  test('wrong initial route receives silence only', () {
    fakeAsync((clock) {
      final server = _AudioServer()..routedIndex = 1;
      LinuxSignalError? error;
      final output = LinuxSignalOutput(
        run: server.run,
        startProcess: server.start,
        onEnd: (e) => error = e,
      );
      unawaited(output.start(TestSignalSettings(dbfs: 0)));
      clock.flushMicrotasks();
      expect(error, isNotNull);
      expect(server.process.bytes, everyElement(0));
    });
  });

  test(
    'stop during async sink discovery cannot start a later process',
    () async {
      final pending = Completer<ProcessResult>();
      var started = false;
      final output = LinuxSignalOutput(
        run: (_, _) => pending.future,
        startProcess: (_, _) async {
          started = true;
          return _Process();
        },
      );
      final start = output.start(TestSignalSettings());
      await output.stop();
      pending.complete(ProcessResult(0, 0, '[]', ''));
      await start;
      expect(started, isFalse);
    },
  );

  test(
    'missing utilities and unavailable server give actionable errors',
    () async {
      for (final missing in [true, false]) {
        LinuxSignalError? error;
        final output = LinuxSignalOutput(
          run: (cmd, args) async {
            if (missing) throw ProcessException(cmd, args, 'missing', 2);
            return ProcessResult(0, 1, '', 'unreachable');
          },
          onEnd: (e) => error = e,
        );
        await output.start(TestSignalSettings());
        expect(
          error,
          missing
              ? LinuxSignalError.missingTools
              : LinuxSignalError.serverUnavailable,
        );
      }
    },
  );
}
