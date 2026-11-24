import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dbus/dbus.dart';

class MprisMetadata {
  const MprisMetadata({
    this.title,
    this.artist,
    this.album,
    this.artUrl,
    this.app,
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.art,
    this.artLarge,
  });
  final String? title, artist, album, app;
  final Uri? artUrl;
  final bool playing;
  final Duration position, duration;
  final Uint8List? art;

  /// Cover in voller Größe für die eigene Oberfläche am selben Rechner.
  final Uint8List? artLarge;
}

/// Accepts native D-Bus values or plain maps, so metadata parsing needs no bus.
MprisMetadata parseMprisMetadata(
  Map<String, dynamic> properties, {
  String? app,
  Uint8List? art,
  Uint8List? artLarge,
}) {
  dynamic native(dynamic value) {
    if (value is DBusValue) return native(value.toNative());
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), native(value)));
    }
    if (value is Iterable) return value.map(native).toList();
    return value;
  }

  final p = native(properties) as Map;
  final metadata = p['Metadata'] is Map ? p['Metadata'] as Map : const {};
  String? text(dynamic value) =>
      value is String ? value.substring(0, value.length.clamp(0, 1024)) : null;
  final artists = metadata['xesam:artist'];
  final url = Uri.tryParse(text(metadata['mpris:artUrl']) ?? '');
  Duration time(dynamic value) => value is int && value >= 0
      ? Duration(microseconds: value)
      : Duration.zero;
  return MprisMetadata(
    title: text(metadata['xesam:title']),
    artist: text(
      artists is Iterable ? artists.whereType<String>().join(', ') : artists,
    ),
    album: text(metadata['xesam:album']),
    artUrl: url != null && {'file', 'http', 'https'}.contains(url.scheme)
        ? url
        : null,
    app: app,
    playing: p['PlaybackStatus'] == 'Playing',
    position: time(p['Position']),
    duration: time(metadata['mpris:length']),
    art: art,
    artLarge: artLarge,
  );
}

/// Polling is owned by the caller; a session bus is opened lazily on Linux only.
class MprisPlayer {
  DBusClient? _bus;
  String? _selected, _artKey;
  Uint8List? _art, _artLarge;
  bool _closed = false;
  static const _interface = 'org.mpris.MediaPlayer2.Player';
  DBusRemoteObject _object(String name) => DBusRemoteObject(
    _bus!,
    name: name,
    path: DBusObjectPath('/org/mpris/MediaPlayer2'),
  );

  Future<MprisMetadata> read() async {
    if (_closed) return const MprisMetadata();
    try {
      _bus ??= DBusClient.session();
      final names = (await _bus!.listNames().timeout(
        const Duration(seconds: 2),
      )).where((n) => n.startsWith('org.mpris.MediaPlayer2.')).toList()..sort();
      // Read players concurrently; one unresponsive service cannot hide others.
      final states = await Future.wait(
        names.map((name) async {
          try {
            final p = await _object(name)
                .getAllProperties(_interface)
                .timeout(const Duration(seconds: 1));
            return (name, p);
          } catch (_) {
            return (name, <String, DBusValue>{});
          }
        }),
      );
      states.sort((a, b) {
        int rank((String, Map<String, DBusValue>) entry) {
          final p = parseMprisMetadata(entry.$2);
          return (p.playing ? 4 : 0) +
              (entry.$1 == _selected ? 2 : 0) +
              (p.title?.isNotEmpty == true ? 1 : 0);
        }

        return rank(b).compareTo(rank(a));
      });
      final chosen = states.where((s) => s.$2.isNotEmpty).firstOrNull;
      if (chosen == null) {
        _selected = null;
        _artKey = null;
        _art = null;
        _artLarge = null;
        return const MprisMetadata();
      }
      _selected = chosen.$1;
      String app = chosen.$1.substring('org.mpris.MediaPlayer2.'.length);
      try {
        final identity = await _object(chosen.$1)
            .getProperty('org.mpris.MediaPlayer2', 'Identity')
            .timeout(const Duration(milliseconds: 500));
        if (identity.toNative() is String) app = identity.toNative() as String;
      } catch (_) {
        /* Identity is optional in broken implementations. */
      }
      var metadata = parseMprisMetadata(chosen.$2, app: app);
      final key = '${chosen.$1}:${metadata.artUrl}';
      if (_artKey != key) {
        _artKey = key;
        final art = metadata.artUrl == null
            ? null
            : await _loadArt(metadata.artUrl!);
        _art = art?.$1;
        _artLarge = art?.$2;
      }
      metadata = parseMprisMetadata(
        chosen.$2,
        app: app,
        art: _art,
        artLarge: _artLarge,
      );
      return metadata;
    } catch (_) {
      _selected = null;
      return const MprisMetadata();
    }
  }

  Future<void> command(String command) async {
    final method = {
      'play': 'Play',
      'pause': 'Pause',
      'toggle': 'PlayPause',
      'next': 'Next',
      'previous': 'Previous',
    }[command];
    if (_closed || method == null) return;
    if (_selected == null) await read();
    final selected = _selected;
    if (selected == null || _closed) return;
    try {
      await _object(selected)
          .callMethod(_interface, method, [])
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      _selected = null;
    }
  }

  Future<void> openPlayer() async {
    if (_selected == null) await read();
    if (_selected == null || _closed) return;
    try {
      await _object(_selected!)
          .callMethod('org.mpris.MediaPlayer2', 'Raise', [])
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      /* Some players cannot raise a window. */
    }
  }

  static bool _isJpegOrPng(Uint8List b) =>
      (b.length >= 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) ||
      (b.length >= 8 &&
          b[0] == 0x89 &&
          b[1] == 0x50 &&
          b[2] == 0x4e &&
          b[3] == 0x47);

  /// Original, wenn JPEG/PNG und klein genug; sonst auf 600 px verkleinert.
  Future<Uint8List?> _largeArt(Uint8List bytes) async {
    const limit = 600000;
    if (bytes.length <= limit && _isJpegOrPng(bytes)) return bytes;
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 600);
      try {
        final frame = await codec.getNextFrame();
        try {
          final data = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (data == null || data.lengthInBytes > limit) return null;
          return data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  /// PNG at [side] × [side], or null if larger than [limit] bytes.
  Future<Uint8List?> _png(Uint8List bytes, int side, int limit) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: side,
        targetHeight: side,
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          final data = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          return data == null || data.lengthInBytes > limit
              ? null
              : data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  /// Klein (80 px PNG, für Smartphones) und groß (Original oder 600 px PNG).
  Future<(Uint8List?, Uint8List?)?> _loadArt(Uri uri) async {
    const limit = 4 * 1024 * 1024;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final bytes = await (() async {
        final data = BytesBuilder(copy: false);
        final Stream<List<int>> stream;
        if (uri.scheme == 'file' &&
            (uri.host.isEmpty || uri.host == 'localhost')) {
          stream = File.fromUri(uri.replace(host: '')).openRead();
        } else if (uri.scheme == 'https' || uri.scheme == 'http') {
          final request = await client.getUrl(uri);
          request.maxRedirects = 3;
          final response = await request.close();
          if (response.statusCode != 200 || response.contentLength > limit) {
            return null;
          }
          stream = response;
        } else {
          return null;
        }
        await for (final chunk in stream) {
          if (data.length + chunk.length > limit) return null;
          data.add(chunk);
        }
        return data.takeBytes();
      })().timeout(const Duration(seconds: 3));
      if (bytes == null || bytes.isEmpty) return null;
      final large = await _largeArt(bytes);
      // Smartphones: PNG within the host artwork budget. Detailed covers can
      // exceed it at 80 px, so step down until it fits.
      Uint8List? small;
      for (final side in const [96, 80, 64, 48]) {
        small = await _png(bytes, side, 30000);
        if (small != null) break;
      }
      return (small, large);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> dispose() async {
    _closed = true;
    await _bus?.close();
    _bus = null;
  }
}
