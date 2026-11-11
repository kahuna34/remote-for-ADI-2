import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../analyzer/analyzer_controller.dart';
import '../analyzer/analyzer_calibration.dart';
import '../analyzer/analyzer_dsp.dart';
import '../analyzer/analyzer_routing.dart';
import '../app_settings.dart';
import '../device/adi2_controller.dart';
import '../device/loopback.dart';
import '../l10n/l10n.dart';
import '../protocol/adi2_params.dart';
import '../protocol/adi2_codec.dart';
import 'outputs_page.dart';
import '../eq/eq_model.dart';

const analyzerColors = [
  Color(0xff65ed81),
  Color(0xff55deef),
  Color(0xffffd15c),
  Color(0xffe5e8eb),
  Color(0xffff6262),
  Color(0xffffa04b),
];
List<String> get analyzerColorNames => [
  tr('Wie Gerät'),
  tr('Grün'),
  tr('Cyan'),
  tr('Amber'),
  tr('Mono'),
  tr('Rot'),
  tr('Orange'),
];

Color analyzerColor(Adi2Controller? ctrl) {
  final setting = AppSettings.instance.analyzerColor;
  final index = setting < 0
      ? ctrl?.value(Adi2Addr.device, DevIdx.meterColor) ?? 0
      : setting;
  return analyzerColors[index.clamp(0, 5)];
}

List<OutputInfo> analyzerOutputs(Adi2Controller? ctrl) => ctrl?.variant == null
    ? []
    : outputsFor(ctrl!.variant!)
          .where((o) => ctrl.value(o.address, OutIdx.loopback) != null)
          .toList();

OutputInfo? analyzerLoopbackSource(Adi2Controller? ctrl) {
  for (final output in analyzerOutputs(ctrl)) {
    final selection = decodeLoopback(
      ctrl!.value(output.address, OutIdx.loopback)!,
      hasInput: ctrl.variant!.hasInput,
    );
    if (selection.tap != 0 && selection.pair == 0) return output;
  }
  return null;
}

/// Other USB pairs are preserved. Only competing USB 1/2 sources are disabled.
void setAnalyzerLoopback(Adi2Controller ctrl, int address, int tap) {
  routeAnalyzerLoopback(ctrl, address, tap);
}

/// Stack labels above controls on narrow screens and with enlarged text.
class _AnalyzerSettingField extends StatelessWidget {
  const _AnalyzerSettingField({
    required this.title,
    required this.trailing,
    this.controlWidth = 180,
  });
  final Widget title, trailing;
  final double controlWidth;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final stacked =
          constraints.maxWidth < 420 ||
          MediaQuery.textScalerOf(context).scale(14) > 21;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  SizedBox(width: double.infinity, child: trailing),
                ],
              )
            : Row(
                children: [
                  Expanded(child: title),
                  SizedBox(width: controlWidth, child: trailing),
                ],
              ),
      );
    },
  );
}

class AnalyzerColorSetting extends StatelessWidget {
  const AnalyzerColorSetting({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppSettings.instance,
    builder: (context, _) => _AnalyzerSettingField(
      title: Text(tr('Analyzer-Farbe')),
      trailing: DropdownButton<int>(
        key: const ValueKey('analyzer-color'),
        isExpanded: true,
        value: AppSettings.instance.analyzerColor,
        items: [
          for (var i = -1; i < 6; i++)
            DropdownMenuItem(value: i, child: Text(analyzerColorNames[i + 1])),
        ],
        onChanged: (value) {
          if (value != null) AppSettings.instance.setAnalyzerColor(value);
        },
      ),
    ),
  );
}

class AnalyzerLoopbackControls extends StatefulWidget {
  const AnalyzerLoopbackControls({
    super.key,
    this.ctrl,
    this.inline = false,
    this.routing,
  });
  final bool inline;
  final AnalyzerRouting? routing;
  final Adi2Controller? ctrl;
  @override
  State<AnalyzerLoopbackControls> createState() =>
      _AnalyzerLoopbackControlsState();
}

class _AnalyzerLoopbackControlsState extends State<AnalyzerLoopbackControls> {
  AnalyzerRouting? _ownedRouting;
  AnalyzerRouting get _routing => widget.routing ?? _ownedRouting!;
  bool _changing = false;
  @override
  void initState() {
    super.initState();
    if (widget.routing == null) _ownedRouting = AnalyzerRouting(widget.ctrl);
  }

  @override
  void didUpdateWidget(AnalyzerLoopbackControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ctrl != widget.ctrl || oldWidget.routing != widget.routing) {
      _ownedRouting?.dispose();
      _ownedRouting = widget.routing == null
          ? AnalyzerRouting(widget.ctrl)
          : null;
    }
  }

  @override
  void dispose() {
    _ownedRouting?.dispose();
    super.dispose();
  }

  Future<void> _set(int output, int tap) async {
    final ctrl = widget.ctrl;
    if (_changing || ctrl == null || ctrl.state != ConnState.connected) return;
    _changing = true;
    try {
      if (tap != 0 && !AppSettings.instance.analyzerLoopbackConfirmed) {
        final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(tr('Loopback zu USB')),
            content: Text(
              tr(
                'Loopback auf USB 1/2 ersetzt dort die Aufnahme des Analogeingangs',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr('Abbrechen')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr('Bestätigen')),
              ),
            ],
          ),
        );
        if (accepted != true || !mounted) return;
        await AppSettings.instance.confirmAnalyzerLoopback();
      }
      // The device may detach while the first-use confirmation is open.
      if (!mounted ||
          ctrl != widget.ctrl ||
          ctrl.state != ConnState.connected) {
        return;
      }
      await _routing.configure(output: output, tap: tap);
    } finally {
      _changing = false;
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([AppSettings.instance, ?widget.ctrl]),
    builder: (context, _) {
      final ctrl = widget.ctrl;
      final outputs = analyzerOutputs(ctrl);
      final settings = AppSettings.instance;
      final selected = outputs
          .where((o) => o.address == _routing.address)
          .firstOrNull;
      final outputValue =
          outputs.any((o) => o.address == settings.analyzerLoopbackOutput)
          ? settings.analyzerLoopbackOutput
          : 0;
      final enabled =
          ctrl?.state == ConnState.connected &&
          ctrl?.analyzerSelfTestActive == false &&
          selected != null;
      // Zeigt den Gerätezustand: Der gespeicherte Abgriff kann von einem anderen
      // Gerät stammen, und erst ein Antippen darf das Loopback schreiben.
      final deviceLoopback = selected == null
          ? null
          : decodeLoopback(
              ctrl!.value(selected.address, OutIdx.loopback)!,
              hasInput: ctrl.variant!.hasInput,
            );
      final tap = deviceLoopback == null
          ? _routing.tap
          : deviceLoopback.pair == 0
          ? deviceLoopback.tap
          : 0;
      Widget field({required Widget title, required Widget trailing}) =>
          widget.inline
          ? Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [title, const SizedBox(width: 8), trailing],
              ),
            )
          : _AnalyzerSettingField(
              title: title,
              trailing: trailing,
              controlWidth: 280,
            );
      final fields = <Widget>[
        // The source picker lives in the loopback sheet so ballistics and tap
        // fit together in the fullscreen row.
        if (outputs.length > 1 && !widget.inline)
          field(
            title: Text(tr('Ausgang')),
            trailing: DropdownButton<int>(
              key: const ValueKey('analyzer-loopback-output'),
              isDense: widget.inline,
              underline: widget.inline ? const SizedBox.shrink() : null,
              isExpanded: !widget.inline,
              menuWidth: 320,
              value: outputValue,
              items: [
                DropdownMenuItem(
                  value: 0,
                  child: Text(tr('Automatisch (aktiver Ausgang)')),
                ),
                for (final output in outputs)
                  DropdownMenuItem(
                    value: output.address,
                    child: Text(output.name),
                  ),
              ],
              onChanged: enabled
                  ? (address) {
                      if (address != null) _set(address, tap == 0 ? 2 : tap);
                    }
                  : null,
            ),
          ),
        field(
          title: Text(tr('Abgriff')),
          trailing: DropdownButton<int>(
            key: const ValueKey('analyzer-loopback-tap'),
            isDense: widget.inline,
            underline: widget.inline ? const SizedBox.shrink() : null,
            isExpanded: !widget.inline,
            value: tap,
            items: [
              for (var i = 0; i < 4; i++)
                DropdownMenuItem(
                  value: i,
                  child: Text(
                    tr(['Aus', 'pre FX', 'post FX', 'post −6 dB'][i]),
                  ),
                ),
            ],
            onChanged: enabled
                ? (tap) {
                    if (tap != null) _set(outputValue, tap);
                  }
                : null,
          ),
        ),
      ];
      return widget.inline
          ? Row(mainAxisSize: MainAxisSize.min, children: fields)
          : Column(mainAxisSize: MainAxisSize.min, children: fields);
    },
  );
}

Future<void> showAnalyzerSettings(
  BuildContext context,
  AnalyzerController controller,
  Adi2Controller? ctrl, {
  bool loopbackOnly = false,
  AnalyzerRouting? routing,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr(
                      loopbackOnly
                          ? 'Loopback zu USB'
                          : 'Analyzer-Einstellungen',
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            if (!loopbackOnly) ...[
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => Column(
                  children: [
                    SwitchListTile(
                      title: Text(tr('Balken')),
                      subtitle: const Text('25 Hz–20 kHz'),
                      value: controller.bars,
                      onChanged: controller.setBars,
                    ),
                    SwitchListTile(
                      title: Text(tr('Peak hold')),
                      value: controller.peakHold,
                      onChanged: controller.setPeakHold,
                    ),
                    _AnalyzerSettingField(
                      title: Text(tr('Ballistik')),
                      trailing: DropdownButton<AnalyzerBallistics>(
                        isExpanded: true,
                        value: controller.ballistics,
                        items: [
                          for (final b in AnalyzerBallistics.values)
                            DropdownMenuItem(
                              value: b,
                              child: Text(
                                tr(['schnell', 'mittel', 'langsam'][b.index]),
                              ),
                            ),
                        ],
                        onChanged: (b) {
                          if (b != null) controller.setBallistics(b);
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const AnalyzerBandSetting(),
              const AnalyzerColorSetting(),
              const AnalyzerRangeSetting(),
              AnalyzerCalibrationSetting(
                controller: controller,
                deviceController: ctrl,
              ),
            ],
            AnalyzerLoopbackControls(ctrl: ctrl, routing: routing),
            const Padding(
              padding: EdgeInsets.all(16),
              child: AnalyzerComparisonInfo(),
            ),
          ],
        ),
      ),
    ),
  ),
);

class AnalyzerRangeSetting extends StatelessWidget {
  const AnalyzerRangeSetting({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppSettings.instance,
    builder: (context, _) => _AnalyzerSettingField(
      title: Text(tr('Pegelbereich')),
      trailing: DropdownButton<int>(
        key: const ValueKey('analyzer-range'),
        isExpanded: true,
        value: AppSettings.instance.analyzerRange,
        items: [
          for (final range in [60, 80, 100])
            DropdownMenuItem(value: range, child: Text('$range dB')),
        ],
        onChanged: (value) {
          if (value != null) AppSettings.instance.setAnalyzerRange(value);
        },
      ),
    ),
  );
}

class AnalyzerBandSetting extends StatelessWidget {
  const AnalyzerBandSetting({super.key, this.inline = false});
  final bool inline;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppSettings.instance,
    builder: (context, _) {
      final dropdown = DropdownButton<AnalyzerBandResolution>(
        key: const ValueKey('analyzer-band-resolution'),
        isExpanded: !inline,
        value: AppSettings.instance.analyzerBandResolution,
        items: [
          for (final resolution in AnalyzerBandResolution.values)
            DropdownMenuItem(
              value: resolution,
              child: Text(
                tr(switch (resolution) {
                  AnalyzerBandResolution.third => '1/3 Oktave',
                  AnalyzerBandResolution.sixth => '1/6 Oktave',
                  AnalyzerBandResolution.twelfth => '1/12 Oktave',
                }),
              ),
            ),
        ],
        onChanged: (value) {
          if (value != null) {
            AppSettings.instance.setAnalyzerBandResolution(value);
          }
        },
      );
      return inline
          ? dropdown
          : _AnalyzerSettingField(
              title: Text(tr('Bandauflösung')),
              trailing: dropdown,
            );
    },
  );
}

/// Explain the absolute reference and the optional capture calibration.
class AnalyzerComparisonInfo extends StatelessWidget {
  const AnalyzerComparisonInfo({super.key});
  @override
  Widget build(BuildContext context) => Text(
    tr(
      'Zum Vergleich mit dem Gerät Balken, 1/3 Oktave und post FX verwenden. Ein voller Sinus zeigt 0 dBFS Peak und −3 dBFS RMS.',
    ),
  );
}

String analyzerCalibrationDb(double value) {
  var number = (value == 0 ? 0.0 : value).toStringAsFixed(1);
  if (AppLang.instance.language == AppLanguage.de) {
    number = number.replaceAll('.', ',');
  }
  return '${value > 0 ? '+' : ''}$number';
}

class AnalyzerCalibrationSetting extends StatefulWidget {
  const AnalyzerCalibrationSetting({
    super.key,
    required this.controller,
    this.deviceController,
    this.startAutomatically = false,
  });
  final Adi2Controller? deviceController;
  final bool startAutomatically;
  final AnalyzerController controller;

  @override
  State<AnalyzerCalibrationSetting> createState() =>
      _AnalyzerCalibrationSettingState();
}

/// Source belongs to the output feeding USB 1/2, not the selected UI output.
bool analyzerCalibrationUsesUsb(Adi2Controller? ctrl) {
  final output = analyzerLoopbackSource(ctrl);
  if (output == null || ctrl?.variant == null) return false;
  final source = ctrl!.value(output.address, OutIdx.source);
  if (source == 0) {
    // In Auto/USB basic mode the connected USB host takes priority. Forced
    // AD/DA, Preamp, Dig Thru and DAC modes use external inputs instead.
    if (ctrl.variant!.isDac) return true;
    final mode = ctrl.value(Adi2Addr.device, 6);
    return mode == 0 || mode == 2;
  }
  return source != null &&
      (ctrl.variant!.isDac
          ? source >= 3 && source <= 5
          : source == 4 || source == 5);
}

/// Outputs of the connected model that report a mute state.
List<OutputInfo> _muteOutputs(Adi2Controller ctrl) =>
    outputsFor(ctrl.variant!)
        .where((o) => ctrl.value(o.address, OutIdx.mute) != null)
        .toList();

List<int> _calibrationRequiredKeys(Adi2Controller ctrl) => [
  for (final output in _muteOutputs(ctrl)) ...[
    output.address << 8 | OutIdx.mute,
    output.address << 8 | OutIdx.volume,
  ],
];

/// Muted by the parameter or by the device's "Mute Line when" function, the
/// same two states the output page shows as Mute. The last sent and the last
/// reported value must agree: either one saying unmuted counts as unmuted.
bool _calibrationOutputMuted(Adi2Controller ctrl, int address) =>
    ((ctrl.value(address, OutIdx.mute) ?? 0) != 0 &&
        (ctrl.confirmedValue(address, OutIdx.mute) ?? 0) != 0) ||
    ctrl.autoMuted(address);

bool calibrationOutputsMuted(Adi2Controller ctrl) {
  final outputs = _muteOutputs(ctrl);
  return outputs.isNotEmpty &&
      outputs.every((o) => _calibrationOutputMuted(ctrl, o.address));
}

void muteCalibrationOutputs(Adi2Controller ctrl) {
  for (final output in _muteOutputs(ctrl)) {
    if (!_calibrationOutputMuted(ctrl, output.address)) {
      ctrl.set(output.address, OutIdx.mute, 1);
    }
  }
}

/// Volume after the built-in tone: −30 dB, in the device's 0.1 dB steps.
const calibrationSafeVolumeRaw = -300;

/// Only ever lowers: quieter outputs keep their volume.
void lowerOutputsAfterCalibration(Adi2Controller ctrl) {
  for (final output in _muteOutputs(ctrl)) {
    final volume = ctrl.value(output.address, OutIdx.volume);
    if (volume != null && volume > calibrationSafeVolumeRaw) {
      ctrl.setVolume(
        output.address,
        calibrationSafeVolumeRaw,
        followLink: false,
      );
    }
  }
}

/// Lowers, then fetches the device's values and requires two consecutive
/// fresh answers at or below the safe volume. Without an answer it fails.
Future<bool> ensureOutputsQuiet(Adi2Controller ctrl) async {
  var confirmedRounds = 0;
  for (var round = 0; round < 5; round++) {
    if (round % 2 == 0) lowerOutputsAfterCalibration(ctrl);
    // Time for the volume tick to send before the device is asked.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (!await ctrl.refreshConfirmedValues(
      requiredKeys: _calibrationRequiredKeys(ctrl),
    )) {
      confirmedRounds = 0;
      continue;
    }
    final quiet = _muteOutputs(ctrl).every((o) {
      final shown = ctrl.value(o.address, OutIdx.volume);
      final confirmed = ctrl.confirmedValue(o.address, OutIdx.volume);
      return shown != null &&
          confirmed != null &&
          shown <= calibrationSafeVolumeRaw &&
          confirmed <= calibrationSafeVolumeRaw;
    });
    confirmedRounds = quiet ? confirmedRounds + 1 : 0;
    if (confirmedRounds >= 2) return true;
  }
  return false;
}

/// Measurement checklist for the built-in tone. Empty means it may play.
List<String> calibrationToneBlockers(
  Adi2Controller? ctrl,
  AnalyzerController controller,
) {
  if (ctrl == null ||
      ctrl.state != ConnState.connected ||
      ctrl.variant == null ||
      ctrl.analyzerSelfTestActive) {
    return [tr('Gerät nicht verbunden')];
  }
  final hasInput = ctrl.variant!.hasInput;
  final blockers = <String>[
    if (!calibrationOutputsMuted(ctrl)) tr('Nicht alle Ausgänge sind stumm'),
  ];
  final output = analyzerLoopbackSource(ctrl);
  final confirmed = output == null
      ? null
      : ctrl.confirmedValue(output.address, OutIdx.loopback);
  final route = confirmed == null
      ? null
      : decodeLoopback(confirmed, hasInput: hasInput);
  final competing = analyzerOutputs(ctrl).any((o) {
    if (o.address == output?.address) return false;
    final other = decodeLoopback(
      ctrl.value(o.address, OutIdx.loopback)!,
      hasInput: hasInput,
    );
    return other.pair == 0 && other.tap != 0 && other.tap != 2;
  });
  if (route == null || route.pair != 0 || route.tap != 2 || competing) {
    blockers.add(tr('Loopback auf post FX und USB 1/2 stellen'));
  }
  if (output != null) {
    final a = output.address;
    if (!analyzerCalibrationUsesUsb(ctrl)) {
      blockers.add(tr('Quelle des gemessenen Ausgangs auf USB stellen'));
    }
    if (ctrl.confirmedValue(a, OutIdx.daFilter) != 0) {
      blockers.add(tr('DA-Filter auf SD Sharp stellen'));
    }
    final bassTreble =
        ctrl.valueOr(a + 1, EqIdx2.btEnable, 0) != 0 &&
        (ctrl.valueOr(a + 1, 21, 0) != 0 || ctrl.valueOr(a + 1, 24, 0) != 0);
    if (ctrl.valueOr(a + 1, EqIdx.enable, 0) != 0 ||
        bassTreble ||
        ctrl.valueOr(a, OutIdx.loudness, 0) != 0 ||
        ctrl.valueOr(a, OutIdx.crossfeed, 0) != 0) {
      blockers.add(tr('EQ, Bass/Treble, Loudness und Crossfeed ausschalten'));
    }
  }
  if (defaultTargetPlatform != TargetPlatform.macOS &&
      (controller.mediaVolume == null ||
          controller.mediaVolumeMax == null ||
          controller.mediaVolumeBelowMaximum)) {
    blockers.add(tr('Medienlautstärke auf Maximum stellen'));
  }
  return blockers;
}

class AnalyzerCalibrationHint extends StatelessWidget {
  const AnalyzerCalibrationHint({
    super.key,
    required this.controller,
    this.deviceController,
  });
  final AnalyzerController controller;
  final Adi2Controller? deviceController;
  @override
  Widget build(BuildContext context) {
    final red =
        analyzerCalibrationUsesUsb(deviceController) &&
        controller.mediaVolumeBelowMaximum;
    final color = red ? Colors.red : Colors.amber;
    return Card(
      key: ValueKey(red ? 'calibration-hint-red' : 'calibration-hint'),
      color: color.withValues(alpha: .16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: color),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: color),
            Text(
              tr(
                'Testton vom Smartphone/Tablet über USB: Medienlautstärke auf Maximum stellen.',
              ),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              controller.mediaVolume == null ||
                      controller.mediaVolumeMax == null
                  ? tr('Medienlautstärke: nicht verfügbar')
                  : trf('Medienlautstärke: {current}/{max}', {
                      'current': controller.mediaVolume,
                      'max': controller.mediaVolumeMax,
                    }),
              key: const ValueKey('calibration-media-volume'),
            ),
            const SizedBox(height: 8),
            Text(
              tr(
                'Genauer ist eine externe Quelle (Optical, SPDIF, AES oder Analog), denn Android-Klangeffekte können den Pegel bei USB-Wiedergabe verändern.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnalyzerCalibrationSettingState
    extends State<AnalyzerCalibrationSetting> {
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    if (widget.startAutomatically) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _automatic();
      });
    }
  }

  String _error(Object error) => switch (error) {
    AnalyzerCalibrationError.tooQuiet => tr(
      'Signal zu leise. Beide Kanäle müssen über −60 dBFS liegen. Nichts gespeichert.',
    ),
    AnalyzerCalibrationError.unbalanced => tr(
      'L und R unterscheiden sich um mehr als 1 dB. Nichts gespeichert.',
    ),
    AnalyzerCalibrationError.unstable => tr(
      'Signal instabil. Der Peak muss je Kanal innerhalb ±0,5 dB bleiben. Nichts gespeichert.',
    ),
    AnalyzerCalibrationError.outOfRange => tr(
      'Der benötigte Offset liegt außerhalb −40 bis +40 dB. Nichts gespeichert.',
    ),
    AnalyzerCalibrationError.volumeUnverified => tr(
      'Lautstärke vom Gerät nicht bestätigt. Ausgänge stumm lassen und Lautstärke am Gerät prüfen.',
    ),
    AnalyzerCalibrationError.toneUnavailable => tr(
      'Testton konnte nicht über USB gestartet werden. Nichts gespeichert.',
    ),
    AnalyzerCalibrationError.toneInterrupted => tr(
      'Testton abgebrochen, weil sich der Messaufbau geändert hat. Nichts gespeichert.',
    ),
    AnalyzerCalibrationError.unavailable => tr(
      'USB-Aufnahme unterbrochen oder zu wenige Messwerte. Erneut versuchen. Nichts gespeichert.',
    ),
    _ => tr(
      'Pegelkalibrierung konnte nicht gespeichert werden. Erneut versuchen.',
    ),
  };

  Future<bool> _confirm({
    required String title,
    required String content,
    required String action,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: Text(content),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('Abbrechen')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _change(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final device = widget.deviceController;
      if (device == null) {
        await action();
      } else {
        await device.withDaFilterProbePaused(action);
      }
    } catch (error) {
      if (mounted) setState(() => _message = _error(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _automatic() => _change(() async {
    var useTone = false;
    final canUseTone =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.macOS) &&
        widget.deviceController != null;
    final accepted =
        await showDialog<bool>(
          context: context,
          builder: (context) {
            bool acknowledged = false;
            String? acknowledgedRoute;
            int? acknowledgedVolume;
            return StatefulBuilder(
              builder: (context, setDialogState) => ListenableBuilder(
                listenable: Listenable.merge([
                  widget.controller,
                  if (widget.deviceController != null) widget.deviceController!,
                ]),
                builder: (context, _) {
                  final c = widget.controller;
                  final blocked =
                      analyzerCalibrationUsesUsb(widget.deviceController) &&
                      c.mediaVolumeBelowMaximum;
                  final confirmed =
                      acknowledged &&
                      acknowledgedRoute == c.calibrationIdentity?.key &&
                      acknowledgedVolume == c.mediaVolume;
                  final device = widget.deviceController;
                  final toneBlockers = useTone
                      ? calibrationToneBlockers(device, c)
                      : const <String>[];
                  return AlertDialog(
                    scrollable: true,
                    title: Text(tr('Auf 0 dB kalibrieren')),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          tr(
                            'Einen voll ausgesteuerten Sinus (0 dBFS) auf L und R einspielen. Abgriff post FX wählen und EQ sowie alle Effekte ausschalten. Anschließend wird der unkalibrierte Peak etwa 2 Sekunden gemessen.',
                          ),
                        ),
                        AnalyzerCalibrationHint(
                          controller: c,
                          deviceController: widget.deviceController,
                        ),
                        if (canUseTone)
                          SwitchListTile(
                            key: const ValueKey('calibration-test-tone'),
                            contentPadding: EdgeInsets.zero,
                            title: Text(tr('Testton der App verwenden')),
                            subtitle: Text(
                              tr(
                                'Spielt 1 kHz mit 0 dBFS nur während der Messung über USB ab.',
                              ),
                            ),
                            value: useTone,
                            onChanged: (value) {
                              setDialogState(() => useTone = value);
                              if (value && device != null) {
                                unawaited(
                                  device.refreshConfirmedValues(
                                    requiredKeys: _calibrationRequiredKeys(
                                      device,
                                    ),
                                  ),
                                );
                              }
                            },
                          ),
                        if (useTone) ...[
                          for (final blocker in toneBlockers)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '• $blocker',
                                key: const ValueKey('calibration-tone-blocker'),
                              ),
                            ),
                          if (device != null &&
                              device.variant != null &&
                              !calibrationOutputsMuted(device))
                            Align(
                              alignment: Alignment.centerLeft,
                              child: OutlinedButton.icon(
                                key: const ValueKey('calibration-mute-all'),
                                icon: const Icon(Icons.volume_off),
                                label: Text(tr('Alle Ausgänge stummschalten')),
                                onPressed: () {
                                  muteCalibrationOutputs(device);
                                  unawaited(
                                    Future<void>.delayed(
                                      const Duration(milliseconds: 200),
                                      () => device.refreshConfirmedValues(
                                        requiredKeys: _calibrationRequiredKeys(
                                          device,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                        ],
                        if (blocked && !useTone)
                          CheckboxListTile(
                            key: const ValueKey('calibration-volume-confirm'),
                            contentPadding: EdgeInsets.zero,
                            title: Text(tr('Trotzdem kalibrieren')),
                            value: confirmed,
                            onChanged: (value) => setDialogState(() {
                              acknowledged = value == true;
                              acknowledgedRoute = c.calibrationIdentity?.key;
                              acknowledgedVolume = c.mediaVolume;
                            }),
                          ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(tr('Abbrechen')),
                      ),
                      FilledButton(
                        onPressed:
                            c.canCalibrate &&
                                (useTone
                                    ? toneBlockers.isEmpty
                                    : !blocked || confirmed)
                            ? () => Navigator.pop(context, true)
                            : null,
                        child: Text(tr('Messung starten')),
                      ),
                    ],
                  );
                },
              ),
            );
          },
        ) ==
        true;
    if (!accepted || !mounted) return;
    if (useTone) {
      // Never start a full-scale tone on remembered values.
      final device = widget.deviceController;
      if (device == null ||
          !await device.refreshConfirmedValues(
            requiredKeys: _calibrationRequiredKeys(device),
          ) ||
          calibrationToneBlockers(device, widget.controller).isNotEmpty) {
        throw AnalyzerCalibrationError.toneInterrupted;
      }
      if (!mounted) return;
    }
    setState(() => _message = tr('Peak wird 2 Sekunden gemessen …'));
    AnalyzerCalibrationProposal? measured;
    Object? failure;
    var measuring = true;
    var deviceAnswers = true;
    if (useTone) {
      // Ask the device throughout the tone; silence from it stops the tone.
      unawaited(() async {
        while (measuring && deviceAnswers) {
          final device = widget.deviceController;
          final answered =
              device != null &&
              await device.refreshConfirmedValues(
                requiredKeys: _calibrationRequiredKeys(device),
              );
          if (measuring) deviceAnswers = answered;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }());
    }
    try {
      measured = await widget.controller.measureCalibration(
        useTestTone: useTone,
        toneAllowed: () =>
            deviceAnswers &&
            calibrationToneBlockers(
              widget.deviceController,
              widget.controller,
            ).isEmpty,
      );
    } catch (error) {
      failure = error;
    }
    measuring = false;
    final device = widget.deviceController;
    if (useTone &&
        device != null &&
        device.state == ConnState.connected &&
        !await ensureOutputsQuiet(device)) {
      throw AnalyzerCalibrationError.volumeUnverified;
    }
    if (failure != null) throw failure;
    final proposal = measured!;
    if (!mounted) return;
    setState(() => _message = null);
    if (await _confirm(
          title: tr('Pegelkalibrierung'),
          content: trf('Offset {offset} dB speichern?', {
            'offset': analyzerCalibrationDb(proposal.offset),
          }),
          action: tr('Speichern'),
        ) &&
        mounted) {
      await widget.controller.saveCalibration(proposal);
    }
    if (useTone && mounted) {
      setState(
        () => _message = tr(
          'Ausgänge bleiben stumm und stehen auf höchstens −30 dB, vom Gerät bestätigt.',
        ),
      );
    }
  });

  Future<void> _reset() => _change(() async {
    final proposal = widget.controller.calibrationProposal(0);
    if (await _confirm(
          title: tr('Pegelkalibrierung zurücksetzen?'),
          content: tr(
            'Den Offset für diese Gerätekombination auf 0 dB zurücksetzen?',
          ),
          action: tr('Zurücksetzen'),
        ) &&
        mounted) {
      await widget.controller.saveCalibration(proposal);
    }
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.controller,
      if (widget.deviceController != null) widget.deviceController!,
    ]),
    builder: (context, _) {
      final controller = widget.controller;
      final raw = controller.rawFrame;
      final enabled = !_busy && controller.canCalibrate;
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('Pegelkalibrierung'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (controller.calibrationIdentity case final identity?)
              Text(
                identity.label,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 8),
            Text(
              trf('Aktueller Offset {offset} dB', {
                'offset': analyzerCalibrationDb(controller.calibrationOffset),
              }),
              key: const ValueKey('analyzer-calibration-offset'),
            ),
            Text(
              trf('Unkalibrierter Peak · L {left} / R {right} dBFS', {
                'left': raw == null ? '—' : analyzerCalibrationDb(raw.peak[0]),
                'right': raw == null ? '—' : analyzerCalibrationDb(raw.peak[1]),
              }),
              key: const ValueKey('analyzer-calibration-raw'),
            ),
            if (!controller.canCalibrate)
              Text(
                tr(
                  'Für die Kalibrierung eine aktive ADI-2-USB-Aufnahme starten.',
                ),
              ),
            AnalyzerCalibrationHint(
              controller: controller,
              deviceController: widget.deviceController,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: const ValueKey('analyzer-calibration-auto'),
                  onPressed: enabled ? _automatic : null,
                  child: Text(tr('Auf 0 dB kalibrieren')),
                ),
                for (final step in [-1.0, -0.1, 0.1, 1.0])
                  OutlinedButton(
                    key: ValueKey('analyzer-calibration-step-$step'),
                    onPressed:
                        enabled &&
                            (controller.calibrationOffset + step).abs() <=
                                40.000001
                        ? () => _change(
                            () => controller.saveCalibration(
                              controller.calibrationProposal(
                                controller.calibrationOffset + step,
                              ),
                            ),
                          )
                        : null,
                    child: Text('${analyzerCalibrationDb(step)} dB'),
                  ),
                TextButton(
                  key: const ValueKey('analyzer-calibration-reset'),
                  onPressed: enabled && controller.calibrationOffset != 0
                      ? _reset
                      : null,
                  child: Text(tr('Zurücksetzen')),
                ),
              ],
            ),
            if (_message != null)
              Text(
                _message!,
                key: const ValueKey('analyzer-calibration-message'),
              ),
          ],
        ),
      );
    },
  );
}
