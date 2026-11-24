import 'package:adi2_remote/desktop/host_interface.dart';
import 'package:flutter/foundation.dart';

bool opensSurfaceAtStartup(List<String> arguments) =>
    !arguments.contains('--autostart');

bool trayLeftClickOpensSurface(TargetPlatform platform) =>
    hostHasInterfaceFor(platform) && platform != TargetPlatform.linux;
