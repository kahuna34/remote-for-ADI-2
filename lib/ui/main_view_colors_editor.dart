import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../device/adi2_controller.dart';
import '../easy/easy_layout.dart';
import '../l10n/l10n.dart';
import '../main_view_colors.dart';
import 'easy_tile_grid.dart';
import 'main_view_control_surface.dart';
import 'outputs_page.dart';
import 'responsive_layout.dart';
import 'theme.dart';

String mainViewControlName(MainViewControl id) => tr(switch (id) {
  MainViewControl.mute => 'Mute',
  MainViewControl.dim => 'Dim',
  MainViewControl.loudness => 'Loudness',
  MainViewControl.crossfeed => 'Crossfeed',
  MainViewControl.recall => 'Recall',
  MainViewControl.source => 'Quelle',
  MainViewControl.eq => 'EQ',
  MainViewControl.limit => 'Limit',
  MainViewControl.settings => 'Settings',
  MainViewControl.lock => 'Lock',
  MainViewControl.link => 'Link',
  MainViewControl.volumeDown => '−0,5 dB',
  MainViewControl.volumeUp => '+0,5 dB',
  MainViewControl.refLevel => 'Ref Level',
  MainViewControl.daFilter => 'DA-Filter',
  MainViewControl.balance => 'Balance',
  MainViewControl.bass => 'Bass',
  MainViewControl.treble => 'Treble',
});

class MainViewColorsEditor extends StatefulWidget {
  const MainViewColorsEditor({super.key, this.ctrl});
  final Adi2Controller? ctrl;

  @override
  State<MainViewColorsEditor> createState() => _MainViewColorsEditorState();
}

class _MainViewColorsEditorState extends State<MainViewColorsEditor> {
  int? _output;

  Future<void> _pick(MainViewControl id) async {
    final color = await showDialog<EasyTileColor>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(mainViewControlName(id)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              EasyColorPicker(
                value: AppSettings.instance.mainViewColor(id),
                onChanged: (color) => Navigator.pop(context, color),
                graphiteLabel: tr('Standard'),
              ),
              const SizedBox(height: 12),
              TextButton(
                key: const ValueKey('main-color-default'),
                onPressed: () => Navigator.pop(context, EasyTileColor.graphite),
                child: Text(tr('Standard')),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Abbrechen')),
          ),
        ],
      ),
    );
    if (color != null && mounted) {
      await AppSettings.instance.setMainViewColor(id, color);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([AppLang.instance, ?widget.ctrl]),
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(tr('Hauptansicht anpassen'))),
      body: SafeArea(
        top: false,
        child: widget.ctrl?.variant == null
            ? Center(
                child: Text(
                  tr('Gerät anschließen oder offline ein Modell wählen'),
                ),
              )
            : LayoutBuilder(
                builder: (context, bounds) => SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                        child: Text(
                          tr(
                            'Knopf antippen, um seine Farbe zu ändern. Änderungen werden automatisch gespeichert.',
                          ),
                          style: ts(14, color: Palette.muted, height: 1.4),
                        ),
                      ),
                      Align(
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: isTabletLandscape(context)
                              ? tabletOutputColumnWidth(bounds.maxWidth)
                              : null,
                          height: math.max(
                            600 * MediaQuery.textScalerOf(context).scale(1),
                            bounds.maxHeight - 100,
                          ),
                          child: MainViewColorScope(
                            onSelect: _pick,
                            onOutputSelected: (output) =>
                                setState(() => _output = output),
                            child: OutputsPage(
                              ctrl: widget.ctrl!,
                              editorOutput: _output,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: OutlinedButton.icon(
            key: const ValueKey('main-colors-reset'),
            onPressed: AppSettings.instance.resetMainViewColors,
            icon: const Icon(Icons.restart_alt),
            label: Text(tr('Alle zurücksetzen')),
          ),
        ),
      ),
    ),
  );
}
