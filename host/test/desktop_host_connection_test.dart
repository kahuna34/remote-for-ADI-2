import 'dart:convert';

import 'package:adi2_host/auxiliary_window_arguments.dart';
import 'package:adi2_host/windows_instance.dart';
import 'package:adi2_remote/desktop/desktop_host_selection.dart';
import 'package:adi2_remote/host/host_client.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const local = HostCredentials(
    HostEndpoint(id: 'B', name: 'B', address: '127.0.0.1', port: 47321),
    'private-local',
    'private-local-key',
  );
  const remote = HostCredentials(
    HostEndpoint(id: 'A', name: 'A', address: '192.168.1.2', port: 47999),
    'desktop-b',
    'paired-remote-key',
  );

  test('Instance credential request follows restored and changed connection for both windows', () async {
    SharedPreferences.setMockInitialValues({
      DesktopHostSelection.preferenceKey: 'A',
      'paired_hosts_v1': jsonEncode([remote.toJson()]),
    });
    final selection = DesktopHostSelection(local);
    await selection.load(); // Also works before the surface has been opened.
    final token = 'a' * 64;
    Future<Object?> request(String kind, {String? auth}) =>
        WindowsInstance.dispatch(
          jsonEncode({
            'type': 'adi2-window-v1',
            'window': kind,
            'method': 'credentials',
            'token': auth ?? token,
          }),
          token,
          onShow: () async {},
          onWindowRequest: (_, data) async => selection.windowCredentials(),
        );
    for (final kind in ['analyzer', 'player']) {
      final response = await request(kind);
      final credentials = decodeWindowCredentials(response);
      expect(credentials.toJson(), remote.toJson());
      expect((response as Map)['local'], false);
    }
    await expectLater(request('player', auth: 'b' * 64), throwsFormatException);
    await selection.select(local);
    final response = await request('analyzer');
    expect(decodeWindowCredentials(response).toJson(), local.toJson());
    expect((response as Map)['local'], true);
    await selection.select(remote);
    selection.forget('A');
    await expectLater(request('player'), throwsStateError);
  });
}
