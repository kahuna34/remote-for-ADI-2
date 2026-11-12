import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'host_log.dart';
import 'midi_helper_protocol.dart';

typedef MidiProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
);

Future<Process> startMidiProcess(String executable, List<String> arguments) =>
    // The Windows Dart runtime sets CREATE_NO_WINDOW for normal mode, while
    // retaining all three pipes. Do not use inheritStdio or a shell here.
    Process.start(
      executable,
      arguments,
      mode: ProcessStartMode.normal,
      runInShell: false,
    );

class MidiHelperException implements Exception {
  const MidiHelperException(this.code);
  final String code;
}

class WindowsMidi {
  WindowsMidi({MidiProcessStarter? starter, String? executable})
    : starter = starter ?? startMidiProcess,
      executable =
          executable ??
          '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}adi2_midi.exe';
  final MidiProcessStarter starter;
  final String executable;
  static const timeout = Duration(seconds: 10);

  Future<Process> start(List<String> args) async {
    HostLog.write('MIDI-Hilfsprozess starten: ${args.first}');
    try {
      return await starter(executable, args);
    } catch (error) {
      HostLog.write('MIDI-Hilfsprozess Startfehler: $error');
      rethrow;
    }
  }

  Future<MidiHelperPorts> list() async {
    final process = await start(['list']);
    try {
      final result = await Future.wait<Object>([
        process.exitCode,
        process.stdout.transform(utf8.decoder).join(),
        process.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .join(),
      ]).timeout(timeout);
      if (result[0] != 0) throw StateError('list: ${result[2]}');
      return MidiHelperPorts.parse(result[1] as String);
    } catch (error) {
      HostLog.write('MIDI-Hilfsprozess list Fehler: $error');
      process.kill();
      rethrow;
    } finally {
      unawaited(process.stdin.close().catchError((Object _) {}));
    }
  }
}

class MidiHelperSession {
  MidiHelperSession(
    this.process, {
    required this.onPacket,
    required this.onLost,
  }) {
    _out = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _line,
          onError: (Object e) => _lost('stdout: $e'),
          onDone: () => _lost('stdout geschlossen'),
        );
    _err = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) => HostLog.write('MIDI-Hilfsprozess Fehler: $line'),
          onError: (Object e) => HostLog.write('MIDI stderr: $e'),
        );
    unawaited(
      process.exitCode.then((code) {
        HostLog.write('MIDI-Hilfsprozess Prozessende: $code');
        // Exit can precede buffered stdout. During the handshake, drain stdout
        // first so an error busy line is not overwritten with missing. EOF is
        // authoritative if the child exits without any handshake at all.
        if (_ready) _lost('Prozessende $code');
      }),
    );
    unawaited(process.stdin.done.catchError((Object e) => _lost('stdin: $e')));
  }

  final Process process;
  final void Function(Uint8List) onPacket;
  final void Function() onLost;
  final _opened = Completer<String>();
  late final StreamSubscription<String> _out, _err;
  bool _ready = false, _closing = false, _lostReported = false;
  Future<void>? _closed;
  Future<String> get opened => _opened.future.timeout(WindowsMidi.timeout);

  void _line(String line) {
    if (_closing) return;
    if (!_opened.isCompleted) {
      if (line.startsWith('ok ') && line.length > 3) {
        _ready = true;
        _opened.complete(line.substring(3));
      } else {
        final code = line.startsWith('error ')
            ? line.split(' ')[1]
            : 'protocol';
        HostLog.write('MIDI-Hilfsprozess Öffnen Fehler: $line');
        _opened.completeError(MidiHelperException(code));
      }
      return;
    }
    if (!_ready) return;
    if (line == 'lost' || line.startsWith('lost ')) {
      _lost(line);
      return;
    }
    try {
      onPacket(decodeMidiLine(line));
    } catch (error) {
      _lost('Protokollfehler: $error');
    }
  }

  void _lost(String reason) {
    if (_closing || _lostReported) return;
    _lostReported = true;
    HostLog.write('MIDI-Hilfsprozess lost: $reason');
    if (!_opened.isCompleted) {
      _opened.completeError(const MidiHelperException('missing'));
    }
    if (_ready) onLost();
    unawaited(close());
  }

  void send(Uint8List bytes) {
    if (!_ready || _closing || _lostReported) return;
    try {
      // Kein flush() je Nachricht: Ein laufendes flush bindet die Senke, und
      // jede weitere Nachricht wirft dann „StreamSink is bound to a stream“
      // (bei schnellen Änderungen mehrerer Clients). IOSink schreibt ohnehin
      // sofort beim nächsten Durchlauf der Ereignisschleife.
      process.stdin.writeln(encodeMidiLine(bytes));
    } catch (error) {
      _lost('send: $error');
    }
  }

  Future<void> close() => _closed ??= _close();

  Future<void> _close() async {
    _closing = true;
    if (!_opened.isCompleted) {
      _opened.completeError(const MidiHelperException('missing'));
    }
    try {
      // Include pipe closure in the deadline: a stuck child may not read stdin.
      await Future.wait([process.stdin.close(), process.exitCode])
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      process.kill();
    } finally {
      await _out.cancel();
      await _err.cancel();
    }
  }
}
