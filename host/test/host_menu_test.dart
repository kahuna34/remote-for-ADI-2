// ignore_for_file: deprecated_member_use
import 'package:adi2_host/host_menu.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    final previous = AppLang.instance.language;
    AppLang.instance.language = AppLanguage.de;
    addTearDown(() => AppLang.instance.language = previous);
  });

  for (final windows in [true, false]) {
    for (final client in [null, 'Mein Smartphone']) {
      for (final device in [null, 'ADI-2 DAC FS (12345678)']) {
        test('Menü Windows=$windows Client=$client Gerät=$device', () {
          final items = buildHostMenu(
            clientNames: client == null ? [] : [client],
            rmeDevice: device,
            status: client == null ? 'Bereit' : 'Clients verbunden',
            port: hostDefaultPort,
            version: '1.1.1 (3)',
            windows: windows,
            autostart: true,
            updatesEnabled: false,
          );
          expect(items[0].label, 'Client: ${client ?? '–'}');
          expect(items[1].label, 'RME device: ${device ?? '–'}');
          expect(items[2].type, 'separator');
          expect(items.map((i) => i.key).whereType<String>(), [
            'pair',
            'devices',
            'autostart',
            'updates',
            'quit',
          ]);
          final autostart = items.singleWhere((i) => i.key == 'autostart');
          expect(autostart.checked, isTrue);
          expect(
            autostart.label,
            windows ? 'Mit Windows starten' : 'Bei Anmeldung starten',
          );
          expect(items.singleWhere((i) => i.key == 'updates').checked, isFalse);
          expect(items[items.length - 2].label, 'Info: Version 1.1.1 (3)');
          expect(items.last.key, 'quit');
          for (final item in [items[0], items[1], items[items.length - 2]]) {
            expect(item.type, 'normal');
            expect(item.disabled, isFalse);
            expect(item.key, isNull);
            expect(item.onClick, isNull);
          }
        });
      }
    }
  }

  for (final notice in [
    'USB-MIDI belegt',
    'Kein ADI-2 gefunden',
    'Host-Fehler Test',
  ]) {
    test('Fehlerzeile: $notice', () {
      final items = buildHostMenu(
        status: notice,
        error: notice, // Doppelter Hinweis wird nur einmal angezeigt.
        version: '2.3.4 (5)',
        windows: true,
        autostart: false,
        updatesEnabled: true,
        availableVersion: '2.4.0',
      );
      expect(items[2].label, notice);
      expect(items[2].disabled, isFalse);
      expect(items[2].key, isNull);
      expect(items[2].onClick, isNull);
      expect(items[3].type, 'separator');
      expect(items[items.length - 3].key, 'download-update');
      expect(items[items.length - 3].label, 'Update 2.4.0 laden…');
      expect(items[items.length - 2].label, 'Info: Version 2.3.4 (5)');
    });
  }

  test('Ausweichport und Initialisierungsfehler erscheinen in einer Hinweiszeile', () {
    final items = buildHostMenu(
      error: 'Netzwerksuche fehlgeschlagen',
      port: hostDefaultPort + 1,
      version: '1.0.0 (1)',
      windows: true,
      autostart: false,
      updatesEnabled: true,
    );
    expect(
      items[2].label,
      'Netzwerksuche fehlgeschlagen · Port $hostDefaultPort belegt; Host verwendet Port ${hostDefaultPort + 1}',
    );
    expect(items[3].type, 'separator');
  });
  test('Menü zeigt alle Clientnamen in Verbindungsreihenfolge', () {
    for (final language in AppLanguage.values) {
      AppLang.instance.language = language;
      final items = buildHostMenu(
        clientNames: ['Telefon', 'Tablet'],
        status: 'Clients verbunden',
        version: '1.1.1 (3)',
        windows: true,
        autostart: false,
        updatesEnabled: true,
      );
      expect(items.first.label, 'Client: Telefon, Tablet');
      expect(items[2].type, 'separator');
      expect(
        hostStatusText('Clients verbunden', 2),
        language == AppLanguage.de
            ? '2 Clients verbunden'
            : '2 clients connected',
      );
      expect(
        hostStatusText('Clients verbunden', 1),
        language == AppLanguage.de
            ? '1 Client verbunden'
            : '1 client connected',
      );
    }
  });
}
