import 'package:flutter/foundation.dart';

const bool playStoreBuild = bool.fromEnvironment('PLAY_STORE');

/// Test override; ignored in profile and release builds.
@visibleForTesting
bool? debugPlayStoreBuild;

bool get isPlayStoreBuild {
  var value = playStoreBuild;
  assert(() {
    value = debugPlayStoreBuild ?? value;
    return true;
  }());
  return value;
}
