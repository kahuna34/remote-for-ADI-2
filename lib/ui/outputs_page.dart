import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../device/adi2_controller.dart';
import '../device/volume_options.dart';
import '../eq/eq_model.dart';
import '../eq/eq_library.dart';
import '../eq/eq_editor_buffer.dart';
import '../easy/easy_layout.dart';
import '../easy/easy_long_press.dart';
import 'easy_tile_grid.dart';
import '../protocol/adi2_codec.dart';
import '../protocol/adi2_params.dart';
import 'eq_page.dart';
import 'param_tile.dart';
import 'protection_page.dart';
import 'signal_flow.dart';
import 'signal_flow_data.dart';
import 'theme.dart';
import 'volume_ring.dart';
import 'responsive_layout.dart';

part 'easy_mode_panel.dart';

class OutputInfo {
  const OutputInfo(this.address, this.name, this.phones);
  final int address;
  final String name;
  final bool phones;
}

List<OutputInfo> outputsFor(Adi2Variant v) => [
  OutputInfo(Adi2Addr.line, tr('Line Out'), false),
  OutputInfo(Adi2Addr.ph12, v.isDac ? tr('Phones') : tr('Phones 1/2'), true),
  if (v.hasPhones34)
    OutputInfo(Adi2Addr.ph34, v.isDac ? tr('IEM') : tr('Phones 3/4'), true),
];

/// Hauptansicht: ein Ausgang zur Zeit, Lautstärke-Ring, Tasten.
class OutputsPage extends StatefulWidget {
  const OutputsPage({
    super.key,
    required this.ctrl,
    this.easyLayout,
    this.useFreedSpace = false,
    this.onOutputSelected,
    this.onEditTile,
    this.onPinTile,
    this.onMoveTile,
    this.editorOutput,
    this.previewTile,
    this.previewColor = EasyTileColor.graphite,
  });
  final Adi2Controller ctrl;
  final VoidCallback? onOutputSelected;
  final EasyLayout? easyLayout;

  /// Renders one operating tile without panel padding or editor overlays.
  /// Preview surfaces are always decorative and ignore all pointer input.
  final EasyTile? previewTile;
  final EasyTileColor previewColor;

  /// Local editor selection; does not change the connected device selection.
  final int? editorOutput;

  /// Player/Status belegen keinen Platz oberhalb der Hauptansicht.
  final bool useFreedSpace;
  final ValueChanged<int>? onEditTile;
  final ValueChanged<int>? onPinTile;
  final void Function(int, int, int)? onMoveTile;

  @override
  State<OutputsPage> createState() => _OutputsPageState();
}

class _OutputsPageState extends State<OutputsPage> {
  final Map<int, int> _lastCrossfeed = {}; // letzte aktive Stufe je Ausgang
  bool _recallFlash = false; // kurzes Aufleuchten beim Abrufen
  Timer? _repeat; // Gemeinsame Wiederholung für die Schrittregler
  bool _holdingUp = false;
  bool _refPending = false;

  /// Gedrückthalten: leiser alle 150 ms (≈3,3 dB/s), lauter alle 250 ms
  /// (≈2 dB/s, zusätzlich vom Lautstärkeschutz gebremst). Jeder Schritt
  /// geht vom Ist-Wert am Gerät aus, damit sich nichts aufstaut.
  void _startRepeat(int a, int step, {VoidCallback? onStep}) {
    _repeat?.cancel();
    if (onStep == null && step > 0) setState(() => _holdingUp = true);
    _repeat = Timer.periodic(Duration(milliseconds: step > 0 ? 250 : 150), (_) {
      if (!mounted) return;
      if (onStep != null) {
        onStep();
      } else {
        final now = c.valueOr(a, OutIdx.volume, -1145);
        c.setVolume(a, now + step);
      }
    });
  }

  void _stopRepeat(int a) {
    _repeat?.cancel();
    _repeat = null;
    if (_holdingUp) {
      c.stopVolumeRamp(a);
      setState(() => _holdingUp = false);
    }
  }

  Timer? _flashTimer;

  /// Ref-Level erst nach Bestätigung umschalten; Lautstärke-Ausgleich
  /// ist vorausgewählt.
  Future<void> _confirmRef(OutputInfo o, int index) async {
    final v = c.variant!;
    final defRef = outputParams(
      v,
      phones: o.phones,
      ess: c.hasEss,
    ).firstWhere((d) => d.index == OutIdx.refLevel);
    final cur = c.valueOr(o.address, OutIdx.refLevel, 0);
    final table = refTable(v, o.address);
    final delta = (index < table.length && cur < table.length)
        ? table[index] - table[cur]
        : 0.0;
    var compensate = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(
            trf('Ref Level auf {neu} umschalten?', {
              'neu': defRef.format(index),
            }),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                delta > 0
                    ? trf('{ausgang} wird dadurch {db} dB lauter.', {
                        'ausgang': o.name,
                        'db': delta.toStringAsFixed(0),
                      })
                    : trf('{ausgang} wird dadurch {db} dB leiser.', {
                        'ausgang': o.name,
                        'db': (-delta).toStringAsFixed(0),
                      }),
                style: ts(15, color: Palette.muted, height: 1.4),
              ),
              if (delta != 0)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: compensate,
                  onChanged: (x) => setD(() => compensate = x ?? true),
                  title: Text(
                    tr('Lautstärke ausgleichen (gleich laut bleiben)'),
                  ),
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
              child: Text(tr('Umschalten')),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      if (c.value(o.address, OutIdx.autoRef) == 1) {
        c.set(o.address, OutIdx.autoRef, 0);
      }
      c.setRefLevel(o.address, index, compensate: compensate);
    }
  }

  /// Bedingung der automatischen Stummschaltung für die Mute-Taste,
  /// z. B. "(Phones)". Nur bei Line Out.
  String? _muteCondition(int a) {
    final v = c.variant;
    if (v == null || a != Adi2Addr.line) return null;
    if (v.isDac) {
      final m = c.valueOr(Adi2Addr.device, 1, 0);
      if (m == 0) return null;
      final d = deviceParams(v).firstWhere((x) => x.index == 1);
      return '(${d.format(m)})';
    }
    final p12 =
        c.valueOr(Adi2Addr.device, 11, 0) != 0 &&
        c.valueOr(Adi2Addr.device, 8, 0) != 0; // Ph 1/2 nur mit Dual Phones
    final p34 = c.valueOr(Adi2Addr.device, 12, 0) != 0;
    if (p12 && p34) return '(Ph 1/2+3/4)';
    if (p12) return '(Ph 1/2)';
    if (p34) return '(Ph 3/4)';
    return null;
  }

  bool _fixedRef(OutputInfo o) => refTable(c.variant!, o.address).length == 1;

  String _fixedRefLabel(OutputInfo o) => trf('Ref {wert} dBu', {
    'wert': refDbu(
      c.variant!,
      o.address,
      c.value(o.address, OutIdx.refLevel),
    )!.toStringAsFixed(0).replaceAll('-', '−'),
  });

  void _showFixedRef() => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(tr('Fester Pegel beim IEM-Ausgang')),
      duration: const Duration(seconds: 2),
    ),
  );

  /// Ref-Level wählen (Kacheln), danach Bestätigung.
  Future<void> _pickRef(OutputInfo o) async {
    if (_fixedRef(o)) {
      _showFixedRef();
      return;
    }
    final v = c.variant!;
    final d = outputParams(
      v,
      phones: o.phones,
      ess: c.hasEss,
    ).firstWhere((x) => x.index == OutIdx.refLevel);
    final cur = c.valueOr(o.address, OutIdx.refLevel, 0);
    final autoRef = c.value(o.address, OutIdx.autoRef);
    // DAC: Line-Pegel gelten für RCA, XLR liegt 6 dB höher.
    final rca = v.isDac && o.address == Adi2Addr.line;

    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                trf('Ref Level, {ausgang}', {
                  'ausgang': rca ? '${o.name} RCA' : o.name,
                }),
                style: ts(18, weight: 600),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (autoRef != null)
                    ChoiceChip(
                      label: Text(tr('Auto')),
                      selected: autoRef == 1,
                      onSelected: (_) => Navigator.pop(ctx, -1),
                      selectedColor: Palette.amber,
                      backgroundColor: Palette.bg,
                      labelStyle: ts(
                        14,
                        weight: 600,
                        color: autoRef == 1 ? Palette.bg : Palette.text,
                      ),
                      showCheckmark: false,
                    ),
                  for (var i = d.min; i <= d.max; i++)
                    ChoiceChip(
                      label: rca
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(d.format(i)),
                                Text(
                                  _refXlr(o, i),
                                  style: ts(
                                    11,
                                    color: Palette.muted,
                                    narrow: true,
                                  ),
                                ),
                              ],
                            )
                          : Text(d.format(i)),
                      selected: i == cur && autoRef != 1,
                      onSelected: i == cur && autoRef != 1
                          ? null
                          : (_) => Navigator.pop(ctx, i),
                      selectedColor: Palette.surf2,
                      backgroundColor: Palette.bg,
                      side: BorderSide(
                        color: i == cur ? Palette.amber : Palette.line,
                      ),
                      labelStyle: ts(14, weight: i == cur ? 600 : 500),
                      showCheckmark: false,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _selectRef(o, picked);
  }

  String _refXlr(OutputInfo o, int index) {
    final r = refDbu(c.variant!, o.address, index);
    if (r == null) return '';
    final x = r + 6;
    final t =
        (x == x.roundToDouble() ? x.toStringAsFixed(0) : x.toStringAsFixed(1))
            .replaceAll('.', ',');
    return '(XLR ${x > 0 ? '+' : ''}$t dBu)';
  }

  /// Gemeinsamer Auswahlweg für Sheet und Custom-Segmente.
  Future<void> _selectRef(OutputInfo o, int picked) async {
    if (_refPending) return;
    if (picked == -1) {
      c.set(o.address, OutIdx.autoRef, 1);
      return;
    }
    if (picked == c.value(o.address, OutIdx.refLevel) &&
        c.value(o.address, OutIdx.autoRef) != 1) {
      return;
    }
    _refPending = true;
    try {
      await _confirmRef(o, picked);
    } finally {
      _refPending = false;
    }
  }

  /// Aktueller Ausgangspegel in dBu; DAC-Line mit RCA und XLR (+6 dB).
  String? _levelText(Adi2Variant v, int a, int volRaw) {
    final ref = refDbu(v, a, c.value(a, OutIdx.refLevel));
    if (ref == null) return null;
    String f(double x) =>
        '${x > 0 ? '+' : ''}${x.toStringAsFixed(1).replaceAll('.', ',')} dBu';
    final dbu = volRaw / 10 + ref;
    if (v.isDac && a == Adi2Addr.line) {
      return 'RCA ${f(dbu)}\nXLR ${f(dbu + 6)}';
    }
    return f(dbu);
  }

  void _flashRecall() {
    _flashTimer?.cancel();
    setState(() => _recallFlash = true);
    _flashTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _recallFlash = false);
    });
  }

  @override
  void dispose() {
    _repeat?.cancel();
    _flashTimer?.cancel();
    super.dispose();
  }

  // Gewählter Ausgang liegt im Controller, damit er beim Neuaufbau der
  // Ansicht (z. B. beim Einstecken eines Kopfhörers) erhalten bleibt.
  int get _sel => c.selectedOutput ?? -1;
  set _sel(int v) => c.selectedOutput = v;

  void _selectEasyOutput(int address) {
    c.stopVolumeRamp(_sel);
    setState(() => _sel = address);
    widget.onOutputSelected?.call();
  }

  Adi2Controller get c => widget.ctrl;

  OutputInfo _current(List<OutputInfo> outs) {
    final hit = outs.where((o) => o.address == _sel);
    if (hit.isNotEmpty) return hit.first;
    // Standard: Kopfhörer – beim DAC "Phones", sonst "Phones 3/4"
    final def = c.variant!.isDac
        ? outs.firstWhere((o) => o.address == Adi2Addr.ph12)
        : outs.last;
    _sel = def.address;
    return def;
  }

  /// Loslassen stoppt jede Anhebung sofort. Weiter nur nach Bestätigung.
  Future<void> _onRelease(OutputInfo o) async {
    final pending = c.stopVolumeRamp(o.address);
    if (pending == null || !mounted) return;
    final now = c.valueOr(o.address, OutIdx.volume, pending) / 10;
    final go = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('Anhebung angehalten'), style: ts(20, weight: 600)),
              const SizedBox(height: 10),
              Text(
                trf(
                  '{name} steht jetzt auf {wert}. Weiter langsam auf {ziel} anheben?',
                  {
                    'name': o.name,
                    'wert': fmtDb(now),
                    'ziel': fmtDb(pending / 10),
                  },
                ),
                style: ts(15, color: Palette.muted, height: 1.4),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(tr('Hier stoppen')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _SoftButton(
                      label: tr('Weiter anheben'),
                      onTap: () => Navigator.pop(ctx, true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (go == true && mounted) c.setVolume(o.address, pending);
  }

  void _storeRecall(int a, int raw) {
    c.setRecall(a, raw);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            trf(
              'Recall gespeichert: {wert}. Tippen stellt ihn wieder ein, lang drücken überschreibt.',
              {'wert': fmtDb(raw / 10)},
            ),
          ),
        ),
      );
  }

  /// Einstellungen zu einer Kurzwahltaste als Blatt von unten.
  Future<void> _paramSheet(
    String title,
    int address,
    List<ParamDef> defs, {
    String? note,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (ctx, sc) => ListenableBuilder(
          listenable: c,
          builder: (ctx, _) => ListView(
            controller: sc,
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewPaddingOf(ctx).bottom + 12,
            ),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(title, style: ts(18, weight: 600)),
              ),
              if (note != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    note,
                    style: ts(13, color: Palette.muted, height: 1.4),
                  ),
                ),
              for (final d in defs)
                ParamTile(ctrl: c, address: address, def: d),
            ],
          ),
        ),
      ),
    );
  }

  void _linkSheet(List<OutputInfo> outs, int current) {
    final dualOff = !c.variant!.isDac && c.valueOr(Adi2Addr.device, 8, 0) == 0;
    // Aktuellen Ausgang direkt vormerken, wenn noch nichts gekoppelt ist.
    if (c.opts.linked.isEmpty) c.setLinked(current, true);
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: c,
          builder: (ctx, _) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('Link Volume'), style: ts(18, weight: 600)),
                const SizedBox(height: 4),
                Text(
                  tr(
                    'Gekoppelte Ausgänge ändern ihre Lautstärke gemeinsam um denselben Betrag. Jedes Volume Limit gilt weiter.',
                  ),
                  style: ts(13, color: Palette.muted, height: 1.4),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final x in outs)
                      if (!(dualOff && x.address == Adi2Addr.ph12))
                        FilterChip(
                          label: Text(x.name),
                          selected: c.opts.linked.contains(x.address),
                          onSelected: (on) => c.setLinked(x.address, on),
                          checkmarkColor: Palette.amber,
                          selectedColor: Palette.surf2,
                          backgroundColor: Palette.bg,
                          side: BorderSide(
                            color: c.opts.linked.contains(x.address)
                                ? Palette.amber
                                : Palette.line,
                          ),
                          labelStyle: ts(14, weight: 500),
                        ),
                  ],
                ),
                const SizedBox(height: 8),
                if (c.opts.linked.length < 2)
                  Text(
                    tr('Mindestens zwei Ausgänge wählen.'),
                    style: ts(13, color: Palette.amber),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _phonesSheet() {
    final v = c.variant!;
    _paramSheet(
      tr('Kopfhörer-Ausgänge'),
      Adi2Addr.device,
      deviceParams(v).where((d) => d.index == 8 || d.index == 9).toList(),
      note: tr(
        'Mit Dual Phones ist zusätzlich Phones 1/2 aktiv, z. B. für zwei Kopfhörer. Bal. TRS Phones nutzt beide Buchsen für einen symmetrischen Kopfhörer.',
      ),
    );
  }

  void _dimInfo() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'Dim senkt die Lautstärke um 20 dB. Am Gerät gibt es dafür keine Einstellungen.',
            ),
          ),
        ),
      );
  }

  void _muteSheet() {
    final v = c.variant!;
    final keep = v.isDac ? {1} : {10, 11, 12};
    _paramSheet(
      tr('Mute und Umschalten'),
      Adi2Addr.device,
      deviceParams(v).where((d) => keep.contains(d.index)).toList(),
      note: tr(
        'Legt fest, wann Line Out stumm geschaltet wird, wenn Kopfhörer eingesteckt sind, und wie das Umschalten Phones/Line arbeitet.',
      ),
    );
  }

  void _recallSheet(int a, String name) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: c,
          builder: (ctx, _) {
            final r = c.opts.of(a).recallRaw;
            final cur = c.valueOr(a, OutIdx.volume, -300);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Text(
                    trf('Recall, {name}', {'name': name}),
                    style: ts(18, weight: 600),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    tr(
                      'Tippen auf „Recall“ stellt diesen Wert ein, beim Anheben langsam.',
                    ),
                    style: ts(13, color: Palette.muted, height: 1.4),
                  ),
                ),
                ListTile(
                  title: Text(tr('Gespeicherter Wert')),
                  trailing: Text(
                    r == null ? tr('keiner') : fmtDb(r / 10),
                    style: ts(15, weight: 500, color: Palette.amber),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.save_outlined),
                  title: Text(
                    trf('Aktuelle Lautstärke speichern ({wert})', {
                      'wert': fmtDb(cur / 10),
                    }),
                  ),
                  onTap: () {
                    c.setRecall(a, cur);
                    Navigator.pop(ctx);
                  },
                ),
                if (r != null)
                  ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title: Text(tr('Löschen')),
                    onTap: () {
                      c.setRecall(a, null);
                      Navigator.pop(ctx);
                    },
                  ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _pickChoice(int a, ParamDef d) async {
    final cur = c.valueOr(a, d.index, d.def);
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: c,
        builder: (ctx, _) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr(d.name), style: ts(18, weight: 600)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = d.min; i <= d.max; i++)
                      ChoiceChip(
                        label: Text(d.format(i)),
                        selected: i == cur,
                        onSelected:
                            i == cur || c.isParamValueDisabled(a, d.index, i)
                            ? null
                            : (_) => Navigator.pop(ctx, i),
                        selectedColor: Palette.surf2,
                        backgroundColor: Palette.bg,
                        side: BorderSide(
                          color:
                              i == cur && !c.isParamValueDisabled(a, d.index, i)
                              ? Palette.amber
                              : Palette.line,
                        ),
                        labelStyle: ts(
                          14,
                          weight: i == cur ? 600 : 500,
                          color: c.isParamValueDisabled(a, d.index, i)
                              ? Palette.muted.withValues(alpha: 0.45)
                              : Palette.text,
                        ),
                        showCheckmark: false,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked != null && mounted) {
      if (d.index == OutIdx.crossfeed && picked > 0) {
        _lastCrossfeed[a] = picked;
      }
      c.set(a, d.index, picked);
    }
  }

  void _stepTone(int address, EqBandDef band, int step) {
    if (c.valueOr(address, EqIdx2.btEnable, 1) == 0) {
      c.set(address, EqIdx2.btEnable, 1);
    }
    final raw = c.eqValue(address, band.gainIdx) ?? 0;
    c.setEq(
      address,
      band.gainIdx,
      (raw + step).clamp(eqGainMinRaw, eqGainMaxRaw),
    );
  }

  void _toneSheet(OutputInfo output, EqBandDef band) {
    final address = output.address + 1;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: ListenableBuilder(
            listenable: c,
            builder: (_, _) => EqBandControls(
              band: eqBands.indexOf(band),
              address: address,
              read: c.eqValue,
              write: c.setEq,
              bassTrebleEnabled: c.valueOr(address, EqIdx2.btEnable, 1) != 0,
              onBassTrebleEnabled: (on) =>
                  c.set(address, EqIdx2.btEnable, on ? 1 : 0),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toneControl(
    OutputInfo output,
    EqBandDef band,
    bool compact, {
    double growth = 0,
  }) {
    final address = output.address + 1;
    void step(int direction) => _stepTone(address, band, direction);
    final label = Text(
      tr(band.label),
      maxLines: 1,
      style: ts(isTablet(context) ? 15 : 13, weight: 500, color: Palette.muted),
    );
    final control = Material(
      key: ValueKey('${band.label}-tile'),
      color: Palette.surf,
      shape: _controlShape,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: isTablet(context) ? 64 : 56,
        child: Opacity(
          opacity: c.valueOr(address, EqIdx2.btEnable, 1) == 0 ? 0.45 : 1,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                key: ValueKey('${band.label}-settings'),
                onLongPress: () => _toneSheet(output, band),
                child: SizedBox(
                  height: isTablet(context)
                      ? 48
                      : (compact ? 20 : _controlHeight) + 10 * growth,
                  child: isTablet(context) && compact
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            label,
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                fmtGain(c.eqValue(address, band.gainIdx) ?? 0),
                                key: ValueKey('${band.label}-value'),
                                maxLines: 1,
                                style: ts(
                                  15,
                                  weight: 500,
                                  color: Palette.amber,
                                ),
                              ),
                            ),
                          ],
                        )
                      : Center(child: label),
                ),
              ),
              const Divider(height: 1),
              _stepButton(
                output.address,
                band.label,
                1,
                () => step(1),
                width: isTablet(context) ? 64 : 56,
                height: 48 + 6 * growth,
              ),
              if (!isTablet(context) || !compact) ...[
                const Divider(height: 1),
                SizedBox(
                  height: (compact ? 20 : _controlHeight) + 10 * growth,
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Text(
                          fmtGain(c.eqValue(address, band.gainIdx) ?? 0),
                          key: ValueKey('${band.label}-value'),
                          style: ts(
                            isTablet(context) ? 15 : 13,
                            weight: 500,
                            color: Palette.amber,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              const Divider(height: 1),
              _stepButton(
                output.address,
                band.label,
                -1,
                () => step(-1),
                width: isTablet(context) ? 64 : 56,
                height: 48 + 6 * growth,
              ),
            ],
          ),
        ),
      ),
    );
    return isTablet(context)
        ? Center(child: control)
        : FittedBox(fit: BoxFit.scaleDown, child: control);
  }

  Widget _stepButton(
    int address,
    String name,
    int step,
    VoidCallback onStep, {
    double width = 44,
    double height = _controlHeight,
  }) {
    return SizedBox(
      width: isTablet(context) ? math.max(48, width) : width,
      height: height,
      child: GestureDetector(
        onLongPressStart: (_) => _startRepeat(address, step, onStep: onStep),
        onLongPressEnd: (_) => _stopRepeat(address),
        onLongPressCancel: () => _stopRepeat(address),
        child: InkWell(
          key: ValueKey('$name-${step > 0 ? 'plus' : 'minus'}'),
          onTap: onStep,
          child: Center(
            child: Text(
              step > 0 ? '+' : '−',
              style: ts(isTablet(context) ? 17 : 15, weight: 500),
            ),
          ),
        ),
      ),
    );
  }

  Widget _balanceControl(int address, ParamDef def, double height) {
    final raw = c.valueOr(address, def.index, def.def);
    void step(int direction) {
      final current = c.valueOr(address, def.index, def.def);
      c.set(address, def.index, (current + direction).clamp(def.min, def.max));
    }

    final value = raw == 0
        ? tr('C')
        : '${raw < 0 ? tr('L') : tr('R')} ${def.format(raw.abs()).replaceAll('.', ',')}';
    return Material(
      key: const ValueKey('Balance-tile'),
      color: Palette.surf,
      shape: _controlShape,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            _stepButton(address, 'Balance', -1, () => step(-1), height: height),
            const VerticalDivider(width: 1),
            Expanded(
              child: InkWell(
                key: const ValueKey('Balance-center'),
                onLongPress: () => c.set(address, def.index, 0),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '${tr('Bal')} $value',
                        style: ts(
                          isTablet(context) ? 15 : 13,
                          weight: 500,
                          color: Palette.amber,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            _stepButton(address, 'Balance', 1, () => step(1), height: height),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.previewTile case final tile?) {
      return ExcludeSemantics(
        child: IgnorePointer(
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) {
              if (c.variant == null) return const SizedBox.shrink();
              final outs = outputsFor(c.variant!);
              final selected =
                  outs
                      .where((o) => o.address == widget.editorOutput)
                      .firstOrNull ??
                  outs.first;
              return _easyTile(
                tile,
                0,
                selected,
                outs,
                widget.previewColor,
                {},
              );
            },
          ),
        ),
      );
    }
    if (widget.easyLayout != null) return _buildEasyPanel(widget.easyLayout!);
    return LayoutBuilder(
      builder: (context, constraints) => ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          if (isTablet(context)) {
            // The parent has already removed the header, app navigation and
            // system insets. Only the ring receives the remaining flex space.
            final compact = constraints.maxHeight < 720;
            return TabletContent(
              child: _buildOutput(context, compact, compact ? 0 : 1),
            );
          }
          // Preserve the previous compact layout when the 120 px header is
          // removed. Only distribute space that fits above the base controls.
          final baselineHeight =
              constraints.maxHeight - (widget.useFreedSpace ? 120 : 0);
          final growth = widget.useFreedSpace && constraints.hasBoundedHeight
              ? ((constraints.maxHeight - 440) / 120).clamp(0.0, 1.0)
              : 0.0;
          final output = _buildOutput(context, baselineHeight < 500, growth);
          // Rotation can lay out this page briefly beneath the analyzer's
          // fullscreen route. Keep controls usable on short viewports too.
          if (constraints.maxHeight < 360) {
            return SingleChildScrollView(
              child: SizedBox(height: 440, child: output),
            );
          }
          return output;
        },
      ),
    );
  }

  Widget _buildOutput(BuildContext context, bool compact, double growth) {
    final controlHeight = isTablet(context)
        ? 48.0
        : _controlHeight + 12 * growth;
    final v = c.variant!;
    final outs = outputsFor(v);
    if (!v.isDac &&
        c.valueOr(Adi2Addr.device, 8, 0) == 0 &&
        _sel == Adi2Addr.ph12) {
      _sel = outs.last.address;
    }
    final o = _current(outs);
    final a = o.address;

    final volRaw = c.valueOr(a, OutIdx.volume, -100);
    final target = c.volumeTarget(a);
    final limitRaw = c.volumeLimit(a);
    final muted = c.valueOr(a, OutIdx.mute, 0) != 0;
    final autoMute = c.autoMuted(a);
    final locked = c.valueOr(a, OutIdx.lockVolume, 0) != 0;
    final recall = c.opts.of(a).recallRaw;
    final linked = c.opts.linked.contains(a) && c.opts.linked.length > 1;
    final crossfeed = c.value(a, OutIdx.crossfeed);
    if (crossfeed != null && crossfeed > 0) {
      _lastCrossfeed[a] = crossfeed;
    }

    String hint = '';
    Color hintColor = Palette.amber;
    if (autoMute && !muted) {
      hint = tr('Stumm: Kopfhörer eingesteckt');
      hintColor = Palette.red;
    } else if (_holdingUp) {
      hint = tr('Wird langsam lauter …');
    } else if (target != null && target > volRaw + 5) {
      hint = trf('Ziel {ziel}, wird langsam angehoben', {
        'ziel': fmtDb(target / 10),
      });
    } else if (c.limitHit(a)) {
      hint = trf('Obergrenze erreicht: {wert}', {'wert': fmtDb(limitRaw / 10)});
      hintColor = Palette.red;
    } else if (locked) {
      hint = tr('Lautstärke am Gerät gesperrt');
      hintColor = Palette.muted;
    } else if (linked) {
      hint = trf('Gekoppelt mit {ausgaenge}', {
        'ausgaenge': c.opts.linked
            .where((x) => x != a)
            .map(
              (x) =>
                  outs.firstWhere((y) => y.address == x, orElse: () => o).name,
            )
            .join(', '),
      });
      hintColor = Palette.muted;
    }

    final defs = outputParams(v, phones: o.phones, ess: c.hasEss);
    ParamDef def(int i) => defs.firstWhere((d) => d.index == i);
    // Phones 1/2 ist bei Pro/2-4 nur mit Dual Phones aktiv (Geräte-Index 8).
    final dualOff = !v.isDac && c.valueOr(Adi2Addr.device, 8, 0) == 0;

    final volumeButtons = Row(
      key: const ValueKey('output-volume-buttons'),
      children: [
        Expanded(
          child: _SoftButton(
            icon: Icons.remove,
            label: '0,5 dB',
            compact: compact,
            growth: growth,
            onTap: locked ? null : () => c.setVolume(a, volRaw - 5),
            onHoldStart: locked ? null : () => _startRepeat(a, -5),
            onHoldEnd: () => _stopRepeat(a),
          ),
        ),
        SizedBox(width: compact ? 6 : 12),
        Expanded(
          child: _SoftButton(
            icon: Icons.add,
            label: '0,5 dB',
            compact: compact,
            growth: growth,
            onTap: locked ? null : () => c.setVolume(a, volRaw + 5),
            onHoldStart: locked ? null : () => _startRepeat(a, 5),
            onHoldEnd: () => _stopRepeat(a),
          ),
        ),
      ],
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        compact ? (isTablet(context) ? 0 : 2) : 10,
      ),
      child: Column(
        children: [
          OutputSwitch(
            compact: compact,
            growth: growth,
            outs: outs,
            selected: a,
            active: c.status?.activeOutput,
            disabled: dualOff ? {Adi2Addr.ph12} : const {},
            onSelect: (x) {
              if (dualOff && x == Adi2Addr.ph12) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    SnackBar(
                      content: Text(
                        tr(
                          'Phones 1/2 ist aus, weil Dual Phones nicht aktiv ist. Gedrückt halten zum Einschalten.',
                        ),
                      ),
                    ),
                  );
                return;
              }
              _stopRepeat(a);
              c.stopVolumeRamp(a);
              setState(() => _sel = x);
              widget.onOutputSelected?.call();
            },
            onLongPress: v.isDac ? null : _phonesSheet,
          ),
          SizedBox(height: isTablet(context) && compact ? 4 : 8),
          Expanded(
            child: Stack(
              key: const ValueKey('output-ring-area'),
              children: [
                Positioned.fill(
                  top: controlHeight + (isTablet(context) && compact ? 0 : 8),
                  bottom: isTablet(context) && compact ? 0 : 8,
                  child: Row(
                    children: [
                      SizedBox(
                        width: isTablet(context) ? 64 : 56,
                        child: _toneControl(
                          o,
                          eqBands.firstWhere((b) => b.isBassTreble),
                          compact,
                          growth: growth,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, ringBox) => Center(
                            child: SizedBox(
                              height: widget.useFreedSpace && !isTablet(context)
                                  ? math.min(
                                      math.min(ringBox.maxWidth, 300) * 0.83,
                                      ringBox.maxHeight,
                                    )
                                  : ringBox.maxHeight,
                              child: VolumeRing(
                                actualDb: volRaw / 10,
                                targetDb: target == null ? null : target / 10,
                                limitDb: limitRaw / 10,
                                muted: muted || autoMute,
                                enabled: !locked,
                                onChanged: (db) =>
                                    c.setVolume(a, (db * 10).round()),
                                onRelease: () => _onRelease(o),
                                levelText: _levelText(v, a, volRaw),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      SizedBox(
                        width: isTablet(context) ? 64 : 56,
                        child: _toneControl(
                          o,
                          eqBands.last,
                          compact,
                          growth: growth,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  top: 0,
                  left: _sideWidth + 8,
                  right: _sideWidth + 8,
                  child: _balanceControl(a, def(OutIdx.balance), controlHeight),
                ),
                // Ref-Level oben links, spiegelbildlich zum DA-Filter.
                if (_fixedRef(o) || c.value(a, OutIdx.refLevel) != null)
                  Positioned(
                    top: 0,
                    left: 0,
                    width: _sideWidth,
                    child: _SideButton(
                      key: const ValueKey('output-ref-level'),
                      height: controlHeight,
                      icon: _fixedRef(o) ? Icons.lock_outline : Icons.tune,
                      label: _fixedRef(o)
                          ? _fixedRefLabel(o)
                          : '${c.value(a, OutIdx.autoRef) == 1 ? '${tr('Auto')} ' : ''}'
                                '${def(OutIdx.refLevel).format(c.valueOr(a, OutIdx.refLevel, 0))}',
                      on: !_fixedRef(o) && c.value(a, OutIdx.autoRef) == 1,
                      onTap: () => _pickRef(o),
                    ),
                  ),
                // DA-Filter oben rechts (Ecke neben dem Bogen ist frei)
                if (c.value(a, OutIdx.daFilter) != null)
                  Positioned(
                    top: 0,
                    right: 0,
                    width: _sideWidth,
                    child: _SideButton(
                      key: const ValueKey('output-da-filter'),
                      height: controlHeight,
                      icon: Icons.filter_alt_outlined,
                      label: def(OutIdx.daFilter)
                          .format(c.valueOr(a, OutIdx.daFilter, 0)),
                      on: false,
                      onTap: () => _pickChoice(a, def(OutIdx.daFilter)),
                    ),
                  ),
                // Use the ring's upper margin for tablet hints without taking
                // flex space or covering its volume and dBu labels.
                if (isTablet(context) && hint.isNotEmpty)
                  Positioned(
                    left: 72,
                    right: 72,
                    top: controlHeight + (compact ? 0 : 8),
                    child: IgnorePointer(
                      child: ColoredBox(
                        color: Palette.bg,
                        child: Text(
                          hint,
                          key: const ValueKey('output-hint-overlay'),
                          maxLines: 1,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: ts(13, weight: 500, color: hintColor),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Zeile unter dem Ring: Lock | Hinweis | Link
          SizedBox(
            height: isTablet(context) ? 48 : 36 + 12 * growth,
            child: Row(
              children: [
                SizedBox(
                  width: compact ? 56 : _sideWidth,
                  child: c.value(a, OutIdx.lockVolume) == null
                      ? null
                      : _SideButton(
                          key: const ValueKey('output-lock'),
                          height: controlHeight,
                          icon: locked ? Icons.lock : Icons.lock_open,
                          label: tr('Lock'),
                          on: locked,
                          onTap: () =>
                              c.set(a, OutIdx.lockVolume, locked ? 0 : 1),
                        ),
                ),
                Expanded(
                  child: compact
                      ? volumeButtons
                      : isTablet(context)
                      ? const SizedBox.shrink()
                      : Center(
                          child: Text(
                            hint,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: ts(13, weight: 500, color: hintColor),
                          ),
                        ),
                ),
                SizedBox(
                  width: compact ? 56 : _sideWidth,
                  child: _SideButton(
                    key: const ValueKey('output-link'),
                    height: controlHeight,
                    icon: Icons.link,
                    label: linked ? '${c.opts.linked.length}' : tr('Link'),
                    on: linked,
                    onTap: () {
                      if (linked) {
                        for (final x in c.opts.linked.toList()) {
                          c.setLinked(x, false);
                        }
                      } else {
                        _linkSheet(outs, a);
                      }
                    },
                    onLongPress: () => _linkSheet(outs, a),
                  ),
                ),
              ],
            ),
          ),
          if (!isTablet(context) && compact && hint.isNotEmpty)
            Text(
              hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ts(11, color: hintColor),
            ),
          if (!compact) const SizedBox(height: 4),
          if (!compact) volumeButtons,
          SizedBox(height: compact ? 3 : 10),
          IntrinsicHeight(
            child: Row(
              key: const ValueKey('output-function-keys'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children:
                  [
                        if (c.value(a, OutIdx.mute) != null)
                          _Key(
                            compact: compact,
                            icon: Icons.volume_off_outlined,
                            label: tr('Mute'),
                            caption: _muteCondition(a),
                            on: muted || autoMute,
                            color: Palette.red,
                            hasMenu: true,
                            onLongPress: () => _muteSheet(),
                            onTap: () => c.set(a, OutIdx.mute, muted ? 0 : 1),
                          ),
                        if (c.value(a, OutIdx.dim) != null)
                          _Key(
                            compact: compact,
                            icon: Icons.brightness_low_outlined,
                            label: tr('Dim'),
                            on: c.valueOr(a, OutIdx.dim, 0) != 0,
                            onLongPress: _dimInfo,
                            onTap: () => c.set(
                              a,
                              OutIdx.dim,
                              c.valueOr(a, OutIdx.dim, 0) != 0 ? 0 : 1,
                            ),
                          ),
                        // Kopfhörer brauchen keine Loudness-Taste; wie beim
                        // IEM bleibt sie dort nur in den Einstellungen.
                        if (a == Adi2Addr.line &&
                            c.value(a, OutIdx.loudness) != null)
                          _Key(
                            compact: compact,
                            icon: Icons.graphic_eq,
                            label: tr('Loudness'),
                            on: c.valueOr(a, OutIdx.loudness, 0) != 0,
                            hasMenu: true,
                            onLongPress: () => _paramSheet(
                              trf('Loudness, {name}', {'name': o.name}),
                              a,
                              defs
                                  .where(
                                    (d) =>
                                        d.index >= OutIdx.loudness &&
                                        d.index <= OutIdx.loudLowVolRef,
                                  )
                                  .toList(),
                              note: tr(
                                'Hebt Bass und Höhen bei leiser Lautstärke an. Unterhalb von „Low Vol Ref“ wirkt die volle Anhebung, 20 dB darüber keine mehr.',
                              ),
                            ),
                            onTap: () => c.set(
                              a,
                              OutIdx.loudness,
                              c.valueOr(a, OutIdx.loudness, 0) != 0 ? 0 : 1,
                            ),
                          ),
                        if (crossfeed != null)
                          _Key(
                            compact: compact,
                            icon: Icons.spatial_audio_off,
                            label: tr('Crossfeed'),
                            caption: def(OutIdx.crossfeed).format(crossfeed),
                            on: crossfeed != 0,
                            hasMenu: true,
                            onTap: () {
                              if (crossfeed > 0) {
                                _lastCrossfeed[a] = crossfeed;
                              }
                              c.set(
                                a,
                                OutIdx.crossfeed,
                                crossfeed == 0 ? (_lastCrossfeed[a] ?? 1) : 0,
                              );
                            },
                            onLongPress: () =>
                                _pickChoice(a, def(OutIdx.crossfeed)),
                          ),
                        _Key(
                          compact: compact,
                          icon: Icons.bookmark_outline,
                          label: recall == null
                              ? tr('Recall')
                              : _short(recall / 10),
                          caption: recall == null
                              ? tr('speichern')
                              : tr('Recall'),
                          on: _recallFlash,
                          onTap: locked
                              ? null
                              : () {
                                  if (recall == null) {
                                    _storeRecall(a, volRaw);
                                  } else {
                                    c.recall(a);
                                    _flashRecall();
                                  }
                                },
                          hasMenu: true,
                          onLongPress: () => _recallSheet(a, o.name),
                        ),
                      ]
                      .expand(
                        (w) => [Expanded(child: w), const SizedBox(width: 8)],
                      )
                      .toList()
                    ..removeLast(),
            ),
          ),
          SizedBox(height: compact ? 3 : 10),
          Row(
            key: const ValueKey('output-tiles'),
            children: [
              Expanded(
                child: _Tile(
                  compact: compact,
                  icon: Icons.input,
                  label: tr('Quelle'),
                  value: c.value(a, OutIdx.source) == null
                      ? tr('wie Line')
                      : def(OutIdx.source)
                            .format(c.valueOr(a, OutIdx.source, 0)),
                  onTap: c.value(a, OutIdx.source) == null
                      ? null
                      : () => _pickChoice(a, def(OutIdx.source)),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _Tile(
                  compact: compact,
                  icon: Icons.tune,
                  label: tr('EQ'),
                  value: c.valueOr(a + 1, 2, 0) != 0 ? tr('an') : tr('aus'),
                  highlight: c.valueOr(a + 1, 2, 0) != 0,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          EqPage(ctrl: c, channelAddr: a, title: o.name),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _Tile(
                  compact: compact,
                  icon: Icons.shield_outlined,
                  label: tr('Limit'),
                  value: c.opts.of(a).limitDbu == null
                      ? tr('aus')
                      : _dbu(c.opts.of(a).limitDbu!),
                  highlight: c.opts.of(a).limitDbu != null,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ProtectionPage(ctrl: c, out: o),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _Tile(
                  compact: compact,
                  icon: Icons.settings_outlined,
                  label: tr('Settings'),
                  value: o.name,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => OutputSettingsPage(ctrl: c, out: o),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _dbu(double v) =>
    '${v < 0 ? '−' : '+'}${v.abs().toStringAsFixed(1).replaceAll('.', ',')} dBu';

/// Shared output selection for the main view and the Custom Mode editor.
class OutputSwitch extends StatelessWidget {
  const OutputSwitch({
    super.key,
    required this.outs,
    required this.selected,
    required this.onSelect,
    this.active,
    this.compact = false,
    this.growth = 0,
    this.disabled = const {},
    this.onLongPress,
  });
  final List<OutputInfo> outs;
  final int selected;
  final int? active;
  final bool compact;
  final double growth;
  final Set<int> disabled;
  final ValueChanged<int> onSelect;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Palette.surf,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (final o in outs)
            Expanded(
              child: GestureDetector(
                onTap: () => onSelect(o.address),
                onLongPress: onLongPress,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  alignment: Alignment.center,
                  constraints: isTablet(context)
                      ? const BoxConstraints(minHeight: 48)
                      : null,
                  padding: EdgeInsets.symmetric(
                    vertical: (compact ? 6 : 10) + 6 * growth,
                  ),
                  decoration: BoxDecoration(
                    color: o.address == selected
                        ? Palette.surf2
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    border: o.address == selected
                        ? const Border(
                            bottom: BorderSide(color: Palette.amber, width: 2),
                          )
                        : null,
                  ),
                  child: disabled.contains(o.address)
                      ? Text(
                          o.name,
                          textAlign: TextAlign.center,
                          style: ts(
                            isTablet(context) ? 17 : 15,
                            weight: 500,
                            color: Palette.muted.withValues(alpha: 0.45),
                          ),
                        )
                      : Text(
                          o.name,
                          textAlign: TextAlign.center,
                          style: ts(
                            isTablet(context) ? 17 : 15,
                            weight: o.address == selected ? 600 : 500,
                            color: o.address == selected
                                ? Palette.text
                                : Palette.muted,
                          ),
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SoftButton extends StatelessWidget {
  const _SoftButton({
    required this.label,
    this.compact = false,
    this.growth = 0,
    this.icon,
    this.onTap,
    this.onHoldStart,
    this.onHoldEnd,
  });
  final String label;
  final bool compact;
  final double growth;
  final IconData? icon;
  final VoidCallback? onTap;
  final VoidCallback? onHoldStart;
  final VoidCallback? onHoldEnd;

  @override
  Widget build(BuildContext context) {
    final col = onTap == null ? Palette.muted : Palette.text;
    return GestureDetector(
      onLongPressStart: onHoldStart == null ? null : (_) => onHoldStart!(),
      onLongPressEnd: onHoldStart == null ? null : (_) => onHoldEnd?.call(),
      onLongPressCancel: onHoldStart == null ? null : () => onHoldEnd?.call(),
      child: _material(context, col),
    );
  }

  Widget _material(BuildContext context, Color col) {
    return Material(
      color: Palette.surf,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Palette.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          constraints: isTablet(context)
              ? const BoxConstraints(minHeight: 48)
              : null,
          padding: EdgeInsets.symmetric(
            vertical: (compact ? 5 : 11) + 6 * growth,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: col),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: ts(
                    isTablet(context) ? 17 : 15,
                    weight: 500,
                    color: col,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Kurzform für die Recall-Taste, z. B. "−30,0".
String _short(double db) =>
    '${db < 0 ? '−' : (db > 0 ? '+' : '')}${db.abs().toStringAsFixed(1).replaceAll('.', ',')}';

/// Taste mit Leuchtstreifen wie am Gerät; aktiv leuchtet sie in [color].
class _Key extends StatelessWidget {
  const _Key({
    this.compact = false,
    required this.icon,
    required this.label,
    required this.on,
    this.onTap,
    this.onLongPress,
    this.color = Palette.amber,
    this.hasMenu = false,
    this.caption,
  });
  final IconData icon;
  final String label;
  final bool on;
  final bool compact;
  final Color color;
  final String? caption;
  final bool hasMenu; // gedrückt halten öffnet Einstellungen
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final fg = on ? Palette.text : Palette.muted;
    return Material(
      color: on
          ? Color.alphaBlend(color.withValues(alpha: 0.14), Palette.surf)
          : Palette.surf,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: on ? color : Palette.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: isTablet(context) ? 48 : 0),
          child: Stack(
            children: [
              if (hasMenu)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Icon(Icons.more_horiz, size: 14, color: Palette.muted),
                ),
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    6,
                    compact ? 4 : 7,
                    6,
                    compact ? 4 : 8,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 22,
                        height: 3,
                        decoration: BoxDecoration(
                          color: on ? color : Palette.line,
                          borderRadius: BorderRadius.circular(2),
                          boxShadow: on
                              ? [
                                  BoxShadow(
                                    color: color.withValues(alpha: 0.6),
                                    blurRadius: 6,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                      SizedBox(height: compact ? 3 : 7),
                      Icon(
                        icon,
                        size: compact ? 16 : 20,
                        color: on ? color : Palette.muted,
                      ),
                      SizedBox(height: compact ? 2 : 5),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          label,
                          maxLines: 1,
                          style: ts(
                            compact ? 12 : (isTablet(context) ? 16 : 14),
                            weight: 600,
                            width: 95,
                            color: fg,
                          ),
                        ),
                      ),
                      if (caption != null)
                        Text(
                          caption!,
                          maxLines: 1,
                          style: ts(
                            compact ? 10 : 11,
                            color: Palette.muted,
                            narrow: true,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // Unsichtbarer Platzhalter gibt der Taste ihre Höhe.
              Opacity(
                opacity: 0,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    6,
                    compact ? 4 : 7,
                    6,
                    compact ? 4 : 8,
                  ),
                  child: Column(
                    children: [
                      SizedBox(
                        height: compact ? 3 + 3 + 16 + 2 : 3 + 7 + 20 + 5,
                      ),
                      Text(
                        'Ag',
                        style: ts(
                          compact ? 12 : (isTablet(context) ? 16 : 14),
                          weight: 600,
                        ),
                      ),
                      Text('Ag', style: ts(compact ? 10 : 11, narrow: true)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Kompakte Kachel: Symbol, Bezeichnung, aktueller Wert.
class _Tile extends StatelessWidget {
  const _Tile({
    this.compact = false,
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
    this.highlight = false,
  });
  final IconData icon;
  final String label, value;
  final VoidCallback? onTap;
  final bool highlight;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final details = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!compact) ...[
          Icon(icon, size: 18, color: Palette.muted),
          const SizedBox(height: 3),
        ],
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            maxLines: 1,
            style: ts(
              compact ? 12 : (isTablet(context) ? 15 : 13),
              weight: 600,
            ),
          ),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            maxLines: 1,
            style: ts(
              compact ? 11 : (isTablet(context) ? 14 : 12),
              weight: 500,
              narrow: true,
              color: highlight ? Palette.amber : Palette.muted,
            ),
          ),
        ),
      ],
    );
    return Material(
      color: Palette.surf,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          constraints: isTablet(context)
              ? const BoxConstraints(minHeight: 48)
              : null,
          padding: EdgeInsets.symmetric(
            horizontal: 4,
            vertical: compact ? 4 : 8,
          ),
          child: Center(
            child: compact
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 16, color: Palette.muted),
                      const SizedBox(width: 4),
                      Flexible(child: details),
                    ],
                  )
                : details,
          ),
        ),
      ),
    );
  }
}

/// Alle Einstellungen eines Ausgangs.
class OutputSettingsPage extends StatelessWidget {
  const OutputSettingsPage({super.key, required this.ctrl, required this.out});
  final Adi2Controller ctrl;
  final OutputInfo out;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final v = ctrl.variant;
        return Scaffold(
          appBar: AppBar(title: Text(out.name)),
          body: v == null
              ? Center(child: Text(tr('Nicht verbunden')))
              : SafeArea(
                  top: false,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Panel(
                        child: Material(
                          type: MaterialType.transparency,
                          child: Column(
                            children: [
                              SwitchListTile(
                                key: const ValueKey('output-bass-treble'),
                                title: Text(tr('Bass/Treble')),
                                value:
                                    ctrl.valueOr(
                                      out.address + 1,
                                      EqIdx2.btEnable,
                                      1,
                                    ) !=
                                    0,
                                onChanged: (on) => ctrl.set(
                                  out.address + 1,
                                  EqIdx2.btEnable,
                                  on ? 1 : 0,
                                ),
                              ),
                              for (final d in outputParams(
                                v,
                                phones: out.phones,
                                ph34: out.address == Adi2Addr.ph34,
                                ess: ctrl.hasEss,
                              ))
                                if (d.index != OutIdx.volume &&
                                    d.index != OutIdx.loopback)
                                  ParamTile(
                                    ctrl: ctrl,
                                    address: ctrl.outputParamAddress(
                                      out.address,
                                      d.index,
                                    ),
                                    def: d,
                                  ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}

const double _sideWidth = 84;
const double _controlHeight = 32;
const _controlShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(10)),
  side: BorderSide(color: Palette.line),
);

/// Kleiner Knopf in der Seitenspalte (z. B. Lock).
class _SideButton extends StatelessWidget {
  const _SideButton({
    super.key,
    required this.icon,
    required this.label,
    required this.on,
    required this.onTap,
    this.onLongPress,
    this.height = _controlHeight,
  });
  final double height;
  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => Material(
    color: on
        ? Color.alphaBlend(Palette.amber.withValues(alpha: 0.14), Palette.surf)
        : Palette.surf,
    shape: on
        ? _controlShape.copyWith(
            side: const BorderSide(color: Palette.amber, width: 1.5),
          )
        : _controlShape,
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: on ? Palette.amber : Palette.muted),
              const SizedBox(width: 4),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: ts(
                      isTablet(context) ? 15 : 13,
                      weight: on ? 600 : 500,
                      color: on ? Palette.text : Palette.muted,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
