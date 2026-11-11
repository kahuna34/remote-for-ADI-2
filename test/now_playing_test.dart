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
}
