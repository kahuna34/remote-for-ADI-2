// Parameter-Definitionen laut RME MIDI-Protokoll v1.2.
// Werte werden als Inkremente übertragen: Anzeige = raw * scale.

import '../l10n/l10n.dart';
import 'adi2_codec.dart';

enum Adi2Variant { dac, pro, pro4se, pro4ex }

extension Adi2VariantX on Adi2Variant {
  bool get isPro4 => this == Adi2Variant.pro4se || this == Adi2Variant.pro4ex;
  bool get isPro => this == Adi2Variant.pro;
  bool get isDac => this == Adi2Variant.dac;

  /// Dritter Ausgangskanal (Adresse 9): Phones 3/4 bzw. beim DAC IEM.
  bool get hasPhones34 => true;
  bool get hasInput => !isDac;
  String get label => switch (this) {
    Adi2Variant.dac => 'ADI-2 DAC',
    Adi2Variant.pro => 'ADI-2 Pro',
    Adi2Variant.pro4se => 'ADI-2/4 Pro SE',
    Adi2Variant.pro4ex => 'ADI-2/4 Pro EX',
  };
}

Adi2Variant variantFor(Adi2Model m, {bool ex = false}) => switch (m) {
  Adi2Model.dac => Adi2Variant.dac,
  Adi2Model.pro => Adi2Variant.pro,
  Adi2Model.pro4 => ex ? Adi2Variant.pro4ex : Adi2Variant.pro4se,
};

class ParamDef {
  const ParamDef(
    this.index,
    this.name, {
    this.min = 0,
    required this.max,
    this.def = 0,
    this.scale = 1,
    this.unit = '',
    this.options,
    this.decimals = 0,
  });

  final int index;
  final String name;

  /// Grenzen in Rohwerten (Inkrementen).
  final int min;
  final int max;
  final int def;

  /// Anzeige = raw * scale
  final double scale;
  final String unit;
  final List<String>? options;
  final int decimals;

  bool get isChoice => options != null;
  bool get isSwitch =>
      options != null && options!.length == 2 && options![0] == 'Aus';

  String format(int raw) {
    if (options != null) {
      return (raw >= 0 && raw < options!.length) ? tr(options![raw]) : '$raw';
    }
    final v = raw * scale;
    return '${v.toStringAsFixed(decimals)}${unit.isEmpty ? '' : ' $unit'}';
  }
}

const _onOff = ['Aus', 'An'];

// ---------------------------------------------------------------------------
// Ausgänge (Adresse 3 Line, 6 Phones 1/2, 9 Phones 3/4)

abstract final class OutIdx {
  static const source = 1;
  static const refLevel = 2;
  static const autoRef = 3;
  static const mono = 4;
  static const width = 5;
  static const msProc = 6;
  static const polarity = 7;
  static const crossfeed = 8;
  static const daFilter = 9;
  static const deEmphasis = 10;
  static const dualEq = 11;
  static const volume = 12;
  static const lockVolume = 13;
  static const balance = 14;
  static const mute = 15;
  static const dim = 16;
  static const loopback = 17;
  static const dcProtection = 18;
  static const rearTrsSource = 19;
  static const loudness = 20;
  static const loudBass = 21;
  static const loudTreble = 22;
  static const loudLowVolRef = 23;
}

/// [ess]: Gerät mit ESS-Wandler (beim DAC: Filterplatz 5 = Brickwall statt
/// SD LD, vgl. RME-Tabelle "DA SD LD (Brickwall)").
/// [ph34]: Phones 3/4, dort wird beim ADI-2/4 auch Rear TRS angeboten.
/// Dessen Datenadresse wird im Controller anhand der gemeldeten Werte gewählt.
List<ParamDef> outputParams(
  Adi2Variant v, {
  required bool phones,
  bool ess = false,
  bool ph34 = false,
}) {
  final source = switch (v) {
    Adi2Variant.dac => const ParamDef(
      OutIdx.source,
      'Quelle',
      max: 5,
      options: [
        'Auto',
        'SPDIF coax',
        'Optical',
        'USB',
        'USB (Rec coax)',
        'USB (Rec opt.)',
      ],
    ),
    Adi2Variant.pro4ex => const ParamDef(
      OutIdx.source,
      'Quelle',
      max: 6,
      options: [
        'Auto',
        'AES',
        'SPDIF',
        'Analog',
        'USB 1/2',
        'USB 3/4',
        'ADAT 3/4',
      ],
    ),
    _ => const ParamDef(
      OutIdx.source,
      'Quelle',
      max: 5,
      options: ['Auto', 'AES', 'SPDIF', 'Analog', 'USB 1/2', 'USB 3/4'],
    ),
  };
  final ref = phones
      ? (v.isPro4
            ? const ParamDef(
                OutIdx.refLevel,
                'Ref Level',
                max: 2,
                def: 1,
                options: ['IEM', 'Lo-Power', 'Hi-Power'],
              )
            : const ParamDef(
                OutIdx.refLevel,
                'Ref Level',
                max: 1,
                options: ['Lo-Power', 'Hi-Power'],
              ))
      : switch (v) {
          Adi2Variant.dac => const ParamDef(
            OutIdx.refLevel,
            'Ref Level',
            max: 3,
            def: 2,
            options: ['-5 dBu', '+1 dBu', '+7 dBu', '+13 dBu'],
          ),
          Adi2Variant.pro => const ParamDef(
            OutIdx.refLevel,
            'Ref Level',
            max: 3,
            def: 2,
            options: ['+4 dBu', '+13 dBu', '+19 dBu', '+24 dBu'],
          ),
          _ => const ParamDef(
            OutIdx.refLevel,
            'Ref Level',
            max: 4,
            def: 1,
            options: ['+1 dBu', '+7 dBu', '+13 dBu', '+19 dBu', '+24 dBu'],
          ),
        };
  final daFilter = switch (v) {
    Adi2Variant.dac => ParamDef(
      OutIdx.daFilter,
      'DA-Filter',
      max: 5,
      options: [
        'SD Sharp',
        'SD Slow',
        'Sharp',
        'Slow',
        'NOS',
        ess ? 'Brickwall' : 'SD LD',
      ],
    ),
    Adi2Variant.pro => const ParamDef(
      OutIdx.daFilter,
      'DA-Filter',
      max: 5,
      options: ['SD Sharp', 'SD Slow', 'Sharp', 'Slow', 'NOS', 'SD LD'],
    ),
    _ => const ParamDef(
      OutIdx.daFilter,
      'DA-Filter',
      max: 6,
      def: 2,
      options: [
        'SD Sharp',
        'SD Slow',
        'Sharp',
        'Slow',
        'SD LD',
        'Brickwall',
        'NOS',
      ],
    ),
  };
  final loopback = v.isDac
      ? const ParamDef(
          OutIdx.loopback,
          'Loopback zu USB',
          max: 3,
          options: ['Aus', 'pre FX', 'post FX', 'post -6dB'],
        )
      : const ParamDef(
          OutIdx.loopback,
          'Loopback zu USB',
          max: 9,
          options: [
            'Aus',
            'pre FX → 1/2',
            'post FX → 1/2',
            'post 1/2 -6dB',
            'pre FX → 3/4',
            'post FX → 3/4',
            'post 3/4 -6dB',
            'pre FX → 5/6',
            'post FX → 5/6',
            'post 5/6 -6dB',
          ],
        );
  return [
    source,
    ref,
    const ParamDef(
      OutIdx.autoRef,
      'Auto Ref Level',
      max: 1,
      def: 1,
      options: _onOff,
    ),
    const ParamDef(
      OutIdx.volume,
      'Lautstärke',
      min: -1145,
      max: 60,
      def: -100,
      scale: 0.1,
      unit: 'dB',
      decimals: 1,
    ),
    const ParamDef(OutIdx.mute, 'Mute', max: 1, options: _onOff),
    const ParamDef(OutIdx.dim, 'Dim', max: 1, options: _onOff),
    const ParamDef(
      OutIdx.lockVolume,
      'Lautstärke sperren',
      max: 1,
      options: _onOff,
    ),
    const ParamDef(
      OutIdx.balance,
      'Balance',
      min: -100,
      max: 100,
      scale: 0.01,
      decimals: 2,
    ),
    const ParamDef(
      OutIdx.mono,
      'Mono',
      max: 2,
      options: ['Aus', 'An', 'nach Links'],
    ),
    const ParamDef(
      OutIdx.width,
      'Stereobreite',
      min: -100,
      max: 100,
      def: 100,
      scale: 0.01,
      decimals: 2,
    ),
    const ParamDef(OutIdx.msProc, 'M/S-Proc', max: 1, options: _onOff),
    const ParamDef(
      OutIdx.polarity,
      'Polarität',
      max: 3,
      options: ['Aus', 'Beide', 'Links', 'Rechts'],
    ),
    const ParamDef(
      OutIdx.crossfeed,
      'Crossfeed',
      max: 5,
      options: ['Aus', '1', '2', '3', '4', '5'],
    ),
    daFilter,
    const ParamDef(
      OutIdx.deEmphasis,
      'De-Emphasis',
      max: 2,
      options: ['Auto', 'An', 'Aus'],
    ),
    const ParamDef(OutIdx.dualEq, 'Dual EQ', max: 1, options: _onOff),
    loopback,
    const ParamDef(
      OutIdx.dcProtection,
      'Dig. DC-Schutz',
      max: 2,
      def: 2,
      options: ['Aus', 'An', 'Filter'],
    ),
    if (v.isPro4 && (!phones || ph34))
      const ParamDef(
        OutIdx.rearTrsSource,
        'Rear TRS Quelle',
        max: 1,
        options: ['Line 1/2', 'Ph. 3/4'],
      ),
    const ParamDef(OutIdx.loudness, 'Loudness', max: 1, options: _onOff),
    const ParamDef(
      OutIdx.loudBass,
      'Loudness Bass',
      min: 2,
      max: 20,
      def: 14,
      scale: 0.5,
      unit: 'dB',
      decimals: 1,
    ),
    const ParamDef(
      OutIdx.loudTreble,
      'Loudness Höhen',
      min: 2,
      max: 20,
      def: 14,
      scale: 0.5,
      unit: 'dB',
      decimals: 1,
    ),
    const ParamDef(
      OutIdx.loudLowVolRef,
      'Loudness Low Vol Ref',
      min: -180,
      max: -40,
      def: -60,
      scale: 0.5,
      unit: 'dB',
      decimals: 1,
    ),
  ];
}

// ---------------------------------------------------------------------------
// Eingang (Adresse 0) – nur ADI-2 Pro und ADI-2/4

List<ParamDef> inputParams(Adi2Variant v) {
  final ref = switch (v) {
    Adi2Variant.pro4ex => const ParamDef(
      1,
      'Ref Level',
      min: -6,
      max: 4,
      def: 2,
      options: null,
    ),
    Adi2Variant.pro => const ParamDef(
      1,
      'Ref Level',
      max: 3,
      def: 2,
      options: ['+4 dBu', '+13 dBu', '+19 dBu', '+24 dBu'],
    ),
    _ => const ParamDef(
      1,
      'Ref Level',
      max: 4,
      def: 2,
      options: ['+1 dBu', '+7 dBu', '+13 dBu', '+19 dBu', '+24 dBu'],
    ),
  };
  return [
    ref,
    const ParamDef(2, 'Auto Ref Level', max: 1, options: _onOff),
    const ParamDef(
      3,
      'Trim Gain Links',
      max: 12,
      scale: 0.5,
      unit: 'dB',
      decimals: 1,
    ),
    const ParamDef(
      4,
      'Trim Gain Rechts',
      max: 12,
      scale: 0.5,
      unit: 'dB',
      decimals: 1,
    ),
    const ParamDef(
      5,
      'Phase Invert',
      max: 3,
      options: ['Aus', 'Beide', 'Links', 'Rechts'],
    ),
    const ParamDef(6, 'M/S-Proc', max: 1, options: _onOff),
    const ParamDef(
      7,
      'AD-Filter',
      max: 3,
      def: 2,
      options: ['SD Sharp', 'SD Slow', 'Sharp', 'Slow'],
    ),
    const ParamDef(8, 'Dual EQ', max: 1, options: _onOff),
    const ParamDef(9, 'AD-Wandlung', max: 1, options: ['PCM', 'DSD']),
    switch (v) {
      Adi2Variant.pro => const ParamDef(
        10,
        'DC-Filter',
        max: 3,
        options: ['Auto', 'ADC', 'RME', 'keiner'],
      ),
      Adi2Variant.pro4ex => const ParamDef(
        10,
        'DC-Filter',
        max: 2,
        options: ['ADC', 'RME', 'keiner'],
      ),
      _ => const ParamDef(10, 'DC-Filter', max: 1, options: ['RME', 'keiner']),
    },
    if (v == Adi2Variant.pro4se)
      const ParamDef(
        11,
        'RIAA-Modus',
        max: 5,
        options: ['Aus', '+14 dB', '+20 dB', '+26 dB', '+32 dB', '+38 dB'],
      ),
    if (v == Adi2Variant.pro4ex)
      const ParamDef(
        11,
        'RIAA-Modus',
        max: 6,
        options: [
          'Aus',
          '0 dB',
          '+14 dB',
          '+20 dB',
          '+26 dB',
          '+32 dB',
          '+38 dB',
        ],
      ),
    if (v.isPro4)
      const ParamDef(12, 'RIAA Mono Bass', max: 1, options: ['Aus', 'Mono']),
    if (v == Adi2Variant.pro4ex)
      const ParamDef(13, 'Bal. Impedanz', max: 1, options: ['94 k', '47 k']),
  ];
}

/// Anzeige für den EX-Eingangspegel (-6..4).
const exInputRef = [
  '-35 dBu',
  '-29 dBu',
  '-23 dBu',
  '-17 dBu',
  '-11 dBu',
  '-5 dBu',
  '+1 dBu',
  '+7 dBu',
  '+13 dBu',
  '+19 dBu',
  '+24 dBu',
];

// ---------------------------------------------------------------------------
// Geräte-Parameter (Adresse 12)

abstract final class DevIdx {
  static const meterColor = 33;
  static const clockSource = 15;
  static const sampleRate = 16;
  static const loadVolumeWithSetup = 62;
  static const doToggleOutputs = 63;
}

/// [ess]: Gerät mit ESS-Wandler – dort gibt es kein DSD Direct.
List<ParamDef> deviceParams(Adi2Variant v, {bool ess = false}) {
  final notDac = !v.isDac;
  return [
    if (v.isDac)
      const ParamDef(
        1,
        'Line stumm bei',
        max: 3,
        def: 1,
        options: ['Aus', 'Phones', 'Toggle Ph/Line', 'Toggle eingesteckt'],
      ),
    const ParamDef(
      2,
      'Auto-Standby',
      max: 4,
      options: ['Aus', '30 min', '1 h', '2 h', '4 h'],
    ),
    const ParamDef(3, 'DSD-Erkennung', max: 1, def: 1, options: _onOff),
    const ParamDef(4, 'DSD-Filter', max: 1, options: ['50 kHz', '150 kHz']),
    if (!v.isPro4 && !ess)
      const ParamDef(5, 'DSD Direct (Line)', max: 1, options: _onOff),
    if (notDac)
      const ParamDef(
        6,
        'Basic Mode',
        max: 5,
        options: ['Auto', 'AD/DA', 'USB', 'Preamp', 'Dig Thru', 'DAC'],
      ),
    if (notDac)
      const ParamDef(
        7,
        'Digital Out Quelle',
        max: 1,
        options: ['Standard', 'Main Out'],
      ),
    if (notDac) const ParamDef(8, 'Dual Phones', max: 1, options: _onOff),
    if (notDac)
      const ParamDef(
        9,
        'Bal. TRS Phones',
        max: 2,
        options: ['Aus', 'An', 'Auto'],
      ),
    if (notDac)
      const ParamDef(
        10,
        'Toggle Phones/Line',
        max: 5,
        options: [
          'Aus',
          'Ph 1/2',
          'Ph 3/4',
          '1/2+3/4',
          'alle eingesteckt',
          'Line/Digit.',
        ],
      ),
    if (notDac)
      const ParamDef(
        11,
        'Line stumm bei Ph 1/2',
        max: 1,
        def: 1,
        options: _onOff,
      ),
    if (notDac)
      const ParamDef(
        12,
        'Line stumm bei Ph 3/4',
        max: 1,
        def: 1,
        options: _onOff,
      ),
    v.isDac
        ? const ParamDef(
            DevIdx.clockSource,
            'Clock-Quelle',
            max: 3,
            options: ['Auto', 'Intern', 'SPDIF coax', 'Optical'],
          )
        : const ParamDef(
            DevIdx.clockSource,
            'Clock-Quelle',
            max: 3,
            options: ['Auto', 'Intern', 'AES', 'SPDIF'],
          ),
    const ParamDef(
      DevIdx.sampleRate,
      'Sample Rate (Anzeige)',
      max: 9,
      def: 1,
      options: [
        '44.1k',
        '48k',
        '88.2k',
        '96k',
        '176.4k',
        '192k',
        '352.8k',
        '384k',
        '705.6k',
        '768k',
      ],
    ),
    if (notDac)
      const ParamDef(
        40,
        'SPDIF-Eingang',
        max: 2,
        options: ['Auto', 'Coax', 'Optical'],
      ),
    if (notDac)
      const ParamDef(
        41,
        'SRC-Modus',
        max: 2,
        def: 2,
        options: ['Aus', 'AES In', 'SPDIF In'],
      ),
    if (notDac)
      const ParamDef(42, 'SRC Gain dig.', max: 1, options: ['0 dB', '-3 dB']),
    if (notDac)
      const ParamDef(
        43,
        'Optical Out Quelle',
        max: 1,
        options: ['SPDIF', 'ADAT'],
      ),
    const ParamDef(
      32,
      'Display-Modus',
      max: 1,
      options: ['Standard', 'Dunkel'],
    ),
    const ParamDef(
      33,
      'Meter-Farbe',
      max: 5,
      options: ['Grün', 'Cyan', 'Amber', 'Mono', 'Rot', 'Orange'],
    ),
    const ParamDef(
      34,
      'Horizontales Meter',
      max: 3,
      options: ['Post-FX', 'Pre-FX', 'Dual', 'Post-FX dBu'],
    ),
    const ParamDef(35, 'AutoDark', max: 1, options: _onOff),
    const ParamDef(
      36,
      'Lautstärke-Bildschirm',
      max: 1,
      def: 1,
      options: _onOff,
    ),
    const ParamDef(
      37,
      'UI sperren',
      max: 3,
      options: ['Aus', 'Remote', 'Tasten', 'Tasten+Remote'],
    ),
    const ParamDef(
      25,
      'Tasten neu belegen',
      max: 2,
      def: 2,
      options: ['Aus', 'An', 'IR-Fernbedienung'],
    ),
    const ParamDef(
      DevIdx.loadVolumeWithSetup,
      'Lautstärke mit Setup laden',
      max: 1,
      options: _onOff,
    ),
    ...remapKeyParams(v),
  ];
}

// ---------------------------------------------------------------------------
// Tastenbelegung (Remap Keys), Liste "Remap-Key Options" im RME-Protokoll.
// Die Funktionsnamen bleiben wie am Gerät englisch.

const _setups = [
  'Default',
  'Setup 1',
  'Setup 2',
  'Setup 3',
  'Setup 4',
  'Setup 5',
  'Setup 6',
  'Setup 7',
  'Setup 8',
  'Setup 9',
];
const _eqPresets9 = [
  'EQ Preset 1',
  'EQ Preset 2',
  'EQ Preset 3',
  'EQ Preset 4',
  'EQ Preset 5',
  'EQ Preset 6',
  'EQ Preset 7',
  'EQ Preset 8',
  'EQ Preset 9',
];

const List<String> remapOptionsDac = [
  ..._setups,
  'Mono',
  'Mono to L',
  'Mute',
  'Loudness',
  'EQ enable',
  'B/T enable',
  'EQ+B/T+Ld',
  'Toggle Ph/Line',
  'Polarity',
  'AutoDark',
  'Dim',
  'Toggle View',
  'Crossfeed 1',
  'Crossfeed 2',
  'Crossfeed 3',
  'Crossfeed 4',
  'Crossfeed 5',
  'DA SD Sharp',
  'DA SD Slow',
  'DA Sharp',
  'DA Slow',
  'DA NOS',
  'DA SD LD (Brickwall)',
  ..._eqPresets9,
];

const _proCommon = [
  'Mono 1/2',
  'Mono 3/4',
  'Mono 1/2 to L',
  'Mono 3/4 to L',
  'Mute 1/2',
  'Mute 3/4',
  'Mute all',
  'Loudness 1/2',
  'Loudness 3/4',
  'EQ In 1/2',
  'EQ Out 1/2',
  'EQ Out 3/4',
  'B/T Out 1/2',
  'B/T Out 3/4',
  'EQ+B/T+Ld 1/2',
  'EQ+B/T+Ld 3/4',
  'Toggle Ph/Line',
  'EQ+B/T+Ld 1-4',
  'Polarity',
  'Crossfeed 1',
  'Crossfeed 2',
  'Crossfeed 3',
  'Crossfeed 4',
  'Crossfeed 5',
  'DA SD Sharp',
  'DA SD Slow',
  'DA Sharp',
  'DA Slow',
];

const List<String> remapOptionsPro = [
  ..._setups,
  ..._proCommon,
  'DA NOS',
  'DA SD LD',
  'Toggle View',
  'DIM',
  'Mono all',
  'Mono all to L',
  'Loudness all',
  'EQ Out all',
  'BT all',
  'Source AES',
  'Source SPDIF coax',
  'Source Optical',
  'Source Analog',
  'Source USB 1/2',
  'AutoDark',
  ..._eqPresets9,
];

const List<String> remapOptionsPro4 = [
  ..._setups,
  ..._proCommon,
  'DA SD LD',
  'Brickwall',
  'DA NOS',
  'Toggle View',
  'DIM',
  'Mono all',
  'Mono all to L',
  'Loudness all',
  'EQ Out all',
  'BT all',
  'Source AES',
  'Source SPDIF coax',
  'Source Optical',
  'Source Analog',
  'Source USB 1/2',
  'AutoDark',
  ..._eqPresets9,
  'RIAA Mode +',
  'RIAA Mode -',
  'RIAA Mono Bass',
];

List<String> remapOptions(Adi2Variant v) =>
    v.isDac ? remapOptionsDac : (v.isPro ? remapOptionsPro : remapOptionsPro4);

/// Indizes der belegbaren Tasten (Geräte-Adresse 12).
const remapKeyIndices = {26, 27, 28, 29, 22, 23, 24};

List<ParamDef> remapKeyParams(Adi2Variant v) {
  final o = remapOptions(v);
  // Werkseinstellung laut RME-Tabelle (VOL, I/O, EQ, SETUP, IR 5, 6, 7)
  final d = v.isDac
      ? const [10, 13, 19, 20]
      : (v.isPro
            ? const [50, 47, 52, 41, 48, 49, 51]
            : const [51, 48, 53, 42, 49, 50, 52]);
  ParamDef key(int idx, String name, int def) =>
      ParamDef(idx, name, max: o.length - 1, def: def, options: o);
  return [
    key(26, 'Taste VOL', d[0]),
    key(27, 'Taste I/O', d[1]),
    key(28, 'Taste EQ', d[2]),
    key(29, 'Taste SETUP', d[3]),
    if (!v.isDac) ...[
      key(22, 'Fernbedienung Taste 5', d[4]),
      key(23, 'Fernbedienung Taste 6', d[5]),
      key(24, 'Fernbedienung Taste 7', d[6]),
    ],
  ];
}

// ---------------------------------------------------------------------------
// EQ (Adressen 1/4/7/10 links, 2/5/8/11 rechts)

abstract final class EqIdx {
  static const enable = 2;
  static const band1Type = 3;
  static const band5Type = 16;
  static const btEnable = 20;
  static const presetSelect = 28;
  static int gain(int band) => const [4, 7, 10, 13, 17][band];
  static int freq(int band) => const [5, 8, 11, 14, 18][band];
  static int q(int band) => const [6, 9, 12, 15, 19][band];
}

/// EQ-Adresse für eine Ausgangs-/Eingangs-Adresse (0,3,6,9).
int eqLeftAddr(int channelAddr) => channelAddr + 1;
int eqRightAddr(int channelAddr) => channelAddr + 2;
