import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Gemeinsame Plattformvorgaben: Sichtbare EQs und Signalpläne erlauben das Drehen.
/// Vollbild hat Vorrang vor der darunterliegenden, verdeckten Seite.
abstract final class EqDisplayMode {
  static final _rotatable = <Object>{};
  static Object? _fullscreen;
  static bool _automatic = false;
  static bool _keepPortrait = false;
  static bool _tablet = false;
  static String? _lastPolicy;
  static int _policyVersion = 0;
  static const _platform = MethodChannel('adi2/display');

  static void initialize() => _apply();

  static void setTablet(bool tablet) {
    if (_tablet == tablet) return;
    _tablet = tablet;
    _apply();
  }

  static void allowRotation(Object owner, bool allow) {
    if (allow) {
      _rotatable.add(owner);
    } else {
      _rotatable.remove(owner);
    }
    _apply();
  }

  /// [keepPortrait] hält das Hochformat: Ein Drehen ins Querformat baute am
  /// Tablet die Seite unter dem Vollbild um und schlösse es dadurch wieder.
  static void enterFullscreen(
    Object owner, {
    required bool automatic,
    bool keepPortrait = false,
  }) {
    _fullscreen = owner;
    _automatic = automatic;
    _keepPortrait = keepPortrait;
    _apply();
  }

  static void leaveFullscreen(Object owner) {
    if (_fullscreen != owner) return;
    _fullscreen = null;
    _apply();
  }

  static void _apply() {
    final fullscreen = _fullscreen != null;
    final keepPortrait = fullscreen && _keepPortrait;
    final rotate =
        !keepPortrait &&
        (fullscreen ? _automatic : _tablet || _rotatable.isNotEmpty);
    final policy = '$fullscreen/$rotate/$keepPortrait';
    if (_lastPolicy == policy) return;
    _lastPolicy = policy;
    SystemChrome.setPreferredOrientations(
      rotate
          ? const [
              DeviceOrientation.portraitUp,
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : fullscreen && !keepPortrait
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [DeviceOrientation.portraitUp],
    );
    _setSystemUi(fullscreen, ++_policyVersion);
  }

  static Future<void> _setSystemUi(bool fullscreen, int version) async {
    await SystemChrome.setEnabledSystemUIMode(
      fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    if (version != _policyVersion ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    // Flutter verwendet für immersiveSticky noch alte Android-Flags. Ab API 35
    // übernimmt der vorhandene Android-Host die WindowInsets-Steuerung.
    try {
      await _platform.invokeMethod<void>('setFullscreen', fullscreen);
    } on MissingPluginException {
      // Andere Einbettungen (u. a. Widget-Tests) verwenden nur SystemChrome.
    }
  }
}
