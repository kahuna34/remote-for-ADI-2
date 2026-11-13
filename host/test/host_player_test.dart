import 'dart:typed_data';

import 'package:adi2_host/host_player.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:flutter_test/flutter_test.dart';

class _Source implements HostPlayerSource {
  NowPlayingInfo info = NowPlayingInfo(
    title: 'One',
    app: 'Music',
    art: Uint8List.fromList([255, 216, 255, 217]),
  );
  int reads = 0;
  bool fail = false;
  final commands = <String>[];
  @override
  Future<NowPlayingInfo> read() async {
    reads++;
    if (fail) throw StateError('permission denied');
    return info;
  }

  @override
  Future<void> command(String command) async {
    commands.add(command);
  }
}

void main() {
  test(
    'poll only on demand, per-client artwork changes and unsubscribe',
    () async {
      final source = _Source(),
          a = <Map<String, dynamic>>[],
          b = <Map<String, dynamic>>[];
      final player = HostPlayer(source: source);
      addTearDown(player.dispose);
      await player.refresh();
      expect(source.reads, 0);
      player.subscribe('a', (_, state) => a.add(state));
      await Future<void>.delayed(Duration.zero);
      expect(a.single['artwork'], isA<String>());
      await player.refresh();
      expect(a, hasLength(1));
      source.info = NowPlayingInfo(
        title: 'Two',
        playing: true,
        art: source.info.art,
      );
      await player.refresh();
      expect(a.last.containsKey('artwork'), isFalse);
      player.subscribe('b', (_, state) => b.add(state));
      await Future<void>.delayed(Duration.zero);
      expect(b.single['artwork'], isA<String>());
      expect(a, hasLength(2));
      source.info = const NowPlayingInfo(title: 'Three');
      await player.refresh();
      expect(a.last.containsKey('artwork'), isTrue);
      expect(a.last['artwork'], isNull);
      player.unsubscribe('a');
      player.unsubscribe('b');
      final reads = source.reads;
      await player.refresh();
      expect(source.reads, reads);
    },
  );
  test('only subscribed clients control; failures clear stale state without throwing', () async {
    final source = _Source(), frames = <Map<String, dynamic>>[];
    final player = HostPlayer(source: source);
    addTearDown(player.dispose);
    player.command('unpaired', 'play');
    player.subscribe('a', (_, state) => frames.add(state));
    await Future<void>.delayed(Duration.zero);
    for (final command in [
      'play',
      'pause',
      'toggle',
      'next',
      'previous',
      'invalid',
    ]) {
      player.command('a', command);
    }
    await Future<void>.delayed(Duration.zero);
    expect(source.commands, ['play', 'pause', 'toggle', 'next', 'previous']);
    source.fail = true;
    await player.refresh();
    expect(frames.last['title'], '');
    expect(frames.last['playing'], false);
    expect(frames.last['artwork'], isNull);
  });
}
