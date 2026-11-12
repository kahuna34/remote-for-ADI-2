import 'dart:io';

/// Kleines Protokoll für die Fehlersuche (Start, Erkennung, MIDI-Hilfsprozess).
/// Windows: %LOCALAPPDATA%\Remote for ADI-2 Host\host.log (auch vom Runner
/// beschrieben), macOS: ~/Library/Logs/Remote for ADI-2 Host.log.
/// Enthält keine Kopplungsschlüssel; Fehler beim Schreiben werden ignoriert.
class HostLog {
  static const maxBytes = 256 * 1024;
  static File? _file;
  static bool _resolved = false;

  static File? get file {
    if (_resolved) return _file;
    _resolved = true;
    try {
      if (Platform.isWindows) {
        final base = Platform.environment['LOCALAPPDATA'];
        if (base != null) {
          final dir = Directory('$base\\Remote for ADI-2 Host')
            ..createSync(recursive: true);
          _file = File('${dir.path}\\host.log');
        }
      } else if (Platform.isMacOS) {
        final home = Platform.environment['HOME'];
        if (home != null) {
          final dir = Directory('$home/Library/Logs')
            ..createSync(recursive: true);
          _file = File('${dir.path}/Remote for ADI-2 Host.log');
        }
      }
    } catch (_) {
      _file = null;
    }
    return _file;
  }

  static void write(String message) {
    try {
      final f = file;
      if (f == null) return;
      if (f.existsSync() && f.lengthSync() > maxBytes) {
        f.writeAsStringSync('');
      }
      f.writeAsStringSync(
        '${DateTime.now().toIso8601String()} [$pid] $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }
}
