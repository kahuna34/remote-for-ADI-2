import 'dart:convert';

import 'package:adi2_host/host_player.dart';
import 'package:adi2_remote/host/host_player_protocol.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Native large artwork is requested for local surfaces only; phone cover stays small', () async {
    final calls = <bool>[];
    final small = [255, 216, 255, 1];
    final big = [255, 216, 255, ...List.filled(40000, 1)];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('adi2/host_player'), (
          call,
        ) async {
          calls.add((call.arguments as Map)['large'] as bool);
          return {
            'playing': true,
            'title': 'Track',
            'artwork': base64Encode(small),
            'artworkLarge': base64Encode(big),
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('adi2/host_player'),
            null,
          ),
    );
    final source = NativeHostPlayerSource();
    final phone = await source.read();
    expect(phone.art, small);
    expect(phone.artLarge, null);
    source.includeLargeArtwork = true;
    final local = await source.read();
    expect(local.artLarge, big);
    expect(encodeHostPlayerState(local)['artwork'], base64Encode(small));
    expect(
      encodeHostPlayerState(local, large: true)['artwork'],
      base64Encode(big),
    );
    expect(calls, [false, true]);
  });
}
