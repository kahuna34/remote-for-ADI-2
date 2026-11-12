import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

class FakeMidiProcess extends Fake implements Process {
  FakeMidiProcess({this.exitOnStdinClose = true}) {
    input.stream.listen(
      (bytes) => written.addAll(bytes),
      onDone: () {
        stdinClosed = true;
        if (exitOnStdinClose) finish();
      },
    );
  }
  final bool exitOnStdinClose;
  final input = StreamController<List<int>>();
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final finished = Completer<int>();
  final written = <int>[];
  bool stdinClosed = false, killed = false;
  @override
  late final IOSink stdin = IOSink(input.sink);
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => finished.future;
  @override
  int get pid => 42;
  void line(String line) => output.add(utf8.encode('$line\n'));
  void finish([int code = 0]) {
    if (finished.isCompleted) return;
    finished.complete(code);
    unawaited(output.close());
    unawaited(errors.close());
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    finish(-1);
    return true;
  }
}

class FakeMidiProcesses {
  List<String> ports = ['ADI-2 DAC Midi Port 1'];
  String response = 'ok ADI-2 DAC Midi Port 1';
  final calls = <List<String>>[];
  final sessions = <FakeMidiProcess>[];
  bool exitOnStdinClose = true;
  Future<Process> start(String executable, List<String> args) async {
    calls.add([executable, ...args]);
    final process = FakeMidiProcess(exitOnStdinClose: exitOnStdinClose);
    if (args.first == 'list') {
      process.line(
        jsonEncode({
          for (final direction in ['inputs', 'outputs'])
            direction: [
              for (var i = 0; i < ports.length; i++)
                {'id': i, 'name': ports[i]},
            ],
        }),
      );
      process.finish();
    } else {
      sessions.add(process);
      process.line(response);
      if (response.startsWith('error')) process.finish(1);
    }
    return process;
  }
}
