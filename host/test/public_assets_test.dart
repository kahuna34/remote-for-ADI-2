import 'dart:io';

import 'package:adi2_remote/eq/eq_preset_library.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Host assets are real files; a missing optional EQ bundle loads empty',
    () async {
      for (final path in [
        'assets/fonts/Archivo.ttf',
        'assets/fonts/ArchivoNarrow.ttf',
        'assets/images/app_icon.png',
      ]) {
        expect(
          await FileSystemEntity.type(path, followLinks: false),
          FileSystemEntityType.file,
        );
        expect(await File(path).length(), greaterThan(0));
      }
      // Simulate a public build where the optional root asset is absent.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', (_) async => null);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMessageHandler('flutter/assets', null),
      );
      expect(await EqPresetLibrary.load(), isEmpty);
    },
  );
}
