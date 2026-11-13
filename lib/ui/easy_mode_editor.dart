import 'easy_slot_preview.dart';

import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../device/adi2_controller.dart';
import '../easy/easy_layout.dart';
import '../eq/eq_library.dart';
import '../l10n/l10n.dart';
import '../protocol/adi2_params.dart';
import 'outputs_page.dart';
import 'easy_size_picker.dart';
import 'easy_tile_grid.dart';
import 'easy_tile_preview.dart';
import 'theme.dart';
import 'header_content_picker.dart';
import 'responsive_layout.dart';

/// Edits only the connected device or the selected offline model.
class EasyModeEditor extends StatelessWidget {
  const EasyModeEditor({super.key, this.ctrl});
  final Adi2Controller? ctrl;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([AppLang.instance, ?ctrl]),
    builder: (context, _) {
      final variant = ctrl?.variant;
      if (variant == null) {
        return Scaffold(
          appBar: AppBar(title: Text(tr('Eigene Ansicht einrichten'))),
          body: Center(
            child: Text(tr('Gerät anschließen oder offline ein Modell wählen')),
          ),
        );
      }
      return _ModelEditor(key: ValueKey((ctrl, variant)), ctrl: ctrl!);
    },
  );
}

class _ModelEditor extends StatefulWidget {
  const _ModelEditor({super.key, required this.ctrl});
  final Adi2Controller ctrl;

  @override
  State<_ModelEditor> createState() => _EasyModeEditorState();
}

class _EasyModeEditorState extends State<_ModelEditor> {
  late Adi2Variant _variant;
  AppSettings get _settings => AppSettings.instance;
  EasyLayout get _setup => _settings.easyLayout(_variant);
  EasyLayout get _layout => _setup.pageFor(_output);
  late int _output;
  double _swipeDistance = 0;

  void _swipeOutput() {
    if (_setup.samePageForAllOutputs || _swipeDistance.abs() < 48) return;
    final outs = outputsFor(_variant);
    final index = outs.indexWhere((o) => o.address == _output);
    final next = (index + (_swipeDistance < 0 ? 1 : -1)).clamp(
      0,
      outs.length - 1,
    );
    setState(() => _output = outs[next].address);
  }

  Future<void> _copyToOutputs() async {
    final source = _output;
    final snapshot = _setup;
    final targets = <int>{};
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(tr('Auf andere Ausgänge kopieren …')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final out in outputsFor(_variant))
                  if (out.address != source)
                    CheckboxListTile(
                      key: ValueKey('easy-copy-target-${out.address}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(out.name),
                      value: targets.contains(out.address),
                      onChanged: (on) => update(() {
                        if (on == true) {
                          targets.add(out.address);
                        } else {
                          targets.remove(out.address);
                        }
                      }),
                    ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Abbrechen')),
            ),
            FilledButton(
              key: const ValueKey('easy-copy-confirm'),
              onPressed: targets.isEmpty
                  ? null
                  : () async {
                      if (!await confirmEasyAction(
                        ctx,
                        tr('Seiten der gewählten Ausgänge überschreiben?'),
                      )) {
                        return;
                      }
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    },
              child: Text(tr('Kopieren')),
            ),
          ],
        ),
      ),
    );
    if (result == true && mounted) {
      await _settings.setEasyLayout(
        _variant,
        snapshot.copyPageTo(source, targets),
      );
    }
  }

  Adi2Controller get _ctrl => widget.ctrl;

  @override
  void initState() {
    super.initState();
    _variant = widget.ctrl.variant!;
    final outs = outputsFor(_variant);
    _output =
        outs
            .where((o) => o.address == widget.ctrl.selectedOutput)
            .firstOrNull
            ?.address ??
        (_variant.isDac ? outs[1] : outs.last).address;
    widget.ctrl.requestPresetNames();
  }

  void _save(EasyLayout layout, {bool adjusted = false}) {
    final resolved = layout.copyWith(positionsAdjusted: adjusted).resolvePins();
    _settings.setEasyLayout(_variant, _setup.withPage(_output, resolved));
  }

  Future<void> _saveSetup() async {
    final slots = _settings.easySlots(_variant);
    final snapshot = _setup;
    var selected = slots.active;
    final name = TextEditingController(text: slots.names[selected] ?? '');
    final route = DialogRoute<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(tr('Setup speichern …')),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      for (var i = 0; i < 4; i++)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(right: i == 3 ? 0 : 4),
                            child: EasySlotPreview(
                              key: ValueKey('easy-save-slot-$i'),
                              ctrl: _ctrl,
                              output: _output,
                              index: i,
                              layout: slots.layouts[i]?.pageFor(_output),
                              name: slots.names[i],
                              active: selected == i,
                              onTap: () => update(() {
                                selected = i;
                                name.text = slots.names[i] ?? '';
                              }),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const ValueKey('easy-slot-name'),
                    controller: name,
                    decoration: InputDecoration(
                      labelText: tr('Name (optional)'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Abbrechen')),
            ),
            FilledButton(
              key: const ValueKey('easy-save-setup-confirm'),
              onPressed: () async {
                if (slots.layouts[selected] != null &&
                    !await confirmEasyAction(
                      ctx,
                      trf('Eigene Ansicht {n} überschreiben?', {
                        'n': selected + 1,
                      }),
                    )) {
                  return;
                }
                if (ctx.mounted) Navigator.pop(ctx, selected);
              },
              child: Text(tr('Speichern')),
            ),
          ],
        ),
      ),
    );
    final result = await Navigator.of(context).push(route);
    await route.completed;
    final slotName = name.text;
    name.dispose();
    if (!mounted || result == null) return;
    await _settings.saveEasySlot(_variant, result, snapshot, name: slotName);
  }

  Future<void> _reset() async {
    if (await confirmEasyAction(
          context,
          tr('Auf Standard-Layout zurücksetzen?'),
          message: tr(
            'Die Kacheln dieser eigenen Ansicht werden durch das '
            'Standard-Layout ersetzt. Der Name bleibt erhalten.',
          ),
        ) &&
        mounted) {
      _settings.setEasyLayout(_variant, EasyLayout.defaults(_variant));
    }
  }

  Future<void> _clearSlot() async {
    final index = _settings.easySlots(_variant).active;
    if (await confirmEasyAction(
          context,
          trf('Eigene Ansicht {n} leeren?', {'n': index + 1}),
          message: tr(
            'Kacheln und Name werden entfernt. Der Platz ist danach frei '
            'und zeigt das Standard-Layout, bis er neu eingerichtet wird.',
          ),
        ) &&
        mounted) {
      await _settings.clearEasySlot(_variant, index);
    }
  }

  void _pin(int index) {
    final tiles = [..._layout.tiles];
    final p = packEasyTiles(tiles)[index];
    tiles[index] = tiles[index].withPosition(
      pinned: !tiles[index].pinned,
      x: p.x,
      y: p.y,
    );
    _save(_layout.copyWith(tiles: tiles));
  }

  void _moveTile(int index, int x, int y) {
    _save(_layout.moveTile(index, x, y));
  }

  Future<void> _add() async {
    final type = await Navigator.of(context).push<EasyTileType>(
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          appBar: AppBar(title: Text(tr('Kachel hinzufügen'))),
          body: SafeArea(
            child: CustomScrollView(
              key: const ValueKey('easy-tile-gallery'),
              slivers: [
                for (final group in _catalogGroups.entries) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Text(group.key, style: ts(16, weight: 600)),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverList.builder(
                      itemCount: _catalogRows(group.value).length,
                      itemBuilder: (ctx, index) {
                        final row = _catalogRows(group.value)[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (var i = 0; i < row.length; i++) ...[
                                if (i > 0) const SizedBox(width: 12),
                                Expanded(child: _catalogCard(ctx, row[i])),
                              ],
                              if (row.length == 1 &&
                                  !_widePreview(row.first)) ...[
                                const SizedBox(width: 12),
                                const Expanded(child: SizedBox()),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          ),
        ),
      ),
    );
    if (type == null || !mounted) return;
    await _edit(EasyTile.defaults(type));
  }

  bool _widePreview(EasyTileType type) =>
      type == EasyTileType.volumeRing || type == EasyTileType.outputSelect;

  List<List<EasyTileType>> _catalogRows(List<EasyTileType> types) {
    final rows = <List<EasyTileType>>[];
    for (final type in types) {
      if (_widePreview(type) ||
          rows.isEmpty ||
          rows.last.length == 2 ||
          _widePreview(rows.last.first)) {
        rows.add([type]);
      } else {
        rows.last.add(type);
      }
    }
    return rows;
  }

  Widget _catalogCard(BuildContext ctx, EasyTileType type) => Material(
    color: Palette.bg,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: const BorderSide(color: Palette.line),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      key: ValueKey('easy-gallery-${type.name}'),
      onTap: () => Navigator.pop(ctx, type),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            SizedBox(
              height: type == EasyTileType.volumeRing ? 240 : 160,
              width: double.infinity,
              child: EasyTilePreview(
                ctrl: _ctrl,
                tile: EasyTile.defaults(type),
                output: _output,
                defaultColor: _layout.defaultColor,
                fillPreview: true,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _catalogTitle(type),
              style: buttonLabelStyle(ctx),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              _catalogDescription(type),
              style: buttonStatusStyle(ctx),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    ),
  );

  String _catalogDescription(EasyTileType type) => switch (type) {
    EasyTileType.volumeRing => tr('Pegel am Ring regeln'),
    EasyTileType.volumeDown => tr('Pegel schrittweise senken'),
    EasyTileType.volumeUp => tr('Pegel schrittweise erhöhen'),
    EasyTileType.outputSelect => tr('Aktiven Ausgang wechseln'),
    EasyTileType.mute => tr('Ausgang stummschalten'),
    EasyTileType.dim => tr('Pegel vorübergehend absenken'),
    EasyTileType.loudness => tr('Loudness umschalten'),
    EasyTileType.crossfeed => tr('Crossfeed umschalten'),
    EasyTileType.recall => tr('Referenzlautstärke abrufen'),
    EasyTileType.link => tr('Ausgänge koppeln'),
    EasyTileType.lock => tr('Lautstärke sperren'),
    EasyTileType.bass => tr('Bass anpassen'),
    EasyTileType.treble => tr('Höhen anpassen'),
    EasyTileType.balance => tr('Balance anpassen'),
    EasyTileType.refLevel => tr('Referenzpegel ändern'),
    EasyTileType.daFilter => tr('D/A-Filter wechseln'),
    EasyTileType.source => tr('Eingangsquelle wechseln'),
    EasyTileType.eqEnable => tr('Equalizer umschalten'),
    EasyTileType.eqPage => tr('Equalizer öffnen'),
    EasyTileType.limit => tr('Pegelbegrenzung öffnen'),
    EasyTileType.outputSettings => tr('Ausgang konfigurieren'),
    EasyTileType.setup => tr('Geräte-Setup abrufen'),
    EasyTileType.eqPreset => tr('Geräte-EQ-Preset abrufen'),
    EasyTileType.sourceDirect => tr('Gespeicherte Quelle wählen'),
    EasyTileType.toggleOutputs => tr('Ausgänge umschalten'),
    EasyTileType.basicMode => tr('Betriebsart direkt wählen'),
    EasyTileType.volumeDirect => tr('Gespeicherten Pegel setzen'),
    EasyTileType.appPreset => tr('EQ aus App-Bibliothek laden'),
  };

  Map<String, List<EasyTileType>> get _catalogGroups {
    final groups = <String, List<EasyTileType>>{};
    for (final type in EasyTileType.values) {
      if (!EasyTile.supportsType(type, _variant)) continue;
      final group = switch (type) {
        EasyTileType.volumeRing ||
        EasyTileType.volumeDown ||
        EasyTileType.volumeUp ||
        EasyTileType.mute ||
        EasyTileType.dim ||
        EasyTileType.recall ||
        EasyTileType.lock => tr('Lautstärke'),
        EasyTileType.outputSelect ||
        EasyTileType.link ||
        EasyTileType.refLevel ||
        EasyTileType.source ||
        EasyTileType.outputSettings ||
        EasyTileType.limit => tr('Ausgang'),
        EasyTileType.loudness ||
        EasyTileType.crossfeed ||
        EasyTileType.bass ||
        EasyTileType.treble ||
        EasyTileType.balance ||
        EasyTileType.daFilter ||
        EasyTileType.eqEnable ||
        EasyTileType.eqPage => tr('Klang'),
        _ => tr('Direkt-Knöpfe'),
      };
      groups.putIfAbsent(group, () => []).add(type);
    }
    return groups;
  }

  String _catalogTitle(EasyTileType type) => switch (type) {
    EasyTileType.setup => tr('Setup laden'),
    EasyTileType.eqPreset => tr('EQ-Preset laden'),
    EasyTileType.sourceDirect => tr('Quelle direkt wählen'),
    EasyTileType.basicMode => tr('Basic Mode wählen'),
    EasyTileType.volumeDirect => tr('Lautstärke auf X dB'),
    EasyTileType.appPreset => tr('App-EQ-Preset'),
    _ => easyTileTitle(EasyTile.defaults(type), _ctrl),
  };

  Future<AppEqPreset?> _pickAppPreset() async {
    final items = await EqLibrary.load();
    if (!mounted) return null;
    return showModalBottomSheet<AppEqPreset>(
      context: context,
      useSafeArea: true,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(tr('Keine App-EQ-Presets gespeichert.')),
            ),
          for (final preset in items)
            ListTile(
              title: Text(preset.name),
              onTap: () => Navigator.pop(ctx, preset),
            ),
        ],
      ),
    );
  }

  Future<void> _edit(EasyTile original, [int? index]) async {
    final tile = original.normalizeShape();
    final label = TextEditingController(text: tile.label ?? '');
    final volume = TextEditingController(text: '${tile.param ?? -30}');
    final form = GlobalKey<FormState>();
    var size = tile.size;
    var height = tile.height;
    var color = tile.color;
    var remove = false;
    var output = tile.output;
    var param = index == null && tile.type == EasyTileType.appPreset
        ? null
        : tile.param;
    Widget buildEditor(BuildContext ctx) => StatefulBuilder(
      builder: (ctx, setDialog) {
        final parsedVolume = double.tryParse(volume.text.replaceAll(',', '.'));
        final previewVolume = parsedVolume != null && parsedVolume.isFinite
            ? parsedVolume
            : tile.param;
        final paramOptions = switch (tile.type) {
          EasyTileType.setup => <int, String>{
            for (var n = 1; n <= 9; n++)
              n: easyTileTitle(EasyTile(type: tile.type, param: n), _ctrl),
          },
          EasyTileType.eqPreset => <int, String>{
            for (var n = 1; n <= 20; n++) n: _ctrl.presetName(n - 1),
          },
          EasyTileType.sourceDirect => <int, String>{
            for (final d in outputParams(
              _variant,
              phones: output != 3,
            ).where((d) => d.index == OutIdx.source))
              for (var n = d.min; n <= d.max; n++) n: d.format(n),
          },
          EasyTileType.basicMode => <int, String>{
            for (final d in deviceParams(_variant).where((d) => d.index == 6))
              for (var n = d.min; n <= d.max; n++) n: d.format(n),
          },
          _ => <int, String>{},
        };
        Widget content(double pickerHeight) => SizedBox(
          width: double.infinity,
          child: SingleChildScrollView(
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: pickerHeight,
                    child: EasySizePicker(
                      key: const ValueKey('easy-size'),
                      type: tile.type,
                      size: size,
                      height: height,
                      previewBuilder: (s, h) => EasyTilePreview(
                        ctrl: _ctrl,
                        defaultColor: _layout.defaultColor,
                        output: _output,
                        tile: EasyTile(
                          type: tile.type,
                          size: s,
                          height: h,
                          color: color,
                          output: output,
                          param: tile.type == EasyTileType.volumeDirect
                              ? previewVolume
                              : param ?? tile.param,
                          label: label.text.trim().isEmpty
                              ? null
                              : label.text.trim(),
                        ),
                      ),
                      onChanged: (s, h) => setDialog(() {
                        size = s;
                        height = h;
                      }),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const ValueKey('easy-label'),
                    controller: label,
                    onChanged: (_) => setDialog(() {}),
                    decoration: InputDecoration(
                      labelText: tr('Beschriftung'),
                      hintText: easyTileTitle(
                        EasyTile(type: tile.type, param: param ?? tile.param),
                        _ctrl,
                      ),
                    ),
                  ),
                  if (index != null) ...[
                    const SizedBox(height: 12),
                    Text(tr('Kachelfarbe'), style: ts(14)),
                    EasyColorPicker(
                      value: color,
                      inherit: true,
                      onChanged: (value) => setDialog(() => color = value),
                    ),
                  ],
                  if (tile.hasOutput) ...[
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      key: const ValueKey('easy-output'),
                      initialValue: output ?? 0,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: tr('Ausgang')),
                      items: [
                        DropdownMenuItem(
                          value: 0,
                          child: Text(tr('Gewählter Ausgang')),
                        ),
                        for (final o in outputsFor(_variant))
                          DropdownMenuItem(
                            value: o.address,
                            child: Text(o.name),
                          ),
                      ],
                      onChanged: (value) =>
                          setDialog(() => output = value == 0 ? null : value),
                    ),
                  ],
                  if (paramOptions.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      key: const ValueKey('easy-param'),
                      initialValue: param as int,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: _catalogTitle(tile.type),
                      ),
                      items: [
                        for (final e in paramOptions.entries)
                          DropdownMenuItem(
                            value: e.key,
                            child: Text(
                              '${e.key} · ${e.value}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) => setDialog(() => param = value),
                    ),
                  ],
                  if (tile.type == EasyTileType.volumeDirect) ...[
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const ValueKey('easy-db'),
                      controller: volume,
                      keyboardType: const TextInputType.numberWithOptions(
                        signed: true,
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: tr('Lautstärke (dB)'),
                      ),
                      validator: (text) {
                        final db = double.tryParse(
                          (text ?? '').replaceAll(',', '.'),
                        );
                        return db == null ||
                                !db.isFinite ||
                                db < -114.5 ||
                                db > 6
                            ? tr('Wert zwischen −114,5 und +6 dB eingeben.')
                            : null;
                      },
                    ),
                  ],
                  if (tile.type == EasyTileType.appPreset) ...[
                    const SizedBox(height: 16),
                    Text(
                      tr(
                        'Das gewählte Bibliotheks-Preset wird als Kopie in der Kachel gespeichert.',
                      ),
                      style: ts(13, color: Palette.muted),
                    ),
                    FormField<Object>(
                      validator: (_) => param == null
                          ? tr('Bitte ein App-EQ-Preset wählen.')
                          : null,
                      builder: (field) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (param case final Map preset)
                            Text(
                              preset['name'] as String? ?? tr('App-EQ-Preset'),
                            ),
                          TextButton(
                            key: const ValueKey('easy-app-preset'),
                            onPressed: () async {
                              final preset = await _pickAppPreset();
                              if (preset != null && ctx.mounted) {
                                setDialog(() => param = preset.toJson());
                                field.didChange(param);
                              }
                            },
                            child: Text(tr('Aus App-Bibliothek laden')),
                          ),
                          if (field.errorText != null)
                            Text(
                              field.errorText!,
                              style: ts(12, color: Palette.red),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
        final actions = <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Abbrechen')),
          ),
          FilledButton(
            key: const ValueKey('easy-save-tile'),
            onPressed: () {
              if (!form.currentState!.validate()) return;
              Navigator.pop(
                ctx,
                EasyTile(
                  type: tile.type,
                  pinned: tile.pinned,
                  x: tile.x,
                  y: tile.y,
                  size: size,
                  height: height,
                  color: color,
                  output: output,
                  param: tile.type == EasyTileType.volumeDirect
                      ? double.parse(volume.text.replaceAll(',', '.'))
                      : param,
                  label: label.text.trim().isEmpty ? null : label.text.trim(),
                ),
              );
            },
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(index == null ? tr('Hinzufügen') : tr('Übernehmen')),
            ),
          ),
        ];
        return Scaffold(
          appBar: AppBar(
            title: Text(
              index == null ? tr('Kachel hinzufügen') : tr('Kachel bearbeiten'),
            ),
            actions: [
              if (index != null)
                IconButton(
                  key: ValueKey('easy-remove-$index'),
                  tooltip: tr('Entfernen'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    remove = true;
                    Navigator.pop(ctx);
                  },
                ),
            ],
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: content(constraints.maxHeight),
              ),
            ),
          ),
          bottomNavigationBar: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                spacing: 12,
                children: [
                  for (final action in actions) Flexible(child: action),
                ],
              ),
            ),
          ),
        );
      },
    );
    final route = MaterialPageRoute<EasyTile>(builder: buildEditor);
    final result = await Navigator.of(context).push(route);
    await route.completed;
    label.dispose();
    volume.dispose();
    if (!mounted) return;
    if (remove && index != null) {
      _save(_layout.copyWith(tiles: [..._layout.tiles]..removeAt(index)));
      return;
    }
    if (result == null) return;
    final tiles = [..._layout.tiles];
    if (index == null) {
      tiles.add(result);
    } else {
      tiles[index] = result;
    }
    _save(_layout.copyWith(tiles: tiles));
  }

  Widget _footerButton(
    String key,
    IconData icon,
    String label,
    String tooltip,
    VoidCallback? action, {
    Color color = Palette.text,
    Color borderColor = Palette.line,
    bool filled = false,
  }) {
    final enabled = action != null;
    final foreground = enabled
        ? (filled ? Palette.bg : color)
        : color.withValues(alpha: 0.38);
    final radius = BorderRadius.circular(10);
    return Expanded(
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          enabled: enabled,
          child: Material(
            key: ValueKey(key),
            color: filled && enabled ? color : Palette.bg,
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(
                color: enabled
                    ? borderColor
                    : borderColor.withValues(alpha: 0.18),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: action,
              borderRadius: radius,
              splashColor: Palette.text.withValues(alpha: 0.24),
              highlightColor: Palette.text.withValues(alpha: 0.12),
              hoverColor: Palette.text.withValues(alpha: 0.06),
              child: SizedBox(
                height: 64,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 24, color: foreground),
                      const SizedBox(height: 4),
                      Text(
                        label,
                        maxLines: 1,
                        style: ts(12, weight: 600, color: foreground),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_settings, AppLang.instance, widget.ctrl]),
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(tr('Eigene Ansicht einrichten'))),
      bottomNavigationBar: Material(
        color: Palette.surf,
        shape: const Border(top: BorderSide(color: Palette.line)),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              key: const ValueKey('easy-editor-footer'),
              children: [
                _footerButton(
                  'easy-add',
                  Icons.add_box_outlined,
                  tr('Hinzufügen'),
                  tr('Kachel hinzufügen'),
                  _add,
                  color: Palette.amber,
                  borderColor: Palette.amber,
                  filled: true,
                ),
                const SizedBox(width: 8),
                _footerButton(
                  'easy-clear-slot',
                  Icons.delete_outline,
                  tr('Löschen'),
                  tr('Slot leeren'),
                  _settings.easySlots(_variant).layouts[_settings
                              .easySlots(_variant)
                              .active] ==
                          null
                      ? null
                      : _clearSlot,
                  color: Palette.red,
                  borderColor: Palette.red.withValues(alpha: 0.45),
                ),
                const SizedBox(width: 8),
                _footerButton(
                  'easy-save-setup',
                  Icons.save_outlined,
                  tr('Speichern'),
                  tr('Setup speichern …'),
                  _saveSetup,
                  color: Palette.amber,
                  borderColor: Palette.amber,
                ),
                const SizedBox(width: 8),
                _footerButton(
                  'easy-reset',
                  Icons.restart_alt,
                  tr('Standard'),
                  tr('Auf Standard-Layout zurücksetzen'),
                  _reset,
                ),
              ],
            ),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: GestureDetector(
          key: const ValueKey('easy-editor-swipe'),
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (_) => _swipeDistance = 0,
          onHorizontalDragUpdate: (details) =>
              _swipeDistance += details.delta.dx,
          onHorizontalDragEnd: (_) => _swipeOutput(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        trf('Eigene Ansicht {n}', {
                          'n': _settings.easySlots(_variant).active + 1,
                        }),
                        style: ts(16, weight: 600),
                      ),
                      SwitchListTile(
                        key: const ValueKey('easy-same-page'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr('Für alle Ausgänge gleich')),
                        value: _setup.samePageForAllOutputs,
                        onChanged: (same) => _settings.setEasyLayout(
                          _variant,
                          _setup.setSamePageForAllOutputs(
                            same,
                            outputsFor(_variant).map((o) => o.address),
                            selectedOutput: _output,
                          ),
                        ),
                      ),
                      if (!_setup.samePageForAllOutputs) ...[
                        OutputSwitch(
                          key: const ValueKey('easy-editor-outputs'),
                          compact: true,
                          outs: outputsFor(_variant),
                          selected: _output,
                          onSelect: (output) =>
                              setState(() => _output = output),
                        ),
                        TextButton.icon(
                          key: const ValueKey('easy-copy-outputs'),
                          icon: const Icon(Icons.copy_outlined),
                          label: Text(tr('Auf andere Ausgänge kopieren …')),
                          onPressed: _copyToOutputs,
                        ),
                      ],
                      ExpansionTile(
                        key: const ValueKey('easy-layout-color'),
                        tilePadding: EdgeInsets.zero,
                        title: Text(tr('Standardfarbe')),
                        leading: CircleAvatar(
                          radius: 12,
                          backgroundColor: easyTileBackground(
                            _layout.defaultColor,
                          ),
                        ),
                        children: [
                          EasyColorPicker(
                            value: _layout.defaultColor,
                            onChanged: (color) =>
                                _save(_layout.copyWith(defaultColor: color)),
                          ),
                        ],
                      ),
                      HeaderContentPicker(
                        value: _layout.headerContent,
                        onChanged: (content) =>
                            _save(_layout.withHeaderContent(content)),
                      ),
                      FittedBox(
                        key: const ValueKey('easy-editor-hints'),
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Row(
                          children: [
                            const Icon(
                              Icons.push_pin_outlined,
                              size: 14,
                              color: Palette.muted,
                            ),
                            Text(
                              tr('fixieren'),
                              style: ts(12, color: Palette.muted),
                            ),
                            Text(' · ', style: ts(12, color: Palette.muted)),
                            const Icon(
                              Icons.edit_outlined,
                              size: 14,
                              color: Palette.muted,
                            ),
                            Text(
                              tr('bearbeiten'),
                              style: ts(12, color: Palette.muted),
                            ),
                            Text(' · ', style: ts(12, color: Palette.muted)),
                            Text(
                              tr('lange drücken = verschieben'),
                              style: ts(12, color: Palette.muted),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_layout.positionsAdjusted)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            tr(
                              'Fixierte Kacheln wurden an die nächste freie Rasterposition verschoben.',
                            ),
                            key: const ValueKey('easy-position-warning'),
                            style: ts(13, color: Palette.amber),
                          ),
                        ),
                      LayoutBuilder(
                        builder: (context, bounds) => Align(
                          alignment: Alignment.topCenter,
                          child: SizedBox(
                            width: isTabletLandscape(context)
                                ? tabletOutputColumnWidth(bounds.maxWidth + 32)
                                : null,
                            height: 400,
                            child: OutputsPage(
                              key: ValueKey((_variant, _output)),
                              editorOutput: _output,
                              ctrl: _ctrl,
                              easyLayout: _layout,
                              onPinTile: _pin,
                              onMoveTile: _moveTile,
                              onEditTile: (index) =>
                                  _edit(_layout.tiles[index], index),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
