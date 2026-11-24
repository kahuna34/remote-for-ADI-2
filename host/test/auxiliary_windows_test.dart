import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:adi2_host/auxiliary_processes.dart';
import 'package:adi2_host/auxiliary_windows.dart' show restoreAuxiliaryBounds;
import 'package:adi2_host/window_preferences.dart';
import 'package:adi2_remote/desktop/desktop_windows.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class FakeProcess implements AuxiliaryProcess {
  final started = Completer<void>();
  final exited = Completer<int>();
  final commands = <String>[];
  final signals = <ProcessSignal>[];
  bool closeExits = true;
  bool killExits = true;
  bool failCommand = false;
  @override
  Future<void> get ready => started.future;
  @override
  Future<int> get exitCode => exited.future;
  @override
  Future<void> command(String command) async {
    if (failCommand) throw StateError('broken pipe');
    commands.add(command);
    if (command == 'close' && closeExits && !exited.isCompleted) {
      exited.complete(0);
    }
  }

  @override
  bool kill(ProcessSignal signal) {
    signals.add(signal);
    if (killExits && !exited.isCompleted) exited.complete(-1);
    return true;
  }
}

void main() {
  test('Analyzer open/exit notifications and live preference refresh reach the main surface', () async {
    final child = FakeProcess()..started.complete();
    final windows = DesktopAuxiliaryWindows(
      appImage: '',
      start: (_, args) async => child,
    );
    final states = <bool>[];
    windows.addListener(
      () => states.add(windows.isOpen(AuxiliaryWindow.analyzer)),
    );
    await windows.open(AuxiliaryWindow.analyzer);
    await windows.refreshPreferences();
    await windows.refreshConnection();
    expect(child.commands, ['present', 'preferences', 'connection']);
    child.exited.complete(0);
    await Future<void>.delayed(Duration.zero);
    expect(states, [true, false]);
    await windows.closeAll();
    windows.dispose();
  });

  test(
    'One process per kind, concurrent opens focus once, exit permits reopening',
    () async {
      final processes = <FakeProcess>[];
      final launches = <List<String>>[];
      final windows = DesktopAuxiliaryWindows(
        executable: '/app/bin/adi2',
        appImage: '',
        start: (executable, args) async {
          expect(executable, '/app/bin/adi2');
          launches.add(args);
          final child = FakeProcess()..started.complete();
          processes.add(child);
          return child;
        },
      );
      await Future.wait(
        List.generate(4, (_) => windows.open(AuxiliaryWindow.analyzer)),
      );
      expect(processes.length, 1);
      expect(processes.single.commands, ['present']);
      await windows.open(AuxiliaryWindow.analyzer);
      expect(processes.single.commands, ['present', 'present']);
      await windows.open(AuxiliaryWindow.player);
      expect(launches, [
        ['--window=analyzer'],
        ['--window=player'],
      ]);
      processes.first.exited.complete(0);
      await Future<void>.delayed(Duration.zero);
      await windows.open(AuxiliaryWindow.analyzer);
      expect(processes.length, 3);
      await windows.closeAll();
      expect(processes[1].commands.last, 'close');
      expect(processes[2].commands.last, 'close');
      await windows.open(AuxiliaryWindow.player);
      expect(processes.length, 3);
    },
  );

  test(
    'AppImage is launched rather than its temporary mounted binary',
    () async {
      final windows = DesktopAuxiliaryWindows(
        executable: '/tmp/mount/adi2',
        appImage: '/home/user/Remote for ADI-2.AppImage',
        start: (exe, args) async {
          expect(exe, '/home/user/Remote for ADI-2.AppImage');
          expect(args, ['--window=player']);
          return FakeProcess()..started.complete();
        },
      );
      await windows.open(AuxiliaryWindow.player);
      await windows.closeAll();
    },
  );

  test('Failed start can be retried', () async {
    var attempts = 0;
    final windows = DesktopAuxiliaryWindows(
      start: (_, _) async {
        if (++attempts == 1) throw StateError('start failed');
        return FakeProcess()..started.complete();
      },
    );
    await expectLater(windows.open(AuxiliaryWindow.player), throwsStateError);
    await windows.open(AuxiliaryWindow.player);
    expect(attempts, 2);
    await windows.closeAll();
  });

  test('Startup timeout kills the child and allows another launch', () async {
    final children = <FakeProcess>[];
    final windows = DesktopAuxiliaryWindows(
      startupTimeout: const Duration(milliseconds: 5),
      start: (_, _) async {
        final p = FakeProcess();
        children.add(p);
        return p;
      },
    );
    await expectLater(windows.open(AuxiliaryWindow.analyzer), throwsStateError);
    expect(children.single.signals, [ProcessSignal.sigkill]);
    await expectLater(windows.open(AuxiliaryWindow.analyzer), throwsStateError);
    expect(children.length, 2);
    await windows.closeAll();
  });

  test(
    'Shutdown kills an unready child without waiting for startup timeout',
    () async {
      final child = FakeProcess()
        ..closeExits = false
        ..killExits = false;
      final windows = DesktopAuxiliaryWindows(
        closeTimeout: Duration.zero,
        start: (_, _) async => child,
      );
      final opening = windows.open(AuxiliaryWindow.player);
      await Future<void>.delayed(Duration.zero);
      await windows.closeAll();
      expect(child.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
      child.started.complete();
      await opening;
    },
  );

  test('Shutdown racing Process.start kills the late child', () async {
    final spawning = Completer<AuxiliaryProcess>();
    final windows = DesktopAuxiliaryWindows(start: (_, _) => spawning.future);
    final opening = windows.open(AuxiliaryWindow.player);
    await windows.closeAll();
    final child = FakeProcess()..started.complete();
    spawning.complete(child);
    await opening;
    expect(child.signals, [ProcessSignal.sigkill]);
    expect(child.commands, isEmpty);
  });

  test(
    'Broken control pipe kills tracked process and permits reopening',
    () async {
      final children = <FakeProcess>[];
      final windows = DesktopAuxiliaryWindows(
        start: (_, _) async {
          final child = FakeProcess()..started.complete();
          children.add(child);
          return child;
        },
      );
      await windows.open(AuxiliaryWindow.player);
      children.first.failCommand = true;
      await expectLater(windows.open(AuxiliaryWindow.player), throwsStateError);
      expect(children.first.signals, [ProcessSignal.sigkill]);
      await windows.open(AuxiliaryWindow.player);
      expect(children.length, 2);
      await windows.closeAll();
    },
  );

  test('A child that cannot receive a route change cannot keep controlling the old host', () async {
    final child = FakeProcess()..started.complete();
    final windows = DesktopAuxiliaryWindows(start: (_, _) async => child);
    await windows.open(AuxiliaryWindow.player);
    child.failCommand = true;
    await windows.refreshConnection();
    expect(child.signals, [ProcessSignal.sigkill]);
    expect(windows.isOpen(AuxiliaryWindow.player), false);
    await windows.closeAll();
    windows.dispose();
  });

  test('Host watchdog tolerates reconnects and exits after sustained loss', () {
    fakeAsync((async) {
      var connected = false;
      var lost = 0;
      final watchdog = HostConnectionWatchdog(
        connected: () => connected,
        onLost: () => lost++,
      );
      async.elapse(const Duration(seconds: 19));
      expect(lost, 0);
      connected = true;
      async.elapse(const Duration(seconds: 1));
      connected = false;
      async.elapse(const Duration(seconds: 19));
      expect(lost, 0);
      async.elapse(const Duration(seconds: 1));
      expect(lost, 1);
      async.elapse(const Duration(seconds: 30));
      expect(lost, 1);
      watchdog.dispose();
    });
  });

  test('Geometry stays in the available monitor work area', () {
    final areas = [const Rect.fromLTWH(0, 0, 1920, 1080)];
    expect(
      restoreAuxiliaryBounds([4000, 3000, 2200, 1400], areas),
      areas.first,
    );
    expect(
      restoreAuxiliaryBounds([50, 60, 900, 600], areas),
      const Rect.fromLTWH(50, 60, 900, 600),
    );
    expect(restoreAuxiliaryBounds(null, areas), isNull);
  });

  test('Preference RPC isolates each window and preserves pairing and main settings', () async {
    final store = InMemorySharedPreferencesStore.withData({
      'flutter.linux_host.paired_devices': 'private',
      'flutter.analyzer_bars': true,
    });
    final service = WindowPreferenceService(store, platform: 'linux');
    WindowPreferences client(AuxiliaryWindow kind) => WindowPreferences(
      kind: kind,
      runtimeDirectory: 'unused',
      request: (data) => service.handle(kind, data),
    );
    final analyzer = client(AuxiliaryWindow.analyzer);
    final player = client(AuxiliaryWindow.player);
    await Future.wait([
      analyzer.setValue('Bool', 'flutter.analyzer_bars', false),
      player.setValue(
        'String',
        'flutter.linux_host.player_window_bounds',
        'player',
      ),
      store.setValue('String', 'flutter.linux_host.window_bounds', 'main'),
    ]);
    await analyzer.setValue('StringList', 'flutter.eq_favorites', ['a', 'b']);
    final all = await store.getAll();
    expect(all['flutter.analyzer_bars'], false);
    expect(all['flutter.linux_host.paired_devices'], 'private');
    expect(all['flutter.linux_host.window_bounds'], 'main');
    expect(all['flutter.linux_host.player_window_bounds'], 'player');
    expect((await analyzer.getAll())['flutter.analyzer_bars'], false);
    expect((await player.getAll())['flutter.analyzer_bars'], false);
    expect(
      (await analyzer.getAll()).containsKey(
        'flutter.linux_host.paired_devices',
      ),
      false,
    );
    expect(
      (await analyzer.getAll()).containsKey(
        'flutter.linux_host.player_window_bounds',
      ),
      false,
    );
    await expectLater(
      analyzer.setValue(
        'String',
        'flutter.linux_host.player_window_bounds',
        'bad',
      ),
      throwsFormatException,
    );
    await expectLater(
      analyzer.remove('flutter.linux_host.paired_devices'),
      throwsFormatException,
    );
    await expectLater(
      analyzer.setValue('String', 'bad', 'bad'),
      throwsFormatException,
    );
    // Player mutations cannot change the shared analyzer settings.
    await player.setValue('Bool', 'flutter.analyzer_bars', true);
    expect((await store.getAll())['flutter.analyzer_bars'], false);
    expect((await player.getAll())['flutter.analyzer_bars'], true);
    expect(await analyzer.clear(), false);
    await analyzer.remove('flutter.eq_favorites');
    expect(
      (await analyzer.getAll()).containsKey('flutter.eq_favorites'),
      false,
    );
  });
}
