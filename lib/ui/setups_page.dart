import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../device/adi2_controller.dart';
import '../device/backup.dart';
import '../eq/eq_editor_buffer.dart';
import '../eq/eq_library.dart';
import '../eq/eq_model.dart';
import '../l10n/l10n.dart';
import '../protocol/adi2_codec.dart';
import '../protocol/adi2_params.dart';
import 'backup_page.dart';
import 'eq_page.dart';
import 'outputs_page.dart';
import 'theme.dart';
import 'responsive_layout.dart';

class SetupsPage extends StatefulWidget {
  const SetupsPage({super.key, required this.ctrl});
  final Adi2Controller ctrl;

  @override
  State<SetupsPage> createState() => _SetupsPageState();
}

class _SetupsPageState extends State<SetupsPage> {
  final _editor = EqEditorBuffer();
  EqEditorBuffer? _clipboard;
  final Map<int, String> _slotNames = {};
  List<AppEqPreset> _items = [];
  int? _selectedTarget;
  bool _busy = false;
  bool _listen = false;
  bool _right = false;
  bool _includeBassTreble = true;
  int _band = 0;
  int _slot = 0;
  double? _readProgress;

  Adi2Controller get c => widget.ctrl;
  int get _target => _selectedTarget ?? c.selectedOutput ?? Adi2Addr.line;
  int get _eqAddress =>
      _editor.dual && _right ? Adi2Addr.presetEqR : Adi2Addr.presetEqL;
  int _dualIdx(int target) => target == 0 ? 8 : OutIdx.dualEq;

  @override
  void initState() {
    super.initState();
    _selectedTarget = _target;
    _run(() async {
      _items = await EqLibrary.load();
      if (!mounted) return;
      if (!c.offline && c.eqPresets?.length != 20) await _reload();
    });
  }

  void _msg(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      _msg(tr('Vorgang konnte nicht abgeschlossen werden.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _sendEditor() {
    if (!_listen) return;
    final target = _target;
    for (final entry in _editor.left.entries) {
      c.setEq(target + 1, entry.key, entry.value);
    }
    for (final entry in _editor.right.entries) {
      c.setEq(target + 2, entry.key, entry.value);
    }
    if (c.valueOr(target, _dualIdx(target), 0) != (_editor.dual ? 1 : 0)) {
      c.set(target, _dualIdx(target), _editor.dual ? 1 : 0);
    }
  }

  void _write(int address, int index, int raw) {
    setState(() => _editor.set(address, index, raw));
    if (_listen) {
      c.setEq(
        address == Adi2Addr.presetEqL ? _target + 1 : _target + 2,
        index,
        _editor.value(address, index)!,
      );
    }
  }

  void _loadAppPreset(AppEqPreset preset) {
    setState(() {
      _editor.loadAppPreset(preset);
      _right = false;
    });
    _sendEditor();
    _msg(trf('{name} geladen', {'name': preset.name}));
  }

  EqPresetData? _preset(int slot) =>
      c.eqPresets?.where((p) => p.number == slot).firstOrNull;
  String _slotName(int slot) =>
      _slotNames[slot] ??
      (_preset(slot)?.name.isNotEmpty == true
          ? _preset(slot)!.name
          : c.presetName(slot));

  void _selectSlot(int slot) {
    final preset = _preset(slot);
    setState(() {
      _slot = slot;
      if (preset != null) {
        _editor.loadDevicePreset(preset);
        _editor.name = _slotNames[slot] ?? _editor.name;
        _right = false;
      }
    });
    if (preset == null) {
      _msg(tr('Nicht eingelesen'));
    } else {
      _sendEditor();
    }
  }

  Future<void> _reload() async {
    if (c.offline) return;
    setState(() => _readProgress = 0);
    try {
      await c.readEqPresets(
        progress: (value) {
          if (mounted) setState(() => _readProgress = value);
        },
      );
      if (mounted) setState(_slotNames.clear);
    } finally {
      if (mounted) setState(() => _readProgress = null);
    }
  }

  Future<String?> _nameDialog(
    String title,
    String name, {
    bool device = false,
    bool store = false,
  }) async {
    final form = GlobalKey<FormState>();
    var editedName = device
        ? name.characters.take(nameLength).toString()
        : name;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: editedName,
                  autofocus: true,
                  maxLength: device ? nameLength : null,
                  decoration: InputDecoration(labelText: tr('Name')),
                  onChanged: (value) => editedName = value,
                  validator: (value) => value == null || value.trim().isEmpty
                      ? tr('Bitte einen Namen eingeben.')
                      : null,
                ),
                if (store)
                  Text(
                    tr('Das Preset im Gerät wird überschrieben.'),
                    style: ts(13, color: Palette.muted),
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
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(ctx, editedName.trim());
              }
            },
            child: Text(tr('Speichern')),
          ),
        ],
      ),
    );
  }

  Future<void> _renameSlot(int slot) async {
    final name = await _nameDialog(
      tr('Umbenennen'),
      _slotName(slot),
      device: true,
    );
    if (name == null || !mounted) return;
    setState(() {
      _slotNames[slot] = name;
      if (_slot == slot) _editor.name = name;
    });
  }

  Future<void> _store() async {
    final slot = _slot;
    final name = await _nameDialog(
      trf('Preset {n} überschreiben?', {'n': slot + 1}),
      _slotNames[slot] ??
          (_editor.name.isEmpty ? _slotName(slot) : _editor.name),
      device: true,
      store: true,
    );
    if (name == null || c.offline) return;
    await c.storeEqPresetData(
      slot,
      _editor.left,
      _editor.right,
      _editor.dual,
      name,
    );
    if (!mounted) return;
    setState(() {
      _slotNames[slot] = c.names[slot + 1] ?? name;
      _editor.name = _slotNames[slot]!;
    });
    _msg(trf('Gespeichert als Preset {n}', {'n': slot + 1}));
  }

  Future<void> _clear() async {
    if (!await _confirm(
      tr('Editor leeren?'),
      tr(
        'Alle Bänder im Editor werden auf Werkseinstellungen und 0 dB gestellt.',
      ),
      tr('Clear'),
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _editor.clear();
      _right = false;
    });
    _sendEditor();
  }

  Future<void> _saveItems(List<AppEqPreset> items) async {
    await EqLibrary.save(items);
    _items = items;
  }

  Future<void> _saveEditor() async {
    final name = await _nameDialog(
      tr('In App-Bibliothek speichern'),
      _editor.name.isEmpty ? tr('EQ') : _editor.name,
    );
    if (name == null) return;
    await _saveItems([..._items, _editor.toAppPreset(name: name)]);
    if (mounted) setState(() => _editor.name = name);
  }

  Future<void> _import() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      if (files.isEmpty) return;
      final preset = AppEqPreset.decode(await files.first.xFile.readAsString());
      await _saveItems([..._items, preset]);
      if (mounted) _loadAppPreset(preset);
    } catch (_) {
      _msg(tr('Datei ist kein EQ-Preset.'));
    }
  }

  Future<void> _share(AppEqPreset preset) async {
    final file = await EqLibrary.exportFile(preset);
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/json')],
        subject: preset.name,
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  Future<void> _appAction(String action, AppEqPreset preset) async {
    switch (action) {
      case 'rename':
        final name = await _nameDialog(tr('Umbenennen'), preset.name);
        if (name == null) return;
        await _saveItems([
          for (final item in _items)
            if (identical(item, preset))
              AppEqPreset(
                name: name,
                dual: item.dual,
                left: item.left,
                right: item.right,
              )
            else
              item,
        ]);
      case 'share':
        await _share(preset);
      case 'delete':
        if (await _confirm(
          trf('{name} löschen?', {'name': preset.name}),
          tr('Die Datei wird aus der App entfernt.'),
          tr('Löschen'),
        )) {
          await _saveItems(_items.where((p) => !identical(p, preset)).toList());
        }
    }
  }

  Future<void> _library() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, refresh) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.7,
            child: Column(
              children: [
                Text(tr('App-Bibliothek'), style: ts(18, weight: 600)),
                TextButton.icon(
                  icon: const Icon(Icons.file_open_outlined),
                  label: Text(tr('Importieren')),
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    _run(_import);
                  },
                ),
                Expanded(
                  child: ListView(
                    children: [
                      if (_items.isEmpty)
                        ListTile(
                          title: Text(tr('Noch keine EQ-Presets gesichert.')),
                        ),
                      for (final preset in _items)
                        ListTile(
                          title: Text(preset.name),
                          subtitle: Text(
                            preset.dual ? tr('Dual EQ') : tr('EQ'),
                          ),
                          leading: IconButton(
                            tooltip: tr('Laden'),
                            icon: const Icon(Icons.file_download_outlined),
                            onPressed: () {
                              Navigator.pop(sheetContext);
                              _loadAppPreset(preset);
                            },
                          ),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _loadAppPreset(preset);
                          },
                          trailing: PopupMenuButton<String>(
                            onSelected: (action) async {
                              await _run(() => _appAction(action, preset));
                              if (sheetContext.mounted) refresh(() {});
                            },
                            itemBuilder: (_) => [
                              _menuItem('share', tr('Teilen')),
                              _menuItem('rename', tr('Umbenennen')),
                              _menuItem('delete', tr('Löschen')),
                            ],
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
    );
  }

  Future<bool> _confirm(String title, String message, String button) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Abbrechen')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(button),
            ),
          ],
        ),
      ) ??
      false;

  String _setupName(int n) {
    final name = c.names[0x20 + n];
    return name == null || name.isEmpty ? trf('Setup {n}', {'n': n}) : name;
  }

  Future<void> _saveSetup(int n) async {
    final ok = await _confirm(
      trf('{name} überschreiben?', {'name': _setupName(n)}),
      tr('Die aktuellen Einstellungen werden im Gerät gespeichert.'),
      tr('Speichern'),
    );
    if (ok && !c.offline) c.saveSetup(n);
  }

  Future<void> _transferInfo() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.85,
    ),
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('Offline-Einstellungen übertragen'),
              style: ts(18, weight: 600),
            ),
            const SizedBox(height: 12),
            for (final text in [
              tr(
                'Was es ist: Im Offline-Modus (Startbildschirm → Ohne Gerät arbeiten → Modell wählen) festgelegte Einstellungen werden je Modell in der App gespeichert.',
              ),
              tr(
                'Was übertragen wird: Der gespeicherte Offline-Stand (Ausgänge, EQ, Gerät …) wird ins angeschlossene Gerät gleichen Modells übertragen. Nur Abweichungen werden gesendet; auch unveränderte Offline-Ausgangswerte können dabei Geräteeinstellungen ersetzen.',
              ),
              tr(
                'Sicherheit: Lautstärken werden nur übernommen, wenn sie leiser sind als jetzt am Gerät. Die Lautstärkegrenzen der App gelten weiterhin.',
              ),
              tr(
                'Was unverändert bleibt: Gespeicherte Setups 1–9 und EQ-Presets im Gerät sowie die Presetwahl. Anzeigewerte (Sample-Rate) und Aktionen (Ausgänge umschalten) werden nicht übertragen.',
              ),
              tr(
                'Tipp: Vorher ein Backup sichern (Setups → Weiteres → Backup sichern / laden).',
              ),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('•  '),
                    Expanded(child: Text(text)),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Future<void> _transfer() async {
    if (!await c.hasOfflineData()) {
      _msg(tr('Für dieses Modell gibt es keinen Offline-Stand.'));
      return;
    }
    if (!mounted) return;
    final settingsText = tr(
      'Alle offline festgelegten Einstellungen werden ins Gerät geschrieben. Lautstärken werden nur übernommen, wenn sie leiser sind als jetzt am Gerät. Gespeicherte Setups und EQ-Presets im Gerät bleiben unverändert.',
    );
    final refLevelWarning = tr(
      'Ein höherer Ref Level kann den Ausgang lauter machen, auch wenn die Lautstärke nicht steigt. Ausgänge vorher leiser stellen oder eine Obergrenze aktivieren.',
    );
    final ok = await _confirm(
      tr('Offline-Einstellungen übertragen?'),
      '$settingsText\n\n$refLevelWarning',
      tr('Übertragen'),
    );
    if (!ok || c.offline) return;
    final n = await c.transferOffline();
    _msg(
      n == 0
          ? tr('Gerät entspricht bereits dem Offline-Stand.')
          : trf('{n} Einstellungen übertragen.', {'n': n}),
    );
  }

  Widget _section(String title, List<Widget> children, {Widget? actions}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Panel(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          child: Material(
            color: Colors.transparent,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(title, style: ts(16, weight: 600))),
                    ?actions,
                  ],
                ),
                const SizedBox(height: 8),
                ...children,
              ],
            ),
          ),
        ),
      );

  PopupMenuItem<String> _menuItem(String action, String label) =>
      PopupMenuItem(value: action, child: Text(label));

  Widget _editorPanel(List<(int, String)> targets) {
    final targetName =
        targets.where((t) => t.$1 == _target).firstOrNull?.$2 ?? tr('EQ');
    return _section(
      tr('EQ-Preset-Editor'),
      [
        Row(
          children: [
            for (var i = 0; i < targets.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  selected: targets[i].$1 == _target,
                  child: OutlinedButton(
                    key: ValueKey('eq-target-${targets[i].$1}'),
                    onPressed: _busy
                        ? null
                        : () {
                            setState(() => _selectedTarget = targets[i].$1);
                            _sendEditor();
                          },
                    style: OutlinedButton.styleFrom(
                      backgroundColor: targets[i].$1 == _target
                          ? Palette.surf2
                          : Palette.bg,
                      side: BorderSide(
                        color: targets[i].$1 == _target
                            ? Palette.amber
                            : Palette.line,
                        width: targets[i].$1 == _target ? 1.5 : 1,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 2,
                        vertical: 9,
                      ),
                      textStyle: ts(
                        14,
                        weight: targets[i].$1 == _target ? 600 : 500,
                      ),
                      foregroundColor: targets[i].$1 == _target
                          ? Palette.text
                          : Palette.muted,
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(targets[i].$2, textAlign: TextAlign.center),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: Semantics(
            toggled: _listen,
            child: OutlinedButton.icon(
              key: const ValueKey('eq-listen'),
              onPressed: _busy
                  ? null
                  : () {
                      setState(() => _listen = !_listen);
                      _sendEditor();
                    },
              style: OutlinedButton.styleFrom(
                backgroundColor: _listen ? Palette.amber : Palette.bg,
                foregroundColor: _listen ? Palette.bg : Palette.text,
                side: BorderSide(color: _listen ? Palette.amber : Palette.line),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                textStyle: ts(14, weight: 600),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
              ),
              icon: Icon(
                _listen ? Icons.headphones : Icons.headphones_outlined,
                size: 18,
              ),
              label: Text(
                _listen
                    ? trf('Anhören auf {output}', {'output': targetName})
                    : trf('Auf {output} anhören', {'output': targetName}),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        EqDualControls(
          dual: _editor.dual,
          right: _right,
          onDualChanged: _busy
              ? null
              : (on) {
                  setState(() {
                    _editor.dual = on;
                    if (!on) _right = false;
                  });
                  _sendEditor();
                },
          onSideChanged: (r) => setState(() => _right = r),
          onClear: _busy ? null : () => _run(_clear),
        ),
        const SizedBox(height: 8),
        EqPlot(
          read: _editor.value,
          write: _write,
          eqAddr: _eqAddress,
          btAddr: Adi2Addr.presetEqL,
          selected: _band,
          enabled: true,
          includeBassTreble: _includeBassTreble,
          onSelect: (band) => setState(() => _band = band),
        ),
        Text(
          _editor.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ts(11, color: Palette.muted),
        ),
        EqBandChips(
          selected: _band,
          onSelect: (band) => setState(() => _band = band),
        ),
        const SizedBox(height: 8),
        EqBandControls(
          band: _band,
          address: eqBands[_band].isBassTreble
              ? Adi2Addr.presetEqL
              : _eqAddress,
          read: _editor.value,
          write: _write,
        ),
        EqCurveControls(
          includeBassTreble: _includeBassTreble,
          onChanged: (on) => setState(() => _includeBassTreble = on),
        ),
      ],
      actions: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<String>(
            enabled: !_busy,
            onSelected: (action) {
              if (action == 'library') {
                _library();
              } else if (action == 'import') {
                _run(_import);
              } else if (action == 'save') {
                _run(_saveEditor);
              } else if (action == 'share') {
                _run(
                  () => _share(
                    _editor.toAppPreset(
                      name: _editor.name.isEmpty ? tr('EQ') : _editor.name,
                    ),
                  ),
                );
              }
            },
            itemBuilder: (_) => [
              _menuItem('library', tr('Aus App-Bibliothek laden')),
              _menuItem('import', tr('Importieren')),
              _menuItem('save', tr('In App-Bibliothek speichern')),
              _menuItem('share', tr('Teilen')),
            ],
            tooltip: tr('Datei'),
            icon: const Icon(Icons.folder_outlined, size: 20),
            color: Palette.surf,
          ),
        ],
      ),
    );
  }

  Widget _presetsPanel() => _section(tr('EQ-Presets (1–20)'), [
    if (_readProgress != null || c.eqPresetReadProgress != null) ...[
      LinearProgressIndicator(value: c.eqPresetReadProgress ?? _readProgress),
      const SizedBox(height: 8),
      Text(
        tr('EQ-Presets werden eingelesen…'),
        style: ts(13, color: Palette.muted),
      ),
    ],
    GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 6,
      crossAxisSpacing: 8,
      mainAxisExtent: 62,
      children: [
        for (var slot = 0; slot < 20; slot++)
          Material(
            color: _slot == slot ? Palette.surf2 : Palette.bg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                color: _slot == slot ? Palette.amber : Palette.line,
              ),
            ),
            child: InkWell(
              key: ValueKey('eq-slot-$slot'),
              borderRadius: BorderRadius.circular(10),
              onTap: _busy ? null : () => _selectSlot(slot),
              onLongPress: _busy ? null : () => _run(() => _renameSlot(slot)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Icon(
                      _slot == slot
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 18,
                      color: _slot == slot ? Palette.amber : Palette.muted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            trf('{n}  {name}', {
                              'n': slot + 1,
                              'name': _slotName(slot),
                            }),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ts(
                              13,
                              weight: 600,
                              color: _slot == slot
                                  ? Palette.amber
                                  : Palette.text,
                            ),
                          ),
                          if (_preset(slot) == null)
                            Text(
                              tr('Nicht eingelesen'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ts(11, color: Palette.muted),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
    const SizedBox(height: 8),
    Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        if (!c.offline) ...[
          TextButton.icon(
            onPressed: _busy ? null : () => _run(_store),
            icon: const Icon(Icons.save_outlined, size: 18),
            label: Text(tr('Ins Gerät speichern')),
          ),
          TextButton.icon(
            onPressed: _busy ? null : () => _run(_reload),
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(tr('Neu einlesen')),
          ),
        ],
        TextButton.icon(
          onPressed: _busy
              ? null
              : () => setState(() => _clipboard = _editor.copy()),
          icon: const Icon(Icons.copy, size: 18),
          label: Text(tr('Kopieren')),
        ),
        TextButton.icon(
          onPressed: _busy || _clipboard == null
              ? null
              : () {
                  setState(() {
                    _editor.paste(_clipboard!);
                    _right = false;
                  });
                  _sendEditor();
                },
          icon: const Icon(Icons.paste, size: 18),
          label: Text(tr('Einfügen')),
        ),
      ],
    ),
  ]);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final variant = c.variant;
      if (variant == null) return const SizedBox.shrink();
      final targets = [
        for (final output in outputsFor(variant)) (output.address, output.name),
        if (variant.hasInput) (0, tr('Eingang')),
      ];
      return AdaptivePageList(
        splitAt: 1,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _editorPanel(targets),
          _presetsPanel(),
          if (!c.offline)
            _section(tr('Geräte-Setups 1–9'), [
              for (var n = 1; n <= 9; n++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _setupName(n),
                          overflow: TextOverflow.ellipsis,
                          style: ts(15, weight: 500),
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: _busy ? null : () => c.loadSetup(n),
                            child: Text(tr('Laden')),
                          ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _run(() => _saveSetup(n)),
                            child: Text(tr('Speichern')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ]),
          _section(tr('Weiteres'), [
            if (c.offline)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('Offline-Stand auf Werkseinstellung')),
                onTap: _busy ? null : () => _run(c.resetOffline),
              )
            else ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('Backup sichern / laden')),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => BackupPage(ctrl: c),
                        ),
                      ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('Offline-Einstellungen übertragen')),
                trailing: IconButton(
                  tooltip: tr('Info'),
                  icon: const Icon(Icons.info_outline),
                  onPressed: _transferInfo,
                ),
                onTap: _busy ? null : () => _run(_transfer),
              ),
            ],
          ]),
        ],
      );
    },
  );
}
