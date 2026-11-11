import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/l10n.dart';
import '../device/adi2_controller.dart';
import '../device/backup.dart';
import 'theme.dart';

/// Backups im App-Speicher (Ordner "backups").
class BackupStore {
  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/backups');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<List<(File, Adi2Backup)>> list() async {
    final d = await _dir();
    final out = <(File, Adi2Backup)>[];
    await for (final f in d.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        out.add((f, Adi2Backup.decode(await f.readAsString())));
      } catch (_) {
        // fremde/kaputte Datei überspringen
      }
    }
    out.sort((a, b) => b.$2.created.compareTo(a.$2.created));
    return out;
  }

  static Future<File> save(Adi2Backup b) async {
    final d = await _dir();
    final f = File('${d.path}/${b.fileName}');
    return f.writeAsString(b.encode());
  }
}

class BackupPage extends StatefulWidget {
  const BackupPage({super.key, required this.ctrl});
  final Adi2Controller ctrl;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  List<(File, Adi2Backup)> _items = [];
  double? _progress;

  Adi2Controller get c => widget.ctrl;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final l = await BackupStore.list();
    if (mounted) setState(() => _items = l);
  }

  void _msg(String t) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(t)));

  Future<void> _create() async {
    setState(() => _progress = 0);
    final b = await c.createBackup(
      progress: (p) => mounted ? setState(() => _progress = p) : null,
    );
    if (!mounted) return;
    setState(() => _progress = null);
    if (b == null) {
      _msg(tr('Backup nicht möglich: Gerät nicht verbunden.'));
      return;
    }
    await BackupStore.save(b);
    final used = b.presets.where((p) => !p.empty).length;
    _msg(
      trf(
        'Backup gespeichert: {anzahl} Einstellungen, {belegt} von 20 EQ-Presets belegt.',
        {'anzahl': b.values.length, 'belegt': used},
      ),
    );
    _reload();
  }

  Future<void> _import() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (files.isEmpty) return;
    try {
      final b = Adi2Backup.decode(await files.first.xFile.readAsString());
      await BackupStore.save(b);
      _msg(tr('Backup importiert.'));
      _reload();
    } on FormatException catch (e) {
      _msg(e.message);
    } catch (_) {
      _msg(tr('Datei konnte nicht gelesen werden.'));
    }
  }

  Future<void> _share(File f) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(f.path, mimeType: 'application/json')],
        subject: tr('ADI-2 Backup'),
      ),
    );
  }

  Future<void> _delete(File f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Backup löschen?')),
        content: Text(tr('Die Datei wird aus der App entfernt.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Abbrechen')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Löschen')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await f.delete();
      _reload();
    }
  }

  Future<void> _restore(Adi2Backup b) async {
    if (c.offline || c.variant == null) {
      _msg(tr('Zum Wiederherstellen das Gerät anschließen.'));
      return;
    }
    if (b.variant != c.variant!.name) {
      _msg(
        trf(
          'Dieses Backup stammt von einem {modell}, verbunden ist ein {geraet}.',
          {'modell': b.label, 'geraet': c.deviceLabel},
        ),
      );
      return;
    }
    var presets = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(tr('Backup wiederherstellen?')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                trf(
                  'Alle Einstellungen vom {datum} werden ins Gerät geschrieben. Lautstärken werden nur übernommen, wenn sie leiser sind als jetzt.',
                  {'datum': _date(b.created)},
                ),
                style: ts(15, color: Palette.muted, height: 1.4),
              ),
              if (b.values.keys.any(
                (key) => Adi2Controller.volumeAddresses.contains(key >> 8),
              )) ...[
                const SizedBox(height: 8),
                Text(
                  tr(
                    'Ein höherer Ref Level kann den Ausgang lauter machen, auch wenn die Lautstärke nicht steigt. Ausgänge vorher leiser stellen oder eine Obergrenze aktivieren.',
                  ),
                ),
              ],
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: presets,
                onChanged: (v) => setD(() => presets = v ?? false),
                title: Text(tr('Auch die 20 EQ-Presets überschreiben')),
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
              child: Text(tr('Wiederherstellen')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final n = await c.restoreBackup(b, withPresets: presets);
    _msg(
      n == 0 && !presets
          ? tr('Gerät entsprach bereits dem Backup.')
          : (presets
                ? trf('Wiederhergestellt: {n} Einstellungen und EQ-Presets.', {
                    'n': n,
                  })
                : trf('Wiederhergestellt: {n} Einstellungen.', {'n': n})),
    );
  }

  String _date(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year}, ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final busy = _progress != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Backup')),
        actions: [
          TextButton.icon(
            onPressed: busy ? null : _import,
            icon: const Icon(Icons.file_open_outlined, color: Palette.muted),
            label: Text(tr('Importieren')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Text(
            tr(
              'Sichert alle Einstellungen und die 20 EQ-Presets des Geräts. Am besten vor größeren Änderungen ein Backup anlegen.',
            ),
            style: ts(13, color: Palette.muted, height: 1.4),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: busy || c.offline ? null : _create,
            icon: const Icon(Icons.save_outlined),
            label: Text(
              busy
                  ? trf('Lese Gerät … {prozent} %', {
                      'prozent': ((_progress ?? 0) * 100).round(),
                    })
                  : tr('Jetzt sichern'),
            ),
          ),
          if (busy) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: _progress,
              color: Palette.amber,
              backgroundColor: Palette.surf2,
            ),
          ],
          const SizedBox(height: 20),
          Text(
            tr('Gespeicherte Backups'),
            style: ts(14, weight: 600, color: Palette.muted),
          ),
          const SizedBox(height: 8),
          if (_items.isEmpty)
            Text(tr('Noch keine.'), style: ts(14, color: Palette.muted)),
          for (final (f, b) in _items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Panel(
                child: Material(
                  type: MaterialType.transparency,
                  child: ListTile(
                    title: Text('${b.label}, ${_date(b.created)}'),
                    subtitle: Text(
                      trf('{anzahl} Einstellungen, {presets} EQ-Presets', {
                        'anzahl': b.values.length,
                        'presets': b.presets.where((p) => !p.empty).length,
                      }),
                    ),
                    onTap: busy ? null : () => _restore(b),
                    trailing: PopupMenuButton<String>(
                      color: Palette.surf2,
                      onSelected: (a) => switch (a) {
                        'restore' => _restore(b),
                        'share' => _share(f),
                        _ => _delete(f),
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'restore',
                          child: Text(tr('Wiederherstellen')),
                        ),
                        PopupMenuItem(
                          value: 'share',
                          child: Text(tr('Teilen')),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(tr('Löschen')),
                        ),
                      ],
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
