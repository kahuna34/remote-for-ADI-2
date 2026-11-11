import 'package:flutter/material.dart';

import '../device/adi2_controller.dart';
import '../l10n/l10n.dart';
import '../protocol/adi2_codec.dart';
import '../protocol/adi2_params.dart';
import 'param_tile.dart';
import 'theme.dart';

/// Geräte-Setups am Ende der Geräteseite; offline nur der lokale Parameter.
class DeviceSetupSection extends StatefulWidget {
  const DeviceSetupSection({super.key, required this.ctrl});
  final Adi2Controller ctrl;

  @override
  State<DeviceSetupSection> createState() => _DeviceSetupSectionState();
}

class _DeviceSetupSectionState extends State<DeviceSetupSection> {
  int _selected = 1;
  Adi2Controller get c => widget.ctrl;

  String _name(int n) {
    final name = c.names[0x20 + n];
    return name == null || name.trim().isEmpty
        ? trf('Setup {n}', {'n': n})
        : name;
  }

  Future<bool> _confirm(
    String title,
    String message,
    String button, {
    bool destructive = false,
  }) async =>
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
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: Palette.red,
                      foregroundColor: Colors.white,
                    )
                  : null,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(button),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _load() async {
    final n = _selected;
    if (c.valueOr(Adi2Addr.device, DevIdx.loadVolumeWithSetup, 0) != 0) {
      if (!await _confirm(
        tr('Setup laden?'),
        tr('Die Lautstärke wird mit dem Setup geladen und kann lauter werden.'),
        tr('Laden'),
      )) {
        return;
      }
    }
    if (mounted && !c.offline) c.loadSetup(n);
  }

  Future<void> _save() async {
    final n = _selected;
    final ok = await _confirm(
      trf('{name} überschreiben?', {'name': _name(n)}),
      tr('Die aktuellen Einstellungen werden im Gerät gespeichert.'),
      tr('Speichern'),
    );
    if (ok && mounted && !c.offline) c.saveSetup(n);
  }

  Future<void> _factory() async {
    final ok = await _confirm(
      tr('Werkseinstellung laden?'),
      tr(
        'Alle aktuellen Einstellungen des Geräts werden auf Werkseinstellung gesetzt.',
      ),
      tr('Werkseinstellung'),
      destructive: true,
    );
    if (ok && mounted && !c.offline) c.loadFactory();
  }

  Future<void> _rename(int n) async {
    final form = GlobalKey<FormState>();
    var edited = _name(n).characters.take(nameLength).toString();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Umbenennen')),
        content: Form(
          key: form,
          child: TextFormField(
            initialValue: edited,
            autofocus: true,
            maxLength: nameLength,
            decoration: InputDecoration(labelText: tr('Name')),
            onChanged: (value) => edited = value,
            validator: (value) =>
                value == null ||
                    String.fromCharCodes(nameBytes(value).take(nameLength))
                        .trim()
                        .isEmpty
                ? tr('Bitte einen Namen eingeben.')
                : null,
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
                Navigator.pop(ctx, edited.trim());
              }
            },
            child: Text(tr('Speichern')),
          ),
        ],
      ),
    );
    if (name != null && mounted && !c.offline) c.renameSetup(n, name);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => Panel(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('Setup'), style: ts(16, weight: 600)),
            const SizedBox(height: 8),
            ParamTile(
              ctrl: c,
              address: Adi2Addr.device,
              def: deviceParams(c.variant!)
                  .firstWhere((d) => d.index == DevIdx.loadVolumeWithSetup),
            ),
            if (!c.offline) ...[
              const SizedBox(height: 8),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                mainAxisExtent: 64,
                children: [
                  for (var n = 1; n <= 9; n++)
                    Semantics(
                      selected: _selected == n,
                      child: Material(
                        color: _selected == n
                            ? Palette.amber.withValues(alpha: 0.15)
                            : Palette.bg,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(
                            color: _selected == n
                                ? Palette.amber
                                : Palette.line,
                          ),
                        ),
                        child: InkWell(
                          key: ValueKey('device-setup-$n'),
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => setState(() => _selected = n),
                          onLongPress: () => _rename(n),
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Text(
                                _name(n),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: ts(
                                  14,
                                  weight: 600,
                                  color: _selected == n
                                      ? Palette.amber
                                      : Palette.text,
                                ),
                              ),
                            ),
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
                  TextButton(onPressed: _load, child: Text(tr('Laden'))),
                  TextButton(onPressed: _save, child: Text(tr('Speichern'))),
                  TextButton(
                    onPressed: _factory,
                    child: Text(tr('Werkseinstellung')),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
