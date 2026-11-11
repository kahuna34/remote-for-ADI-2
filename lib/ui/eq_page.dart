import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../l10n/l10n.dart';
import '../device/adi2_controller.dart';
import '../eq/eq_math.dart';
import '../eq/eq_model.dart';
import '../eq/eq_plot_scale.dart';
import '../protocol/adi2_params.dart';
import 'theme.dart';
import 'eq_display_mode.dart';
import 'responsive_layout.dart';

part 'eq_fullscreen.dart';

/// Equalizer für einen Kanal (Ausgang oder Eingang).
/// [channelAddr]: 0 Eingang, 3 Line, 6 Phones 1/2, 9 Phones 3/4.
class EqPage extends StatefulWidget {
  const EqPage({
    super.key,
    required this.ctrl,
    required this.channelAddr,
    required this.title,
    this.embedded = false,
  });
  final Adi2Controller ctrl;
  final int channelAddr;
  final String title;
  final bool embedded;

  @override
  State<EqPage> createState() => _EqPageState();
}

class _EqPageState extends State<EqPage> {
  int _band = 0;
  bool _right = false;
  bool _includeBassTreble = true;

  Adi2Controller get c => widget.ctrl;
  int get _left => widget.channelAddr + 1;
  int get _rightAddr => widget.channelAddr + 2;
  bool get _dual =>
      c.valueOr(
        widget.channelAddr,
        widget.channelAddr == 0 ? 8 : OutIdx.dualEq,
        0,
      ) !=
      0;
  int get _eqAddr => (_dual && _right) ? _rightAddr : _left;

  int _v(int addr, int idx, int def) => c.eqValue(addr, idx) ?? def;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (c.variant == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(child: Text(tr('Nicht verbunden'))),
          );
        }
        final enabled = _v(_left, EqIdx2.enable, 0) != 0;
        final presetSel = _v(_left, EqIdx2.presetSelect, 0);
        final editor = SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Panel(
                      child: InkWell(
                        onTap: () => _pickPreset(presetSel),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _presetLabel(presetSel),
                                  overflow: TextOverflow.ellipsis,
                                  style: ts(15, weight: 500),
                                ),
                              ),
                              const Icon(
                                Icons.chevron_right,
                                color: Palette.muted,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Switch(
                    value: enabled,
                    onChanged: (on) => c.set(_left, EqIdx2.enable, on ? 1 : 0),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              EqDualControls(
                dual: _dual,
                right: _right,
                onDualChanged: (on) => c.set(
                  widget.channelAddr,
                  widget.channelAddr == 0 ? 8 : OutIdx.dualEq,
                  on ? 1 : 0,
                ),
                onSideChanged: (r) => setState(() => _right = r),
                onClear: _confirmReset,
              ),
              const SizedBox(height: 6),
              EqPlot(
                glide: c.viaHost
                    ? const Duration(milliseconds: 700)
                    : const Duration(milliseconds: 120),
                read: c.eqValue,
                write: c.setEq,
                eqAddr: _eqAddr,
                btAddr: _left,
                selected: _band,
                enabled: enabled,
                includeBassTreble: _includeBassTreble,
                onSelect: (i) => setState(() => _band = i),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  tr('Punkte ziehen: seitwärts Frequenz, hoch/runter Gain'),
                  style: ts(12, color: Palette.muted, narrow: true),
                ),
              ),
              EqBandChips(
                selected: _band,
                onSelect: (i) => setState(() => _band = i),
              ),
              const SizedBox(height: 6),
              EqBandControls(
                band: _band,
                address: eqBands[_band].isBassTreble ? _left : _eqAddr,
                read: c.eqValue,
                write: c.setEq,
                bassTrebleEnabled: _v(_left, EqIdx2.btEnable, 1) != 0,
                onBassTrebleEnabled: (on) =>
                    c.set(_left, EqIdx2.btEnable, on ? 1 : 0),
              ),
              EqCurveControls(
                includeBassTreble: _includeBassTreble,
                onChanged: (on) => setState(() => _includeBassTreble = on),
              ),
              const SizedBox(height: 6),
              FilledButton(
                onPressed: () => _storePreset(presetSel),
                child: Text(tr('Als Preset speichern')),
              ),
            ],
          ),
        );
        if (widget.embedded) return editor;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('Equalizer')),
                Text(
                  widget.title,
                  style: ts(
                    13,
                    weight: 500,
                    color: Palette.muted,
                    narrow: true,
                  ),
                ),
              ],
            ),
          ),
          body: TabletContent(child: editor),
        );
      },
    );
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('EQ zurücksetzen?')),
        content: Text(
          trf(
            'Alle Bänder von {name} werden auf 0 dB (linear) gestellt. Gespeicherte Presets bleiben erhalten.',
            {'name': widget.title},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Abbrechen')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Clear')),
          ),
        ],
      ),
    );
    if (ok == true) c.resetEq(widget.channelAddr);
  }

  String _presetLabel(int sel) => switch (sel) {
    0 => tr('Manuell (nicht gespeichert)'),
    1 => tr('Temp (geändertes Preset)'),
    22 => tr('Zurückgesetzt (linear)'),
    23 => tr('Rumpelfilter'),
    _ => trf('Preset {n}: {name}', {
      'n': sel - 1,
      'name': c.presetName(sel - 2),
    }),
  };

  Future<void> _pickPreset(int sel) async {
    final max = c.variant!.isPro4 ? 23 : 22;
    final picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (ctx, sc) => ListView(
          controller: sc,
          children: [
            // Immer dieselben Zeilen: Erschiene „Temp“ nur zeitweise, rutschten
            // die Presets darunter und ein Tipp träfe das falsche.
            for (var i = 0; i <= max; i++)
              ListTile(
                enabled: i != 1 || sel == 1,
                title: Text(_presetLabel(i)),
                trailing: i == sel
                    ? const Icon(Icons.check, color: Palette.amber)
                    : null,
                onTap: () => Navigator.pop(ctx, i),
              ),
          ],
        ),
      ),
    );
    if (picked != null) unawaited(c.loadEqPreset(_left, picked));
  }

  Future<void> _storePreset(int sel) async {
    var slot = (sel >= 2 && sel <= 21) ? sel - 2 : 0;
    final nameCtl = TextEditingController(text: c.presetName(slot));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(tr('Als Preset speichern')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButton<int>(
                value: slot,
                isExpanded: true,
                dropdownColor: Palette.surf2,
                items: [
                  for (var n = 0; n < 20; n++)
                    DropdownMenuItem(
                      value: n,
                      child: Text(
                        trf('Preset {n}: {name}', {
                          'n': n + 1,
                          'name': c.presetName(n),
                        }),
                      ),
                    ),
                ],
                onChanged: (n) => setD(() {
                  slot = n!;
                  nameCtl.text = c.presetName(n);
                }),
              ),
              TextField(
                controller: nameCtl,
                maxLength: 16,
                decoration: InputDecoration(labelText: tr('Name')),
              ),
              Text(
                tr('Das Preset im Gerät wird überschrieben.'),
                style: ts(13, color: Palette.muted),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Abbrechen')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Speichern')),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      await c.storeEqPreset(_left, _rightAddr, slot, nameCtl.text, _dual);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Gespeichert als Preset {n}', {'n': slot + 1})),
          ),
        );
      }
    }
  }
}

/// Gemeinsame Bandregler für Live-EQ und Editor-Puffer.
class EqBandControls extends StatelessWidget {
  const EqBandControls({
    super.key,
    required this.band,
    required this.address,
    required this.read,
    required this.write,
    this.showType = true,
    this.compact = false,
    this.bassTrebleEnabled = true,
    this.onBassTrebleEnabled,
  });
  final int band, address;
  final int? Function(int address, int index) read;
  final void Function(int address, int index, int raw) write;
  final bool showType, bassTrebleEnabled;
  final bool compact;
  final ValueChanged<bool>? onBassTrebleEnabled;

  int _value(int address, int index, int fallback) =>
      read(address, index) ?? fallback;

  @override
  Widget build(BuildContext context) {
    final i = band;
    final b = eqBands[i];
    final a = address;
    final typeRaw = b.typeIdx == null ? null : _value(a, b.typeIdx!, 0);
    final kind = b.kindFor(typeRaw);
    final hasGain = kind != FilterKind.highPass && kind != FilterKind.lowPass;
    final gain = _value(a, b.gainIdx, 0);
    final freq = _value(a, b.freqIdx, b.defF);
    final q = _value(a, b.qIdx, (b.defQ * 10).round());
    final parameters = <Widget>[
      if (hasGain || compact)
        _ParamRow(
          compact: compact,
          enabled: hasGain,
          label: tr('Gain'),
          value: fmtGain(gain),
          color: Palette.bands[i],
          pos: (gain - eqGainMinRaw) / (eqGainMaxRaw - eqGainMinRaw),
          onSlide: (n) => write(
            a,
            b.gainIdx,
            (eqGainMinRaw + n * (eqGainMaxRaw - eqGainMinRaw)).round(),
          ),
          onMinus: () =>
              write(a, b.gainIdx, (gain - 1).clamp(eqGainMinRaw, eqGainMaxRaw)),
          onPlus: () =>
              write(a, b.gainIdx, (gain + 1).clamp(eqGainMinRaw, eqGainMaxRaw)),
        ),
      _ParamRow(
        compact: compact,
        label: tr(compact ? 'Freq' : 'Frequenz'),
        value: fmtFreq(freq),
        color: Palette.bands[i],
        pos: math.log(freq / b.minF) / math.log(b.maxF / b.minF),
        onSlide: (n) => write(
          a,
          b.freqIdx,
          snapFreq(b, b.minF * math.pow(b.maxF / b.minF, n).toDouble()),
        ),
        onMinus: () => write(a, b.freqIdx, stepFreq(b, freq, -1)),
        onPlus: () => write(a, b.freqIdx, stepFreq(b, freq, 1)),
      ),
      _ParamRow(
        compact: compact,
        enabled: b.maxQ > b.minQ,
        label: tr('Q'),
        value: fmtQ(q),
        color: Palette.bands[i],
        pos: b.maxQ == b.minQ
            ? 0
            : (q - (b.minQ * 10).round()) /
                  ((b.maxQ * 10).round() - (b.minQ * 10).round()),
        onSlide: (n) => write(
          a,
          b.qIdx,
          ((b.minQ * 10).round() +
                  n * ((b.maxQ * 10).round() - (b.minQ * 10).round()))
              .round(),
        ),
        onMinus: () => write(
          a,
          b.qIdx,
          (q - 1).clamp((b.minQ * 10).round(), (b.maxQ * 10).round()),
        ),
        onPlus: () => write(
          a,
          b.qIdx,
          (q + 1).clamp((b.minQ * 10).round(), (b.maxQ * 10).round()),
        ),
      ),
    ];
    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
        child: Row(
          children: [
            for (final parameter in parameters) Expanded(child: parameter),
          ],
        ),
      );
    }
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: Palette.bands[i],
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  b.isBassTreble
                      ? tr(b.label)
                      : trf('Band {band}, {typ}', {
                          'band': b.label,
                          'typ': tr(b.typeName(typeRaw)),
                        }),
                  style: ts(16, weight: 600),
                ),
              ),
              if (b.isBassTreble && onBassTrebleEnabled != null)
                Switch(
                  value: bassTrebleEnabled,
                  onChanged: onBassTrebleEnabled,
                ),
            ],
          ),
          if (showType && b.types.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: EqTypeTiles(
                band: i,
                value: typeRaw ?? 0,
                onChanged: (t) => write(a, b.typeIdx!, t),
              ),
            ),
          ...parameters,
        ],
      ),
    );
  }
}

class _ParamRow extends StatelessWidget {
  const _ParamRow({
    required this.label,
    required this.value,
    required this.color,
    required this.pos,
    required this.onSlide,
    required this.onMinus,
    required this.onPlus,
    this.compact = false,
    this.enabled = true,
  });
  final bool compact, enabled;
  final String label, value;
  final Color color;
  final double pos; // 0..1
  final ValueChanged<double> onSlide;
  final VoidCallback onMinus, onPlus;

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData i, VoidCallback f) => Material(
      color: Palette.surf2,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: enabled ? f : null,
        child: SizedBox(
          width: compact ? 32 : 40,
          height: compact ? 32 : 44,
          child: Icon(i, color: Palette.text),
        ),
      ),
    );
    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: color,
        thumbColor: color,
        inactiveTrackColor: Palette.surf2,
        overlayColor: color.withValues(alpha: 0.15),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      ),
      child: Slider(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        value: pos.clamp(0.0, 1.0),
        onChanged: enabled ? onSlide : null,
      ),
    );
    if (compact) {
      return Opacity(
        opacity: enabled ? 1 : 0.35,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(label, style: ts(12, color: Palette.muted)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      value,
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts(13, weight: 500, color: color),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  btn(Icons.remove, onMinus),
                  Expanded(child: SizedBox(height: 32, child: slider)),
                  btn(Icons.add, onPlus),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: ts(14, weight: 500, color: Palette.muted),
            ),
          ),
          btn(Icons.remove, onMinus),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(value, style: ts(16, weight: 500, width: 105)),
                SizedBox(height: 20, child: slider),
              ],
            ),
          ),
          btn(Icons.add, onPlus),
        ],
      ),
    );
  }
}

/// Anzeigeoption für die Kurve, unabhängig vom Bass/Treble-Geräteschalter.
class EqCurveControls extends StatelessWidget {
  const EqCurveControls({
    super.key,
    required this.includeBassTreble,
    required this.onChanged,
  });

  final bool includeBassTreble;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 36,
    child: Row(
      children: [
        Expanded(
          child: Text(
            tr('Bass/Treble in Kurve'),
            style: ts(13, color: Palette.muted),
          ),
        ),
        const SizedBox(width: 4),
        Semantics(
          label: tr('Bass/Treble in Kurve'),
          child: Transform.scale(
            scale: 0.8,
            child: Switch(
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              value: includeBassTreble,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Gemeinsame Dual-EQ-Zeile für EQ-Menü und Preset-Editor.
class EqDualControls extends StatelessWidget {
  const EqDualControls({
    super.key,
    required this.dual,
    required this.right,
    required this.onDualChanged,
    required this.onSideChanged,
    required this.onClear,
  });

  final bool dual;
  final bool right;
  final ValueChanged<bool>? onDualChanged;
  final ValueChanged<bool> onSideChanged;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Row(
      children: [
        Text(tr('Dual EQ'), style: ts(14, weight: 600)),
        const SizedBox(width: 8),
        Switch(value: dual, onChanged: onDualChanged),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: dual
                ? FittedBox(
                    fit: BoxFit.scaleDown,
                    child: SizedBox(
                      width: 132,
                      child: EqSideSwitch(
                        right: right,
                        onChanged: onSideChanged,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
        SizedBox(
          width: 56,
          height: 40,
          child: OutlinedButton(
            onPressed: onClear,
            style: OutlinedButton.styleFrom(
              foregroundColor: Palette.muted,
              side: const BorderSide(color: Palette.line),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              textStyle: ts(13, weight: 600),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(tr('Clear')),
          ),
        ),
      ],
    ),
  );
}

class EqSideSwitch extends StatelessWidget {
  const EqSideSwitch({super.key, required this.right, required this.onChanged});
  final bool right;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: Palette.surf,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        for (final r in [false, true])
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(r),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: r == right ? Palette.surf2 : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  r ? tr('Rechts') : tr('Links'),
                  textAlign: TextAlign.center,
                  style: ts(
                    14,
                    weight: r == right ? 600 : 500,
                    color: r == right ? Palette.text : Palette.muted,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Bandwahl als Leiste (wie im EQ-Menü); auch im Preset-Editor genutzt.
class EqBandChips extends StatelessWidget {
  const EqBandChips({
    super.key,
    required this.selected,
    required this.onSelect,
    this.compact = false,
  });
  final int selected;
  final ValueChanged<int> onSelect;
  final bool compact;

  Widget _chip(int i) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: i == selected ? Palette.surf2 : Palette.surf,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: i == selected ? Palette.bands[i] : Palette.line,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => onSelect(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Palette.bands[i],
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    tr(eqBands[i].label),
                    style: ts(
                      14,
                      weight: i == selected ? 600 : 500,
                      color: i == selected ? Palette.text : Palette.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => compact
      ? Row(children: [for (var i = 0; i < eqBands.length; i++) _chip(i)])
      : Column(
          children: [
            Row(children: [for (var i = 0; i < 5; i++) _chip(i)]),
            const SizedBox(height: 6),
            Row(children: [_chip(5), _chip(6)]),
          ],
        );
}

// ---------------------------------------------------------------------------

/// Frequenzgang mit farbigen Bändern; Punkte lassen sich ziehen,
/// zwei Finger ändern Q.
class EqPlot extends StatefulWidget {
  const EqPlot({
    super.key,
    required this.read,
    required this.write,
    required this.eqAddr,
    required this.btAddr,
    required this.selected,
    required this.enabled,
    required this.onSelect,
    this.includeBassTreble,
    this.fullscreen = false,
    this.glide = const Duration(milliseconds: 120),
  });
  final bool? includeBassTreble;

  /// Interne Vollbilddarstellung ohne weiteren Vollbildknopf.
  final bool fullscreen;

  /// Dauer, mit der die Kurve zu neuen Gerätewerten gleitet. Über den Host
  /// kommen EQ-Werte nur etwa alle 0,7 s, dann entsprechend länger.
  final Duration glide;
  final int? Function(int address, int index) read;
  final void Function(int address, int index, int raw) write;
  final int eqAddr, btAddr;
  final int selected;
  final bool enabled;
  final ValueChanged<int> onSelect;

  @override
  State<EqPlot> createState() => _EqPlotState();
}

class _EqPlotState extends State<EqPlot>
    with
        WidgetsBindingObserver,
        AutomaticKeepAliveClientMixin<EqPlot>,
        SingleTickerProviderStateMixin<EqPlot> {
  // Auch ein aus dem sichtbaren Bereich gescrollter EQ gehört zur offenen Seite.
  @override
  bool get wantKeepAlive => true;

  EqPlotScale _scale = const EqPlotScale(12);
  int? _drag;
  Offset _grab = Offset.zero;

  /// Neue Werte (etwa aus anderer Software über den Host) kommen in Sprüngen
  /// an. Die Kurve gleitet deshalb kurz zum neuen Stand, außer beim Ziehen.
  late final AnimationController _glider = AnimationController(
    vsync: this,
    duration: widget.glide,
  );
  List<EqBandShape?>? _from, _to;
  late final ValueNotifier<EqPlot> _source;
  Route<void>? _fullscreenRoute;
  bool _current = false;
  bool _waitForPortrait = false;
  bool _checkScheduled = false;

  @override
  void initState() {
    super.initState();
    _source = ValueNotifier(widget);
    if (!widget.fullscreen) {
      WidgetsBinding.instance.addObserver(this);
      AppSettings.instance.addListener(_scheduleOrientationCheck);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.fullscreen) return;
    _current = ModalRoute.isCurrentOf(context) ?? true;
    MediaQuery.orientationOf(context);
    _scheduleOrientationCheck();
  }

  @override
  void didUpdateWidget(EqPlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _glider.duration = widget.glide;
    // Der offene Vollbildgraph folgt auch externen Geräteänderungen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _source.value = widget;
    });
  }

  @override
  void didChangeMetrics() => _scheduleOrientationCheck();

  void _scheduleOrientationCheck() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted) return;
      final size = MediaQuery.sizeOf(context);
      final landscape = size.width > size.height;
      if (!landscape) _waitForPortrait = false;
      final auto = AppSettings.instance.autoFullscreenEq && !isTablet(context);
      EqDisplayMode.allowRotation(this, _current && auto && !_waitForPortrait);
      if (_current &&
          auto &&
          landscape &&
          !_waitForPortrait &&
          _fullscreenRoute == null) {
        _openFullscreen(automatic: true);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _openFullscreen({bool automatic = false}) async {
    if (_fullscreenRoute != null) return;
    final navigator = Navigator.of(context);
    final route = PageRouteBuilder<void>(
      settings: const RouteSettings(name: 'eq-fullscreen'),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => _EqFullscreen(
        source: _source,
        automatic: automatic,
        onClosing: () {
          // Erst wieder automatisch öffnen, nachdem Hochformat erreicht wurde.
          _waitForPortrait = true;
          EqDisplayMode.allowRotation(this, false);
        },
      ),
    );
    _fullscreenRoute = route;
    await navigator.push(route);
    _fullscreenRoute = null;
    if (mounted) _scheduleOrientationCheck();
  }

  @override
  void dispose() {
    _glider.dispose();
    if (!widget.fullscreen) {
      WidgetsBinding.instance.removeObserver(this);
      AppSettings.instance.removeListener(_scheduleOrientationCheck);
      EqDisplayMode.allowRotation(this, false);
      final route = _fullscreenRoute;
      if (route != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (route.isActive) route.navigator?.removeRoute(route);
          _source.dispose();
        });
      } else {
        _source.dispose();
      }
    } else {
      _source.dispose();
    }
    super.dispose();
  }

  int _addr(int i) => eqBands[i].isBassTreble ? widget.btAddr : widget.eqAddr;

  static bool _same(List<EqBandShape?>? a, List<EqBandShape?> b) {
    if (a == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (x == null || y == null) {
        if (x != y) return false;
        continue;
      }
      if (x.kind != y.kind ||
          x.freq != y.freq ||
          x.gainDb != y.gainDb ||
          x.q != y.q) {
        return false;
      }
    }
    return true;
  }

  static EqBandShape? _lerp(EqBandShape? a, EqBandShape? b, double t) {
    if (a == null || b == null || a.kind != b.kind) return b;
    double geo(double x, double y) =>
        math.exp(math.log(x) + (math.log(y) - math.log(x)) * t);
    return EqBandShape(
      b.kind,
      geo(a.freq, b.freq),
      a.gainDb + (b.gainDb - a.gainDb) * t,
      geo(a.q, b.q),
    );
  }

  /// Startet das Gleiten, wenn sich die Kurve geändert hat.
  void _retarget(List<EqBandShape?> target) {
    if (_drag != null || _to == null) {
      _from = _to = target;
      _glider.value = 1;
      return;
    }
    if (_same(_to, target)) return;
    _from = _shown(_to!);
    _to = target;
    _glider.forward(from: 0);
  }

  List<EqBandShape?> _shown(List<EqBandShape?> fallback) {
    final from = _from, to = _to;
    if (from == null || to == null || from.length != to.length) {
      return fallback;
    }
    final t = Curves.easeOut.transform(_glider.value);
    if (t >= 1) return to;
    return [for (var i = 0; i < to.length; i++) _lerp(from[i], to[i], t)];
  }

  List<EqBandShape?> _shapes() {
    final btOn =
        widget.includeBassTreble ??
        (widget.read(widget.btAddr, EqIdx2.btEnable) ?? 1) != 0;
    return [
      for (var i = 0; i < eqBands.length; i++)
        if (eqBands[i].isBassTreble && !btOn) null else _shape(i),
    ];
  }

  EqBandShape _shape(int i) {
    final b = eqBands[i], a = _addr(i);
    final t = b.typeIdx == null ? null : widget.read(a, b.typeIdx!);
    return EqBandShape(
      b.kindFor(t),
      (widget.read(a, b.freqIdx) ?? b.defF).toDouble(),
      (widget.read(a, b.gainIdx) ?? 0) / 2,
      (widget.read(a, b.qIdx) ?? (b.defQ * 10).round()) / 10,
    );
  }

  static Rect _plotRect(Size size) =>
      Rect.fromLTRB(36, 16, size.width - 14, size.height - 26);

  double _y(double db, Rect rect) =>
      rect.center.dy - db / _scale.range * rect.height / 2;
  double _db(double y, Rect rect) =>
      (rect.center.dy - y) / (rect.height / 2) * _scale.range;

  /// Punkt liegt auf der Gesamtkurve bei der Frequenz des Bands.
  Offset _pointPos(int i, List<EqBandShape?> sh, Size s) {
    final b = sh[i]!;
    final total = totalResponseDb(sh.whereType<EqBandShape>(), b.freq);
    final rect = _plotRect(s);
    return Offset(
      rect.left + freqToX(b.freq) * rect.width,
      _y(total.clamp(-_scale.range, _scale.range), rect),
    );
  }

  int? _hit(Offset p, Size s) {
    final sh = _shapes();
    int? best;
    double bd = 44;
    for (var i = 0; i < sh.length; i++) {
      if (sh[i] == null) continue;
      final d = (_pointPos(i, sh, s) - p).distance;
      if (d < bd) {
        bd = d;
        best = i;
      }
    }
    return best;
  }

  void _dragTo(int i, Offset p, Size s) {
    final b = eqBands[i], a = _addr(i);
    final rect = _plotRect(s);
    final f = snapFreq(b, xToFreq((p.dx - rect.left) / rect.width));
    widget.write(a, b.freqIdx, f);
    final shape = _shape(i);
    if (shape.hasGain) {
      // Gain so wählen, dass der Punkt (auf der Gesamtkurve) am Finger liegt:
      // gewünschte Höhe minus Beitrag der anderen Bänder an dieser Frequenz.
      final others = _shapes()
          .asMap()
          .entries
          .where((e) => e.key != i && e.value != null)
          .map((e) => e.value!);
      final want = _db(p.dy, rect) - totalResponseDb(others, f.toDouble());
      final raw = (want * 2).round().clamp(eqGainMinRaw, eqGainMaxRaw);
      widget.write(a, b.gainIdx, raw);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return LayoutBuilder(
      builder: (context, box) {
        final height = widget.fullscreen
            ? box.maxHeight
            : math.max(190.0, box.maxWidth / 2);
        final size = Size(box.maxWidth, height);
        final sh = _shapes();
        _scale = EqPlotScale.forShapes(sh.whereType<EqBandShape>());
        _retarget(sh);
        return RawGestureDetector(
          gestures: {
            TapGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                  TapGestureRecognizer.new,
                  (t) => t.onTapUp = (d) {
                    final i = _hit(d.localPosition, size);
                    if (i != null) widget.onSelect(i);
                  },
                ),
            _PointDrag: GestureRecognizerFactoryWithHandlers<_PointDrag>(
              _PointDrag.new,
              (r) => r
                // Ecke mit dem Vollbild-Knopf frei lassen, sonst fängt der
                // Graph den Tipp ab.
                ..accepts = ((p) =>
                    !(!widget.fullscreen &&
                        p.dx > size.width - 60 &&
                        p.dy < 60) &&
                    _hit(p, size) != null)
                ..onStart = (d) {
                  final i = _hit(d.localPosition, size);
                  if (i == null) return;
                  // Abstand Finger–Punkt merken, damit der Punkt nicht springt.
                  _grab = _pointPos(i, _shapes(), size) - d.localPosition;
                  _drag = i;
                  widget.onSelect(i);
                  setState(() {});
                }
                ..onUpdate = (d) {
                  final i = _drag;
                  if (i != null) _dragTo(i, d.localPosition + _grab, size);
                }
                ..onEnd = ((_) => setState(() => _drag = null))
                ..onCancel = (() => setState(() => _drag = null)),
            ),
          },
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: Palette.surf,
              borderRadius: BorderRadius.circular(14),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _glider,
                    builder: (context, _) => CustomPaint(
                      painter: _EqPainter(
                        _shown(sh),
                        widget.selected,
                        widget.enabled,
                        _drag != null,
                        _scale,
                      ),
                    ),
                  ),
                ),
                if (_drag != null && sh[_drag!] != null)
                  Positioned(
                    top: 8,
                    left: 0,
                    right: 0,
                    child: Center(child: _bubble(_drag!, sh[_drag!]!)),
                  ),
                if (!widget.fullscreen)
                  Positioned(
                    top: 2,
                    right: 2,
                    child: IconButton.filledTonal(
                      tooltip: tr('Vollbild'),
                      onPressed: _openFullscreen,
                      icon: const Icon(Icons.fullscreen),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _bubble(int i, EqBandShape s) {
    final b = eqBands[i];
    final head = b.isBassTreble
        ? tr(b.label)
        : trf('Band {band}', {'band': b.label});
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Palette.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Palette.bands[i]),
      ),
      child: Text(
        '$head: ${fmtFreq(s.freq.round())}'
        '${s.hasGain ? '  ${fmtGain((s.gainDb * 2).round())}' : ''}'
        '  Q ${fmtQ((s.q * 10).round())}',
        style: ts(13, weight: 600),
      ),
    );
  }
}

class _EqPainter extends CustomPainter {
  _EqPainter(
    this.shapes,
    this.selected,
    this.enabled,
    this.dragging,
    this.scale,
  );
  final List<EqBandShape?> shapes;
  final int selected;
  final bool enabled;
  final bool dragging;

  final EqPlotScale scale;
  double get _range => scale.range;

  @override
  void paint(Canvas canvas, Size s) {
    final rect = _EqPlotState._plotRect(s);
    double y(double db) => rect.center.dy - db / _range * rect.height / 2;
    double x(double f) => rect.left + freqToX(f) * rect.width;
    final grid = Paint()..strokeWidth = 1;
    for (final f in EqPlotScale.minorFrequencies) {
      grid.color = Palette.line.withValues(alpha: 0.45);
      canvas.drawLine(
        Offset(x(f.toDouble()), rect.top),
        Offset(x(f.toDouble()), rect.bottom),
        grid,
      );
    }
    for (final f in EqPlotScale.frequencyLabels.keys) {
      grid.color = Palette.line;
      canvas.drawLine(
        Offset(x(f.toDouble()), rect.top),
        Offset(x(f.toDouble()), rect.bottom),
        grid,
      );
    }
    for (final gain in scale.gains) {
      grid.color = gain == 0
          ? Palette.muted.withValues(alpha: 0.65)
          : Palette.line;
      canvas.drawLine(
        Offset(rect.left, y(gain)),
        Offset(rect.right, y(gain)),
        grid,
      );
    }
    void label(String text, Offset offset, {bool alignRight = false}) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: ts(11, weight: 500, color: Palette.muted),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        alignRight
            ? offset - Offset(painter.width, painter.height / 2)
            : offset,
      );
    }

    for (final entry in EqPlotScale.frequencyLabels.entries) {
      label(entry.value, Offset(x(entry.key.toDouble()), rect.bottom + 7));
    }
    for (final gain in scale.gains) {
      label(
        scale.gainLabel(gain),
        Offset(rect.left - 7, y(gain)),
        alignRight: true,
      );
    }

    canvas.save();
    canvas.clipRect(rect);
    final active = shapes.whereType<EqBandShape>().toList();
    const n = 160;
    final fade = enabled ? 1.0 : 0.4;

    // Bandanteile als Farbfläche
    for (var i = 0; i < shapes.length; i++) {
      final sh = shapes[i];
      if (sh == null) continue;
      final p = Path()..moveTo(rect.left, y(0));
      for (var k = 0; k <= n; k++) {
        final f = xToFreq(k / n);
        p.lineTo(x(f), y(sh.responseDb(f).clamp(-_range, _range)));
      }
      p
        ..lineTo(rect.right, y(0))
        ..close();
      canvas.drawPath(
        p,
        Paint()
          ..color = Palette.bands[i].withValues(
            alpha: (i == selected ? 0.35 : 0.16) * fade,
          ),
      );
    }

    // Gesamtkurve
    final total = Path();
    for (var k = 0; k <= n; k++) {
      final f = xToFreq(k / n);
      final v = y(totalResponseDb(active, f).clamp(-_range, _range));
      k == 0 ? total.moveTo(rect.left, v) : total.lineTo(x(f), v);
    }
    canvas.drawPath(
      total,
      Paint()
        ..color = Palette.text.withValues(alpha: fade)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );

    // Punkte
    for (var i = 0; i < shapes.length; i++) {
      final sh = shapes[i];
      if (sh == null) continue;
      final pos = Offset(
        x(sh.freq),
        y(totalResponseDb(active, sh.freq).clamp(-_range, _range)),
      );
      final col = Palette.bands[i].withValues(alpha: fade);
      if (i == selected) {
        canvas.drawCircle(
          pos,
          dragging ? 26 : 20,
          Paint()..color = col.withValues(alpha: 0.2),
        );
        if (dragging) _arrows(canvas, pos, col);
        canvas.drawCircle(pos, 13, Paint()..color = Palette.bg);
        canvas.drawCircle(pos, 10.5, Paint()..color = col);
      } else {
        canvas.drawCircle(pos, 9, Paint()..color = Palette.bg);
        canvas.drawCircle(
          pos,
          8,
          Paint()
            ..color = col
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5,
        );
      }
    }
    canvas.restore();
  }

  void _arrows(Canvas c, Offset p, Color col) {
    final pa = Paint()
      ..color = col
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const a = 34.0;
    for (final d in [
      const Offset(1, 0),
      const Offset(-1, 0),
      const Offset(0, 1),
      const Offset(0, -1),
    ]) {
      final tip = p + d * a;
      c.drawLine(p + d * 16, tip, pa);
      final n = Offset(-d.dy, d.dx);
      c.drawLine(tip, tip - d * 5 + n * 4, pa);
      c.drawLine(tip, tip - d * 5 - n * 4, pa);
    }
  }

  @override
  bool shouldRepaint(_EqPainter o) => true;
}

/// Greift einen EQ-Punkt sofort (sonst würde die scrollbare Seite
/// senkrechte Bewegungen abfangen). Nur auf einem Punkt aktiv.
class _PointDrag extends PanGestureRecognizer {
  bool Function(Offset local) accepts = (_) => false;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      super.isPointerAllowed(event) && accepts(event.localPosition);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// Filtertyp eines Bandes (Band 1 und 5) als gleich breite Kacheln.
class EqTypeTiles extends StatelessWidget {
  const EqTypeTiles({
    super.key,
    required this.band,
    required this.value,
    required this.onChanged,
    this.compact = false,
  });
  final bool compact;
  final int band;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final b = eqBands[band];
    final col = Palette.bands[band];
    return Row(
      children: [
        for (var k = 0; k < b.types.length; k++) ...[
          if (k > 0) const SizedBox(width: 6),
          Expanded(
            child: Material(
              color: k == value ? col.withValues(alpha: 0.18) : Palette.bg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(
                  color: k == value ? col : Palette.line,
                  width: k == value ? 1.5 : 1,
                ),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: k == value ? null : () => onChanged(k),
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: compact ? 8 : 10),
                  child: Text(
                    tr(b.types[k].$1),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: ts(
                      compact ? 12 : 13,
                      weight: k == value ? 600 : 500,
                      color: k == value ? Palette.text : Palette.muted,
                      narrow: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
