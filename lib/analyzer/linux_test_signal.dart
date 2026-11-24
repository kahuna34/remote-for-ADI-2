import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'linux_capture.dart' show LinuxProcessRunner, LinuxProcessStarter;
import 'test_signal.dart';

enum LinuxSignalError {
  serverUnavailable,
  outputsUnverified,
  noSink,
  ambiguousSink,
  unsupportedRate,
  interrupted,
  routeUnverified,
  missingTools,
  playbackFailed,
  routeChanged,
  sinkChanged,
}

class LinuxSignalException implements Exception {
  const LinuxSignalException(this.code);

  /// Stable error code; translated at the UI boundary.
  final LinuxSignalError code;
}

class LinuxSignalSink {
  const LinuxSignalSink(this.name, this.rate, this.index);
  final String name;
  final int rate, index;
}

bool _adi2(String text) =>
    RegExp(r'ADI[-_ ]?2', caseSensitive: false).hasMatch(text);

List<LinuxSignalSink> parseTestSignalSinks(String output) {
  final rows = jsonDecode(output) as List;
  return [
    for (final row in rows.whereType<Map>())
      if (row['name'] is String &&
          row['index'] is int &&
          _adi2('${row['name']} ${row['description'] ?? ''}') &&
          RegExp(
            r'(\d+)\s*Hz',
            caseSensitive: false,
          ).hasMatch('${row['sample_specification']}'))
        LinuxSignalSink(
          row['name'] as String,
          int.parse(
            RegExp(
              r'(\d+)\s*Hz',
              caseSensitive: false,
            ).firstMatch('${row['sample_specification']}')![1]!,
          ),
          row['index'] as int,
        ),
  ];
}

List<String> testSignalPacatArguments(LinuxSignalSink sink, String stream) => [
  '--playback',
  '--device=${sink.name}',
  '--format=float32le',
  '--channels=2',
  '--rate=${sink.rate}',
  '--raw',
  '--latency-msec=100',
  '--process-time-msec=20',
  '--no-remix',
  '--no-remap',
  '--stream-name=$stream',
  '--property=node.dont-fallback=true',
  '--property=node.dont-reconnect=true',
  '--property=node.dont-move=true',
];

/// Process boundary, also exercised without real processes and with a fake
/// clock. Only reads pactl state; never changes sink, stream or device volume.
class LinuxSignalOutput {
  LinuxSignalOutput({
    LinuxProcessRunner? run,
    LinuxProcessStarter? startProcess,
    this.elapsed,
    this.onPosition,
    this.onEnd,
  }) : _run = run ?? ((c, a) => Process.run(c, a)),
       _startProcess = startProcess ?? ((c, a) => Process.start(c, a));
  final LinuxProcessRunner _run;
  final LinuxProcessStarter _startProcess;
  final Duration Function()? elapsed;
  final void Function(Duration)? onPosition;
  final void Function(LinuxSignalError?)? onEnd;
  final _clock = Stopwatch();
  Duration _began = Duration.zero;
  Process? _process;
  TestSignalSynth? _synth;
  LinuxSignalSink? _sink;
  Timer? _timer, _watch;
  bool _writing = false, _checking = false, _cancelled = false;
  Future<void>? _stopping;
  Completer<void>? _writeBarrier;
  final _ended = Completer<void>();
  String _stream = '';

  Future<ProcessResult> _pactl(List<String> args) async {
    final result = await _run(
      'pactl',
      args,
    ).timeout(const Duration(seconds: 2));
    if (result.exitCode != 0) {
      throw const LinuxSignalException(LinuxSignalError.serverUnavailable);
    }
    return result;
  }

  Future<List<LinuxSignalSink>> _sinks() async {
    try {
      return parseTestSignalSinks(
        (await _pactl(['-f', 'json', 'list', 'sinks'])).stdout as String,
      );
    } on FormatException {
      throw const LinuxSignalException(LinuxSignalError.outputsUnverified);
    }
  }

  Future<void> start(TestSignalSettings settings) async {
    try {
      final sinks = await _sinks();
      if (_cancelled) return;
      if (sinks.length != 1) {
        throw LinuxSignalException(
          sinks.isEmpty
              ? LinuxSignalError.noSink
              : LinuxSignalError.ambiguousSink,
        );
      }
      final sink = _sink = sinks.single;
      if (sink.rate < 44100 || sink.rate > 768000) {
        throw const LinuxSignalException(LinuxSignalError.unsupportedRate);
      }
      final synth = _synth = TestSignalSynth(settings, sink.rate);
      if (_cancelled) return;
      _stream =
          'adi2-test-signals-$pid-${DateTime.now().microsecondsSinceEpoch}';
      final process = await _startProcess(
        'pacat',
        testSignalPacatArguments(sink, _stream),
      );
      _process = process;
      if (_cancelled) {
        await _terminate();
        return;
      }
      unawaited(process.stdout.drain<void>().catchError((Object _) {}));
      unawaited(process.stderr.drain<void>().catchError((Object _) {}));
      unawaited(
        process.exitCode.then((code) async {
          if (!_cancelled) {
            await _finish(LinuxSignalError.interrupted, immediate: true);
          }
        }),
      );
      // Silence until the server confirms the actual sink-input route. This
      // also detects stream-restore rules overriding the explicit --device.
      process.stdin.add(Uint8List(sink.rate ~/ 50 * 8));
      await process.stdin.flush().timeout(const Duration(milliseconds: 500));
      var verified = false;
      for (var retry = 0; retry < 50 && !_cancelled; retry++) {
        if (await _routeMatches(allowMissing: true)) {
          verified = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if (_cancelled) {
        await _terminate();
        return;
      }
      if (!verified) {
        throw const LinuxSignalException(LinuxSignalError.routeUnverified);
      }
      _clock.start();
      _began = elapsed?.call() ?? Duration.zero;
      await _write(
        sink.rate ~/ 10,
      ); // 100 ms reserve, then 20 ms replenishment.
      if (_cancelled) return;
      onPosition?.call(Duration.zero);
      var lastPosition = Duration.zero;
      _timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
        if (_writing || _cancelled) return;
        final now = elapsed == null ? _clock.elapsed : elapsed!() - _began;
        final due =
            (now.inMicroseconds * sink.rate ~/ 1000000) +
            sink.rate ~/ 10 -
            synth.frame;
        if (due > 0) unawaited(_write(math.min(due, sink.rate ~/ 10)));
        if (now - lastPosition >= const Duration(milliseconds: 100)) {
          lastPosition = now;
          onPosition?.call(
            Duration(
              microseconds:
                  math.max(0, synth.frame - sink.rate ~/ 10) *
                  1000000 ~/
                  sink.rate,
            ),
          );
        }
      });
      _watch = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => unawaited(_checkRoute()),
      );
    } on LinuxSignalException catch (error) {
      await _finish(error.code, immediate: true);
    } on ProcessException {
      await _finish(LinuxSignalError.missingTools, immediate: true);
    } catch (_) {
      await _finish(LinuxSignalError.playbackFailed, immediate: true);
    }
  }

  Future<bool> _routeMatches({bool allowMissing = false}) async {
    final rows = jsonDecode(
      (await _pactl(['-f', 'json', 'list', 'sink-inputs'])).stdout as String,
    ) as List;
    final matches = rows
        .whereType<Map>()
        .where((r) => (r['properties'] as Map?)?['media.name'] == _stream)
        .toList();
    if (matches.isEmpty && allowMissing) return false;
    if (matches.length != 1 || matches.single['sink'] != _sink!.index) {
      throw const LinuxSignalException(LinuxSignalError.routeChanged);
    }
    return true;
  }

  Future<void> _checkRoute() async {
    if (_checking || _cancelled) return;
    _checking = true;
    try {
      final sinks = await _sinks();
      if (!sinks.any(
        (s) =>
            s.name == _sink!.name &&
            s.index == _sink!.index &&
            s.rate == _sink!.rate,
      )) {
        throw const LinuxSignalException(LinuxSignalError.sinkChanged);
      }
      if (!_cancelled) await _routeMatches();
    } catch (_) {
      await _finish(LinuxSignalError.routeChanged, immediate: true);
    } finally {
      _checking = false;
    }
  }

  Future<void> _write(int count) async {
    _writing = true;
    final barrier = _writeBarrier = Completer<void>();
    try {
      if (_cancelled) return;
      _process!.stdin.add(_synth!.render(count));
      await _process!.stdin.flush().timeout(const Duration(milliseconds: 500));
      if (_synth!.finished) unawaited(_finish(null));
    } catch (_) {
      if (!_cancelled) {
        unawaited(_finish(LinuxSignalError.interrupted, immediate: true));
      }
    } finally {
      _writing = false;
      barrier.complete();
    }
  }

  Future<void> stop() => _finish(null);
  Future<void> get ended => _ended.future;

  Future<void> _finish(LinuxSignalError? error, {bool immediate = false}) {
    if (_stopping != null) return _stopping!;
    _cancelled = true;
    _timer?.cancel();
    _watch?.cancel();
    _clock.stop();
    if (immediate) _process?.kill();
    return _stopping = () async {
      try {
        await _writeBarrier?.future.timeout(const Duration(milliseconds: 600));
        if (!immediate && _process != null && _synth != null) {
          // A queued write may still be flushing; IOSink preserves ordering.
          _synth!.fadeOut();
          _process!.stdin.add(_synth!.render((_sink!.rate * .02).round()));
          await _process!.stdin.flush().timeout(
            const Duration(milliseconds: 500),
          );
          await _process!.stdin.close().timeout(
            const Duration(milliseconds: 500),
          );
          await _process!.exitCode.timeout(const Duration(seconds: 1));
        }
      } catch (_) {
        /* A failed/disconnected output is terminated below. */
      }
      await _terminate();
      if (!_ended.isCompleted) {
        _ended.complete();
        onEnd?.call(error);
      }
    }();
  }

  Future<void> _terminate() async {
    final process = _process;
    _process = null;
    if (process == null) return;
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(milliseconds: 300));
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
    }
  }
}

/// The UI exchanges only settings/status with this worker. PCM, timers,
/// process I/O and initial pink-noise FFT never occupy Flutter's UI isolate.
void _signalWorker(List<Object> args) async {
  final parent = args[0] as SendPort;
  final settings = args[1] as TestSignalSettings;
  final commands = ReceivePort();
  LinuxSignalError? failure;
  final output = LinuxSignalOutput(
    onPosition: (elapsed) => parent.send(elapsed),
    onEnd: (error) => failure = error,
  );
  commands.listen((_) => unawaited(output.stop()));
  parent.send(commands.sendPort);
  await output.start(settings);
  parent.send('ready');
  await output.ended;
  parent.send(['ended', failure]);
  commands.close();
}

class LinuxTestSignalPlayer extends ChangeNotifier {
  LinuxTestSignalPlayer({void Function(List<Object>)? workerMain})
    : _workerMain = workerMain ?? _signalWorker;
  final void Function(List<Object>) _workerMain;
  static final instance = LinuxTestSignalPlayer();
  bool sessionAccepted = false;
  bool busy = false, running = false;
  LinuxSignalError? error;
  Duration elapsed = Duration.zero;
  TestSignalSettings? settings;
  Isolate? _worker;
  ReceivePort? _events;
  SendPort? _commands;
  Completer<void>? _ended;
  Future<void>? _starting;
  int _generation = 0;
  Future<void>? _stopOperation;
  bool _stopRequested = false;

  Future<void> start(TestSignalSettings value) async {
    if (busy || running) return;
    if (!Platform.isLinux) throw UnsupportedError('Linux test signals');
    await startWorker(value);
  }

  @visibleForTesting
  Future<void> startWorker(TestSignalSettings value) async {
    if (busy || running) return;
    if (_stopOperation != null) return;
    _worker?.kill(priority: Isolate.immediate);
    _events?.close();
    _worker = null;
    _events = null;
    _commands = null;
    _starting = null;
    _stopRequested = false;
    final generation = ++_generation;
    settings = value;
    error = null;
    elapsed = Duration.zero;
    busy = true;
    notifyListeners();
    final ready = Completer<void>();
    _starting = ready.future;
    _ended = Completer<void>();
    final events = _events = ReceivePort();
    events.listen((message) {
      if (generation != _generation) return;
      if (message is SendPort) {
        _commands = message;
        if (_stopRequested) message.send('stop');
      } else if (message is Duration) {
        elapsed = message;
        notifyListeners();
      } else if (message == 'ready') {
        if (!ready.isCompleted) ready.complete();
        if (!_ended!.isCompleted && !_stopRequested) {
          busy = false;
          running = true;
          notifyListeners();
        }
      } else {
        // Normal end, isolate error or unexpected isolate exit.
        if (message is List && message.first == 'ended') {
          error = message[1] as LinuxSignalError?;
        } else if (!_ended!.isCompleted) {
          error = LinuxSignalError.playbackFailed;
        }
        busy = false;
        running = false;
        if (!_ended!.isCompleted) _ended!.complete();
        if (!ready.isCompleted) ready.complete();
        notifyListeners();
      }
    });
    try {
      _worker = await Isolate.spawn(
        _workerMain,
        [events.sendPort, value],
        onError: events.sendPort,
        onExit: events.sendPort,
      );
      await ready.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      error = LinuxSignalError.playbackFailed;
      await stop();
    }
  }

  Future<void> stop() =>
      _stopOperation ??= _stop().whenComplete(() => _stopOperation = null);

  Future<void> _stop() async {
    _stopRequested = true;
    final starting = _starting;
    if (starting != null && _commands == null) {
      try {
        await starting.timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    _commands?.send('stop');
    try {
      await _ended?.future.timeout(const Duration(seconds: 5));
    } catch (_) {}
    ++_generation;
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _commands = null;
    _starting = null;
    _events?.close();
    _events = null;
    busy = false;
    running = false;
    notifyListeners();
  }
}
