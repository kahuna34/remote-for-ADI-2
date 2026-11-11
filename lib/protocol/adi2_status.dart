// Auswertung der Statusmeldung (Kommando 0x07), ca. 1x pro Sekunde.

const List<String> _ioRates = [
  '32k',
  '44.1k',
  '48k',
  '–',
  '64k',
  '88.2k',
  '96k',
  '–',
  '128k',
  '176.4k',
  '192k',
  '–',
  '–',
  '–',
  '–',
  '–',
];

/// Interne Sample-Rate (Index wie Device-Parameter "Sample Rate", erweitert).
const List<String> internalRates = [
  '32k',
  '44.1k',
  '48k',
  '64k',
  '88.2k',
  '96k',
  '128k',
  '176.4k',
  '192k',
  '352.8k',
  '384k',
  '705.6k',
  '768k',
];

class Adi2Status {
  Adi2Status(this.raw);

  /// Datenbytes ab Byte 6 (Index 0 = Byte 6).
  final List<int> raw;

  int _b(int byteNo) {
    final i = byteNo - 6;
    return (i >= 0 && i < raw.length) ? raw[i] : 0;
  }

  /// 4 Bytes à 7 Bit, niederwertigstes Byte zuerst.
  int _word28(int firstByte) {
    var w = 0;
    for (var k = 0; k < 4; k++) {
      w |= (_b(firstByte + k) & 0x7F) << (7 * k);
    }
    return w;
  }

  int get io1 => _word28(7);
  int get io2 => _word28(11);
  bool _bit(int w, int n) => (w >> n) & 1 == 1;

  int get activeOutput => _b(6) & 0x03;
  int get deviceRevision => (_b(6) >> 2) & 0x03;
  int get activeLineOutput => (_b(6) >> 4) & 0x03;
  bool get phones34Active => _bit(_b(6), 6);

  /// Bei ADI-2/4: Revision 1 = ADI-2/4 Pro EX.
  bool get isEx => deviceRevision == 1;

  bool get aesLock => _bit(io1, 0);
  bool get spdifLock => _bit(io1, 1);
  bool get aesSync => _bit(io1, 2);
  bool get spdifSync => _bit(io1, 3);
  bool get spdifOptical => _bit(io1, 4);
  bool get adatDetected => _bit(io1, 5);
  int get clockSource => (io1 >> 6) & 0x03;
  String get clockSourceName =>
      const ['Intern', 'AES', 'SPDIF', 'Intern'][clockSource];
  String get aesRate => _ioRates[(io1 >> 8) & 0x0F];
  String get spdifRate => _ioRates[(io1 >> 12) & 0x0F];
  int get internalRateIndex => (io1 >> 16) & 0x1F;
  String get internalRate => internalRateIndex < internalRates.length
      ? internalRates[internalRateIndex]
      : '?';
  bool get phones1Plugged => _bit(io1, 21);
  bool get overCurrentPhones1 => _bit(io1, 25);
  bool get overCurrentPhones2 => _bit(io1, 26);
  bool get phones2Plugged => _bit(io1, 27);

  bool get dsdUsb => _bit(io2, 2);
  bool get dsdLine => _bit(io2, 3);
  bool get dsdPhones => _bit(io2, 4);
  bool get emphasisAes => _bit(io2, 12);
  bool get emphasisSpdif => _bit(io2, 13);
  bool get dsdAes => _bit(io2, 6);
  bool get dsdSpdif => _bit(io2, 7);
  bool get bits24Aes => _bit(io2, 8);
  bool get bits24Spdif => _bit(io2, 9);
  bool get professionalAes => _bit(io2, 10);
  bool get professionalSpdif => _bit(io2, 11);
  bool get nonAudioAes => _bit(io2, 16);
  bool get nonAudioSpdif => _bit(io2, 17);
  bool get dcErrorPhones1 => _bit(io2, 18);
  bool get dcErrorPhones2 => _bit(io2, 19);
  bool get powerFail => _bit(io2, 24);

  int get deviceMode => _b(15) & 0x07;
  bool get balancedMode => _bit(_b(15), 3);
  int get protocolRevision => _b(16) & 0x0F;
  bool get eightChannelMode => _bit(_b(16), 4);
  int get dacSampleRate => _b(17) & 0x1F;
  bool get pentaPlug => _bit(_b(17), 5);
  bool get dcDetectLine => _bit(_b(18), 3);
  bool get dcDetectPhones => _bit(_b(18), 4);
}
