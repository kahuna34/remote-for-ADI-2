// Aktuell laufender Player (Titel, Interpret, Cover) und Steuerung.
// Android: aktive Medien-Sitzung über den Benachrichtigungszugriff.
// Andere Plattformen: (noch) nicht verfügbar -> Leiste bleibt verborgen.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NowPlayingInfo {
  const NowPlayingInfo({
    this.title,
    this.artist,
    this.app,
    this.playing = false,
    this.art,
  });
  final String? title;
  final String? artist;
  final String? app;
  final bool playing;
  final Uint8List? art;

  bool get hasContent => (title ?? '').isNotEmpty;
}

class NowPlaying extends ChangeNotifier {
  static const _ch = MethodChannel('adi2/media');
  static const _ev = EventChannel('adi2/media/events');

  StreamSubscription? _sub;

  /// Plattform unterstützt die Player-Leiste.
  bool supported = false;

  /// Zugriff erteilt (Android: Benachrichtigungszugriff).
  bool access = false;

  /// Nutzer hat den Hinweis zur Freigabe ausgeblendet.
  bool promptDismissed = false;

  NowPlayingInfo? info;

  Future<void> start() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    supported = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      promptDismissed = prefs.getBool('player_prompt_dismissed') ?? false;
    } catch (_) {}
    _sub = _ev.receiveBroadcastStream().listen((e) {
      final m = Map<String, dynamic>.from(e as Map);
      access = m['access'] == true;
      final incomingArt = m['art'] as Uint8List?;
      final art = listEquals(info?.art, incomingArt) ? info?.art : incomingArt;
      info = access && m['title'] != null
          ? NowPlayingInfo(
              title: m['title'] as String?,
              artist: m['artist'] as String?,
              app: m['app'] as String?,
              playing: m['playing'] == true,
              art: art,
            )
          : null;
      notifyListeners();
    }, onError: (_) {});
    notifyListeners();
  }

  Future<void> openAccessSettings() => _ch.invokeMethod('openAccessSettings');

  Future<void> dismissPrompt() async {
    promptDismissed = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('player_prompt_dismissed', true);
    } catch (_) {}
  }

  Future<void> command(String c) async {
    try {
      await _ch.invokeMethod('command', c);
    } catch (_) {}
  }

  Future<void> openPlayer() async {
    try {
      await _ch.invokeMethod('openPlayer');
    } catch (_) {}
  }

  void playPause() => command(info?.playing == true ? 'pause' : 'play');

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
