import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adi2_remote/analyzer/linux_capture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';

List<int> pcm(List<double> samples, {Endian endian = Endian.little}) {
  final bytes = ByteData(samples.length * 4);
  for (var i = 0; i < samples.length; i++) {
    bytes.setFloat32(i * 4, samples[i], endian);
  }
  return bytes.buffer.asUint8List();
}

class _CaptureProcess extends Fake implements Process {
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final exited = Completer<int>();
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => exited.future;
  void finish(int code) {
    if (exited.isCompleted) return;
    exited.complete(code);
    unawaited(output.close());
    unawaited(errors.close());
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    finish(0);
    return true;
  }
}

void main() {
  test('Irregular process chunks are paced at 60 Hz without losing samples; unity gain precedes recording', () {
    fakeAsync((time) {
      final process = _CaptureProcess();
      final calls = <List<String>>[];
      final output = <double>[];
      final arrivals = <Duration>[];
      final capture = LinuxAnalyzerCapture(
        elapsed: () => time.elapsed,
        readDmi: (_) async => 'Test Linux',
        run: (command, args) async {
          calls.add([command, ...args]);
          return ProcessResult(
            1,
            0,
            '[{"name":"RME_ADI-2","sample_specification":"float32le 2ch 48000Hz"}]',
            '',
          );
        },
        startProcess: (command, args) async {
          expect(
            calls,
            containsAllInOrder([
              ['pactl', 'set-source-volume', 'RME_ADI-2', '100%'],
              ['pactl', 'set-source-mute', 'RME_ADI-2', '0'],
            ]),
          );
          expect(command, 'parec');
          expect(
            args,
            containsAll(['--latency-msec=10', '--process-time-msec=5']),
          );
          return process;
        },
      );
      final sub = capture.events.listen((event) {
        if (event['pcm'] case final List<double> samples) {
          output.addAll(samples);
          arrivals.add(time.elapsed);
        }
      });
      unawaited(capture.start());
      time.flushMicrotasks();
      final expected = List<double>.generate(48000, (i) => i.toDouble());
      var offset = 0;
      // 30 ms, 10 ms, 45 ms, 15 ms chunks: within the 50 ms jitter reserve.
      for (final frames in [
        1440,
        480,
        2160,
        720,
        1440,
        480,
        2160,
        720,
        1440,
        480,
        2160,
        720,
        1440,
        480,
        2160,
        720,
        1440,
        480,
        2160,
        720,
      ]) {
        final end = offset + frames * 2;
        process.output.add(pcm(expected.sublist(offset, end)));
        offset = end;
        time.flushMicrotasks();
        time.elapse(Duration(microseconds: (frames / 48000 * 1e6).round()));
      }
      time.elapse(const Duration(milliseconds: 100));
      expect(output, expected);
      expect(arrivals.length, inInclusiveRange(29, 32));
      for (var i = 1; i < arrivals.length; i++) {
        expect((arrivals[i] - arrivals[i - 1]).inMicroseconds, 16667);
      }
      unawaited(capture.dispose());
      time.flushMicrotasks();
      unawaited(sub.cancel());
      time.flushMicrotasks();
      final count = arrivals.length;
      time.elapse(const Duration(seconds: 1));
      expect(arrivals.length, count);
    });
  });

  test('Pacer drops oldest stereo frames only at overflow and carries fractional frames', () {
    final pacer = LinuxPcmPacer(44100);
    final samples = List<double>.generate(30000, (i) => i.toDouble());
    pacer.add(samples);
    expect(pacer.bufferedSamples, 22050);
    expect(pacer.droppedSamples, 7950);
    final first = pacer.take(const Duration(microseconds: 16667));
    expect(first.first, 7950);
    expect(first.length.isEven, isTrue);
    final clean = LinuxPcmPacer(44100);
    final all = List<double>.generate(20000, (i) => i.toDouble());
    clean.add(all);
    final received = <double>[];
    for (var i = 0; i < 60; i++) {
      received.addAll(clean.take(const Duration(microseconds: 16667)));
    }
    expect(received, all);
    expect(clean.droppedSamples, 0);
  });

  test(
    'short-format fallback records the chosen source and reports process loss',
    () async {
      final process = _CaptureProcess();
      final firstPcm = Completer<Map<String, dynamic>>();
      final lost = Completer<Map<String, dynamic>>();
      final capture = LinuxAnalyzerCapture(
        run: (_, args) async => ProcessResult(
          1,
          args.contains('json') ? 1 : 0,
          args.contains('json')
              ? ''
              : '1 RME_ADI-2 PipeWire float32le 2ch 96000Hz RUNNING',
          '',
        ),
        startProcess: (command, args) async {
          expect(command, 'parec');
          expect(args, contains('--device=RME_ADI-2'));
          expect(args, contains('--rate=96000'));
          expect(args, isNot(contains('--dont-move')));
          return process;
        },
      );
      final sub = capture.events.listen((event) {
        if (event.containsKey('pcm') && !firstPcm.isCompleted) {
          firstPcm.complete(event);
        }
        if (event['status'] == 'usbUnavailable' && !lost.isCompleted) {
          lost.complete(event);
        }
      });
      await capture.start();
      process.output.add(pcm([.5, -.5]));
      final event = await firstPcm.future;
      expect(event['pcm'], [.5, -.5]);
      expect(event['sampleRate'], 96000);
      expect(event['routeVerified'], isTrue);
      expect(event['mediaStreamVolume'], 100);
      expect(event['calibrationIdentity'], contains('hostManufacturer'));
      process.finish(7);
      expect((await lost.future)['detail'], contains('(7)'));
      await sub.cancel();
      await capture.dispose();
    },
  );
  test('pactl JSON selects ADI-2 by description and RME by name; excludes monitors', () {
    final sources = parsePactlJson(
      jsonEncode([
        {'name': 'default', 'description': 'Built-in microphone'},
        {'name': 'alsa_output.RME.monitor', 'description': 'ADI-2 Monitor'},
        {'name': 'other-monitor', 'description': 'RME', 'monitor_of_sink': 2},
        {
          'name': 'alsa_input.usb-device',
          'description': 'ADI-2 DAC (123)',
          'sample_specification': 's32le 2ch 96000Hz',
          'properties': {'device.serial': '123'},
        },
        {'name': 'alsa_input.RME', 'monitor_of_sink': 4294967295},
      ]),
    );
    expect(sources.map((s) => s.name), [
      'alsa_input.usb-device',
      'alsa_input.RME',
    ]);
    expect(sources.first.rate, 96000);
    expect(sources.first.properties['device.serial'], '123');
    expect(sources.last.rate, 48000);
    expect(parsePactlJson('[{"name":"microphone"}]'), isEmpty);
    expect(parsePactlJson('[]'), isEmpty);
  });

  test(
    'pactl short handles tabs, spaces, source rate, monitors and no source',
    () {
      final sources = parsePactlShort(
        '0\talsa_output.RME.monitor\tPipeWire\tfloat32le 2ch 48000Hz\tRUNNING\n1 alsa_input.usb-RME_ADI-2 module-alsa-card.c s32le 2ch 44100Hz SUSPENDED\n',
      );
      expect(sources.single.name, 'alsa_input.usb-RME_ADI-2');
      expect(sources.single.rate, 44100);
      expect(
        parsePactlShort('1 microphone PipeWire s16le 2ch 48000Hz IDLE'),
        isEmpty,
      );
      expect(parsePactlShort(''), isEmpty);
      expect(parsePactlShort('3 RME').single.rate, 48000);
    },
  );

  test(
    'Float32 stereo keeps order and incomplete frames across byte boundaries',
    () {
      final bytes = pcm([0, 1, -.5, .25, -1, .75]);
      for (var split = 0; split <= bytes.length; split++) {
        final decoder = LinuxFloat32StereoDecoder();
        expect(
          [
            ...decoder.add(bytes.sublist(0, split)),
            ...decoder.add(bytes.sublist(split)),
          ],
          [0, 1, -.5, .25, -1, .75],
        );
      }
      expect(
        () => LinuxFloat32StereoDecoder().add(pcm([double.nan, 0])),
        throwsFormatException,
      );
    },
  );

  test('pw-record WAV skips padded extra chunks and fragmented headers', () {
    final fmt = ByteData(16)
      ..setUint16(0, 3, Endian.little)
      ..setUint16(2, 2, Endian.little)
      ..setUint32(4, 48000, Endian.little)
      ..setUint32(8, 384000, Endian.little)
      ..setUint16(12, 8, Endian.little)
      ..setUint16(14, 32, Endian.little);
    List<int> size(int n) =>
        (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List();
    final bytes = [
      ...ascii.encode('RIFF'),
      ...size(0xffffffff),
      ...ascii.encode('WAVEJUNK'),
      ...size(1),
      0,
      0,
      ...ascii.encode('fmt '),
      ...size(16),
      ...fmt.buffer.asUint8List(),
      ...ascii.encode('data'),
      ...size(0xffffffff),
      ...pcm([.5, -.5, .25, 1]),
    ];
    for (var split = 0; split < bytes.length; split++) {
      final decoder = LinuxRecordingDecoder();
      expect(
        [
          ...decoder.add(bytes.sublist(0, split)),
          ...decoder.add(bytes.sublist(split)),
        ],
        [.5, -.5, .25, 1],
        reason: 'split $split',
      );
    }
  });

  test('pw-record AU decodes big-endian float samples', () {
    final header = ByteData(24)
      ..setUint32(0, 0x2e736e64)
      ..setUint32(4, 24)
      ..setUint32(8, 0xffffffff)
      ..setUint32(12, 6)
      ..setUint32(16, 48000)
      ..setUint32(20, 2);
    final bytes = [
      ...header.buffer.asUint8List(),
      ...pcm([.5, -.25], endian: Endian.big),
    ];
    final decoder = LinuxRecordingDecoder();
    final samples = <double>[];
    for (final byte in bytes) {
      samples.addAll(decoder.add([byte]));
    }
    expect(samples, [.5, -.25]);
  });

  test(
    'missing source reports usbUnavailable without starting a recorder',
    () async {
      final capture = LinuxAnalyzerCapture(
        run: (_, _) async => ProcessResult(0, 0, '[]', ''),
        startProcess: (_, _) => throw StateError('No recorder expected'),
      );
      final event = capture.events.first;
      await capture.start();
      expect((await event)['status'], 'usbUnavailable');
      await capture.dispose();
    },
  );

  test('missing recorder tools gives an actionable package message', () async {
    final commands = <String>[];
    final capture = LinuxAnalyzerCapture(
      run: (_, _) async => ProcessResult(0, 0, '[{"name":"RME"}]', ''),
      startProcess: (command, _) async {
        commands.add(command);
        throw ProcessException(command, [], 'missing', 2);
      },
    );
    final event = capture.events.first;
    await capture.start();
    final error = await event;
    expect(commands, ['parec', 'pw-record']);
    expect(error['status'], 'captureFailed');
    expect(error['detail'], contains('pulseaudio-utils'));
    await capture.dispose();
  });
}
