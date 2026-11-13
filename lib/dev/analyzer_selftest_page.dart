// Temporary, deliberately German-only developer UI.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../analyzer/analyzer_dsp.dart';
import 'analyzer_selftest_diagnostics.dart';
import '../analyzer/analyzer_routing.dart';
import '../device/adi2_controller.dart';
import '../protocol/adi2_codec.dart';
import 'analyzer_selftest.dart';

/// Five taps within four seconds; no persistent setting or ordinary menu item.
class AnalyzerSelfTestEntry extends StatefulWidget {
  const AnalyzerSelfTestEntry({super.key, required this.child, this.ctrl});
  final Widget child;
  final Adi2Controller? ctrl;
  @override
  State<AnalyzerSelfTestEntry> createState() => _AnalyzerSelfTestEntryState();
}

class _AnalyzerSelfTestEntryState extends State<AnalyzerSelfTestEntry> {
  int taps = 0;
  DateTime? first;
  @override
  Widget build(BuildContext context) => GestureDetector(
    key: const ValueKey('analyzer-selftest-entry'),
    behavior: HitTestBehavior.opaque,
    onTap: widget.ctrl?.viaHost == true
        ? null
        : () {
            if (widget.ctrl?.viaHost == true) return;
            final now = DateTime.now();
            if (first == null ||
                now.difference(first!) > const Duration(seconds: 4)) {
              first = now;
              taps = 0;
            }
            if (++taps < 5) return;
            taps = 0;
            first = null;
            analyzerDeveloperMode.value = true;
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AnalyzerSelfTestPage(ctrl: widget.ctrl),
              ),
            );
          },
    child: widget.child,
  );
}

class AnalyzerSelfTestPage extends StatefulWidget {
  const AnalyzerSelfTestPage({super.key, this.ctrl, this.session});
  final Adi2Controller? ctrl;
  final AnalyzerSelfTest? session;
  @override
  State<AnalyzerSelfTestPage> createState() => _AnalyzerSelfTestPageState();
}

class _AnalyzerSelfTestPageState extends State<AnalyzerSelfTestPage>
    with WidgetsBindingObserver {
  AnalyzerSelfTest? session;
  int? output;
  bool loading = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session =
        widget.session ??
        (widget.ctrl == null
            ? null
            : AnalyzerSelfTest(
                MidiSelfTestDevice(widget.ctrl!),
                SelfTestAudio(),
              ));
    output = widget.ctrl == null
        ? session?.device.loopbackOutputs.firstOrNull
        : activeAnalyzerOutput(widget.ctrl!);
    session?.addListener(_changed);
    unawaited(_load());
  }

  Future<void> _load() async {
    if (widget.session != null || Platform.isAndroid) {
      await session?.loadLastResult();
      await session?.loadRecovery();
    }
    if (mounted) {
      setState(() {
        loading = false;
      });
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(session?.cancel());
  }

  Future<void> _start() async {
    final s = session;
    if (s == null || output == null || widget.ctrl?.viaHost == true) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sicherheitsbestätigung'),
        content: const SingleChildScrollView(
          child: Text(
            'Kopfhörer abnehmen. Andere Audiowiedergabe vorher beenden.\n\n'
            'Alle Ausgänge werden vor dem Test stummgeschaltet. Der gewählte Ausgang wird auf USB 1/2 und pre FX → USB 1/2 gestellt. '
            'Die App spielt Sinustöne mit -20 dBFS für alle 206 Bänder (1/3, 1/6, 1/12 Oktave). Dauer etwa 3–5 Minuten.\n\n'
            'Falls pre FX bei Mute kein Signal liefert, wird post FX mit höchstens -100 dB Lautstärke geprüft. Dabei wird nur der gewählte Ausgang entstummt. '
            'Effekte können dieses Ergebnis beeinflussen; der Fallback wird im Bericht markiert.\n\n'
            'Abbruch und App-Hintergrund stoppen den Test und stellen Mute, Lautstärke, Quelle und Loopback wieder her. '
            'Bei USB-Trennung das Originalgerät wieder verbinden und die Wiederherstellung erneut starten. '
            'Während des Tests keine Gerätebedienung und keine weitere Audiowiedergabe.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Zurück'),
          ),
          FilledButton(
            key: const ValueKey('selftest-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Bestätigen und starten'),
          ),
        ],
      ),
    );
    if (confirmed == true &&
        mounted &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      try {
        final allowed = await s.audio.permission();
        if (!mounted) return;
        if (!allowed) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Aufnahmeberechtigung erforderlich.')),
          );
          return;
        }
        if (WidgetsBinding.instance.lifecycleState ==
            AppLifecycleState.resumed) {
          await s.run(output!);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Start fehlgeschlagen: $e')));
        }
      }
    }
  }

  Future<void> _share(String format) async {
    final s = session!;
    final data = format == 'json'
        ? const JsonEncoder.withIndent('  ').convert(s.report)
        : format == 'csv'
        ? s.csv
        : s.text;
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: s.text,
          files: [
            XFile.fromData(
              utf8.encode(data),
              mimeType: format == 'json'
                  ? 'application/json'
                  : format == 'csv'
                  ? 'text/csv'
                  : 'text/plain',
            ),
          ],
          fileNameOverrides: ['analyzer_selftest.$format'],
          sharePositionOrigin: Rect.fromLTWH(
            0,
            0,
            MediaQuery.sizeOf(context).width,
            1,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Export fehlgeschlagen: $e')));
      }
    }
  }

  Future<void> _copyResult() async {
    final result = session?.lastResult;
    if (result == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: result.text));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Ergebnis kopiert.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Kopieren fehlgeschlagen: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = session;
    final supported = widget.session != null || Platform.isAndroid;
    return PopScope(
      canPop: s?.running != true && s?.restored != false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && s?.running == true) unawaited(s?.cancel());
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Entwickler: Analyzer-Selbsttest')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (s?.lastResult != null) ...[
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .55,
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    s!.lastResult!.text,
                    key: const ValueKey('selftest-last-result'),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const ValueKey('selftest-copy-result'),
                  onPressed: _copyResult,
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Ergebnis kopieren'),
                ),
              ),
              const Divider(),
            ],
            if (s?.lastResultError != null) Text(s!.lastResultError!),
            const Text(
              'Temporäre Kalibrierung · bit-perfect: −20 dBFS ±1 dB; sonst relativ zum Breitband-RMS +3,01 dB (±1 dB). Nachbartrennung mindestens 9 dB. '
              'Reaktionszeit bis -3 dB vom gemessenen Endwert ab erkanntem Aufnahmebeginn, ohne USB-Latenz.',
            ),
            if (!supported)
              const Text('Wiedergabe-Selbsttest nur unter Android verfügbar.'),
            if (s == null) const Text('Kein ADI-2-Controller verfügbar.'),
            if (s != null) ...[
              DropdownButtonFormField<int>(
                key: const ValueKey('selftest-output'),
                initialValue: output,
                decoration: const InputDecoration(labelText: 'Testausgang'),
                items: [
                  for (final a in s.device.loopbackOutputs)
                    DropdownMenuItem(
                      value: a,
                      child: Text(
                        a == Adi2Addr.line
                            ? 'Line'
                            : a == Adi2Addr.ph12
                            ? 'Phones 1/2'
                            : 'Phones 3/4 / IEM',
                      ),
                    ),
                ],
                onChanged: s.running || !s.restored
                    ? null
                    : (value) => setState(() {
                        output = value;
                      }),
              ),
              const SizedBox(height: 12),
              Text(s.status, key: const ValueKey('selftest-status')),
              if (s.metadata.isNotEmpty) Text(s.playbackText),
              if (s.fallback)
                const Text(
                  'POST FX: ausgewählter Ausgang höchstens -100 dB; alle anderen Ausgänge stumm.',
                ),
              for (final warning in s.warnings) Text(warning),
              if (s.error != null) SelectableText(s.error!),
              if (s.diagnosticText.isNotEmpty)
                SelectableText(
                  s.diagnosticText,
                  key: const ValueKey('selftest-diagnostics'),
                ),
              if (s.restoreError != null)
                SelectableText(
                  'Wiederherstellung ausstehend: ${s.restoreError}',
                ),
              if (s.running) ...[
                LinearProgressIndicator(value: s.results.length / s.total),
                FilledButton(
                  key: const ValueKey('selftest-cancel'),
                  onPressed: s.cancel,
                  child: const Text('Abbrechen'),
                ),
              ] else if (!s.restored)
                FilledButton(
                  onPressed: s.retryRestore,
                  child: const Text('Wiederherstellung erneut starten'),
                )
              else
                FilledButton(
                  key: const ValueKey('selftest-start'),
                  onPressed:
                      !loading &&
                          supported &&
                          s.device.connected &&
                          output != null
                      ? _start
                      : null,
                  child: const Text('Selbsttest vorbereiten'),
                ),
              if (!loading &&
                  supported &&
                  !s.running &&
                  s.canResetTestState) ...[
                OutlinedButton(
                  key: const ValueKey('selftest-reset-state'),
                  onPressed: s.device.connected ? s.resetTestState : null,
                  child: const Text('Testzustand aufheben'),
                ),
                const Text(
                  'Ohne Sicherung: Loopback Aus, Quelle Auto/USB-Standard. '
                  'Mute und Lautstärke bleiben erhalten. Mute am Gerät prüfen',
                ),
              ],
              if (s.results.isNotEmpty || s.path.isNotEmpty) ...[
                Text('Gesamtnote: ${s.report['grade']}'),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('Oktave')),
                      DataColumn(label: Text('OK')),
                      DataColumn(label: Text('Abweichung')),
                      DataColumn(label: Text('Offen')),
                    ],
                    rows: [
                      for (final r in AnalyzerBandResolution.values)
                        DataRow(
                          cells: [
                            DataCell(Text('1/${r.bandsPerOctave}')),
                            DataCell(
                              Text(
                                '${s.results.where((v) => v.resolution == r && v.ok).length}',
                              ),
                            ),
                            DataCell(
                              Text(
                                '${s.results.where((v) => v.resolution == r && !v.ok).length}',
                              ),
                            ),
                            DataCell(
                              Text(
                                '${r.count - s.results.where((v) => v.resolution == r).length}',
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                ExpansionTile(
                  title: const Text('Alle Bandmessungen'),
                  children: [
                    for (final r in s.results)
                      ListTile(
                        dense: true,
                        title: Text(
                          '1/${r.resolution.bandsPerOctave} · ${r.resolution.centre(r.index).toStringAsFixed(2)} Hz · ${r.ok ? 'OK' : 'Abweichung'}',
                        ),
                        subtitle: Text(
                          '${r.levelText} · ${r.responseMs?.toStringAsFixed(1) ?? '—'} ms\nNachbarn: ${r.neighbours.map((v) => v.toStringAsFixed(2)).join(' / ')} dBFS'
                          '${r.broadbandText.isEmpty ? '' : '\n${r.broadbandText}'}'
                          '${r.measurementValid ? '' : '\nMessfenster ungültig (${r.invalidReason})'}',
                        ),
                      ),
                  ],
                ),
                if (!s.running)
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final format in ['txt', 'json', 'csv'])
                        OutlinedButton(
                          onPressed: () => _share(format),
                          child: Text(
                            '${format.toUpperCase()} teilen/exportieren',
                          ),
                        ),
                    ],
                  ),
                SelectableText(s.path),
              ],
            ],
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session?.removeListener(_changed);
    if (widget.session == null) session?.dispose();
    super.dispose();
  }
}
