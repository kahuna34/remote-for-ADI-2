import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../app_settings.dart';
import '../protocol/adi2_params.dart';
import 'adi2_controller.dart';

/// One owner on HomePage. Native interception follows route, lifecycle and device.
class VolumeKeys {
  VolumeKeys({
    required this.controller,
    required this.output,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _channel.setMethodCallHandler(_handle);
    controller.addListener(_sync);
    AppSettings.instance.addListener(_sync);
  }

  static const _channel = MethodChannel('adi2/volume_keys');
  final Adi2Controller controller;
  final int? Function() output;
  final DateTime Function() _now;
  bool _foreground = false, _current = false, _disposed = false;
  bool? _sentEnabled;
  DateTime? _lastUp, _lastDown;

  bool get _enabled =>
      !_disposed &&
      _foreground &&
      _current &&
      AppSettings.instance.volumeKeys &&
      controller.isConnected &&
      !controller.offline &&
      !controller.hostReconnecting &&
      controller.variant != null &&
      output() != null;

  void update({
    required bool foreground,
    required bool current,
    bool force = false,
  }) {
    _foreground = foreground;
    _current = current;
    // Native bridges also disable themselves on pause. Reassert after resume,
    // including the initial transition from an inactive launch window.
    if (force) _sentEnabled = null;
    _sync();
  }

  void _sync() {
    final enabled = _enabled;
    if (_sentEnabled == enabled) return;
    _sentEnabled = enabled;
    if (!enabled) _lastUp = _lastDown = null;
    unawaited(_sendEnabled(enabled));
  }

  Future<void> _sendEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setEnabled', enabled);
    } on MissingPluginException {
      // Desktop and widget tests do not install the phone bridge.
    } on PlatformException {
      // A disappearing native surface must not affect device controls.
    }
  }

  Future<void> _handle(MethodCall call) async {
    if (call.method != 'step' || !_enabled) return;
    final direction = call.arguments;
    if (direction != -1 && direction != 1) return;
    final address = output();
    if (address == null ||
        controller.valueOr(address, OutIdx.lockVolume, 0) != 0) {
      return;
    }
    final value = controller.value(address, OutIdx.volume);
    if (value == null) return;
    final up = direction == 1;
    final now = _now();
    final last = up ? _lastUp : _lastDown;
    if (last != null &&
        now.difference(last).inMilliseconds < (up ? 250 : 100)) {
      return;
    }
    if (up) {
      _lastUp = now;
    } else {
      _lastDown = now;
    }
    final target = controller.volumeTarget(address) ?? value;
    controller.setVolume(address, up ? value + 5 : math.min(target, value) - 5);
  }

  void dispose() {
    _disposed = true;
    _sync();
    controller.removeListener(_sync);
    AppSettings.instance.removeListener(_sync);
    _channel.setMethodCallHandler(null);
  }
}
