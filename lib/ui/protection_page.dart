import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../device/adi2_controller.dart';
import '../device/volume_options.dart';
import '../protocol/adi2_params.dart';
import 'outputs_page.dart';
import 'theme.dart';
import 'volume_ring.dart';

/// Obergrenze (dBu), Anstiegsgeschwindigkeit, Merk-Lautstärke, Koppeln.
class ProtectionPage extends StatelessWidget {
  const ProtectionPage({super.key, required this.ctrl, required this.out});
  final Adi2Controller ctrl;
  final OutputInfo out;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final v = ctrl.variant;
        if (v == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(child: Text(tr('Nicht verbunden'))),
          );
        }
        final a = out.address;
        final o = ctrl.opts.of(a);
        final ref = ctrl.currentRefDbu(a);
        final refName = outputParams(v, phones: out.phones)
            .firstWhere((d) => d.index == OutIdx.refLevel)
            .format(ctrl.valueOr(a, OutIdx.refLevel, 0));
        final limit = o.limitDbu;
        final maxDb = ctrl.volumeLimit(a) / 10;

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('Volume Limit')),
                Text(
                  '${out.name}, $refName'
                  '${ref == null ? '' : ' (${_dbu(ref)})'}',
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
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _Section(
                icon: Icons.shield_outlined,
                title: tr('Obergrenze'),
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr('Obergrenze aktiv')),
                    value: limit != null,
                    onChanged: (on) =>
                        ctrl.setLimitDbu(a, on ? (ref ?? 10) - 20 : null),
                  ),
                  if (limit != null) ...[
                    Row(
                      children: [
                        _Step(
                          icon: Icons.remove,
                          onTap: () => ctrl.setLimitDbu(a, limit - 1),
                        ),
                        Expanded(
                          child: Column(
                            children: [
                              Text(
                                _dbu(limit),
                                style: ts(30, weight: 300, width: 110),
                              ),
                              Text(
                                trf('entspricht max. {wert} am Gerät', {
                                  'wert': fmtDb(maxDb),
                                }),
                                style: ts(
                                  12,
                                  weight: 500,
                                  color: Palette.muted,
                                  narrow: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                        _Step(
                          icon: Icons.add,
                          onTap: () => ctrl.setLimitDbu(a, limit + 1),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                  _Note(
                    tr(
                      'Die Grenze gilt für den Pegel am Ausgang. Wird der Ref-Level umgeschaltet, rechnet die App die erlaubte Lautstärke neu und senkt sie vorher, falls nötig. Wird am Gerät höher gedreht, regelt die App zurück, solange sie verbunden ist.',
                    ),
                  ),
                ],
              ),
              _Section(
                icon: Icons.trending_up,
                title: tr('Lauter werden'),
                children: [
                  _Segmented(
                    options: [for (final m in RiseMode.values) tr(m.label)],
                    selected: ctrl.opts.rise.index,
                    onSelect: (i) => ctrl.setRiseMode(RiseMode.values[i]),
                  ),
                  _Note(
                    tr(
                      'Adaptiv: je lauter, desto langsamer. Leiser geht immer sofort. Loslassen hält die Anhebung an. Gilt für alle Ausgänge.',
                    ),
                  ),
                ],
              ),
              _Section(
                icon: Icons.bookmark_border,
                title: tr('Recall-Lautstärke'),
                children: [
                  Row(
                    children: [
                      if (o.recallRaw != null)
                        IconButton(
                          tooltip: tr('Löschen'),
                          icon: const Icon(Icons.close, color: Palette.muted),
                          onPressed: () => ctrl.setRecall(a, null),
                        ),
                      Expanded(
                        child: Text(
                          o.recallRaw == null
                              ? tr('nicht gesetzt')
                              : fmtDb(o.recallRaw! / 10),
                          style: ts(24, weight: 300, width: 110),
                        ),
                      ),
                      TextButton(
                        onPressed: () => ctrl.setRecall(
                          a,
                          ctrl.valueOr(a, OutIdx.volume, -300),
                        ),
                        child: Text(tr('Aktuelle übernehmen')),
                      ),
                    ],
                  ),
                  _Note(
                    tr(
                      'Die Taste „Recall“ auf der Hauptseite stellt diesen Wert ein, beim Anheben langsam. Langes Drücken dort speichert die aktuelle Lautstärke.',
                    ),
                  ),
                ],
              ),
              _Section(
                icon: Icons.link,
                title: tr('Gekoppelte Ausgänge'),
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final x in outputsFor(v))
                        FilterChip(
                          label: Text(x.name),
                          selected: ctrl.opts.linked.contains(x.address),
                          onSelected: (on) => ctrl.setLinked(x.address, on),
                          showCheckmark: true,
                          checkmarkColor: Palette.amber,
                          selectedColor: Palette.surf2,
                          backgroundColor: Palette.bg,
                          side: BorderSide(
                            color: ctrl.opts.linked.contains(x.address)
                                ? Palette.amber
                                : Palette.line,
                          ),
                          labelStyle: ts(14, weight: 500),
                        ),
                    ],
                  ),
                  _Note(
                    tr(
                      'Gekoppelte Ausgänge ändern sich gemeinsam um denselben Betrag. Jede Obergrenze gilt weiter.',
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

String _dbu(double v) =>
    '${v < 0 ? '−' : '+'}${v.abs().toStringAsFixed(1).replaceAll('.', ',')} dBu';

class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.children,
  });
  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: Palette.amber),
                const SizedBox(width: 8),
                Text(title, style: ts(16, weight: 600)),
              ],
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Text(text, style: ts(13, color: Palette.muted, height: 1.4)),
  );
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: Palette.surf2,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Icon(icon, color: Palette.text),
      ),
    ),
  );
}

class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.options,
    required this.selected,
    required this.onSelect,
  });
  final List<String> options;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: Palette.bg,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        for (var i = 0; i < options.length; i++)
          Expanded(
            child: GestureDetector(
              onTap: () => onSelect(i),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: i == selected ? Palette.surf2 : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                  border: i == selected
                      ? Border.all(color: Palette.amber)
                      : null,
                ),
                child: Text(
                  options[i],
                  textAlign: TextAlign.center,
                  style: ts(
                    14,
                    weight: i == selected ? 600 : 500,
                    color: i == selected ? Palette.text : Palette.muted,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
