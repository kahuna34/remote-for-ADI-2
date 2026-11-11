import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../l10n/l10n.dart';
import '../update/app_updates.dart';
import '../update/open_update.dart';
import '../update/update_check.dart';

class UpdateSettings extends StatefulWidget {
  const UpdateSettings({super.key, this.check});
  final Future<UpdateResult> Function()? check;
  @override
  State<UpdateSettings> createState() => _UpdateSettingsState();
}

class _UpdateSettingsState extends State<UpdateSettings> {
  bool _busy = false;
  UpdateResult? _manualResult;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([AppSettings.instance, AppUpdates.instance]),
    builder: (context, _) {
      final result = _manualResult ?? AppUpdates.instance.result;
      final available = result?.status == UpdateStatus.available;
      return Column(
        children: [
          SwitchListTile(
            key: const ValueKey('update-check-switch'),
            title: Text(tr('Automatisch nach Updates suchen')),
            subtitle: Text(
              tr('Fragt einmal täglich bei GitHub nach einer neuen Version.'),
            ),
            value: AppSettings.instance.updateCheck,
            onChanged: (value) async {
              await AppSettings.instance.setUpdateCheck(value);
              AppUpdates.instance.settingsChanged();
            },
          ),
          ListTile(
            key: const ValueKey('update-check-now'),
            title: Text(tr('Jetzt nach Updates suchen')),
            onTap: _busy
                ? null
                : () async {
                    setState(() => _busy = true);
                    final value =
                        await (widget.check ?? AppUpdates.instance.checkNow)();
                    if (mounted) {
                      setState(() {
                        _manualResult = value;
                        _busy = false;
                      });
                    }
                  },
            subtitle: _busy
                ? const LinearProgressIndicator()
                : result == null
                ? null
                : Text(
                    available
                        ? trf('Version {version} verfügbar', {
                            'version': result.version,
                          })
                        : result.status == UpdateStatus.error
                        ? tr('Keine Verbindung zu GitHub')
                        : tr('Die App ist aktuell'),
                  ),
            trailing: available
                ? TextButton(
                    onPressed: () async {
                      final opened = await openUpdate(result!.url!);
                      if (!opened && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              tr('Download-Link konnte nicht geöffnet werden'),
                            ),
                          ),
                        );
                      }
                    },
                    child: Text(tr('Laden', context: 'update')),
                  )
                : null,
          ),
        ],
      );
    },
  );
}
