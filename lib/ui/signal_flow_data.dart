import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'theme.dart';

// Reihenfolge entspricht dem bestehenden Basic-Mode-Parameter 6.
enum SignalFlowMode {
  auto('Auto'),
  adda('AD/DA'),
  usb('USB'),
  preamp('Preamp'),
  digThru('Dig Thru'),
  dac('DAC');

  const SignalFlowMode(this.label);
  final String label;
}

enum SignalFlowNodeKind { input, processing, output }

abstract final class SignalFlowColors {
  static const analog = Color(0xFF7F77DD);
  static const aes = Color(0xFFD85A30);
  static const spdif = Color(0xFF378ADD);
  static const usb = Color(0xFFD4537E);
  static const output = Color(0xFF4CC3B8);
  static const neutral = Palette.muted;
}

class SignalFlowNode {
  const SignalFlowNode(this.id, this.rect, this.text, this.kind, this.color);
  final String id;
  final Rect rect;
  final String text;
  final SignalFlowNodeKind kind;
  final Color color;
}

class SignalFlowWire {
  const SignalFlowWire(
    this.from,
    this.to,
    this.points,
    this.color, {
    this.dashed = false,
  });
  // Logical source stays unchanged when the route starts on a shared stem.
  final String from;
  final String to;
  final List<Offset> points;
  final Color color;
  final bool dashed;
}

class SignalFlowDiagram {
  const SignalFlowDiagram({
    required this.nodes,
    required this.wires,
    required this.explanation,
    this.height = 345,
    this.notes = const [],
  });
  static const width = 680.0;
  final double height;
  final List<SignalFlowNode> nodes;
  final List<SignalFlowWire> wires;
  final String explanation;
  final List<String> notes;
}

SignalFlowNode _input(String id, String text, double y, Color color) =>
    SignalFlowNode(
      id,
      Rect.fromLTWH(40, y, 86, 24),
      text,
      SignalFlowNodeKind.input,
      color,
    );

SignalFlowNode _process(
  String id,
  String text,
  double x,
  double y,
  double width,
  double height,
) => SignalFlowNode(
  id,
  Rect.fromLTWH(x, y, width, height),
  text,
  SignalFlowNodeKind.processing,
  Palette.line,
);

SignalFlowNode _output(String id, String text, double y) => SignalFlowNode(
  id,
  Rect.fromLTWH(568, y, 72, 20),
  text,
  SignalFlowNodeKind.output,
  SignalFlowColors.output,
);

SignalFlowWire _wire(
  String from,
  String to,
  List<(double, double)> points, {
  Color color = SignalFlowColors.neutral,
  bool dashed = false,
}) => SignalFlowWire(
  from,
  to,
  [for (final (x, y) in points) Offset(x, y)],
  color,
  dashed: dashed,
);

List<SignalFlowNode> _inputs({
  String usb = 'USB 1/2 · 3/4',
  bool usbFirst = false,
}) => [
  if (usbFirst) _input('usb', usb, 28, SignalFlowColors.usb),
  _input('analog', 'Analog 1/2', 58, SignalFlowColors.analog),
  _input('aes', 'AES', 138, SignalFlowColors.aes),
  _input('coax', 'Coaxial', 184, SignalFlowColors.spdif),
  _input('optical', 'Optical', 218, SignalFlowColors.spdif),
  if (!usbFirst) _input('usb', usb, 270, SignalFlowColors.usb),
];

List<SignalFlowNode> _outputs({double phonesY = 252}) => [
  _output('aesOut', 'AES', 30),
  _output('coaxOut', 'Coaxial', 60),
  _output('opticalOut', 'Optical', 90),
  _output('xlr', 'XLR 1/2', 154),
  _output('ts', 'TS 1/2', 186),
  _output('ph12', 'PH 1/2', 218),
  _output('ph34', 'PH 3/4', phonesY),
];

List<SignalFlowNode> _converters({bool spdif = true, bool digital = true}) => [
  _process('adc', 'ADC/DSP', 164, 56, 94, 28),
  if (spdif) _process('spdif', tr('SPDIF\nAuswahl'), 164, 186, 76, 54),
  if (digital) _process('digital', 'Dig. Out\nSource', 442, 52, 94, 38),
  _process('mainDsp', 'DSP/DAC', 440, 150, 94, 28),
  _process('phonesDsp', 'DSP/DAC', 440, 248, 94, 28),
];

SignalFlowNode _phones() =>
    _process('phones', tr('Quelle\nPhones 3/4'), 320, 230, 82, 64);
SignalFlowNode _main() =>
    _process('main', tr('Quelle\nMain 1/2'), 320, 136, 82, 56);

List<SignalFlowWire> _inputWires() => [
  _wire('analog', 'adc', [
    (126, 70),
    (162, 70),
  ], color: SignalFlowColors.analog),
  _wire('coax', 'spdif', [
    (126, 196),
    (162, 196),
  ], color: SignalFlowColors.spdif),
  _wire('optical', 'spdif', [
    (126, 230),
    (162, 230),
  ], color: SignalFlowColors.spdif),
];

List<SignalFlowWire> _phonesInputs({bool digitalBranches = false}) => [
  _wire('adc', 'phones', [
    (258, 70),
    (272, 70),
    (272, 240),
    (318, 240),
  ], color: SignalFlowColors.analog),
  _wire('aes', 'phones', [
    if (!digitalBranches) (126, 150),
    (284, 150),
    (284, 254),
    (318, 254),
  ], color: SignalFlowColors.aes),
  _wire('spdif', 'phones', [
    if (!digitalBranches) (240, 213),
    (296, 213),
    (296, 268),
    (318, 268),
  ], color: SignalFlowColors.spdif),
  _wire('usb', 'phones', [(126, 282), (318, 282)], color: SignalFlowColors.usb),
];

List<SignalFlowWire> _analogOutputs() => [
  _wire('phones', 'phonesDsp', [(402, 262), (438, 262)]),
  _wire('mainDsp', 'xlr', [(534, 164), (566, 164)]),
  _wire('mainDsp', 'ts', [(550, 164), (550, 196), (566, 196)]),
  _wire('mainDsp', 'ph12', [(550, 196), (550, 228), (566, 228)]),
  _wire('phonesDsp', 'ph34', [(534, 262), (566, 262)]),
];

List<SignalFlowWire> _digitalOutputs() => [
  _wire('digital', 'coaxOut', [(536, 70), (566, 70)]),
  _wire('digital', 'aesOut', [(550, 70), (550, 40), (566, 40)]),
  _wire('digital', 'opticalOut', [(550, 70), (550, 100), (566, 100)]),
  _wire('mainDsp', 'digital', [(486, 148), (486, 92)], dashed: true),
];

String get _recordNote => tr(
  'USB-Aufnahme nicht gezeigt. Alle Eingänge werden an USB übertragen, im Stereo-Modus nur Analog 1/2, im Mehrkanal-Modus drei Stereopaare.',
);
String get _usb34Note => tr(
  'USB Playback 3/4 ist nur im Mehrkanal-Modus separat verfügbar. Im Stereo-Modus spielt die Auswahl USB 3/4 die Kanäle 1/2.',
);
String get _digitalNote => tr(
  'Gestrichelt bedeutet Digital Out Source – Main Out. Diese Option legt das bearbeitete Main-Out-Signal auf die digitalen Ausgänge.',
);

/// Geometrie und Farben von AD/DA folgen signalflow_adda.svg (680 × 345).
/// Die Vorlage lässt vor Kacheln einen Abstand von zwei Koordinateneinheiten.
SignalFlowDiagram signalFlowDiagram(
  SignalFlowMode mode, {
  bool usbMulti = false,
}) {
  switch (mode) {
    case SignalFlowMode.auto:
      return SignalFlowDiagram(
        nodes: const [],
        wires: const [],
        explanation: tr(
          'Auto wählt anhand der angeschlossenen Quellen den Betriebsmodus. USB hat Vorrang vor einem Digitalsignal, Dig Thru und DAC sind nur manuell wählbar.',
        ),
      );
    case SignalFlowMode.adda:
      return SignalFlowDiagram(
        nodes: [
          ..._inputs(),
          ..._converters(),
          _main(),
          _phones(),
          ..._outputs(),
        ],
        wires: [
          ..._inputWires(),
          _wire('adc', 'digital', [
            (272, 70),
            (440, 70),
          ], color: SignalFlowColors.analog),
          _wire('adc', 'main', [
            (272, 164),
            (318, 164),
          ], color: SignalFlowColors.analog),
          _wire('aes', 'main', [
            (126, 150),
            (318, 150),
          ], color: SignalFlowColors.aes),
          _wire('spdif', 'main', [
            (240, 213),
            (296, 213),
            (296, 178),
            (318, 178),
          ], color: SignalFlowColors.spdif),
          ..._phonesInputs(digitalBranches: true),
          _wire('main', 'mainDsp', [(402, 164), (438, 164)]),
          ..._analogOutputs(),
          ..._digitalOutputs(),
        ],
        explanation: tr(
          'Analog wird an alle digitalen Ausgänge gesendet, die gewählte digitale Quelle an die analogen Ausgänge. Phones 3/4 kann unabhängig eine andere Quelle wiedergeben.',
        ),
        notes: [_recordNote, _usb34Note, _digitalNote],
      );
    case SignalFlowMode.preamp:
      return SignalFlowDiagram(
        nodes: [..._inputs(), ..._converters(), _phones(), ..._outputs()],
        wires: [
          ..._inputWires(),
          _wire('adc', 'digital', [
            (272, 70),
            (440, 70),
          ], color: SignalFlowColors.analog),
          _wire('adc', 'mainDsp', [
            (272, 164),
            (438, 164),
          ], color: SignalFlowColors.analog),
          ..._phonesInputs(),
          ..._analogOutputs(),
          ..._digitalOutputs(),
        ],
        explanation: tr(
          'Der Analogeingang speist die analogen und digitalen Ausgänge. Eingangs-DSP wirkt auf alle diese Wege, die analogen Ausgangseinstellungen wirken anschließend unabhängig.',
        ),
        notes: [
          _recordNote,
          _usb34Note,
          tr(
            'Digital Out Source ist in Dig Thru und Preamp am Gerät und in der App ausgegraut und dort nicht wählbar.',
          ),
        ],
      );
    case SignalFlowMode.usb:
      return usbMulti ? _usbMulti() : _usbStereo();
    case SignalFlowMode.digThru:
      return SignalFlowDiagram(
        nodes: [
          ..._inputs(),
          ..._converters(digital: false),
          _main(),
          _phones(),
          ..._outputs(),
        ],
        wires: [
          ..._inputWires(),
          _wire('aes', 'main', [
            (126, 150),
            (318, 150),
          ], color: SignalFlowColors.aes),
          _wire('spdif', 'main', [
            (240, 213),
            (296, 213),
            (296, 178),
            (318, 178),
          ], color: SignalFlowColors.spdif),
          _wire('main', 'mainDsp', [(402, 164), (438, 164)]),
          _wire('main', 'coaxOut', [(418, 164), (418, 70), (566, 70)]),
          _wire('main', 'aesOut', [(550, 70), (550, 40), (566, 40)]),
          _wire('main', 'opticalOut', [(550, 70), (550, 100), (566, 100)]),
          ..._phonesInputs(digitalBranches: true),
          ..._analogOutputs(),
        ],
        explanation: tr(
          'Die gewählte digitale Quelle wird an alle digitalen Ausgänge weitergereicht und analog abgehört. Ohne SRC bleiben die 24-Bit-Audiodaten unverändert, bei ADAT werden alle acht Kanäle durchgereicht und nur 1/2 abgehört.',
        ),
        notes: [
          _recordNote,
          _usb34Note,
          tr(
            'Nur manuell wählbar. Digital Out Source ist in Dig Thru und Preamp am Gerät und in der App ausgegraut und dort nicht wählbar.',
          ),
        ],
      );
    case SignalFlowMode.dac:
      return _dac();
  }
}

SignalFlowDiagram _usbStereo() => SignalFlowDiagram(
  height: 365,
  nodes: [
    ..._inputs(usb: 'USB 1/2', usbFirst: true),
    ..._converters(),
    _phones(),
    ..._outputs(),
    _output('record12', 'USB Rec 1/2', 318),
  ],
  wires: [
    ..._inputWires(),
    ..._phonesInputs().where((w) => w.from != 'usb'),
    // Branch to Phones directly above its tile, alongside the output DSP stem.
    _wire('usb', 'digital', [
      (126, 40),
      (420, 40),
      (420, 70),
      (440, 70),
    ], color: SignalFlowColors.usb),
    _wire('usb', 'mainDsp', [
      (420, 70),
      (420, 164),
      (438, 164),
    ], color: SignalFlowColors.usb),
    _wire('usb', 'phones', [
      (360, 40),
      (360, 228),
    ], color: SignalFlowColors.usb),
    _wire('adc', 'record12', [
      (272, 240),
      (272, 328),
      (566, 328),
    ], color: SignalFlowColors.analog),
    ..._analogOutputs(),
    ..._digitalOutputs(),
  ],
  explanation: tr(
    'USB-Stereo sendet nur Analog 1/2 zur Aufnahme an den Host. USB Playback 1/2 speist alle analogen und digitalen Ausgänge, Phones 3/4 bleibt frei umschaltbar.',
  ),
  notes: [
    _usb34Note,
    tr(
      'Digitale Eingänge werden im USB-Stereo-Modus nur lokal gemessen und können über Phones 3/4 abgehört werden.',
    ),
    _digitalNote,
  ],
);

// Keep the shared analog layout below the expanded digital routing area.
SignalFlowWire _lowerMultiWire(SignalFlowWire wire) => SignalFlowWire(
  wire.from,
  wire.to,
  [for (final point in wire.points) point + const Offset(0, 100)],
  wire.color,
  dashed: wire.dashed,
);

SignalFlowDiagram _usbMulti() => SignalFlowDiagram(
  height: 554,
  nodes: [
    // Order USB pairs by their destinations, keeping distinct streams apart.
    _input('usb56', 'USB 5/6', 28, SignalFlowColors.usb),
    _input('usb78', 'USB 7/8', 106, SignalFlowColors.usb),
    _input('usb12', 'USB 1/2', 154, SignalFlowColors.usb),
    _input('usb34', 'USB 3/4', 194, SignalFlowColors.usb),
    _input('analog', 'Analog 1/2', 236, SignalFlowColors.analog),
    _input('aes', 'AES', 282, SignalFlowColors.aes),
    _input('coax', 'Coaxial', 328, SignalFlowColors.spdif),
    _input('optical', 'Optical', 362, SignalFlowColors.spdif),
    _process('adc', 'ADC/DSP', 164, 234, 94, 28),
    _process('spdif', tr('SPDIF\nAuswahl'), 164, 330, 76, 54),
    _process('digitalAes', 'AES · 5/6', 420, 28, 114, 24),
    _process('digitalSpdif', 'SPDIF · 7/8', 420, 100, 114, 38),
    _process('mainDsp', 'DSP/DAC', 440, 250, 94, 28),
    _process('phones', tr('Quelle\nPhones 3/4'), 320, 330, 82, 104),
    _process('phonesDsp', 'DSP/DAC', 440, 370, 94, 28),
    _output('aesOut', 'AES', 30),
    _output('coaxOut', 'Coaxial', 90),
    _output('opticalOut', 'Optical', 140),
    ..._outputs(phonesY: 274)
        .where((n) => !['aesOut', 'coaxOut', 'opticalOut'].contains(n.id))
        .map(
          (n) => SignalFlowNode(
            n.id,
            n.rect.shift(const Offset(0, 100)),
            n.text,
            n.kind,
            n.color,
          ),
        ),
    _output('record12', 'USB Rec 1/2', 446),
    _output('record34', 'USB Rec 3/4', 480),
    _output('record56', 'USB Rec 5/6', 514),
  ],
  wires: [
    _wire('analog', 'adc', [
      (126, 248),
      (162, 248),
    ], color: SignalFlowColors.analog),
    _wire('coax', 'spdif', [
      (126, 340),
      (162, 340),
    ], color: SignalFlowColors.spdif),
    _wire('optical', 'spdif', [
      (126, 374),
      (162, 374),
    ], color: SignalFlowColors.spdif),
    _wire('adc', 'phones', [
      (258, 248),
      (272, 248),
      (272, 340),
      (318, 340),
    ], color: SignalFlowColors.analog),
    _wire('aes', 'phones', [
      (126, 294),
      (284, 294),
      (284, 354),
      (318, 354),
    ], color: SignalFlowColors.aes),
    _wire('spdif', 'phones', [
      (240, 370),
      (296, 370),
      (296, 398),
      (318, 398),
    ], color: SignalFlowColors.spdif),
    _wire('usb12', 'mainDsp', [
      (126, 166),
      (376, 166),
      (376, 218),
      (416, 218),
      (416, 264),
      (438, 264),
    ], color: SignalFlowColors.usb),
    _wire('usb12', 'phones', [
      (376, 218),
      (376, 328),
    ], color: SignalFlowColors.usb),
    _wire('usb34', 'phones', [
      (126, 206),
      (340, 206),
      (340, 328),
    ], color: SignalFlowColors.usb),
    _wire('usb56', 'digitalAes', [
      (126, 40),
      (418, 40),
    ], color: SignalFlowColors.usb),
    _wire('usb78', 'digitalSpdif', [
      (126, 118),
      (418, 118),
    ], color: SignalFlowColors.usb),
    _wire('digitalAes', 'aesOut', [(534, 40), (566, 40)]),
    _wire('digitalSpdif', 'coaxOut', [
      (534, 118),
      (550, 118),
      (550, 100),
      (566, 100),
    ]),
    _wire('digitalSpdif', 'opticalOut', [(550, 118), (550, 150), (566, 150)]),
    _wire('mainDsp', 'digitalAes', [
      (486, 248),
      (486, 190),
      (404, 190),
      (404, 70),
      (476, 70),
      (476, 54),
    ], dashed: true),
    _wire('mainDsp', 'digitalSpdif', [(486, 190), (486, 140)], dashed: true),
    _wire('adc', 'record12', [
      (272, 340),
      (272, 456),
      (566, 456),
    ], color: SignalFlowColors.analog),
    _wire('aes', 'record34', [
      (284, 354),
      (284, 490),
      (566, 490),
    ], color: SignalFlowColors.aes),
    _wire('spdif', 'record56', [
      (296, 398),
      (296, 524),
      (566, 524),
    ], color: SignalFlowColors.spdif),
    ..._analogOutputs().where((w) => w.from == 'mainDsp').map(_lowerMultiWire),
    _wire('phones', 'phonesDsp', [(402, 384), (438, 384)]),
    _wire('phonesDsp', 'ph34', [(534, 384), (566, 384)]),
  ],
  explanation: tr(
    'USB-Mehrkanal überträgt sechs Aufnahme- und acht Wiedergabekanäle getrennt. Phones 3/4 folgt bei Quelle Auto USB 1/2 und kann unter anderem auf USB 3/4 umgeschaltet werden.',
  ),
  notes: [
    tr(
      'Aufnahme 1/2 = Analog, 3/4 = AES, 5/6 = SPDIF (ADAT). Wiedergabe 1/2 = Analog 1/2, 3/4 = Analog 3/4, 5/6 = AES, 7/8 = SPDIF (ADAT).',
    ),
    _digitalNote,
    tr(
      'Mit Digital Out Source – Main Out entfallen die separaten Wiedergabekanäle 5/6 und 7/8. Mehrkanal ist bis 192 kHz verfügbar.',
    ),
  ],
);

SignalFlowDiagram _dac() => SignalFlowDiagram(
  height: 365,
  nodes: [
    ..._inputs(usb: 'USB 1/2', usbFirst: true),
    ..._converters(spdif: false),
    _process('main', tr('Quelle\nMain 1/2'), 320, 136, 82, 94),
    ..._outputs(),
    _output('record12', 'USB Rec 1/2', 318),
  ],
  wires: [
    _wire('analog', 'adc', [
      (126, 70),
      (162, 70),
    ], color: SignalFlowColors.analog),
    _wire('adc', 'main', [
      (258, 70),
      (272, 70),
      (272, 164),
      (318, 164),
    ], color: SignalFlowColors.analog),
    _wire('aes', 'main', [(126, 150), (318, 150)], color: SignalFlowColors.aes),
    _wire('coax', 'main', [
      (126, 196),
      (296, 196),
      (296, 178),
      (318, 178),
    ], color: SignalFlowColors.spdif),
    _wire('optical', 'main', [
      (126, 230),
      (308, 230),
      (308, 192),
      (318, 192),
    ], color: SignalFlowColors.spdif),
    _wire('usb', 'main', [(360, 40), (360, 134)], color: SignalFlowColors.usb),
    _wire('usb', 'digital', [
      (126, 40),
      (420, 40),
      (420, 70),
      (440, 70),
    ], color: SignalFlowColors.usb),
    _wire('adc', 'record12', [
      (272, 164),
      (272, 328),
      (566, 328),
    ], color: SignalFlowColors.analog),
    _wire('main', 'mainDsp', [(402, 164), (438, 164)]),
    _wire('main', 'phonesDsp', [(418, 164), (418, 262), (438, 262)]),
    ..._analogOutputs().where((w) => w.from != 'phones'),
    ..._digitalOutputs(),
  ],
  explanation: tr(
    'DAC koppelt die Clock an die gewählte Main-Out-Quelle. Phones 3/4 hört immer dieselbe Quelle wie Main Out 1/2, behält aber unabhängige Lautstärke- und EQ-Einstellungen.',
  ),
  notes: [
    tr(
      'Gezeigt ist USB-Stereo mit Analog 1/2 als Aufnahmequelle. Im Mehrkanalbetrieb sind drei Aufnahme- und vier Wiedergabe-Stereopaare verfügbar, die analogen Ausgänge können gemeinsam entweder USB 1/2 oder 3/4 abhören.',
    ),
    _digitalNote,
    tr(
      'DAC ist nur manuell wählbar. Die AD-Wandlung verwendet die zuletzt über USB eingestellte Sample Rate.',
    ),
  ],
);
