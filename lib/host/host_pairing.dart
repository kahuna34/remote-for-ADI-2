import 'dart:math';

import 'host_protocol.dart';

class PairedDevice {
  const PairedDevice(this.id, this.name, this.key);
  final String id, name, key;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'key': key};
  factory PairedDevice.fromJson(Map<String, dynamic> j) =>
      PairedDevice(j['id'] as String, j['name'] as String, j['key'] as String);
}

class HostPairing {
  HostPairing({DateTime Function()? now}) : now = now ?? DateTime.now;
  final DateTime Function() now;
  final Map<String, PairedDevice> devices = {};
  String? code;
  DateTime? expires;
  int _attempts = 0;

  String issue() {
    code = Random.secure().nextInt(1000000).toString().padLeft(6, '0');
    expires = now().add(hostPairingLifetime);
    _attempts = 0;
    return code!;
  }

  PairedDevice? redeem(String candidate, String id, String name) {
    if (code == null || expires == null || !now().isBefore(expires!)) {
      return null;
    }
    if (++_attempts > 5) {
      code = null;
      return null;
    }
    if (!secureEquals(candidate, code!) || id.isEmpty || name.length > 100) {
      return null;
    }
    code = null; // vor jedem asynchronen Speichern verbraucht
    final device = PairedDevice(id, name, randomToken());
    devices[id] = device;
    return device;
  }

  void revoke(String id) => devices.remove(id);
}
