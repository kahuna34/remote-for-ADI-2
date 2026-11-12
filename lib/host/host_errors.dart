import '../l10n/l10n.dart';

String hostErrorText(String error) {
  if (error.contains('not_paired') || error.contains('revoked')) {
    return tr('Host-Kopplung fehlt oder wurde widerrufen');
  }
  if (error.contains('usb_missing')) {
    return tr('Am Host wurde kein ADI-2 gefunden');
  }
  if (error.contains('usb_busy')) return tr('USB-MIDI am Host ist belegt');
  if (error.contains('busy')) {
    return tr('Zu viele Clients am Host verbunden (maximal 4)');
  }
  return tr('Host-Verbindung unterbrochen. Neuer Verbindungsversuch läuft …');
}
