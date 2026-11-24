import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:adi2_host/host_analyzer.dart';
import 'package:adi2_host/isolated_host_analyzer.dart';
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/host/host_analyzer_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

class _Capture implements HostAnalyzerCapture {
  _Capture(this.observer, {this.fail = false});
  final SendPort observer;
  final bool fail;
  final input = StreamController<dynamic>.broadcast(sync: true);
  Timer? timer;
  @override
  Stream<dynamic> get events => input.stream;
  @override
  Future<void> start() async {
    observer.send(['start', Isolate.current.debugName]);
    if (fail) throw StateError('fake missing input');
    timer = Timer.periodic(const Duration(milliseconds: 17), (_) {
      input.add({
        'sampleRate': 48000,
        'device': 'fake ADI-2',
        'pcm': List.generate(
          1600,
          (i) => .2 * math.sin(2 * math.pi * 1000 * (i ~/ 2) / 48000),
        ),
      });
    });
  }

  @override
  Future<void> stop() async {
    timer?.cancel();
    observer.send(['stop']);
  }
}

IsolatedHostAnalyzer _create(SendPort observer, {bool fail = false}) {
  // Only a SendPort and bool are captured; no UI/capture instance crosses isolates.
  return IsolatedHostAnalyzer(
    captureFactory: () => _Capture(observer, fail: fail),
  );
}

HostAnalyzerCapture _brokenFactory() =>
    throw StateError('fake factory failure');

void main() {
  test(
    'Factory failure before handshake is reported once and can be retried',
    () async {
      final host = IsolatedHostAnalyzer(captureFactory: _brokenFactory);
      final errors = <String>[];
      void send(String type, Map<String, dynamic> data) {
        if (type == 'analyzer_error') errors.add(data['code'] as String);
      }

      await host.start('ui', AnalyzerBandResolution.third, send);
      await host.start('ui', AnalyzerBandResolution.third, send);
      expect(errors, ['analyzer_no_input', 'analyzer_no_input']);
      await host.dispose();
    },
  );

  test('Worker owns capture; UI receives encoded frames; stop, retry and dispose are barriers', () async {
    final events = ReceivePort();
    final lifecycle = <List>[];
    final sub = events.listen((dynamic m) => lifecycle.add(m as List));
    final host = _create(events.sendPort);
    final messages = <(String, Map<String, dynamic>)>[];
    var frame = Completer<void>();
    void send(String type, Map<String, dynamic> data) {
      messages.add((type, data));
      if (type == 'analyzer_frame' && !frame.isCompleted) frame.complete();
    }

    await host.start(
      'ui',
      AnalyzerBandResolution.third,
      send,
      version: 2,
      fps: 30,
    );
    await frame.future.timeout(const Duration(seconds: 5));
    expect(lifecycle.first, ['start', 'Linux analyzer']);
    expect(host.analysisCount, 1);
    final metadata = messages.firstWhere((m) => m.$1 == 'analyzer_metadata').$2;
    final encoded = messages.lastWhere((m) => m.$1 == 'analyzer_frame').$2;
    expect(encoded['s'], isA<String>());
    expect(encoded.containsKey('pcm'), isFalse);
    final decoded = decodeHostAnalyzerFrame({...metadata, ...encoded});
    expect(decoded.peak.first, closeTo(-14, 1));
    await host.stop('ui');
    final count = messages.length;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(messages.length, count);
    expect(host.analysisCount, 0);
    expect(lifecycle.where((m) => m.first == 'stop'), hasLength(1));
    frame = Completer<void>();
    await host.start(
      'ui',
      AnalyzerBandResolution.twelfth,
      send,
      version: 2,
      fps: 60,
      levelsOnly: true,
    );
    await frame.future.timeout(const Duration(seconds: 5));
    final levels = messages.last.$2;
    expect(levels['l'], true);
    expect(levels.containsKey('s'), false);
    expect(levels.containsKey('b'), false);
    host.acknowledge('ui', 1);
    await host.dispose();
    final disposed = messages.length;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(messages.length, disposed);
    expect(lifecycle.where((m) => m.first == 'stop'), hasLength(2));
    await host.dispose();
    await sub.cancel();
    events.close();
  });

  test(
    'Worker capture errors reach all requesters and shutdown does not hang',
    () async {
      final events = ReceivePort();
      final sub = events.listen((_) {});
      final host = _create(events.sendPort, fail: true);
      final errors = <String>[];
      await host.start('ui', AnalyzerBandResolution.third, (type, data) {
        if (type == 'analyzer_error') errors.add(data['code'] as String);
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(errors, ['analyzer_no_input']);
      await host.dispose();
      await sub.cancel();
      events.close();
    },
  );
}
