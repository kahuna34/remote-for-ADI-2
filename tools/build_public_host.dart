// Public macOS/Windows builds use an isolated source tree. Flutter also bundles
// assets from path dependencies, so omitting EQ assets in host/pubspec is not
// sufficient. Never edit the developer's root pubspec or library feature flag.
import 'dart:io';

const _excluded = {
  '.git',
  '.dart_tool',
  'build',
  'ephemeral',
  'Pods',
  '.symlinks',
  'eq_library',
};

Future<void> _copyTree(Directory source, Directory target) async {
  await target.create(recursive: true);
  await for (final entry in source.list(followLinks: false)) {
    final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (_excluded.contains(name)) continue;
    final path = '${target.path}/$name';
    if (entry is Directory) {
      await _copyTree(entry, Directory(path));
    } else if (entry is File) {
      await entry.copy(path);
    } else {
      throw StateError('Public source must contain real files: ${entry.path}');
    }
  }
}

Future<void> preparePublicHost(Directory source, Directory target) async {
  await target.create(recursive: true);
  for (final name in ['lib', 'assets', 'host']) {
    await _copyTree(
      Directory('${source.path}/$name'),
      Directory('${target.path}/$name'),
    );
  }
  for (final name in ['pubspec.yaml', 'pubspec.lock']) {
    await File('${source.path}/$name').copy('${target.path}/$name');
  }
  final manifest = File('${target.path}/pubspec.yaml');
  final yaml = await manifest.readAsString();
  await manifest.writeAsString(
    yaml.replaceAll(
      RegExp(r'^\s*- assets/eq_library/[^\r\n]*\r?\n', multiLine: true),
      '',
    ),
  );
  final feature = File('${target.path}/lib/eq/eq_library_feature.dart');
  await feature.writeAsString(
    (await feature.readAsString()).replaceAll(
      RegExp(r'const bool eqLibraryAvailable = (true|false);'),
      'const bool eqLibraryAvailable = false;',
    ),
  );
  if ((await manifest.readAsString()).contains('eq_library/')) {
    throw StateError('Unexpected EQ asset declaration');
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || !['macos', 'windows'].contains(arguments.first)) {
    stderr.writeln(
      'Usage: dart tools/build_public_host.dart macos|windows [Flutter build options]',
    );
    exitCode = 64;
    return;
  }
  final platform = arguments.first;
  if (Platform.operatingSystem != platform) {
    stderr.writeln('Build on the target platform: $platform');
    exitCode = 64;
    return;
  }
  final source = File.fromUri(Platform.script).parent.parent;
  final temporary = await Directory.systemTemp.createTemp('adi2-public-host-');
  try {
    await preparePublicHost(source, temporary);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    final flutter = flutterRoot == null
        ? 'flutter'
        : '$flutterRoot/bin/flutter${Platform.isWindows ? '.bat' : ''}';
    final host = '${temporary.path}/host';
    Future<void> run(List<String> args) async {
      final process = await Process.start(
        flutter,
        args,
        workingDirectory: host,
        runInShell: Platform.isWindows,
        mode: ProcessStartMode.inheritStdio,
      );
      final code = await process.exitCode;
      if (code != 0)
        throw ProcessException(flutter, args, 'Public host build failed', code);
    }

    await run(['pub', 'get', '--offline']);
    await run([
      'build',
      platform,
      if (!arguments.contains('--debug') && !arguments.contains('--profile'))
        '--release',
      ...arguments.skip(1),
    ]);
    final output = Directory('$host/build/$platform');
    final assets = await output
        .list(recursive: true, followLinks: false)
        .toList();
    if (assets.any(
      (entry) => entry.path.replaceAll('\\', '/').contains('/eq_library/'),
    )) {
      throw StateError('EQ assets found in public output');
    }
    // macOS frameworks use internal symlinks. Copy final build products with
    // platform tools, preserving their metadata and code signatures.
    final destination = '${source.path}/host/build/$platform';
    final target = Directory(destination);
    if (await target.exists()) await target.delete(recursive: true);
    await target.create(recursive: true);
    final result = Platform.isMacOS
        ? await Process.run('/usr/bin/ditto', [output.path, destination])
        : await Process.run('robocopy.exe', [
            output.path,
            destination,
            '/E',
            '/PURGE',
            '/NFL',
            '/NDL',
            '/NJH',
            '/NJS',
          ]);
    if (Platform.isMacOS ? result.exitCode != 0 : result.exitCode >= 8) {
      throw StateError('Could not copy public build products');
    }
    stdout.writeln('Public host without EQ assets: $destination');
  } finally {
    await temporary.delete(recursive: true);
  }
}
