import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adi2_remote/desktop/desktop_windows.dart';

abstract class AuxiliaryProcess {
  Future<void> get ready;
  Future<int> get exitCode;
  Future<void> command(String command);
  bool kill(ProcessSignal signal);
}

typedef AuxiliaryProcessStarter = Future<AuxiliaryProcess> Function(
  String executable,
  List<String> arguments,
);

class _NativeProcess implements AuxiliaryProcess {
  _NativeProcess(this.process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line == 'adi2-window-v1 ready' && !_ready.isCompleted) {
              _ready.complete();
            }
          },
          onError: (Object _) {},
          onDone: () {
            if (!_ready.isCompleted) {
              _ready.completeError(StateError('Window exited before ready'));
            }
          },
        );
    // Drain both pipes; a full log pipe must never stall a child.
    process.stderr.listen((_) {}, onError: (Object _) {});
  }
  final Process process;
  final _ready = Completer<void>();
  @override
  Future<void> get ready => _ready.future;
  @override
  Future<int> get exitCode => process.exitCode;
  @override
  Future<void> command(String command) async {
    process.stdin.writeln('adi2-window-v1 $command');
    await process.stdin.flush();
  }

  @override
  bool kill(ProcessSignal signal) => process.kill(signal);
}

/// Each window gets its own engine AND process (independent OpenGL context).
class DesktopAuxiliaryWindows extends DesktopWindows {
  DesktopAuxiliaryWindows({
    String? executable,
    String? appImage,
    AuxiliaryProcessStarter? start,
    this.startupTimeout = const Duration(seconds: 15),
    this.closeTimeout = const Duration(milliseconds: 600),
  }) : executable =
           (appImage ??
                       (Platform.isLinux
                           ? Platform.environment['APPIMAGE']
                           : null))
                   ?.isNotEmpty ==
               true
           ? (appImage ??
                 (Platform.isLinux ? Platform.environment['APPIMAGE'] : null))!
           : executable ?? Platform.resolvedExecutable,
       _start = start ?? _startNative;
  final String executable;
  final AuxiliaryProcessStarter _start;
  final Duration startupTimeout, closeTimeout;
  final _children = <AuxiliaryWindow, AuxiliaryProcess>{};
  final _opening = <AuxiliaryWindow, Future<void>>{};
  bool _closing = false;
  @override
  bool isOpen(AuxiliaryWindow kind) => _children.containsKey(kind);

  void _remove(AuxiliaryWindow kind, AuxiliaryProcess child) {
    if (identical(_children[kind], child)) {
      _children.remove(kind);
      notifyListeners();
    }
  }

  static Future<AuxiliaryProcess> _startNative(
    String executable,
    List<String> args,
  ) async => _NativeProcess(await Process.start(executable, args));

  @override
  Future<void> open(AuxiliaryWindow kind) {
    if (_closing) return Future.value();
    return _opening.putIfAbsent(
      kind,
      () => _open(kind).whenComplete(() {
        _opening.remove(kind);
      }),
    );
  }

  Future<void> _open(AuxiliaryWindow kind) async {
    var child = _children[kind];
    if (child == null) {
      child = await _start(executable, ['--window=${kind.name}']);
      // closeAll may have run while Process.start was still pending.
      if (_closing) {
        unawaited(child.ready.catchError((Object _) {}));
        child.kill(ProcessSignal.sigkill);
        return;
      }
      _children[kind] = child;
      notifyListeners();
      final tracked = child;
      unawaited(
        child.exitCode.then((_) {
          _remove(kind, tracked);
        }),
      );
      try {
        await child.ready.timeout(startupTimeout);
      } catch (_) {
        child.kill(ProcessSignal.sigkill);
        _remove(kind, child);
        throw StateError('Auxiliary window did not start');
      }
    }
    if (_closing) {
      child.kill(ProcessSignal.sigkill);
      return;
    }
    try {
      await child.command('present').timeout(const Duration(seconds: 1));
    } catch (_) {
      // Do not create an untracked duplicate if a control pipe fails.
      child.kill(ProcessSignal.sigkill);
      _remove(kind, child);
      throw StateError('Auxiliary window control unavailable');
    }
  }

  Future<void> refreshConnection() =>
      _broadcast('connection', stopOnFailure: true);
  Future<void> refreshPreferences() => _broadcast('preferences');

  Future<void> _broadcast(String command, {bool stopOnFailure = false}) async {
    await Future.wait(
      _children.entries.toList().map((entry) async {
        final child = entry.value;
        try {
          await child.command(command).timeout(const Duration(seconds: 1));
        } catch (_) {
          if (stopOnFailure) {
            // A window that missed the route change must not keep controlling
            // the previous host while the main surface shows another one.
            child.kill(ProcessSignal.sigkill);
            _remove(entry.key, child);
          }
        }
      }),
    );
  }

  Future<void> _stop(AuxiliaryProcess child) async {
    try {
      await child.command('close').timeout(const Duration(milliseconds: 100));
      await child.exitCode.timeout(closeTimeout);
      return;
    } catch (_) {}
    child.kill(ProcessSignal.sigterm);
    try {
      await child.exitCode.timeout(const Duration(milliseconds: 200));
    } catch (_) {
      child.kill(ProcessSignal.sigkill);
    }
  }

  Future<void> closeAll() async {
    _closing = true;
    // Do not wait for startup readiness: even hung children must be killed
    // before the main process's three-second exit deadline.
    await Future.wait(_children.values.toList().map(_stop));
  }
}

/// Also covers a broken host connection when a pipe remains open unexpectedly.
class HostConnectionWatchdog {
  HostConnectionWatchdog({
    required bool Function() connected,
    required void Function() onLost,
    Duration grace = const Duration(seconds: 20),
  }) {
    var missing = Duration.zero;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      missing = connected()
          ? Duration.zero
          : missing + const Duration(seconds: 1);
      if (missing >= grace) {
        _timer.cancel();
        onLost();
      }
    });
  }
  late final Timer _timer;
  void dispose() => _timer.cancel();
}
