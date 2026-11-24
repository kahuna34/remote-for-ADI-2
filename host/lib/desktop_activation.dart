import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// LSUIElement remains set: hidden hosts and auxiliary processes stay accessory
/// apps. Only the visible main surface gets a Dock entry.
class DesktopActivation {
  static const _channel = MethodChannel('adi2/host_window');
  static void onReopen(Future<void> Function() open) {
    if (Platform.isMacOS) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'reopen') await open();
      });
      unawaited(_channel.invokeMethod<void>('ready').catchError((Object _) {}));
    }
  }

  static Future<void> present({bool auxiliary = false}) async {
    if (Platform.isMacOS) {
      await _channel.invokeMethod<void>('present', {'auxiliary': auxiliary});
    }
  }

  static Future<void> hide() async {
    if (Platform.isMacOS) await _channel.invokeMethod<void>('hide');
  }
}
