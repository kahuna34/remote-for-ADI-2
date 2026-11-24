import 'package:adi2_host/auxiliary_window_arguments.dart';
import 'package:adi2_remote/desktop/desktop_windows.dart';
import 'package:adi2_remote/host/host_client.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Normal and autostart launches do not select a child', () {
    expect(AuxiliaryWindowArguments.parse([]), isNull);
    expect(AuxiliaryWindowArguments.parse(['--autostart']), isNull);
  });
  for (final kind in AuxiliaryWindow.values) {
    test('Select $kind using only its public kind', () {
      expect(
        AuxiliaryWindowArguments.parse(['--window=${kind.name}'])!.kind,
        kind,
      );
    });
  }
  test('Reject invalid or mixed window flags', () {
    for (final args in [
      ['--window'],
      ['--window', 'player'],
      ['--window=unknown'],
      ['--window=player', '--window=analyzer'],
      ['--window=player', '--autostart'],
      ['--window=player', 'secret'],
      ['--windows=player'],
    ]) {
      expect(() => AuxiliaryWindowArguments.parse(args), throwsFormatException);
    }
  });
  final credentials = HostCredentials(
    const HostEndpoint(
      id: 'local',
      name: 'UI',
      address: '127.0.0.1',
      port: 47322,
    ),
    'ui',
    'private-key',
  );
  test('Socket credentials retain fallback port', () {
    expect(
      decodeWindowCredentials(credentials.toJson()).toJson(),
      credentials.toJson(),
    );
  });
  test('Private channel accepts the selected remote host', () {
    final remote = {
      ...credentials.toJson(),
      'host': {...credentials.host.toJson(), 'address': '192.168.1.2'},
      'local': false,
    };
    expect(decodeWindowCredentials(remote).host.address, '192.168.1.2');
  });
  test('Reject malformed credentials without leaking keys', () {
    for (final value in [
      null,
      [],
      {},
      {
        ...credentials.toJson(),
        'host': {...credentials.host.toJson(), 'address': ''},
      },
      for (final port in [0, -1, 65536])
        {
          ...credentials.toJson(),
          'host': {...credentials.host.toJson(), 'port': port},
        },
    ]) {
      try {
        decodeWindowCredentials(value);
        fail('Accepted invalid credentials');
      } on FormatException catch (error) {
        expect(error.toString(), isNot(contains('private-key')));
      }
    }
  });
}
