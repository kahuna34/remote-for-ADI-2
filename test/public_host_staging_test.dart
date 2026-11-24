import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/build_public_host.dart';

void main() {
  test('Public host staging excludes dependency EQ data without changing original app/Linux sources', () async {
    final source = await Directory.systemTemp.createTemp('adi2-public-source-');
    final stage = await Directory.systemTemp.createTemp('adi2-public-stage-');
    addTearDown(() async {
      await source.delete(recursive: true);
      await stage.delete(recursive: true);
    });
    const files = {
      'pubspec.yaml': 'name: adi2_remote\nflutter:\n  assets:\n    - assets/images/app_icon.png\n    - assets/eq_library/oratory1990.json\n',
      'pubspec.lock': '# unchanged lockfile\n',
      'lib/eq/eq_library_feature.dart': 'const bool eqLibraryAvailable = true;',
      'assets/eq_library/oratory1990.json': 'private presets',
      'assets/images/app_icon.png': 'icon',
      'host/pubspec.yaml': 'name: adi2_host\nversion: 1.2.3+8\n',
      'host/assets/fonts/Archivo.ttf': 'font',
      'host/lib/main.dart': 'main',
      'host/.dart_tool/package_config.json': 'stale',
      'host/macos/Flutter/ephemeral/generated': 'stale',
    };
    for (final entry in files.entries) {
      final file = File('${source.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    await preparePublicHost(source, stage);
    expect(await Directory('${stage.path}/assets/eq_library').exists(), false);
    expect(
      await File('${stage.path}/pubspec.yaml').readAsString(),
      isNot(contains('eq_library/')),
    );
    expect(
      await File('${stage.path}/lib/eq/eq_library_feature.dart').readAsString(),
      contains('= false;'),
    );
    expect(
      await File('${stage.path}/host/pubspec.yaml').readAsString(),
      files['host/pubspec.yaml'],
    );
    expect(
      await FileSystemEntity.type(
        '${stage.path}/host/assets/fonts/Archivo.ttf',
        followLinks: false,
      ),
      FileSystemEntityType.file,
    );
    expect(await Directory('${stage.path}/host/.dart_tool').exists(), false);
    expect(
      await Directory('${stage.path}/host/macos/Flutter/ephemeral').exists(),
      false,
    );
    for (final entry in files.entries) {
      expect(
        await File('${source.path}/${entry.key}').readAsString(),
        entry.value,
      );
    }
  });
}
