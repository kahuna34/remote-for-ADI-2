import 'package:adi2_remote/desktop/desktop_windows.dart';
import 'package:adi2_remote/host/host_client.dart';

/// Only the window kind belongs on the command line, never host credentials.
class AuxiliaryWindowArguments {
  const AuxiliaryWindowArguments(this.kind);
  final AuxiliaryWindow kind;

  static AuxiliaryWindowArguments? parse(List<String> arguments) {
    final flags = arguments.where((a) => a.startsWith('--window')).toList();
    if (flags.isEmpty) return null;
    if (flags.length == 1 && arguments.length == 1) {
      for (final kind in AuxiliaryWindow.values) {
        if (flags.single == '--window=${kind.name}') {
          return AuxiliaryWindowArguments(kind);
        }
      }
    }
    throw const FormatException('Invalid auxiliary window arguments');
  }
}

HostCredentials decodeWindowCredentials(Object? value) {
  try {
    final credentials = HostCredentials.fromJson(
      Map<String, dynamic>.from(value as Map),
    );
    if (credentials.host.address.trim().isEmpty ||
        credentials.host.address != credentials.host.address.trim() ||
        credentials.host.port < 1 ||
        credentials.host.port > 65535 ||
        credentials.host.id.isEmpty ||
        credentials.deviceId.isEmpty ||
        credentials.key.isEmpty) {
      throw const FormatException();
    }
    return credentials;
  } catch (_) {
    throw const FormatException('Invalid window credentials');
  }
}
