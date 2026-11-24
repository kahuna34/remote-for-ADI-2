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
    this.appImage,
    this.configHome,
    HostProcessRunner? run,
  }) : run = run ?? _run;
  final String platform, executable, home;
  final String? appImage, configHome;
  final HostProcessRunner run;
  static Future<ProcessResult> _run(String command, List<String> args) =>
      Process.run(command, args);
  static const registry = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const label = 'de.markus.adi2Host';
  String get agentPath => '$home/Library/LaunchAgents/$label.plist';
  String get desktopPath =>
      '${configHome?.startsWith('/') == true ? configHome : '$home/.config'}/autostart/remote-for-adi2-host.desktop';

  /// Desktop Entry Exec escaping is not shell escaping. Percent is a field code.
  static String linuxDesktopEntry(String executable) {
    if (executable.contains('\n') || executable.contains('\r')) {
      throw const FormatException('Invalid executable path');
    }
    final escaped = executable
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('`', '\\`')
        .replaceAll(r'$', r'\$')
        .replaceAll('%', '%%');
    // The general Desktop Entry string parser consumes one backslash layer.
    final exec = escaped.replaceAll('\\', '\\\\');
    return '[Desktop Entry]\nType=Application\nName=Remote for ADI-2\nExec="$exec" --autostart\nTerminal=false\nX-GNOME-Autostart-enabled=true\n';
  }

  /// Übernimmt bei aktivem Windows-Autostart den aktuellen Installationspfad.
  /// Ein bewusst ausgeschalteter Autostart bleibt ausgeschaltet.
  Future<bool> refreshEnabledPath() async {
    final active = await enabled();
    if ((platform == 'windows' || platform == 'linux' || platform == 'macos') &&
        active) {
      await setEnabled(true);
    }
    return active;
  }

  Future<bool> enabled() async {
    if (platform == 'windows') {
      final result = await run('reg.exe', [
        'query',
        registry,
        '/v',
        'Remote for ADI-2 Host',
      ]);
      return result.exitCode == 0;
    }
    return File(platform == 'linux' ? desktopPath : agentPath).exists();
  }

  Future<void> setEnabled(bool value) async {
    if (platform == 'linux') {
      final file = File(desktopPath);
      if (!value) {
        if (await file.exists()) await file.delete();
        return;
      }
      final path = appImage?.startsWith('/') == true ? appImage! : executable;
      await file.parent.create(recursive: true);
      final temporary = File('$desktopPath.tmp');
      await temporary.writeAsString(linuxDesktopEntry(path), flush: true);
      await temporary.rename(desktopPath);
      return;
    }
    if (platform == 'windows') {
      final result = await run(
        'reg.exe',
        value
            ? [
                'add',
                registry,
                '/v',
                'Remote for ADI-2 Host',
                '/t',
                'REG_SZ',
                '/d',
                '"$executable" --autostart',
                '/f',
              ]
            : ['delete', registry, '/v', 'Remote for ADI-2 Host', '/f'],
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
<key>ProgramArguments</key><array><string>$escaped</string><string>--autostart</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
''';
    await file.parent.create(recursive: true);
    final temporary = File('$agentPath.tmp');
    await temporary.writeAsString(plist, flush: true);
    await temporary.rename(agentPath);
  }
}
