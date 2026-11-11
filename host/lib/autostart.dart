import 'dart:convert';
import 'dart:io';

typedef HostProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class HostAutostart {
  HostAutostart({
    required this.platform,
    required this.executable,
    required this.home,
    HostProcessRunner? run,
  }) : run = run ?? _run;
  final String platform, executable, home;
  final HostProcessRunner run;
  static Future<ProcessResult> _run(String command, List<String> args) =>
      Process.run(command, args);
  static const registry = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const label = 'de.markus.adi2Host';
  String get agentPath => '$home/Library/LaunchAgents/$label.plist';

  Future<bool> enabled() async {
    if (platform == 'windows') {
      final result = await run('reg.exe', [
        'query',
        registry,
        '/v',
        'Adi2RemoteHost',
      ]);
      return result.exitCode == 0;
    }
    return File(agentPath).exists();
  }

  Future<void> setEnabled(bool value) async {
    if (platform == 'windows') {
      final result = await run(
        'reg.exe',
        value
            ? [
                'add',
                registry,
                '/v',
                'Adi2RemoteHost',
                '/t',
                'REG_SZ',
                '/d',
                '"$executable"',
                '/f',
              ]
            : ['delete', registry, '/v', 'Adi2RemoteHost', '/f'],
      );
      if (result.exitCode != 0) {
        throw ProcessException(
          'reg.exe',
          [],
          '${result.stderr}',
          result.exitCode,
        );
      }
      return;
    }
    if (platform != 'macos') throw UnsupportedError(platform);
    final file = File(agentPath);
    if (!value) {
      if (await file.exists()) await file.delete();
      return;
    }
    // RunAtLoad startet beim nächsten Anmelden. Der aktuelle Host läuft schon.
    final escaped = const HtmlEscape(HtmlEscapeMode.element)
        .convert(executable);
    final plist =
        '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$escaped</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
''';
    await file.parent.create(recursive: true);
    final temporary = File('$agentPath.tmp');
    await temporary.writeAsString(plist, flush: true);
    await temporary.rename(agentPath);
  }
}
