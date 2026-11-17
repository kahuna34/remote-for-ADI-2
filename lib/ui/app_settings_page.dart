import '../eq/eq_library_feature.dart';

import 'package:flutter/material.dart';

import '../app_info.dart';
import 'eq_preset_library_page.dart';
import '../dev/analyzer_selftest_page.dart';
import '../app_settings.dart';
import '../protocol/adi2_params.dart';
import '../device/adi2_controller.dart';
import 'easy_mode_editor.dart';
import 'main_view_colors_editor.dart';
import 'easy_slot_preview.dart';
import 'outputs_page.dart';
import '../device/supported_models.dart';
import '../l10n/l10n.dart';
import 'theme.dart';
import 'header_content_picker.dart';
import 'analyzer_controls.dart';
import 'update_settings.dart';
import 'setup_wizard.dart';
import 'privacy_page.dart';
import '../media/now_playing.dart';

/// App-Menü: Einstellungen der App selbst (nicht des Geräts).
class AppSettingsPage extends StatelessWidget {
  const AppSettingsPage({super.key, this.ctrl, this.np});
  final Adi2Controller? ctrl;
  final NowPlaying? np;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([AppLang.instance, AppSettings.instance]),
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(tr('App-Einstellungen'))),
        body: SafeArea(
          top: false,
          maintainBottomViewPadding: true,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              // Je nach Modus nur der passende Editor: Hauptansicht-Farben
              // ohne Custom-Modus, Custom-Editor nur im Custom-Modus.
              ListenableBuilder(
                listenable: Listenable.merge([AppSettings.instance, ?ctrl]),
                builder: (context, _) => AppSettings.instance.easyMode
                    ? _EasyModeCard(ctrl: ctrl)
                    : _MainViewCard(ctrl: ctrl),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                child: Text(
                  tr('Sprache'),
                  style: ts(14, weight: 600, color: Palette.muted),
                ),
              ),
              Panel(
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(
                    children: [
                      for (final l in AppLanguage.values)
                        ListTile(
                          title: Text(l.label),
                          trailing: AppLang.instance.language == l
                              ? const Icon(Icons.check, color: Palette.amber)
                              : null,
                          onTap: () => AppLang.instance.set(l),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
                child: Text(
                  tr('Bedienung'),
                  style: ts(14, weight: 600, color: Palette.muted),
                ),
              ),
              Panel(
                child: Material(
                  type: MaterialType.transparency,
                  child: ListenableBuilder(
                    listenable: AppSettings.instance,
                    builder: (context, _) => Column(
                      children: [
                        HeaderContentPicker(
                          value: AppSettings.instance.headerContent,
                          onChanged: AppSettings.instance.setHeaderContent,
                        ),
                        if (eqLibraryAvailable)
                          SwitchListTile(
                            title: Text(tr('EQ-Bibliothek (oratory1990)')),
                            subtitle: Text(
                              tr(
                                'Vorbereitete EQ-Presets für viele Kopfhörer von oratory1990, angepasst an die 5 Bänder + Bass/Treble des ADI-2. Quelle: oratory1990.',
                              ),
                            ),
                            value: AppSettings.instance.eqLibraryEnabled,
                            onChanged: AppSettings.instance.setEqLibraryEnabled,
                          ),
                        const AnalyzerBandSetting(),
                        const AnalyzerColorSetting(),
                        const AnalyzerRangeSetting(),
                        SwitchListTile(
                          title: Text(
                            tr('Automatisch zum aktiven Ausgang wechseln'),
                          ),
                          subtitle: Text(
                            tr(
                              'Z. B. beim Einstecken eines Kopfhörers. '
                              'Derzeit beim ADI-2 DAC.',
                            ),
                          ),
                          value: AppSettings.instance.autoSwitchOutput,
                          onChanged: AppSettings.instance.setAutoSwitchOutput,
                        ),
                        SwitchListTile(
                          title: Text(
                            tr(
                              'EQ-Graph im Querformat automatisch im Vollbild',
                            ),
                          ),
                          subtitle: Text(
                            tr(
                              'Gilt auch für den Analyzer und die Signalpläne der Basic Modes.',
                            ),
                          ),
                          value: AppSettings.instance.autoFullscreenEq,
                          onChanged: AppSettings.instance.setAutoFullscreenEq,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Panel(
                child: Material(
                  type: MaterialType.transparency,
                  child: UpdateSettings(),
                ),
              ),
              const SizedBox(height: 20),
              ListTile(
                title: Text(tr('Einrichtung erneut starten')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final player = np ?? NowPlaying();
                  if (np == null) await player.start();
                  if (!context.mounted) {
                    if (np == null) player.dispose();
                    return;
                  }
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => SetupWizard(
                        ctrl: ctrl,
                        np: player,
                        onDone: () => Navigator.pop(context),
                      ),
                    ),
                  );
                  if (np == null) player.dispose();
                },
              ),
              ListTile(
                title: Text(tr('Datenschutz')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PrivacyPage()),
                ),
              ),
              Panel(
                key: const ValueKey('about-app-card'),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Über die App'),
                      style: ts(14, weight: 600, color: Palette.muted),
                    ),
                    const SizedBox(height: 12),
                    Text('Remote for ADI-2', style: ts(22, weight: 650)),
                    const SizedBox(height: 4),
                    AnalyzerSelfTestEntry(
                      ctrl: ctrl,
                      child: Text(
                        trf('Version {version}', {'version': appVersion}),
                        style: ts(14, color: Palette.muted),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (AppSettings.instance.eqLibraryEnabled)
                      Text(eqLibraryCredit()),
                    Text(
                      tr('Entwickelt von Markus Rass'),
                      style: ts(14, weight: 600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '© 2026 Markus Rass',
                      style: ts(14, color: Palette.muted),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      trf('Unterstützte Geräte: {models}', {
                        'models': supportedModels
                            .map((model) => tr(model.name))
                            .join(', '),
                      }),
                      style: ts(14, color: Palette.muted, height: 1.4),
                    ),
                    const SizedBox(height: 16),
                    const Divider(),
                    const SizedBox(height: 12),
                    Text(
                      tr(
                        'RME, ADI-2 und ADI-2 Remote und weitere genannte Produktnamen sind Marken von RME Intelligent Audio Solutions.',
                      ),
                      style: ts(12, color: Palette.muted, height: 1.4),
                    ),
                    const SizedBox(height: 12),
                    Material(
                      type: MaterialType.transparency,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr('Marken und Rechtliches')),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const _TrademarksPage(),
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
    );
  }
}

class _TrademarksPage extends StatelessWidget {
  const _TrademarksPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Marken und Rechtliches'))),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                tr(
                  'RME ist eine eingetragene Marke von RME Intelligent Audio Solutions. ADI-2 Pro ist eine Marke von RME Intelligent Audio Solutions; ADI-2 und ADI-2 Remote sind Produktnamen von RME.',
                ),
                style: ts(14, height: 1.5),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                tr(
                  'Alesis und ADAT sind eingetragene Marken der Alesis Corp. ADAT optical ist eine Marke der Alesis Corp.',
                ),
                style: ts(14, height: 1.5),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                tr('Apple, iPhone und Lightning sind Marken der Apple Inc.'),
                style: ts(14, height: 1.5),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                tr('Android ist eine Marke der Google LLC.'),
                style: ts(14, height: 1.5),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                tr(
                  'Direct Stream Digital und DSD sind Marken der jeweiligen Inhaber (Sony / Philips).',
                ),
                style: ts(14, height: 1.5),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                tr(
                  'Alle weiteren genannten Marken und Produktnamen sind Eigentum ihrer jeweiligen Inhaber und werden nur zur Bezeichnung der kompatiblen Geräte und Funktionen verwendet.',
                ),
                style: ts(14, height: 1.5),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.description_outlined),
                label: Text(tr('Open-Source-Lizenzen')),
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: 'Remote for ADI-2',
                  applicationVersion: appVersion,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Custom layouts with a dedicated editor button and separate slot activation.
class _EasyModeCard extends StatelessWidget {
  const _EasyModeCard({this.ctrl});
  final Adi2Controller? ctrl;

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final variant = ctrl?.variant;
    final slots = variant == null ? null : settings.easySlots(variant);
    final outputs = variant == null ? <OutputInfo>[] : outputsFor(variant);
    final selected =
        outputs.where((o) => o.address == ctrl?.selectedOutput).firstOrNull ??
        (variant == null ? null : (variant.isDac ? outputs[1] : outputs.last));
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: Palette.line),
    );
    return Material(
      key: const ValueKey('easy-settings-card'),
      color: Palette.surf,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Palette.surf2,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.dashboard_customize,
                    color: Palette.muted,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    tr('Eigene Ansicht einrichten'),
                    style: ts(20, weight: 650),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              tr('Eigenes Bedienfeld aus Kacheln bauen'),
              style: ts(14, color: Palette.muted, height: 1.4),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('easy-open-editor'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Palette.text,
                  side: const BorderSide(color: Palette.line),
                ),
                icon: const Icon(Icons.edit_outlined),
                label: Text(tr('Bearbeiten')),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => EasyModeEditor(ctrl: ctrl)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (variant == null)
              Text(tr('Gerät anschließen oder offline ein Modell wählen'))
            else
              Row(
                children: [
                  for (var i = 0; i < 4; i++)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: i == 3 ? 0 : 6),
                        child: EasySlotPreview(
                          key: ValueKey('easy-slot-$i'),
                          ctrl: ctrl,
                          output: selected?.address,
                          index: i,
                          layout: slots!.layouts[i]?.pageFor(selected!.address),
                          name: slots.names[i],
                          active: slots.active == i,
                          onTap: () async {
                            if (slots.active == i) return;
                            final confirmed = await confirmEasyAction(
                              context,
                              trf('Eigene Ansicht {n} aktivieren?', {
                                'n': i + 1,
                              }),
                            );
                            if (confirmed) {
                              await settings.activateEasySlot(variant, i);
                            }
                          },
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _MainViewCard extends StatelessWidget {
  const _MainViewCard({this.ctrl});
  final Adi2Controller? ctrl;

  @override
  Widget build(BuildContext context) => Material(
    key: const ValueKey('main-view-settings-card'),
    color: Palette.surf,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: Palette.line),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Palette.surf2,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.palette_outlined,
                  color: Palette.muted,
                  size: 26,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  tr('Hauptansicht anpassen'),
                  style: ts(20, weight: 650),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            tr('Farben der Knöpfe in der Hauptansicht wählen'),
            style: ts(14, color: Palette.muted, height: 1.4),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const ValueKey('main-view-open-editor'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Palette.text,
              side: const BorderSide(color: Palette.line),
            ),
            icon: const Icon(Icons.palette_outlined),
            label: Text(tr('Farben wählen')),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MainViewColorsEditor(ctrl: ctrl),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
