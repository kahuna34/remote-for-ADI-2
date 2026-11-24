// Aktuell laufender Player (Titel, Interpret, Cover) und Steuerung.
// Android: aktive Medien-Sitzung über den Benachrichtigungszugriff.
// iOS: Apple Music über den systemMusicPlayer.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mpris.dart';

class NowPlayingInfo {
  const NowPlayingInfo({
    this.title,
    this.artist,
    this.app,
    this.playing = false,
    this.art,
    this.artLarge,
    this.album,
    this.artUrl,
    this.position,
    this.duration,
  });
  final String? title;
  final String? artist;
  final String? app;
  final bool playing;
  final Uint8List? art;

  /// Cover in voller Größe (für die Oberfläche am selben Rechner).
  final Uint8List? artLarge;
  final String? album;
  final Uri? artUrl;
  final Duration? position, duration;

  factory NowPlayingInfo.fromMpris(MprisMetadata data) => NowPlayingInfo(
    title: data.title,
    artist: data.artist,
    app: data.app,
    playing: data.playing,
    art: data.art,
    artLarge: data.artLarge,
    album: data.album,
    artUrl: data.artUrl,
    position: data.position,
    duration: data.duration,
  );

  bool get hasContent => (title ?? '').isNotEmpty;
}

class NowPlaying extends ChangeNotifier {
  NowPlaying({this.hostOnly = false});
  final bool hostOnly;
  static const _ch = MethodChannel('adi2/media');
  static const _ev = EventChannel('adi2/media/events');

  StreamSubscription? _sub;
  MprisPlayer? _mpris;
  Timer? _poll;
  bool _reading = false, _disposed = false;

  Future<void> _readLinux() async {
    if (_reading || _disposed) return;
    _reading = true;
    try {
      final state = await _mpris!.read();
      if (_disposed) return;
      info = NowPlayingInfo.fromMpris(state);
      notifyListeners();
    } finally {
      _reading = false;
    }
  }

  /// Plattform unterstützt die Player-Leiste.
  bool supported = false;

  /// Zugriff erteilt (Android: Benachrichtigungszugriff).
  bool access = false;

  /// Android sperrt den Zugriff als „eingeschränkte Einstellung“
  /// (App aus heruntergeladener Datei installiert, noch nicht freigegeben).
  bool restricted = false;

  /// Nutzer hat den Hinweis zur Freigabe ausgeblendet.
  bool promptDismissed = false;

  NowPlayingInfo? info;

  Future<void> start() async {
    if (hostOnly) return;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      if (_mpris != null || _disposed) return;
      supported = access = true;
      _mpris = MprisPlayer();
      _poll = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_readLinux()),
      );
      await _readLinux();
      return;
    }
    if (kIsWeb ||
        ![
          TargetPlatform.android,
          TargetPlatform.iOS,
        ].contains(defaultTargetPlatform) ||
        _sub != null) {
      return;
    }
    supported = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      promptDismissed = prefs.getBool('player_prompt_dismissed') ?? false;
    } catch (_) {}
    _sub = _ev.receiveBroadcastStream().listen((e) {
      final m = Map<String, dynamic>.from(e as Map);
      access = m['access'] == true;
      if (!access) unawaited(_checkRestricted());
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

  /// Re-read permission after returning from Android settings.
  Future<void> refreshAccess() async {
    if (_mpris != null) {
      await _readLinux();
      return;
    }
    if (!supported) return;
    try {
      access = await _ch.invokeMethod<bool>('hasAccess') == true;
      if (access) {
        restricted = false;
      } else {
        await _checkRestricted();
        info = null;
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> openAccessSettings() => _ch.invokeMethod('openAccessSettings');

  /// App-Infos öffnen (dort über ⋮ „Eingeschränkte Einstellungen zulassen“).
  Future<void> openAppDetails() => _ch.invokeMethod('openAppDetails');

  Future<void> _checkRestricted() async {
    try {
      final r = await _ch.invokeMethod<bool>('restricted') == true;
      if (r != restricted) {
        restricted = r;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> dismissPrompt() async {
    promptDismissed = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('player_prompt_dismissed', true);
    } catch (_) {}
  }

  Future<void> command(String c) async {
    if (_mpris != null) {
      await _mpris!.command(c);
      await _readLinux();
      return;
    }
    try {
      await _ch.invokeMethod('command', c);
    } catch (_) {}
  }

  Future<void> openPlayer() async {
    if (_mpris != null) {
      await _mpris!.openPlayer();
      return;
    }
    try {
      await _ch.invokeMethod('openPlayer');
    } catch (_) {}
  }

  void playPause() => command(info?.playing == true ? 'pause' : 'play');

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    unawaited(_mpris?.dispose());
    _sub?.cancel();
    super.dispose();
  }
}
