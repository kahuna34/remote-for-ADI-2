import 'dart:io';

import 'package:adi2_host/autostart.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Aktiver Windows-Autostart übernimmt beim Start den aktuellen Pfad',
    () async {
      final calls = <(String, List<String>)>[];
      final autostart = HostAutostart(
        platform: 'windows',
        executable: r'C:\Users\Test\AppData\Local\Programs\Remote for ADI-2 Host\adi2_host.exe',
        home: '',
        run: (command, args) async {
          calls.add((command, args));
          return ProcessResult(
            1,
            0,
            'Remote for ADI-2 Host REG_SZ "C:\\Portable\\adi2_host.exe"',
            '',
          );
        },
      );
      expect(await autostart.refreshEnabledPath(), isTrue);
      expect(calls.map((call) => call.$1), everyElement('reg.exe'));
      expect(calls.map((call) => call.$2.first), ['query', 'add']);
      expect(
        calls.last.$2,
        containsAllInOrder([
          HostAutostart.registry,
          '/v',
          'Remote for ADI-2 Host',
          '/t',
          'REG_SZ',
          '/d',
          '"${autostart.executable}"',
          '/f',
        ]),
      );
    },
  );

  test(
    'Deaktivierter Windows-Autostart wird beim Aktualisieren nicht angelegt',
    () async {
      final calls = <List<String>>[];
      final autostart = HostAutostart(
        platform: 'windows',
        executable: r'C:\Installed\adi2_host.exe',
        home: '',
        run: (_, args) async {
          calls.add(args);
          return ProcessResult(1, 1, '', 'not found');
        },
      );
      expect(await autostart.refreshEnabledPath(), isFalse);
      expect(calls.single.first, 'query');
    },
  );

  test(
    'Fehler beim Aktualisieren des Windows-Autostarts wird weitergegeben',
    () async {
      final autostart = HostAutostart(
        platform: 'windows',
        executable: r'C:\Installed\adi2_host.exe',
        home: '',
        run: (_, args) async =>
            ProcessResult(1, args.first == 'query' ? 0 : 5, '', 'denied'),
      );
      await expectLater(
        autostart.refreshEnabledPath(),
        throwsA(isA<ProcessException>()),
      );
    },
  );

  test('Windows benutzt ausschließlich HKCU und getrennte Argumente', () async {
    final calls = <(String, List<String>)>[];
    final autostart = HostAutostart(
      platform: 'windows',
      executable: r'C:\My App\Host.exe',
      home: '',
      run: (command, args) async {
        calls.add((command, args));
        return ProcessResult(1, 0, '', '');
      },
    );
    await autostart.setEnabled(true);
    expect(calls.single.$1, 'reg.exe');
    expect(calls.single.$2, [
      'add',
      HostAutostart.registry,
      '/v',
      'Remote for ADI-2 Host',
      '/t',
      'REG_SZ',
      '/d',
      '"C:\\My App\\Host.exe"',
      '/f',
    ]);
    await autostart.setEnabled(false);
    expect(calls.last.$2.first, 'delete');
    expect(await autostart.enabled(), isTrue);
    expect(calls.last.$2.first, 'query');
  });

  test('Windows-Prozessfehler wird zurückgegeben', () async {
    final autostart = HostAutostart(
      platform: 'windows',
      executable: 'host.exe',
      home: '',
      run: (_, _) async => ProcessResult(1, 5, '', 'denied'),
    );
    await expectLater(
      autostart.setEnabled(true),
      throwsA(isA<ProcessException>()),
    );
    await expectLater(
      autostart.setEnabled(false),
      throwsA(isA<ProcessException>()),
    );
    expect(await autostart.enabled(), isFalse);
  });

  test('Windows: Startfehler von reg.exe wird weitergegeben', () async {
    final autostart = HostAutostart(
      platform: 'windows',
      executable: r'C:\Example App\Host.exe',
      home: '',
      run: (_, _) async => throw const ProcessException('reg.exe', []),
    );
    await expectLater(
      autostart.setEnabled(true),
      throwsA(isA<ProcessException>()),
    );
    await expectLater(autostart.enabled(), throwsA(isA<ProcessException>()));
  });

  test(
    'macOS schreibt und entfernt LaunchAgent nur im Testverzeichnis',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'adi2-autostart-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var calls = 0;
      final autostart = HostAutostart(
        platform: 'macos',
        executable: '/Applications/A & B/Host.app/Contents/MacOS/Host',
        home: directory.path,
        run: (_, _) async {
          calls++;
          return ProcessResult(1, 0, '', '');
        },
      );
      expect(await autostart.enabled(), isFalse);
      await autostart.setEnabled(true);
      final contents = await File(autostart.agentPath).readAsString();
      expect(contents, contains('A &amp; B'));
      expect(contents, contains('<key>RunAtLoad</key><true/>'));
      expect(await autostart.enabled(), isTrue);
      await autostart.setEnabled(false);
      expect(await autostart.enabled(), isFalse);
      expect(calls, 0);
    },
  );
}
