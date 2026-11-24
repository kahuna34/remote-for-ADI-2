import 'dart:async';
import 'dart:isolate';

import 'package:adi2_remote/analyzer/analyzer_dsp.dart';

import 'host_analyzer.dart';

HostAnalyzerCapture _linuxCapture() => LinuxHostAnalyzerCapture();

/// Linux capture, decoding, pacing, DSP and wire encoding live in this worker.
/// Only encoded payloads cross back to the platform/UI isolate. Native platform
/// channels on macOS/Windows retain their existing main-isolate path.
class IsolatedHostAnalyzer extends HostAnalyzer {
  IsolatedHostAnalyzer({this.captureFactory = _linuxCapture})
    : super(capture: _UnusedCapture());

  final HostAnalyzerCapture Function() captureFactory;
  final _clients = <Object, (int, HostAnalyzerSend)>{};
  final _requests = <int, Completer<void>>{};
  var _ready = Completer<SendPort>();
  ReceivePort? _messages, _errors, _exit;
  Isolate? _isolate;
  Future<void>? _spawning;
  int _serial = 0, _count = 0;
  bool _closed = false, _broken = false;

  @override
  int get analysisCount => _count;

  Future<void> _spawn() async {
    _messages = ReceivePort()
      ..listen((dynamic message) {
        final m = message as List;
        switch (m[0]) {
          case 'ready':
            _ready.complete(m[1] as SendPort);
          case 'done':
            _count = m[2] as int;
            _requests.remove(m[1])?.complete();
          case 'frame':
            final id = m[1] as int;
            final client = _clients.values.where((c) => c.$1 == id).firstOrNull;
            if (client == null || _closed) return;
            if (m[2] == 'analyzer_error') {
              _clients.removeWhere((_, c) => c.$1 == id);
              _count = 0;
            }
            client.$2(m[2] as String, Map<String, dynamic>.from(m[3] as Map));
          case 'failed':
            _requests.remove(m[1])?.completeError(StateError('${m[2]}'));
        }
      });
    _errors = ReceivePort()..listen((dynamic error) => _failed('$error'));
    _exit = ReceivePort()
      ..listen((_) {
        if (!_closed) _failed('Analyzer worker exited');
      });
    try {
      _isolate = await Isolate.spawn(
        _worker,
        [_messages!.sendPort, captureFactory],
        onError: _errors!.sendPort,
        onExit: _exit!.sendPort,
        debugName: 'Linux analyzer',
      );
    } catch (error) {
      _failed('$error');
    }
  }

  void _failed(String detail) {
    if (_broken) return;
    _broken = true;
    _isolate?.kill(priority: Isolate.immediate);
    _messages?.close();
    _errors?.close();
    _exit?.close();
    _spawning = null;
    if (!_ready.isCompleted) _ready.completeError(StateError(detail));
    for (final request in _requests.values) {
      request.completeError(StateError(detail));
    }
    _requests.clear();
    final clients = _clients.values.toList();
    _clients.clear();
    _count = 0;
    for (final client in clients) {
      client.$2('analyzer_error', {
        'code': 'analyzer_no_input',
        'detail': detail,
      });
    }
  }

  Future<void> _command(List<Object?> command) async {
    if (_broken) {
      _broken = false;
      _ready = Completer<SendPort>();
    }
    // Attach the error listener before spawning: even a factory failure before
    // the ready handshake must be observed by this command.
    final connection = _ready.future.timeout(const Duration(seconds: 5));
    _spawning ??= _spawn();
    final port = await connection;
    final id = ++_serial;
    final done = Completer<void>();
    _requests[id] = done;
    port.send([id, ...command]);
    await done.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _requests.remove(id);
        _failed('Analyzer worker command timed out');
        throw TimeoutException('Analyzer worker command');
      },
    );
  }

  @override
  Future<void> start(
    Object client,
    AnalyzerBandResolution resolution,
    HostAnalyzerSend send, {
    int version = 1,
    bool bars = false,
    bool levelsOnly = false,
    int? fps,
  }) async {
    if (_closed) return;
    // A fresh token also discards frames still in transit from the old request.
    final id = ++_serial;
    final old = _clients[client];
    _clients[client] = (id, send);
    try {
      await _command([
        'start',
        id,
        resolution.index,
        version,
        bars,
        levelsOnly,
        fps,
        old?.$1,
      ]);
    } catch (error) {
      if (_clients[client]?.$1 == id) {
        _clients.remove(client);
        send('analyzer_error', {'code': 'analyzer_no_input'});
      }
    }
  }

  @override
  void acknowledge(Object client, Object? received) {
    final id = _clients[client]?.$1;
    if (id != null && !_closed) {
      unawaited(_command(['ack', id, received]).catchError((Object _) {}));
    }
  }

  @override
  Future<void> stop(Object client) async {
    final id = _clients.remove(client)?.$1;
    if (id != null && !_closed) await _command(['stop', id]);
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _clients.clear();
    try {
      if (_spawning != null && !_broken) await _command(['dispose']);
    } finally {
      _isolate?.kill(priority: Isolate.immediate);
      _messages?.close();
      _errors?.close();
      _exit?.close();
      for (final request in _requests.values) {
        request.completeError(StateError('Analyzer disposed'));
      }
      _requests.clear();
      _count = 0;
    }
  }
}

void _worker(List<Object> arguments) {
  final output = arguments[0] as SendPort;
  final capture = (arguments[1] as HostAnalyzerCapture Function())();
  final analyzer = HostAnalyzer(capture: capture);
  final commands = ReceivePort();
  // Preserve start/stop/dispose barriers even when capture startup is async.
  var work = Future<void>.value();
  commands.listen((dynamic message) {
    final m = message as List;
    work = work.then((_) async {
      try {
        switch (m[1]) {
          case 'start':
            // Replace before removing the old owner: keep one continuous capture.
            await analyzer.start(
              m[2] as int,
              AnalyzerBandResolution.values[m[3] as int],
              (type, data) => output.send(['frame', m[2], type, data]),
              version: m[4] as int,
              bars: m[5] as bool,
              levelsOnly: m[6] as bool,
              fps: m[7] as int?,
            );
            if (m[8] != null) await analyzer.stop(m[8] as int);
          case 'stop':
            await analyzer.stop(m[2] as int);
          case 'ack':
            analyzer.acknowledge(m[2] as int, m[3]);
          case 'dispose':
            await analyzer.dispose();
            commands.close();
        }
        output.send(['done', m[0], analyzer.analysisCount]);
      } catch (error) {
        output.send(['failed', m[0], '$error']);
      }
    });
  });
  output.send(['ready', commands.sendPort]);
}

class _UnusedCapture implements HostAnalyzerCapture {
  @override
  Stream<dynamic> get events => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}
