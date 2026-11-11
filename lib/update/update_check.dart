import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum UpdatePlatform { android, macos, windows, other }

enum UpdateStatus { available, current, error, skipped }

typedef ReleaseFetcher = Future<String> Function();

class UpdateResult {
  const UpdateResult(this.status, {this.version, this.url});
  final UpdateStatus status;
  final String? version;
  final Uri? url;
}

List<int>? _version(String value) {
  final match = RegExp(
    r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\+[0-9A-Za-z.-]+| \(\d+\))?$',
  ).firstMatch(value);
  if (match == null) return null;
  final parts = [for (var i = 1; i <= 3; i++) int.tryParse(match[i]!)];
  return parts.any((p) => p == null) ? null : parts.cast<int>();
}

bool isNewerVersion(String installed, String candidate) {
  final a = _version(installed), b = _version(candidate);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return b[i] > a[i];
  }
  return false;
}

Future<String> fetchLatestRelease() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    return await (() async {
      final request = await client.getUrl(
        Uri.https(
          'api.github.com',
          '/repos/kahuna34/remote-for-ADI-2/releases/latest',
        ),
      );
      request.headers.set('Accept', 'application/vnd.github+json');
      request.headers.set('User-Agent', 'Remote-for-ADI-2');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      return response.transform(utf8.decoder).join();
    })().timeout(const Duration(seconds: 10));
  } finally {
    client.close(force: true);
  }
}

Uri _https(Object? value) {
  final uri = Uri.parse(value as String);
  if (uri.scheme != 'https' || uri.host.isEmpty) {
    throw const FormatException('Invalid release URL');
  }
  return uri;
}

/// Pure Dart service. Persistence and notifications belong to the caller.
class UpdateCheck {
  UpdateCheck({
    required this.installedVersion,
    required this.platform,
    ReleaseFetcher? fetcher,
    DateTime Function()? clock,
    this.enabled = true,
    this.lastCheck,
    this.skippedVersion,
    this.onState,
    this.onResult,
  }) : fetcher = fetcher ?? fetchLatestRelease,
       clock = clock ?? DateTime.now;
  final String installedVersion;
  final UpdatePlatform platform;
  final ReleaseFetcher fetcher;
  final DateTime Function() clock;
  final Future<void> Function()? onState;
  final void Function(UpdateResult)? onResult;
  bool enabled;
  DateTime? lastCheck;
  String? skippedVersion;
  UpdateResult? result;
  bool resultWasAutomatic = false;
  Future<UpdateResult>? _pending;
  Timer? _timer;
  static const interval = Duration(hours: 24);

  bool get due =>
      lastCheck == null || clock().difference(lastCheck!) >= interval;
  bool shouldNotify(UpdateResult value) =>
      value.status == UpdateStatus.available &&
      _version(value.version!)?.join('.') !=
          _version(skippedVersion ?? '')?.join('.');

  Future<void> skip(String version) async {
    skippedVersion = version;
    await onState?.call();
  }

  Future<UpdateResult> check({bool manual = false}) {
    if (!manual && (!enabled || !due)) {
      return Future.value(const UpdateResult(UpdateStatus.skipped));
    }
    final pending = _pending ??= _check(manual)
        .whenComplete(() => _pending = null);
    if (manual) {
      return pending.then((value) {
        resultWasAutomatic = false;
        return value;
      });
    }
    return pending;
  }

  Future<UpdateResult> _check(bool manual) async {
    try {
      lastCheck = clock();
      await onState?.call();
      final data = jsonDecode(
        await fetcher().timeout(const Duration(seconds: 10)),
      ) as Map<String, dynamic>;
      final tag = data['tag_name'] as String;
      if (!isNewerVersion(installedVersion, tag)) {
        result = const UpdateResult(UpdateStatus.current);
      } else {
        var url = _https(data['html_url']);
        final name = switch (platform) {
          UpdatePlatform.android => 'Remote-for-ADI-2-Android.apk',
          UpdatePlatform.macos => 'Remote-for-ADI-2-Host-macOS.zip',
          UpdatePlatform.windows => 'Remote-for-ADI-2-Host-Windows-x64.zip',
          UpdatePlatform.other => '',
        };
        for (final asset in (data['assets'] as List? ?? [])) {
          if (asset is Map && asset['name'] == name) {
            url = _https(asset['browser_download_url']);
            break;
          }
        }
        result = UpdateResult(
          UpdateStatus.available,
          version: _version(tag)!.join('.'),
          url: url,
        );
      }
    } catch (_) {
      result = const UpdateResult(UpdateStatus.error);
    }
    resultWasAutomatic = !manual;
    try {
      await onState?.call();
    } catch (_) {}
    try {
      onResult?.call(result!);
    } catch (_) {}
    return result!;
  }

  void start() {
    stop();
    unawaited(check());
    _timer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(check()),
    );
  }

  void stop() => _timer?.cancel();
}
