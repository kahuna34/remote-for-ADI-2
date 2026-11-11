import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum UsbCcMode { stereo, multi, unknown }

/// Reads only existing Android USB permission; never requests access.
Future<UsbCcMode> readUsbCcMode() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return UsbCcMode.unknown;
  }
  try {
    final mode = await const MethodChannel('adi2/usb')
        .invokeMethod<String>('ccMode');
    return switch (mode) {
      'stereo' => UsbCcMode.stereo,
      'multi' => UsbCcMode.multi,
      _ => UsbCcMode.unknown,
    };
  } on PlatformException {
    return UsbCcMode.unknown;
  } on MissingPluginException {
    return UsbCcMode.unknown;
  }
}
