import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'host_protocol.dart';

class HostDiscovery extends ChangeNotifier {
  final Map<String, HostEndpoint> hosts = {};
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _events;
  static const _channel = MethodChannel('de.markus.adi2_remote/host_network');
  bool _stopped = false;

  Future<void> start() async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod<void>('acquireMulticast');
      }
      if (_stopped) {
        await _release();
        return;
      }
      final discovery = BonsoirDiscovery(
        type: hostServiceType,
        printLogs: false,
      );
      _discovery = discovery;
      await discovery.initialize();
      if (_stopped) {
        await discovery.stop();
        return;
      }
      _events = discovery.eventStream?.listen((event) {
        final service = event.service;
        if (service == null) return;
        if (event is BonsoirDiscoveryServiceFoundEvent) {
          unawaited(
            service
                .resolve(discovery.serviceResolver)
                .catchError((Object _) {}),
          );
        } else if (event is BonsoirDiscoveryServiceResolvedEvent ||
            event is BonsoirDiscoveryServiceUpdatedEvent) {
          final id = service.attributes['id'];
          final address = service.hostAddresses
              .where(
                (address) =>
                    InternetAddress.tryParse(address)?.type ==
                    InternetAddressType.IPv4,
              )
              .firstOrNull;
          if (id != null && address != null) {
            hosts[id] = HostEndpoint(
              id: id,
              name: service.name,
              address: address,
              port: service.port,
            );
            notifyListeners();
          }
        } else if (event is BonsoirDiscoveryServiceLostEvent) {
          hosts.remove(service.attributes['id']);
          notifyListeners();
        }
      });
      await discovery.start();
    } catch (_) {
      await _release();
    }
  }

  Future<void> _release() async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<void>('releaseMulticast');
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _stopped = true;
    _events?.cancel();
    if (_discovery?.isReady == true) unawaited(_discovery!.stop());
    unawaited(_release());
    super.dispose();
  }
}
