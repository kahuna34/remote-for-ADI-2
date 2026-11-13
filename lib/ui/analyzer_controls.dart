import 'dart:math' as math;
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
import '../device/loopback_routing.dart';
import 'loopback_feedback.dart';
import '../l10n/l10n.dart';
import '../protocol/adi2_params.dart';
import '../protocol/adi2_codec.dart';
import 'outputs_page.dart';
import 'responsive_layout.dart';
import '../eq/eq_model.dart';

/// Each tool supplies its own optional toolbar controls.
/// New tools can return an empty list or different widget builders.
extension AnalyzerToolPresentation on AnalyzerView {
  String get title => switch (this) {
    AnalyzerView.spectrum => tr('Spektrum'),
  };

  /// Werkzeuge mit Peak-Marken zeigen den Knopf „Peak hold“.
  bool get hasPeakHold => switch (this) {
    AnalyzerView.spectrum => true,
  };
  List<Widget> viewControls(AnalyzerController controller) => switch (this) {
    AnalyzerView.spectrum => [
      AnalyzerChoices<bool>(
        key: const ValueKey('analyzer-spectrum-mode'),
        values: const [false, true],
        value: controller.bars,
        label: (bars) => tr(bars ? 'Balken' : 'Linien'),
        onSelected: controller.setBars,
      ),
    ],
  };

  List<Widget> settingsOptions(AnalyzerController controller) => switch (this) {
    AnalyzerView.spectrum => [
      _AnalyzerSettingField(
        title: Text(tr('Darstellung')),
        trailing: viewControls(controller).single,
      ),
      const AnalyzerBandSetting(),
      SwitchListTile(
        title: Text(tr('Peak hold')),
        value: controller.peakHold,
        onChanged: controller.setPeakHold,
      ),
      AnalyzerBallisticsSetting(controller: controller),
      const AnalyzerPeakHoldSetting(),
    ],
  };

  List<WidgetBuilder> get toolbarOptions => switch (this) {
    AnalyzerView.spectrum => [
      (context) => const AnalyzerBandSetting(inline: true),
    ],
  };
}

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

/// Zuletzt gemeldete Gerätefarbe: Beim Neuverbinden sind die Gerätewerte
/// kurz leer; „Wie Gerät“ soll dann nicht auf Grün springen.
int? _lastDeviceMeterColor;

Color analyzerColor(Adi2Controller? ctrl) {
  final setting = AppSettings.instance.analyzerColor;
  int index;
  if (setting < 0) {
    final device = ctrl?.value(Adi2Addr.device, DevIdx.meterColor);
    if (device != null) _lastDeviceMeterColor = device;
    index = device ?? _lastDeviceMeterColor ?? 0;
  } else {
    index = setting;
  }
  return analyzerColors[index.clamp(0, 5)];
}

List<OutputInfo> analyzerOutputs(Adi2Controller? ctrl) => ctrl?.variant == null
    ? []
    : outputsFor(ctrl!.variant!)
          .where((o) => ctrl.value(o.address, OutIdx.loopback) != null)
          .toList();

OutputInfo? analyzerLoopbackSource(Adi2Controller? ctrl) {
  final outputs = analyzerOutputs(ctrl);
  if (ctrl?.variant?.isDac == true) {
    final address = dacLoopbackAddress(ctrl!);
    return address == null || ctrl.value(address, OutIdx.loopback) == 0
        ? null
        : outputs.where((o) => o.address == address).firstOrNull;
  }
  for (final output in outputs) {
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
            : trailing is AnalyzerChoices
            // Knöpfe beginnen direkt nach einer schmalen Beschriftungsspalte
            // und nutzen die ganze restliche Breite; zu viele brechen um.
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: math.min(170, constraints.maxWidth * 0.3),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: title,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: trailing,
                    ),
                  ),
                ],
              )
            : Row(
                children: [
                  Expanded(child: title),
                  const SizedBox(width: 12),
                  SizedBox(width: controlWidth, child: trailing),
                ],
              ),
      );
    },
  );
}

/// Shared wrapping selection buttons for analyzer preferences.
class AnalyzerChoices<T> extends StatelessWidget {
  const AnalyzerChoices({
    super.key,
    required this.values,
    required this.value,
    required this.label,
    required this.onSelected,
    this.color,
  });
  final List<T> values;
  final T value;
  final String Function(T) label;
  final ValueChanged<T>? onSelected;
  final Color? Function(T)? color;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 4,
    alignment: WrapAlignment.start,
    children: [
      for (final option in values)
        ChoiceChip(
          key: ValueKey((key, option)),
          label: Text(label(option)),
          avatar: color?.call(option) == null
              ? null
              : CircleAvatar(backgroundColor: color!(option), radius: 8),
          selected: option == value,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onSelected: onSelected == null ? null : (_) => onSelected!(option),
        ),
    ],
  );
}

class _AnalyzerHeaderField extends StatelessWidget {
  const _AnalyzerHeaderField({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: title,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
        child,
      ],
    ),
  );
}

class AnalyzerBallisticsSetting extends StatelessWidget {
  const AnalyzerBallisticsSetting({
    super.key,
    required this.controller,
    this.inline = false,
  });
  final AnalyzerController controller;
  final bool inline;
  @override
  Widget build(BuildContext context) {
    String label(AnalyzerBallistics b) =>
        tr(['schnell', 'mittel', 'langsam'][b.index]);
    if (inline) {
      return _AnalyzerHeaderField(
        title: tr('Ballistik'),
        child: DropdownButton<AnalyzerBallistics>(
          key: const ValueKey('analyzer-ballistics-header'),
          isExpanded: true,
          isDense: true,
          underline: const SizedBox.shrink(),
          value: controller.ballistics,
          items: [
            for (final b in AnalyzerBallistics.values)
              DropdownMenuItem(
                value: b,
                child: Text(
                  label(b),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (b) {
            if (b != null) controller.setBallistics(b);
          },
        ),
      );
    }
    return _AnalyzerSettingField(
      title: Text(tr('Ballistik')),
      trailing: AnalyzerChoices<AnalyzerBallistics>(
        key: const ValueKey('analyzer-ballistics'),
        values: AnalyzerBallistics.values,
        value: controller.ballistics,
        label: label,
        onSelected: controller.setBallistics,
      ),
    );
  }
}

class AnalyzerPeakHoldSetting extends StatelessWidget {
  const AnalyzerPeakHoldSetting({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppSettings.instance,
    builder: (context, _) => _AnalyzerSettingField(
      title: Text(tr('Peak-Hold-Zeit')),
      trailing: AnalyzerChoices<int>(
        key: const ValueKey('analyzer-peak-hold-seconds'),
        values: AppSettings.analyzerPeakHoldOptions,
        value: AppSettings.instance.analyzerPeakHoldSeconds,
        label: (seconds) =>
            seconds == 0 ? tr('∞') : trf('{seconds} s', {'seconds': seconds}),
        onSelected: AppSettings.instance.setAnalyzerPeakHoldSeconds,
      ),
    ),
  );
}

class AnalyzerColorSetting extends StatelessWidget {
  const AnalyzerColorSetting({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppSettings.instance,
    builder: (context, _) => _AnalyzerSettingField(
      title: Text(tr('Analyzer-Farbe')),
      trailing: AnalyzerChoices<int>(
        key: const ValueKey('analyzer-color'),
        values: const [-1, 0, 1, 2, 3, 4, 5],
        value: AppSettings.instance.analyzerColor,
        label: (i) => analyzerColorNames[i + 1],
        color: (i) => i < 0 ? null : analyzerColors[i],
        onSelected: AppSettings.instance.setAnalyzerColor,
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
    if (widget.routing == null) {
      _ownedRouting = AnalyzerRouting(
        widget.ctrl,
        onDisplaced: (a, p) {
          if (mounted) showLoopbackDisplaced(context, widget.ctrl!, a, p);
        },
      );
    }
  }

  @override
  void didUpdateWidget(AnalyzerLoopbackControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ctrl != widget.ctrl || oldWidget.routing != widget.routing) {
      _ownedRouting?.dispose();
      _ownedRouting = widget.routing == null
          ? AnalyzerRouting(
              widget.ctrl,
              onDisplaced: (a, p) {
                if (mounted) showLoopbackDisplaced(context, widget.ctrl!, a, p);
              },
            )
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
    if (_changing ||
        ctrl == null ||
        (ctrl.state != ConnState.connected && !ctrl.offline)) {
      return;
    }
    _changing = true;
    try {
      if (tap != 0 &&
          ctrl.variant?.hasInput == true &&
          !AppSettings.instance.analyzerLoopbackConfirmed) {
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
      if (ctrl.variant?.isDac == true &&
          !AppSettings.instance.analyzerLoopbackConfirmed) {
        await AppSettings.instance.confirmAnalyzerLoopback();
      }
      // The device may detach while the first-use confirmation is open.
      if (!mounted ||
          ctrl != widget.ctrl ||
          (ctrl.state != ConnState.connected && !ctrl.offline)) {
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
          (ctrl?.state == ConnState.connected || ctrl?.offline == true) &&
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
      final fields = <Widget>[
        if (ctrl?.variant?.isDac != true &&
            outputs.length > 1 &&
            !widget.inline)
          _AnalyzerSettingField(
            title: Text(tr('Ausgang')),
            controlWidth: 280,
            trailing: AnalyzerChoices<int>(
              key: const ValueKey('analyzer-loopback-output'),
              values: [0, for (final output in outputs) output.address],
              value: outputValue,
              label: (address) => address == 0
                  ? tr('Automatisch (aktiver Ausgang)')
                  : outputs.firstWhere((o) => o.address == address).name,
              onSelected: enabled
                  ? (address) => _set(address, tap == 0 ? 2 : tap)
                  : null,
            ),
          ),
        if (widget.inline)
          _AnalyzerHeaderField(
            title: tr('Loopback-Quelle'),
            child: DropdownButton<int>(
              key: const ValueKey('analyzer-loopback-tap'),
              menuWidth: 180,
              isDense: true,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              value: tap,
              items: [
                for (var i = 0; i < 4; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      tr(['Aus', 'pre FX', 'post FX', 'post −6 dB'][i]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: enabled
                  ? (value) {
                      if (value != null) _set(outputValue, value);
                    }
                  : null,
            ),
          )
        else
          _AnalyzerSettingField(
            title: Text(tr('Loopback-Quelle')),
            controlWidth: 280,
            trailing: AnalyzerChoices<int>(
              key: const ValueKey('analyzer-loopback-tap'),
              values: const [0, 1, 2, 3],
              value: tap,
              label: (i) => tr(['Aus', 'pre FX', 'post FX', 'post −6 dB'][i]),
              onSelected: enabled ? (value) => _set(outputValue, value) : null,
            ),
          ),
      ];
      return widget.inline
          ? fields.single
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
                    _AnalyzerSettingField(
                      title: Text(tr('Werkzeug')),
                      trailing: AnalyzerChoices<AnalyzerView>(
                        key: const ValueKey('analyzer-tool'),
                        values: AnalyzerView.values,
                        value: controller.view,
                        label: (tool) => tool.title,
                        onSelected: controller.setView,
                      ),
                    ),
                    ...controller.view.settingsOptions(controller),
                  ],
                ),
              ),
              ListenableBuilder(
                listenable: AppSettings.instance,
                builder: (context, _) => _AnalyzerSettingField(
                  title: Text(tr('Anzeige im Hauptfenster')),
                  trailing: AnalyzerChoices<AnalyzerMainView>(
                    key: const ValueKey('analyzer-main-view-setting'),
                    values: isTablet(context)
                        ? AnalyzerMainView.values
                        : const [
                            AnalyzerMainView.spectrum,
                            AnalyzerMainView.levels,
                          ],
                    value:
                        !isTablet(context) &&
                            AppSettings.instance.analyzerMainView ==
                                AnalyzerMainView.both
                        ? AnalyzerMainView.spectrum
                        : AppSettings.instance.analyzerMainView,
                    label: (value) => tr(switch (value) {
                      AnalyzerMainView.spectrum => 'Spektrum',
                      AnalyzerMainView.levels => 'Pegel (Peak/RMS)',
                      AnalyzerMainView.both => 'Beides',
                    }),
                    onSelected: AppSettings.instance.setAnalyzerMainView,
                  ),
                ),
              ),
              ListenableBuilder(
                listenable: AppSettings.instance,
                builder: (context, _) => SwitchListTile(
                  key: const ValueKey('analyzer-player-setting'),
                  title: Text(tr('Player beim Antippen des Graphen')),
                  value: AppSettings.instance.analyzerPlayerOnTap,
                  onChanged: AppSettings.instance.setAnalyzerPlayerOnTap,
                ),
              ),
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
      trailing: AnalyzerChoices<int>(
        key: const ValueKey('analyzer-range'),
        values: const [60, 80, 100],
        value: AppSettings.instance.analyzerRange,
        label: (range) => '$range dB',
        onSelected: AppSettings.instance.setAnalyzerRange,
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
      final choices = AnalyzerChoices<AnalyzerBandResolution>(
        key: const ValueKey('analyzer-band-resolution'),
        values: AnalyzerBandResolution.values,
        value: AppSettings.instance.analyzerBandResolution,
        label: (resolution) => inline
            ? '1/${resolution.bandsPerOctave}'
            : tr(switch (resolution) {
                AnalyzerBandResolution.third => '1/3 Oktave',
                AnalyzerBandResolution.sixth => '1/6 Oktave',
                AnalyzerBandResolution.twelfth => '1/12 Oktave',
              }),
        onSelected: AppSettings.instance.setAnalyzerBandResolution,
      );
      return inline
          ? Tooltip(message: tr('Bandauflösung'), child: choices)
          : _AnalyzerSettingField(
              title: Text(tr('Bandauflösung')),
              trailing: choices,
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
  if (controller.viaHost || ctrl?.viaHost == true) {
    return [
      tr(
        'Kalibrier-Testton und Analyzer-Selbsttest: nur bei direkter USB-Verbindung.',
      ),
    ];
  }
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
  final competing =
      !ctrl.variant!.isDac &&
      analyzerOutputs(ctrl).any((o) {
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
        !widget.controller.viaHost &&
        widget.deviceController?.viaHost != true &&
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
                            'Einen voll ausgesteuerten Sinus (0 dBFS) auf L und R einspielen. Loopback-Quelle post FX wählen und EQ sowie alle Effekte ausschalten. Anschließend wird der unkalibrierte Peak etwa 2 Sekunden gemessen.',
                          ),
                        ),
                        AnalyzerCalibrationHint(
                          controller: c,
                          deviceController: widget.deviceController,
                        ),
                        if (c.viaHost)
                          Text(
                            tr(
                              'Kalibrier-Testton und Analyzer-Selbsttest: nur bei direkter USB-Verbindung.',
                            ),
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
