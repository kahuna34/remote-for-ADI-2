import 'package:flutter/material.dart';

import '../eq/eq_library.dart';
import '../eq/eq_model.dart';
import '../eq/eq_preset_library.dart';
import '../l10n/l10n.dart';

String eqLibraryCredit() =>
    '${tr('EQ-Presets: oratory1990 (reddit.com/r/oratory1990), für den RME ADI-2 aufbereitet.')} '
    '${tr('Mit „Angepasst“ markierte Presets sind automatisch aus oratory1990s Korrekturen berechnet.')}';

class EqPresetLibraryPage extends StatefulWidget {
  const EqPresetLibraryPage({super.key});
  @override
  State<EqPresetLibraryPage> createState() => _EqPresetLibraryPageState();
}

class _EqPresetLibraryPageState extends State<EqPresetLibraryPage> {
  late final _entries = EqPresetLibrary.load();
  String _query = '';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr('EQ-Bibliothek'))),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              decoration: InputDecoration(
                labelText: tr('Marke, Modell, Variante suchen'),
                prefixIcon: const Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<EqLibraryEntry>>(
              future: _entries,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text(tr('Bibliothek konnte nicht geladen werden.')),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final entries = snapshot.data!
                    .where((entry) => entry.matches(_query))
                    .toList();
                return ListView(
                  children: [
                    if (entries.isEmpty)
                      ListTile(title: Text(tr('Keine passenden Presets.'))),
                    for (var i = 0; i < entries.length; i++) ...[
                      if (i == 0 || entries[i - 1].brand != entries[i].brand)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                          child: Text(
                            entries[i].brand,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ListTile(
                        title: Text(entries[i].model),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (entries[i].variant.isNotEmpty)
                              Text(entries[i].variant),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Chip(
                                  label: Text(
                                    entries[i].target,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                                if (entries[i].generated != null ||
                                    entries[i].fit != null)
                                  Chip(
                                    avatar: const Icon(Icons.tune, size: 16),
                                    label: Text(
                                      entries[i].generated != null
                                          ? tr('Angepasst')
                                          : tr('2 Fassungen'),
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall,
                                    ),
                                    visualDensity: VisualDensity.compact,
                                  ),
                              ],
                            ),
                          ],
                        ),
                        trailing: entries[i].notes.isEmpty
                            ? null
                            : Icon(
                                Icons.info_outline,
                                semanticLabel: tr('Hinweise'),
                              ),
                        onTap: () async {
                          final preset = await Navigator.push<AppEqPreset>(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  EqLibraryDetailPage(entry: entries[i]),
                            ),
                          );
                          if (preset != null && context.mounted) {
                            Navigator.pop(context, preset);
                          }
                        },
                      ),
                    ],
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(eqLibraryCredit()),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

class EqLibraryDetailPage extends StatefulWidget {
  const EqLibraryDetailPage({super.key, required this.entry});
  final EqLibraryEntry entry;
  @override
  State<EqLibraryDetailPage> createState() => _EqLibraryDetailPageState();
}

class _EqLibraryDetailPageState extends State<EqLibraryDetailPage> {
  bool _saving = false;
  bool _fitted = false;

  String _distance(double value) =>
      _number(value.toStringAsFixed(2).replaceAll('.', ','));

  void _explain() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr('Vergleich der Fassungen')),
      content: SingleChildScrollView(
        child: Text(
          tr(
            'Original = oratory1990s Korrektur mit bis zu 10 Bändern. Die ADI-2-Fassung von oratory1990 nutzt hier Werte außerhalb der Gerätegrenzen; diese werden begrenzt oder entfallen. Die angepasste Fassung ist automatisch berechnet und nicht von oratory1990 geprüft. Die Gegenprobe vergleicht Messdaten mit dem Harman-Target. Kleiner = näher; der Hörtest entscheidet.',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('Schließen')),
        ),
      ],
    ),
  );
  String _number(String value) => AppLang.instance.language == AppLanguage.en
      ? value.replaceAll(',', '.')
      : value;
  String _note(EqLibraryNote note) {
    if (note.kind == 'dropped') {
      return trf('Zusätzlicher High-Shelf bei {freq} nicht übertragbar', {
        'freq': _number(fmtFreq(note.from.round())),
      });
    }
    final band = ['Bass', 'Treble'].contains(note.band)
        ? tr(note.band)
        : trf('Band {band}', {'band': note.band});
    return trf('{band}: {param} {from} → {to} (Gerätegrenze)', {
      'band': band,
      'param': note.param == 'q' ? tr('Q') : tr('Frequenz'),
      'from': _number(
        note.param == 'q'
            ? note.from.toStringAsFixed(1).replaceAll('.', ',')
            : fmtFreq(note.from.round()),
      ),
      'to': _number(
        note.param == 'q'
            ? note.to.toStringAsFixed(1).replaceAll('.', ',')
            : fmtFreq(note.to.round()),
      ),
    });
  }

  Future<void> _add() async {
    setState(() => _saving = true);
    try {
      final added = await EqPresetLibrary.addToPersonal(
        widget.entry,
        fitted: _fitted,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              added
                  ? tr('Zu meinen Presets hinzugefügt.')
                  : tr('Bereits in meinen Presets.'),
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Vorgang konnte nicht abgeschlossen werden.')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final values = _fitted ? entry.fit!.left : entry.left;
    return Scaffold(
      appBar: AppBar(title: Text(tr('EQ-Preset'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(entry.name, style: Theme.of(context).textTheme.titleLarge),
            Text(entry.target),
            const SizedBox(height: 16),
            if (entry.generated != null) ...[
              Card(
                margin: EdgeInsets.zero,
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    trf(
                      'Automatisch aus oratory1990s 10-Band-Korrektur an die ADI-2-Grenzen angepasst. Nicht von oratory1990 geprüft. Abweichung vom Original: {deviation} dB.',
                      {'deviation': _distance(entry.generated!.deviation)},
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (entry.generated == null && entry.fit != null) ...[
              RadioGroup<bool>(
                groupValue: _fitted,
                onChanged: (value) {
                  if (value != null) setState(() => _fitted = value);
                },
                child: Column(
                  children: [
                    RadioListTile<bool>(
                      value: false,
                      title: Text(tr('oratory1990')),
                      subtitle: Text(tr('an Gerätegrenzen gesetzt')),
                      contentPadding: EdgeInsets.zero,
                    ),
                    RadioListTile<bool>(
                      value: true,
                      title: Text(tr('Angepasst')),
                      subtitle: Text(
                        tr('neu an das 10-Band-Original angepasst'),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (entry.deviation != null &&
                            entry.fit!.deviation != null)
                          Text(
                            trf(
                              'Abweichung vom Original: {preset} dB / {fit} dB',
                              {
                                'preset': _distance(
                                  entry.deviation!.original10,
                                ),
                                'fit': _distance(entry.fit!.deviation!),
                              },
                            ),
                          ),
                        if (entry.measured != null)
                          Text(
                            trf(
                              'Gegenprobe Messung: Original {original} · oratory1990 {preset} · angepasst {fit} dB',
                              {
                                'original': _distance(
                                  entry.measured!.original10,
                                ),
                                'preset': _distance(entry.measured!.preset),
                                'fit': _distance(entry.measured!.fit),
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: tr('Vergleich der Fassungen'),
                    onPressed: _explain,
                    icon: const Icon(Icons.info_outline),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                horizontalMargin: 0,
                columnSpacing: 16,
                columns: [
                  for (final label in [
                    tr('Band'),
                    tr('Typ'),
                    tr('Frequenz'),
                    tr('Gain'),
                    tr('Q'),
                  ])
                    DataColumn(label: Text(label)),
                ],
                rows: [
                  for (final band in eqBands)
                    DataRow(
                      cells: [
                        DataCell(Text(tr(band.label))),
                        DataCell(Text(tr(band.typeName(values[band.typeIdx])))),
                        DataCell(Text(_number(fmtFreq(values[band.freqIdx]!)))),
                        DataCell(Text(_number(fmtGain(values[band.gainIdx]!)))),
                        DataCell(Text(_number(fmtQ(values[band.qIdx]!)))),
                      ],
                    ),
                ],
              ),
            ),
            if (!_fitted && entry.notes.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                tr('Hinweise'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final note in entry.notes)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_note(note)),
                ),
            ],
            const SizedBox(height: 16),
            Text(tr('Lautstärke beim Vergleichen angleichen')),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    entry.toAppPreset(fitted: _fitted),
                  ),
                  child: Text(tr('Laden')),
                ),
                OutlinedButton(
                  onPressed: _saving ? null : _add,
                  child: Text(tr('Zu meinen Presets')),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(eqLibraryCredit()),
          ],
        ),
      ),
    );
  }
}
