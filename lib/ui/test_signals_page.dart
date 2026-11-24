import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../analyzer/analyzer_controller.dart';
import '../analyzer/linux_test_signal.dart';
import '../analyzer/test_signal.dart';
import '../desktop/desktop_windows.dart';
import '../device/adi2_controller.dart';
import '../l10n/l10n.dart';
import 'analyzer_panel.dart';
import 'theme.dart';

/// Only the embedded Linux main window has this capability. In particular,
/// phones, standalone Linux clients and auxiliary processes cannot start it.
class TestSignalsTile extends StatelessWidget {
  const TestSignalsTile({super.key, required this.ctrl});
  final Adi2Controller? ctrl;
  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.linux ||
        ctrl?.usesLocalHost != true ||
        DesktopWindowScope.maybeOf(context) == null) {
      return const SizedBox.shrink();
    }
    return ListTile(
      key: const ValueKey('test-signals-open'),
      leading: const Icon(Icons.waves),
      title: Text(tr('Testsignale')),
      subtitle: Text(tr('Testsignale per USB an den ADI-2 ausgeben')),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => TestSignalsPage(ctrl: ctrl!)),
      ),
    );
  }
}

String testSignalTitle(TestSignal signal) => switch (signal) {
  TestSignal.sine => tr('Sinus'),
  TestSignal.thirds => tr('Terz-Treppe'),
  TestSignal.sweep => tr('Gleitsinus (Sweep)'),
  TestSignal.pink => tr('Rosa Rauschen'),
  TestSignal.white => tr('Weißes Rauschen'),
  TestSignal.levels => tr('Pegeltreppe 1 kHz'),
};

String _channelTitle(TestSignalChannel channel) => switch (channel) {
  TestSignalChannel.left => tr('L'),
  TestSignalChannel.right => tr('R'),
  TestSignalChannel.both => tr('Beide'),
  TestSignalChannel.opposite => tr('Beide gegenphasig'),
};

String _frequency(double frequency) => frequency >= 1000
    ? '${(frequency / 1000).toStringAsFixed(frequency % 1000 == 0 ? 0 : 2)} kHz'
    : '${frequency.toStringAsFixed(frequency % 1 == 0 ? 0 : 1)} Hz';

class TestSignalsPage extends StatefulWidget {
  const TestSignalsPage({super.key, required this.ctrl, this.player});
  final Adi2Controller ctrl;

  /// Injection keeps widget tests away from actual audio devices.
  final LinuxTestSignalPlayer? player;
  @override
  State<TestSignalsPage> createState() => _TestSignalsPageState();
}

class _TestSignalsPageState extends State<TestSignalsPage>
    with WidgetsBindingObserver {
  late final _player = widget.player ?? LinuxTestSignalPlayer.instance;
  final _frequencyInput = TextEditingController(text: '1000');
  TestSignal _signal = TestSignal.sine;
  TestSignalChannel _channel = TestSignalChannel.both;
  double _dbfs = -20;
  int _stepSeconds = 2, _sweepSeconds = 20;
  bool _repeat = false, _meters = true, _confirming = false;
  bool get _locked => _player.busy || _player.running || _confirming;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_player.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_player.stop());
    _frequencyInput.dispose();
    super.dispose();
  }

  Future<bool> _confirm(String title, String message, String accept) async =>
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('Abbrechen')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(accept),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _start() async {
    if (_locked) return;
    final frequency = double.tryParse(
      _frequencyInput.text.replaceAll(',', '.'),
    );
    if (_signal == TestSignal.sine &&
        (frequency == null ||
            !frequency.isFinite ||
            frequency < 20 ||
            frequency > 20000)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Frequenz zwischen 20 und 20000 Hz eingeben.')),
        ),
      );
      return;
    }
    final settings = TestSignalSettings(
      signal: _signal,
      frequency: _signal == TestSignal.sine ? frequency! : 1000,
      dbfs: _dbfs,
      channel: _channel,
      stepSeconds: _stepSeconds,
      sweepSeconds: _sweepSeconds,
      repeat: _repeat,
    );
    setState(() => _confirming = true);
    try {
      if (!_player.sessionAccepted) {
        if (!await _confirm(
          tr('Testsignal per USB'),
          tr(
            'Das Signal geht per USB an den ADI-2. Lautstärke vorher niedrig stellen und Kopfhörer abnehmen. Am ADI-2 muss der USB-Wiedergabe-Eingang aktiv sein (Quelle USB/Auto). Die Gerätelautstärke wird nicht verändert.',
          ),
          tr('Verstanden'),
        )) {
          return;
        }
        if (!mounted) return;
        _player.sessionAccepted = true;
      }
      if (settings.requiresHighLevel) {
        if (!await _confirm(
          tr('Hoher Testpegel'),
          tr(
            'Dieses Signal überschreitet −6 dBFS. Die Pegeltreppe beginnt mit 0 dBFS. Lautstärke niedrig stellen und Kopfhörer abnehmen.',
          ),
          tr('Hohen Pegel starten'),
        )) {
          return;
        }
        if (!mounted) return;
      }
      await _player.start(settings);
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _player,
    builder: (context, _) {
      final playing = _player.settings;
      final position = playing?.position(_player.elapsed);
      return Scaffold(
        appBar: AppBar(title: Text(tr('Testsignale'))),
        // Stop stays reachable even on a small window or while scrolled.
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('test-signal-start'),
                    onPressed: _locked ? null : _start,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(tr('Starten')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('test-signal-stop'),
                    onPressed: _player.busy || _player.running
                        ? () => unawaited(_player.stop())
                        : null,
                    icon: const Icon(Icons.stop),
                    label: Text(tr('Stopp')),
                  ),
                ),
              ],
            ),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 780),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      tr(
                        'Für den Display-Vergleich: Loopback auf post FX stellen (nicht post −6 dB), Analyzer auf Balken und 1/3 Oktave, Peak hold aus. Sinus mit 0 dBFS: 0 dBFS Peak / −3 dBFS RMS.',
                      ),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<TestSignal>(
                      key: const ValueKey('test-signal-kind'),
                      initialValue: _signal,
                      decoration: InputDecoration(labelText: tr('Signal')),
                      items: [
                        for (final s in TestSignal.values)
                          DropdownMenuItem(
                            value: s,
                            child: Text(testSignalTitle(s)),
                          ),
                      ],
                      onChanged: _locked
                          ? null
                          : (value) => setState(() => _signal = value!),
                    ),
                    const SizedBox(height: 12),
                    if (_signal == TestSignal.sine) ...[
                      TextField(
                        key: const ValueKey('test-signal-frequency'),
                        controller: _frequencyInput,
                        enabled: !_locked,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: tr('Frequenz (Hz)'),
                          helperText: '20–20000 Hz',
                        ),
                      ),
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final f in <double>[
                            31.5,
                            63,
                            125,
                            250,
                            500,
                            1000,
                            2000,
                            4000,
                            8000,
                            16000,
                          ])
                            ActionChip(
                              label: Text(_frequency(f)),
                              onPressed: _locked
                                  ? null
                                  : () {
                                      _frequencyInput.text = '$f';
                                    },
                            ),
                        ],
                      ),
                    ],
                    if (_signal == TestSignal.thirds)
                      DropdownButtonFormField<int>(
                        initialValue: _stepSeconds,
                        decoration: InputDecoration(
                          labelText: tr('Dauer je Terz'),
                        ),
                        items: [
                          for (var s = 1; s <= 5; s++)
                            DropdownMenuItem(value: s, child: Text('$s s')),
                        ],
                        onChanged: _locked
                            ? null
                            : (s) => setState(() => _stepSeconds = s!),
                      ),
                    if (_signal == TestSignal.sweep) ...[
                      DropdownButtonFormField<int>(
                        initialValue: _sweepSeconds,
                        decoration: InputDecoration(
                          labelText: tr('Sweep-Dauer (20 Hz → 20 kHz)'),
                        ),
                        items: [
                          for (final s in [10, 20, 30])
                            DropdownMenuItem(value: s, child: Text('$s s')),
                        ],
                        onChanged: _locked
                            ? null
                            : (s) => setState(() => _sweepSeconds = s!),
                      ),
                      SwitchListTile(
                        title: Text(tr('Wiederholen')),
                        value: _repeat,
                        onChanged: _locked
                            ? null
                            : (v) => setState(() => _repeat = v),
                      ),
                    ],
                    if (_signal == TestSignal.levels)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          tr(
                            '1 kHz: 0, −6, −12, −20, −40 dBFS, jeweils 3 Sekunden.',
                          ),
                        ),
                      )
                    else ...[
                      const SizedBox(height: 12),
                      Text(
                        trf('Signalpegel: {level} dBFS', {
                          'level': _dbfs.round(),
                        }),
                      ),
                      Slider(
                        // Flutter 3.47 retains stale slider semantics when toggling
                        // enabled state. Recreate that control at this boundary.
                        key: ValueKey(('test-signal-level', _locked)),
                        value: _dbfs,
                        min: -60,
                        max: 0,
                        divisions: 60,
                        label: '${_dbfs.round()} dBFS',
                        onChanged: _locked
                            ? null
                            : (v) => setState(() => _dbfs = v),
                      ),
                    ],
                    if (_signal == TestSignal.pink ||
                        _signal == TestSignal.white)
                      Text(
                        tr(
                          'Bei Rauschen bezeichnet der Pegel die Spitzenobergrenze, nicht RMS. Rosa Rauschen: gleiche Energie je Terz.',
                        ),
                      ),
                    DropdownButtonFormField<TestSignalChannel>(
                      initialValue: _channel,
                      decoration: InputDecoration(labelText: tr('Kanal')),
                      items: [
                        for (final c in TestSignalChannel.values)
                          DropdownMenuItem(
                            value: c,
                            child: Text(_channelTitle(c)),
                          ),
                      ],
                      onChanged: _locked
                          ? null
                          : (v) => setState(() => _channel = v!),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _player.busy
                          ? tr('Testsignal wird vorbereitet…')
                          : _player.running && playing != null
                          ? '${testSignalTitle(playing.signal)} · ${position?.frequency == null ? '' : '${_frequency(position!.frequency!)} · '}${position!.dbfs.toStringAsFixed(0)} dBFS'
                          : tr('Testsignal gestoppt'),
                      key: const ValueKey('test-signal-status'),
                    ),
                    if (_player.running && position?.progress != null) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: position!.progress),
                      Text('${(position.progress! * 100).round()} %'),
                    ],
                    if (_player.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          testSignalErrorText(_player.error!),
                          key: const ValueKey('test-signal-error'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    SwitchListTile(
                      title: Text(tr('Analyzer-Pegel einblenden')),
                      value: _meters,
                      onChanged: (v) => setState(() => _meters = v),
                    ),
                    if (_meters) _SignalMeters(ctrl: widget.ctrl),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _SignalMeters extends StatefulWidget {
  const _SignalMeters({required this.ctrl});
  final Adi2Controller ctrl;
  @override
  State<_SignalMeters> createState() => _SignalMetersState();
}

class _SignalMetersState extends State<_SignalMeters> {
  late final _analyzer = AnalyzerController(host: widget.ctrl.host);
  @override
  void initState() {
    super.initState();
    _analyzer.setMeterOnlyFor(this, true);
    unawaited(_analyzer.setActiveFor(this, true));
  }

  @override
  void dispose() {
    _analyzer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(tr('Peak / RMS · dBFS')),
      for (var channel = 0; channel < 2; channel++)
        AnalyzerLevelBar(
          controller: _analyzer,
          channel: channel,
          color: Palette.amber,
          height: 14,
          compactRow: true,
        ),
    ],
  );
}

String testSignalErrorText(LinuxSignalError error) => switch (error) {
  LinuxSignalError.serverUnavailable => tr(
    'PipeWire/PulseAudio ist nicht erreichbar.',
  ),
  LinuxSignalError.outputsUnverified => tr(
    'ADI-2-Ausgänge konnten nicht geprüft werden.',
  ),
  LinuxSignalError.noSink => tr(
    'Keine ADI-2-Senke gefunden. ADI-2 per USB anschließen und Audio-Ausgang prüfen.',
  ),
  LinuxSignalError.ambiguousSink => tr(
    'Mehrere ADI-2-Senken gefunden. Für Testsignale genau einen ADI-2-Ausgang aktivieren.',
  ),
  LinuxSignalError.unsupportedRate => tr(
    'Die Abtastrate der ADI-2-Senke wird nicht unterstützt.',
  ),
  LinuxSignalError.interrupted => tr(
    'Die Testsignal-Wiedergabe wurde unterbrochen. ADI-2-Ausgang prüfen.',
  ),
  LinuxSignalError.routeUnverified => tr(
    'ADI-2-Wiedergaberoute konnte nicht bestätigt werden.',
  ),
  LinuxSignalError.missingTools => tr(
    'Für Testsignale werden pactl und pacat benötigt (Paket pulseaudio-utils).',
  ),
  LinuxSignalError.playbackFailed => tr(
    'Testsignal konnte nicht ausgegeben werden. ADI-2 und PipeWire/PulseAudio prüfen.',
  ),
  LinuxSignalError.routeChanged => tr(
    'Die ADI-2-Wiedergaberoute hat sich geändert. Testsignal gestoppt.',
  ),
  LinuxSignalError.sinkChanged => tr(
    'Die ADI-2-Senke wurde getrennt oder umgestellt. Testsignal gestoppt.',
  ),
};
