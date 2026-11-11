import 'package:adi2_remote/media/now_playing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Gleiche Cover-Bytes bleiben identisch, späte und entfernte Cover kommen an', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('adi2/media/events'),
      (_) async => null,
    );
    final np = NowPlaying();
    addTearDown(() {
      np.dispose();
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(
        const MethodChannel('adi2/media/events'),
        null,
      );
    });
    await np.start();
    Future<void> send(
      String title,
      Uint8List? art, {
      bool playing = false,
    }) async {
      await messenger.handlePlatformMessage(
        'adi2/media/events',
        codec.encodeSuccessEnvelope({
          'access': true,
          'title': title,
          'artist': 'Artist',
          'art': art,
          'playing': playing,
        }),
        (_) {},
      );
    }

    await send('A', null);
    expect(np.info!.art, isNull);
    await send('A', Uint8List.fromList([1, 2, 3]));
    final first = np.info!.art;
    await send('A', Uint8List.fromList([1, 2, 3]), playing: true);
    expect(identical(np.info!.art, first), isTrue);
    expect(np.info!.playing, isTrue);
    await send('A', Uint8List.fromList([4, 5]));
    expect(np.info!.art, [4, 5]);
    await send('B', null);
    expect(np.info!.art, isNull);
  });

  test('Freigabe wird nach Rückkehr neu gelesen und Sperre entfernt', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('adi2/media');
    var granted = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'hasAccess') return granted;
      if (call.method == 'restricted') return true;
      return null;
    });
    final np = NowPlaying()..supported = true;
    addTearDown(() {
      np.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });
    await np.refreshAccess();
    expect(np.access, false);
    expect(np.restricted, true);
    granted = true;
    await np.refreshAccess();
    expect(np.access, true);
    expect(np.restricted, false);
  });

  test(
    'Gesperrter Zugriff wird erkannt und App-Infos sind erreichbar',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      SharedPreferences.setMockInitialValues({});
      const codec = StandardMethodCodec();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      var restricted = true;
      messenger.setMockMethodCallHandler(
        const MethodChannel('adi2/media/events'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(const MethodChannel('adi2/media'), (
        call,
      ) async {
        calls.add(call.method);
        return call.method == 'restricted' ? restricted : null;
      });
      final np = NowPlaying();
      addTearDown(() {
        np.dispose();
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(
          const MethodChannel('adi2/media/events'),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('adi2/media'),
          null,
        );
      });
      await np.start();
      Future<void> send(bool access) async {
        await messenger.handlePlatformMessage(
          'adi2/media/events',
          codec.encodeSuccessEnvelope({'access': access}),
          (_) {},
        );
        await Future<void>.delayed(Duration.zero);
      }

      await send(false);
      expect(np.restricted, isTrue);
      await np.openAppDetails();
      expect(calls, contains('openAppDetails'));
      restricted = false;
      await send(false);
      expect(np.restricted, isFalse);
      calls.clear();
      await send(true);
      expect(calls, isNot(contains('restricted')));
    },
  );
}
