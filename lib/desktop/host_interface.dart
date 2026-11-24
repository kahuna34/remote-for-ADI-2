import 'package:flutter/foundation.dart';

/// Capability of the combined host program, not of a standalone mobile app.
/// Callers must also check that they are embedded in the host.
bool hostHasInterfaceFor(TargetPlatform platform) => switch (platform) {
  TargetPlatform.linux ||
  TargetPlatform.macOS ||
  TargetPlatform.windows => true,
  _ => false,
};

bool get hostHasInterface =>
    !kIsWeb && hostHasInterfaceFor(defaultTargetPlatform);

String hostPreferencePrefixFor(String platform) => switch (platform) {
  'linux' => 'linux_host.',
  'macos' => 'macos_host.',
  'windows' => 'windows_host.',
  _ => '',
};
