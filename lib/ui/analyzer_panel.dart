import 'loopback_feedback.dart';
import '../dev/analyzer_selftest_diagnostics.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../analyzer/analyzer_controller.dart';
import '../analyzer/analyzer_dsp.dart';
import '../analyzer/analyzer_routing.dart';
import '../app_settings.dart';
import '../device/adi2_controller.dart';
import '../device/loopback.dart';
import '../protocol/adi2_params.dart';
import '../l10n/l10n.dart';
import 'analyzer_controls.dart';
import 'eq_display_mode.dart';
import 'responsive_layout.dart';
import 'player_bar.dart';
import 'theme.dart';

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
  List<WidgetBuilder> get toolbarOptions => switch (this) {
    AnalyzerView.spectrum => [
      (context) => const AnalyzerBandSetting(inline: true),
    ],
  };
}

/// One capture owner survives compact/fullscreen transitions, but stops when
/// hidden by another page, a tab change, backgrounding, or removal.
/// On the Mac a visible window that merely lost focus is `inactive`; the
/// analyzer keeps running there. Mobile apps only run while resumed.
bool analyzerRunsIn(AppLifecycleState state) =>
    state == AppLifecycleState.resumed ||
    (state == AppLifecycleState.inactive &&
        defaultTargetPlatform == TargetPlatform.macOS);

/// „Peak hold“: Tippen schaltet um, langes Drücken setzt die Marken zurück.
class AnalyzerPeakHoldChip extends StatelessWidget {
  const AnalyzerPeakHoldChip({super.key, required this.controller});
  final AnalyzerController controller;

  @override
  Widget build(BuildContext context) => GestureDetector(
    key: const ValueKey('analyzer-peak-hold'),
    onLongPress: () {
      controller.resetPeaks();
      HapticFeedback.selectionClick();
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(tr('Peak-Marken zurückgesetzt')),
            duration: const Duration(seconds: 1),
          ),
        );
    },
    child: FilterChip(
      label: Text(tr('Peak hold')),
      selected: controller.peakHold,
      showCheckmark: false,
      labelStyle: ts(12),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: controller.setPeakHold,
    ),
  );
}

class AnalyzerPanel extends StatefulWidget {
  const AnalyzerPanel({
    super.key,
    this.controller,
    this.deviceController,
    this.expanded = false,
  });
  final bool expanded;
  final Adi2Controller? deviceController;
  final AnalyzerController? controller;
  @override
  State<AnalyzerPanel> createState() => _AnalyzerPanelState();
}

class _AnalyzerPanelState extends State<AnalyzerPanel>
    with WidgetsBindingObserver {
  late final AnalyzerController _controller;
  late AnalyzerRouting _routing;
  bool _current = true, _foreground = true, _waitForPortrait = false;
  bool _scheduled = false, _controlsOpen = false;
  bool _fullscreenCurrent = false;
  bool _fullscreenDisposed = false, _resourcesDisposed = false;
  Route<void>? _fullscreen;
  bool _calibrationPromptScheduled = false, _calibrationPromptOpen = false;

  void _scheduleCalibrationPrompt() {
    if (_calibrationPromptScheduled || _calibrationPromptOpen || !mounted) {
      return;
    }
    _calibrationPromptScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _calibrationPromptScheduled = false;
      if (mounted) unawaited(_offerCalibration());
    });
  }

  bool get _canOfferCalibration =>
      _foreground &&
      (_current || _fullscreenCurrent) &&
      !_controlsOpen &&
      widget.deviceController?.state == ConnState.connected &&
      widget.deviceController?.analyzerSelfTestActive == false &&
      _controller.canCalibrate;

  Future<void> _offerCalibration() async {
    if (!_canOfferCalibration || _calibrationPromptOpen) return;
    final key = _controller.calibrationIdentity!.key;
    final settings = AppSettings.instance;
    if (!settings.claimAnalyzerCalibrationPrompt(key)) return;
    _calibrationPromptOpen = true;
    _controlsOpen = true;
    try {
      final answer = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => ListenableBuilder(
          listenable: Listenable.merge([_controller, widget.deviceController!]),
          builder: (context, _) => AlertDialog(
            scrollable: true,
            title: Text(tr('Analyzer kalibrieren?')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr(
                    'Für genaue Pegel empfohlen, dauert wenige Sekunden. Kalibrierung jederzeit in den Analyzer-Einstellungen.',
                  ),
                ),
                AnalyzerCalibrationHint(
                  controller: _controller,
                  deviceController: widget.deviceController,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr('Nein')),
              ),
              FilledButton(
                onPressed:
                    _controller.canCalibrate &&
                        _controller.calibrationIdentity?.key == key &&
                        widget.deviceController?.state == ConnState.connected &&
                        widget.deviceController?.analyzerSelfTestActive == false
                    ? () => Navigator.pop(context, true)
                    : null,
                child: Text(tr('Ja')),
              ),
            ],
          ),
        ),
      );
      if (answer == null) return;
      await settings.answerAnalyzerCalibrationPrompt(key, answer);
      if (!mounted ||
          answer != true ||
          _controller.calibrationIdentity?.key != key ||
          widget.deviceController?.analyzerSelfTestActive == true ||
          widget.deviceController?.state != ConnState.connected) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          content: AnalyzerCalibrationSetting(
            controller: _controller,
            deviceController: widget.deviceController,
            startAutomatically: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('Schließen')),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                'Pegelkalibrierung konnte nicht gespeichert werden. Erneut versuchen.',
              ),
            ),
          ),
        );
      }
    } finally {
      settings.releaseAnalyzerCalibrationPrompt(key);
      _calibrationPromptOpen = false;
      _controlsOpen = false;
      if (mounted) _schedule();
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? AnalyzerController();
    _routing = AnalyzerRouting(
      widget.deviceController,
      onDisplaced: (a, p) {
        if (mounted) {
          showLoopbackDisplaced(context, widget.deviceController!, a, p);
        }
      },
    );
    _controller.addListener(_scheduleCalibrationPrompt);
    widget.deviceController?.addListener(_scheduleCalibrationPrompt);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || analyzerRunsIn(lifecycle);
    WidgetsBinding.instance.addObserver(this);
    AppSettings.instance.addListener(_schedule);
  }

  @override
  void didUpdateWidget(AnalyzerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceController != widget.deviceController) {
      oldWidget.deviceController?.removeListener(_scheduleCalibrationPrompt);
      widget.deviceController?.addListener(_scheduleCalibrationPrompt);
      _routing.dispose();
      _routing = AnalyzerRouting(
        widget.deviceController,
        onDisplaced: (a, p) {
          if (mounted) {
            showLoopbackDisplaced(context, widget.deviceController!, a, p);
          }
        },
      );
      _updateActivity();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _current = ModalRoute.isCurrentOf(context) ?? true;
    _updateActivity();
    MediaQuery.orientationOf(context);
    _schedule();
  }

  @override
  void didChangeMetrics() => _schedule();
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = analyzerRunsIn(state);
    _updateActivity();
  }

  void _updateActivity() {
    _scheduleCalibrationPrompt();
    final active =
        _foreground && (_current || _fullscreenCurrent || _controlsOpen);
    _routing.setActive(active);
    unawaited(
      _controller.setActiveFor(
        this,
        _foreground && (_current || _fullscreenCurrent || _controlsOpen),
      ),
    );
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      _updateActivity();
      final size = MediaQuery.sizeOf(context);
      if (size.height >= size.width) _waitForPortrait = false;
      final auto = AppSettings.instance.autoFullscreenEq && !isTablet(context);
      EqDisplayMode.allowRotation(this, _current && auto && !_waitForPortrait);
      if (_foreground &&
          _current &&
          auto &&
          !_waitForPortrait &&
          size.width > size.height &&
          _fullscreen == null &&
          !_controlsOpen) {
        unawaited(_open(automatic: true));
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _showControls({bool loopbackOnly = false}) async {
    _controlsOpen = true;
    try {
      await showAnalyzerSettings(
        context,
        _controller,
        widget.deviceController,
        loopbackOnly: loopbackOnly,
        routing: _routing,
      );
    } finally {
      _controlsOpen = false;
      if (mounted) _schedule();
    }
  }

  Future<void> _open({bool automatic = false}) async {
    if (_fullscreen != null) return;
    _fullscreenDisposed = false;
    final route = MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'analyzer-fullscreen'),
      builder: (_) => _AnalyzerFullscreen(
        controller: _controller,
        automatic: automatic,
        routing: _routing,
        deviceController: widget.deviceController,
        onDisposed: () {
          _fullscreenDisposed = true;
          if (!mounted) _disposeResources();
        },
        onVisibilityChanged: (visible) {
          _fullscreenCurrent = visible;
          if (mounted) {
            _updateActivity();
          } else {
            _routing.setActive(visible);
          }
        },
      ),
    );
    _fullscreen = route;
    await Navigator.of(context).push(route);
    await route.completed;
    _fullscreen = null;
    _fullscreenCurrent = false;
    if (!mounted) {
      _disposeResources();
      return;
    }
    _waitForPortrait = true;
    EqDisplayMode.allowRotation(this, false);
    if (mounted) _schedule();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_scheduleCalibrationPrompt);
    widget.deviceController?.removeListener(_scheduleCalibrationPrompt);
    AppSettings.instance.removeListener(_schedule);
    EqDisplayMode.allowRotation(this, false);
    unawaited(_controller.setActiveFor(this, false));
    // Rotation rebuilds the tablet page under this route. The fullscreen owns
    // its capture activity and retains these resources until it closes.
    if (_fullscreen == null || _fullscreenDisposed) _disposeResources();
    super.dispose();
  }

  void _disposeResources() {
    if (_resourcesDisposed) return;
    _resourcesDisposed = true;
    _routing.dispose();
    if (widget.controller == null) _controller.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: SizedBox(
      height: widget.expanded ? null : headerSlotHeight(context) - 8,
      child: Panel(
        child: InkWell(
          onTap: _open,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: EdgeInsets.only(top: widget.expanded ? 40 : 0),
                child: AnalyzerDisplay(
                  controller: _controller,
                  compact: !widget.expanded,
                  deviceController: widget.deviceController,
                ),
              ),
              Align(
                alignment: Alignment.topRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_controller.view.hasPeakHold)
                      ListenableBuilder(
                        listenable: _controller,
                        builder: (context, _) =>
                            AnalyzerPeakHoldChip(controller: _controller),
                      ),
                    IconButton(
                      tooltip: tr('Analyzer-Einstellungen'),
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      style: IconButton.styleFrom(
                        fixedSize: const Size.square(40),
                        minimumSize: const Size.square(40),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      padding: EdgeInsets.zero,
                      iconSize: 18,
                      visualDensity: VisualDensity.standard,
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: _showControls,
                    ),
                    IconButton(
                      tooltip: tr('Vollbild'),
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      style: IconButton.styleFrom(
                        fixedSize: const Size.square(40),
                        minimumSize: const Size.square(40),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      padding: EdgeInsets.zero,
                      iconSize: 18,
                      visualDensity: VisualDensity.standard,
                      icon: const Icon(Icons.fullscreen),
                      onPressed: _open,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AnalyzerFullscreen extends StatefulWidget {
  const _AnalyzerFullscreen({
    required this.controller,
    required this.automatic,
    required this.routing,
    required this.onVisibilityChanged,
    required this.onDisposed,
    this.deviceController,
  });
  final AnalyzerController controller;
  final bool automatic;
  final AnalyzerRouting routing;
  final ValueChanged<bool> onVisibilityChanged;
  final VoidCallback onDisposed;
  final Adi2Controller? deviceController;
  @override
  State<_AnalyzerFullscreen> createState() => _AnalyzerFullscreenState();
}

class _AnalyzerFullscreenState extends State<_AnalyzerFullscreen>
    with WidgetsBindingObserver {
  bool _spectrumOnly = false;
  bool _foreground = true, _current = true, _controlsOpen = false;

  void _updateActivity() {
    final active = _foreground && (_current || _controlsOpen);
    widget.onVisibilityChanged(active);
    unawaited(widget.controller.setActiveFor(this, active));
  }

  Future<void> _showControls() async {
    _controlsOpen = true;
    _updateActivity();
    try {
      await showAnalyzerSettings(
        context,
        widget.controller,
        widget.deviceController,
        routing: widget.routing,
      );
    } finally {
      _controlsOpen = false;
      if (mounted) {
        // The route's inherited isCurrent value may still describe the sheet
        // during its closing frame. Read the navigator's current route now.
        _current = ModalRoute.of(context)?.isCurrent ?? true;
        _updateActivity();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = analyzerRunsIn(state);
    _updateActivity();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _current = ModalRoute.isCurrentOf(context) ?? true;
    _updateActivity();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    EqDisplayMode.enterFullscreen(this, automatic: widget.automatic);
  }

  @override
  void didChangeMetrics() {
    if (!widget.automatic) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = MediaQuery.sizeOf(context);
      if (size.height > size.width && ModalRoute.isCurrentOf(context) == true) {
        Navigator.pop(context);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    EqDisplayMode.leaveFullscreen(this);
    widget.onVisibilityChanged(false);
    unawaited(widget.controller.setActiveFor(this, false));
    widget.onDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => _spectrumOnly
            ? GestureDetector(
                key: const ValueKey('analyzer-spectrum-only'),
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _spectrumOnly = false),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    AnalyzerDisplay(
                      controller: widget.controller,
                      deviceController: widget.deviceController,
                      spectrumOnly: true,
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: IconButton(
                        tooltip: tr('Bedienleiste anzeigen'),
                        icon: const Icon(Icons.tune),
                        onPressed: () => setState(() => _spectrumOnly = false),
                      ),
                    ),
                  ],
                ),
              )
            : Column(
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final toolbar = Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          DropdownButton<AnalyzerView>(
                            value: widget.controller.view,
                            underline: const SizedBox.shrink(),
                            items: [
                              for (final tool in AnalyzerView.values)
                                DropdownMenuItem(
                                  value: tool,
                                  child: Text(tool.title),
                                ),
                            ],
                            onChanged: (v) {
                              if (v != null) widget.controller.setView(v);
                            },
                          ),
                          for (final option
                              in widget.controller.view.toolbarOptions)
                            option(context),
                        ],
                      );
                      final quickControls = SizedBox(
                        width: math.min(
                          240,
                          math.max(80, constraints.maxWidth * .34),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: AnalyzerBallisticsSetting(
                                controller: widget.controller,
                                inline: true,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: AnalyzerLoopbackControls(
                                ctrl: widget.deviceController,
                                inline: true,
                                routing: widget.routing,
                              ),
                            ),
                          ],
                        ),
                      );
                      final actions = Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          quickControls,
                          IconButton(
                            tooltip: tr('Nur Spektrum'),
                            icon: const Icon(Icons.hide_source),
                            onPressed: () =>
                                setState(() => _spectrumOnly = true),
                          ),
                          IconButton(
                            tooltip: tr('Analyzer-Einstellungen'),
                            constraints: const BoxConstraints.tightFor(
                              width: 40,
                              height: 40,
                            ),
                            style: IconButton.styleFrom(
                              fixedSize: const Size.square(40),
                              minimumSize: const Size.square(40),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.settings_outlined),
                            onPressed: _showControls,
                          ),
                          IconButton(
                            tooltip: tr('Vollbild schließen'),
                            constraints: const BoxConstraints.tightFor(
                              width: 40,
                              height: 40,
                            ),
                            style: IconButton.styleFrom(
                              fixedSize: const Size.square(40),
                              minimumSize: const Size.square(40),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.fullscreen_exit),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      );
                      return Padding(
                        key: const ValueKey('analyzer-fullscreen-toolbar'),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: constraints.maxWidth < 640
                            ? Column(
                                children: [
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: actions,
                                  ),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: toolbar,
                                  ),
                                ],
                              )
                            : Row(
                                children: [
                                  Expanded(child: toolbar),
                                  actions,
                                ],
                              ),
                      );
                    },
                  ),
                  Expanded(
                    child: AnalyzerDisplay(
                      controller: widget.controller,
                      deviceController: widget.deviceController,
                      routing: widget.routing,
                    ),
                  ),
                ],
              ),
      ),
    ),
  );
}

/// Public presentation surface also permits deterministic status widget tests.
class AnalyzerDisplay extends StatelessWidget {
  const AnalyzerDisplay({
    super.key,
    required this.controller,
    this.compact = false,
    this.spectrumOnly = false,
    this.routing,
    this.deviceController,
  });
  final AnalyzerController controller;
  final bool compact, spectrumOnly;
  final AnalyzerRouting? routing;
  final Adi2Controller? deviceController;
  static String statusText(AnalyzerStatus status) => switch (status) {
    AnalyzerStatus.permissionRequired => tr('Aufnahmeberechtigung fehlt'),
    AnalyzerStatus.usbUnavailable => tr('USB-Aufnahme nicht verfügbar'),
    AnalyzerStatus.captureFailed => tr(
      'USB-Aufnahme unterbrochen. Erneut versuchen.',
    ),
    AnalyzerStatus.silent => tr('Kein Signal. Loopback aktivieren.'),
    AnalyzerStatus.idle ||
    AnalyzerStatus.starting => tr('USB-Aufnahme wird vorbereitet …'),
    AnalyzerStatus.running => tr('USB 1/2'),
  };

  Future<void> _permission(BuildContext context) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('USB-Audio aufnehmen')),
        content: Text(
          tr(
            'Der Analyzer benötigt die Aufnahmeberechtigung für das USB-Audio des ADI-2. Das Handy-Mikrofon wird nicht verwendet. Audio wird nur bei sichtbarem Analyzer analysiert und nicht gespeichert.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Abbrechen')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Berechtigung erteilen')),
          ),
        ],
      ),
    );
    if (accepted == true) await controller.requestPermission();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      controller,
      AppSettings.instance,
      analyzerDeveloperMode,
      ?deviceController,
    ]),
    builder: (context, _) {
      final f = controller.frame;
      final source = analyzerLoopbackSource(deviceController);
      final tap = source == null
          ? 0
          : decodeLoopback(
              deviceController!.value(source.address, OutIdx.loopback)!,
              hasInput: deviceController!.variant!.hasInput,
            ).tap;
      final sourceText = source != null
          ? '${deviceController?.variant?.isDac == true ? tr('Gilt für alle Ausgänge') : source.name} · ${tr('Loopback')} · ${tr(['Aus', 'pre FX', 'post FX', 'post −6 dB'][tap])}'
          : deviceController?.variant?.isDac == true
          ? tr('Loopback aus')
          : tr('Analogeingang');
      final hasData =
          f != null &&
          (controller.status == AnalyzerStatus.running ||
              controller.status == AnalyzerStatus.silent);
      return Padding(
        padding: EdgeInsets.all(
          spectrumOnly
              ? 0
              : compact
              ? 8
              : 16,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => _AnalyzerInfoOverlay(
            enabled: compact,
            maxHeight: math.max(24, constraints.maxHeight - 28),
            info: [
              if (hasData && !spectrumOnly)
                [
                  '${tr('USB 1/2')} · $sourceText · ${f.sampleRate / 1000} kHz',
                  if (controller.calibrationOffset != 0)
                    trf('kalibriert {offset} dB', {
                      'offset': analyzerCalibrationDb(
                        controller.calibrationOffset,
                      ),
                    }),
                  if (controller.status == AnalyzerStatus.silent)
                    source == null
                        ? tr('Kein Signal. Loopback aktivieren.')
                        : tr('Kein Signal.'),
                ].join(' · '),
              if (analyzerDeveloperMode.value &&
                  controller.diagnosticText.isNotEmpty)
                controller.diagnosticText,
            ].join('\n'),
            child: Column(
              children: [
                if (!compact && !spectrumOnly) ...[
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final controls = _FullscreenControls(
                        controller: controller,
                        deviceController: deviceController,
                        routing: routing,
                      );
                      final levels = hasData
                          ? _HorizontalLevels(
                              frame: f,
                              color: analyzerColor(deviceController),
                            )
                          : null;
                      if (constraints.maxWidth < 600) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            controls,
                            if (levels != null) ...[
                              const SizedBox(height: 8),
                              levels,
                            ],
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: controls),
                          if (levels != null) ...[
                            const SizedBox(width: 16),
                            Expanded(child: levels),
                          ],
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                ],
                Expanded(
                  child: hasData
                      ? Row(
                          children: [
                            Expanded(
                              child: RepaintBoundary(
                                child: CustomPaint(
                                  key: const ValueKey('analyzer-spectrum'),
                                  size: Size.infinite,
                                  painter: _SpectrumPainter(
                                    controller,
                                    compact: compact,
                                    color: analyzerColor(deviceController),
                                  ),
                                ),
                              ),
                            ),
                            if (compact)
                              SizedBox(
                                width: 116,
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 30),
                                  child: _Levels(
                                    frame: f,
                                    compact: true,
                                    color: analyzerColor(deviceController),
                                  ),
                                ),
                              ),
                          ],
                        )
                      : Center(
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  controller.phoneMicrophone &&
                                          controller.inputRejected
                                      ? tr(
                                          'Quelle: Handy-Mikrofon – ADI-2-Aufnahme nicht verfügbar',
                                        )
                                      : controller.inputErrorCode ==
                                                'routeMismatch' &&
                                            controller
                                                    .diagnostics['routedDevice']
                                                is Map
                                      ? trf(
                                          'Aufnahme läuft über {device} statt über den ADI-2',
                                          {
                                            'device':
                                                (controller
                                                        .diagnostics['routedDevice']
                                                    as Map)['name'],
                                          },
                                        )
                                      : statusText(controller.status),
                                  textAlign: TextAlign.center,
                                  style: ts(
                                    compact ? 12 : 16,
                                    color: Palette.muted,
                                  ),
                                ),
                                if (controller.status ==
                                    AnalyzerStatus.permissionRequired)
                                  TextButton(
                                    onPressed: () => _permission(context),
                                    child: Text(tr('Berechtigung erteilen')),
                                  )
                                else if (controller.status ==
                                        AnalyzerStatus.usbUnavailable ||
                                    controller.status ==
                                        AnalyzerStatus.captureFailed)
                                  TextButton(
                                    onPressed: controller.retry,
                                    child: Text(tr('Erneut versuchen')),
                                  ),
                              ],
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// The expanded information overlays only this display, keeping its plot stable.
class _AnalyzerInfoOverlay extends StatefulWidget {
  const _AnalyzerInfoOverlay({
    required this.enabled,
    required this.maxHeight,
    required this.info,
    required this.child,
  });
  final bool enabled;
  final double maxHeight;
  final String info;
  final Widget child;

  @override
  State<_AnalyzerInfoOverlay> createState() => _AnalyzerInfoOverlayState();
}

class _AnalyzerInfoOverlayState extends State<_AnalyzerInfoOverlay> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.info.isEmpty) return widget.child;
    if (!widget.enabled) {
      return Column(
        children: [
          Expanded(child: widget.child),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 40),
            child: SingleChildScrollView(
              child: Text(
                widget.info,
                key: const ValueKey('analyzer-diagnostics'),
                textAlign: TextAlign.center,
                style: ts(12, color: Palette.muted),
              ),
            ),
          ),
        ],
      );
    }
    return Stack(
      children: [
        Column(
          children: [
            Expanded(child: widget.child),
            Semantics(
              expanded: _expanded,
              child: InkWell(
                key: const ValueKey('analyzer-info-toggle'),
                onTap: () => setState(() => _expanded = !_expanded),
                child: SizedBox(
                  height: 24,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.info.replaceAll('\n', ' · '),
                          key: const ValueKey('analyzer-info-summary'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts(10, color: Palette.muted),
                        ),
                      ),
                      Tooltip(
                        message: _expanded
                            ? tr('Informationen zuklappen')
                            : tr('Informationen aufklappen'),
                        child: Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_expanded)
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Material(
              elevation: 4,
              color: Palette.surf2,
              borderRadius: BorderRadius.circular(6),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _expanded = false),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: widget.maxHeight),
                  child: Scrollbar(
                    child: SingleChildScrollView(
                      key: const ValueKey('analyzer-info-expanded'),
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        widget.info,
                        key: const ValueKey('analyzer-diagnostics'),
                        style: ts(11, color: Palette.text),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Levels extends StatelessWidget {
  const _Levels({
    required this.frame,
    required this.compact,
    required this.color,
  });
  final Color color;
  final AnalyzerFrame frame;
  final bool compact;
  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    child: SizedBox(
      width: compact ? 116 : 168,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              tr('Peak / RMS · dBFS'),
              style: ts(compact ? 7 : 12, color: Palette.muted, height: 1),
            ),
          ),
          for (var ch = 0; ch < 2; ch++) ...[
            SizedBox(height: compact ? 1 : 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '${ch == 0 ? 'L' : 'R'}  ${frame.displayPeak[ch].toStringAsFixed(1)} / ${frame.displayRms[ch].toStringAsFixed(1)}',
                style: ts(
                  compact ? 9 : 15,
                  height: 1,
                  color: frame.clipped[ch] ? Palette.red : Palette.text,
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: AnalyzerLevelBar(
                    peak: frame.displayPeak[ch],
                    rms: frame.displayRms[ch],
                    clipped: frame.clipped[ch],
                    color: color,
                    height: compact ? 7 : 12,
                  ),
                ),
                const SizedBox(width: 3),
                Semantics(
                  label: tr('Übersteuerung'),
                  value: frame.clipped[ch] ? tr('Ja') : tr('Nein'),
                  child: Container(
                    width: 5,
                    height: compact ? 5 : 9,
                    color: frame.clipped[ch] ? Palette.red : Palette.line,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}

/// Wrapping controls use the available column width in either presentation.
class _FullscreenControls extends StatelessWidget {
  const _FullscreenControls({
    required this.controller,
    this.deviceController,
    this.routing,
  });
  final AnalyzerController controller;
  final Adi2Controller? deviceController;
  final AnalyzerRouting? routing;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        key: const ValueKey('analyzer-view-controls'),
        spacing: 4,
        runSpacing: 4,
        children: [
          ChoiceChip(
            label: Text(tr('Linien')),
            selected: !controller.bars,
            showCheckmark: false,
            labelStyle: ts(12),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onSelected: (_) => controller.setBars(false),
          ),
          ChoiceChip(
            label: Text(tr('Balken')),
            selected: controller.bars,
            showCheckmark: false,
            labelStyle: ts(12),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onSelected: (_) => controller.setBars(true),
          ),
          if (controller.view.hasPeakHold)
            AnalyzerPeakHoldChip(controller: controller),
        ],
      ),
    ],
  );
}

/// Fullscreen levels occupy the header; the plot keeps all available width.
class _HorizontalLevels extends StatelessWidget {
  const _HorizontalLevels({required this.frame, required this.color});
  final Color color;
  final AnalyzerFrame frame;

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('analyzer-fullscreen-levels'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Text(tr('Peak / RMS · dBFS'), style: ts(12, color: Palette.muted)),
      for (var ch = 0; ch < 2; ch++)
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Row(
            children: [
              SizedBox(
                key: ValueKey('analyzer-channel-$ch'),
                width: 18,
                child: Text(tr(ch == 0 ? 'L' : 'R'), style: ts(18)),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: AnalyzerLevelBar(
                  key: ValueKey('analyzer-track-$ch'),
                  peak: frame.displayPeak[ch],
                  rms: frame.displayRms[ch],
                  clipped: frame.clipped[ch],
                  color: color,
                  height: 18,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                key: ValueKey('analyzer-values-$ch'),
                width: 112,
                child: Row(
                  children: [
                    for (var metric = 0; metric < 2; metric++) ...[
                      if (metric == 1) Text(' / ', style: ts(18)),
                      Expanded(
                        child: FittedBox(
                          key: ValueKey('analyzer-number-$ch-$metric'),
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Text(
                            (metric == 0
                                    ? frame.displayPeak[ch]
                                    : frame.displayRms[ch])
                                .toStringAsFixed(1),
                            style: ts(
                              18,
                              color: frame.clipped[ch]
                                  ? Palette.red
                                  : Palette.text,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

/// Label geometry is shared by line and bar plots and adapts to local bounds.
class AnalyzerSpectrumScale {
  AnalyzerSpectrumScale({
    required Size size,
    required bool compact,
    required int range,
    required bool bars,
    required AnalyzerBandResolution resolution,
  }) {
    textStyle = ts(compact ? 8 : 10, color: Palette.muted);
    Size measure(String value) {
      final painter = TextPainter(
        text: TextSpan(text: value, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final result = painter.size;
      painter.dispose();
      return result;
    }

    final labelSize = measure('−100');
    area = Rect.fromLTRB(
      labelSize.width + 6,
      labelSize.height + 4,
      size.width - 8,
      size.height - labelSize.height - 4,
    );
    unitLabel = Offset.zero & measure(tr('dB'));
    final low = resolution.centre(0) / resolution.edgeRatio;
    final high = resolution.centre(resolution.count - 1) * resolution.edgeRatio;
    frequencyX = (hz) =>
        area.left +
        (bars ? math.log(hz / low) / math.log(high / low) : logFrequency(hz))
                .clamp(0.0, 1.0) *
            area.width;
    if (area.width <= 0 || area.height <= 0) return;
    final step = area.height / (range / 10) >= labelSize.height + 2 ? 10 : 20;
    for (var db = 0; db >= -range; db -= step) {
      final y = area.bottom - (db + range) / range * area.height;
      final valueSize = measure(db == 0 ? '0' : '−${db.abs()}');
      levelLabels[db] = Rect.fromLTWH(
        area.left - valueSize.width - 5,
        y - valueSize.height / 2,
        valueSize.width,
        valueSize.height,
      );
    }
    const frequencies = [
      20.0,
      50.0,
      100.0,
      200.0,
      500.0,
      1000.0,
      2000.0,
      5000.0,
      10000.0,
      20000.0,
    ];
    Rect bounds(double hz) {
      final label = measure(frequencyText(hz));
      return Rect.fromLTWH(
        (frequencyX(hz) - label.width / 2).clamp(
          area.left,
          size.width - label.width,
        ),
        area.bottom + 3,
        label.width,
        label.height,
      );
    }

    final last = bounds(frequencies.last);
    var right = double.negativeInfinity;
    for (final hz in frequencies) {
      final rect = bounds(hz);
      if (rect.left < right + 4 ||
          (hz != frequencies.last && rect.right + 4 > last.left)) {
        continue;
      }
      frequencyLabels[hz] = rect;
      right = rect.right;
    }
  }
  late final Rect area, unitLabel;
  late final TextStyle textStyle;
  late final double Function(double) frequencyX;
  final frequencyLabels = <double, Rect>{};
  final levelLabels = <int, Rect>{};
  static String frequencyText(double hz) =>
      hz >= 1000 ? '${(hz / 1000).toInt()}k' : '${hz.toInt()}';
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter(
    this.controller, {
    required this.compact,
    required this.color,
  });
  final Color color;
  final AnalyzerController controller;
  final bool compact;
  @override
  void paint(Canvas canvas, Size size) {
    final scale = AnalyzerSpectrumScale(
      size: size,
      compact: compact,
      range: AppSettings.instance.analyzerRange,
      bars: controller.bars,
      resolution: controller.bandResolution,
    );
    final area = scale.area;
    if (area.width <= 0 || area.height <= 0) return;
    final grid = Paint()
      ..color = Palette.line
      ..strokeWidth = 0.6;
    final text = TextPainter(textDirection: TextDirection.ltr);
    void label(String value, Rect bounds) {
      text.text = TextSpan(text: value, style: scale.textStyle);
      text.layout();
      text.paint(canvas, bounds.topLeft);
    }

    final resolution = controller.bandResolution;
    final range = AppSettings.instance.analyzerRange;
    double y(double db) =>
        area.bottom - ((db + range) / range).clamp(0, 1) * area.height;
    for (var db = 0; db >= -range; db -= 10) {
      canvas.drawLine(
        Offset(area.left, y(db.toDouble())),
        Offset(area.right, y(db.toDouble())),
        grid,
      );
    }
    label(tr('dB'), scale.unitLabel);
    for (final entry in scale.levelLabels.entries) {
      label(entry.key == 0 ? '0' : '−${entry.key.abs()}', entry.value);
    }
    for (final entry in scale.frequencyLabels.entries) {
      final hz = entry.key;
      canvas.drawLine(
        Offset(scale.frequencyX(hz), area.top),
        Offset(scale.frequencyX(hz), area.bottom),
        grid,
      );
      label(AnalyzerSpectrumScale.frequencyText(hz), entry.value);
    }
    text.dispose();
    final frame = controller.frame;
    if (frame == null) return;
    canvas.save();
    canvas.clipRect(area);
    final envelope = controller.bars ? controller.bands : controller.spectrum;
    void draw(List<double> values, bool held) {
      final paint = Paint()
        ..color = held ? Color.lerp(color, Colors.white, 0.55)! : color
        ..strokeWidth = held ? 1 : 1.5
        ..style = PaintingStyle.stroke;
      if (controller.bars) {
        for (var i = 0; i < values.length; i++) {
          final bounds = analyzerBarBounds(area, resolution, i);
          final left = bounds.left, right = bounds.right;

          if (held) {
            canvas.drawLine(
              Offset(left, y(values[i])),
              Offset(right, y(values[i])),
              paint,
            );
          } else {
            canvas.drawRect(
              Rect.fromLTRB(
                left,
                y(values[i]),
                math.max(left, right),
                area.bottom,
              ),
              paint..style = PaintingStyle.fill,
            );
          }
        }
      } else {
        final columns = logSpectrumDb(
          values,
          frame.binHz,
          area.width.ceil() + 1,
        );
        final bassValues = held
            ? controller.bassSpectrum.held
            : controller.bassSpectrum.values;
        if (bassValues.isNotEmpty && frame.bassBinHz > 0) {
          final bass = logSpectrumDb(
            bassValues,
            frame.bassBinHz,
            columns.length,
          );
          for (var i = 0; i < columns.length; i++) {
            final hz = frequencyAt(i / (columns.length - 1));
            final blend = ((hz - 250) / 100).clamp(0.0, 1.0);
            columns[i] = bass[i] * (1 - blend) + columns[i] * blend;
          }
        }
        final path = Path();
        for (var i = 0; i < columns.length; i++) {
          final dx = area.left + area.width * i / (columns.length - 1);
          if (i == 0) {
            path.moveTo(dx, y(columns[i]));
          } else {
            path.lineTo(dx, y(columns[i]));
          }
        }
        canvas.drawPath(path, paint);
      }
    }

    draw(envelope.values, false);
    if (controller.peakHold) draw(envelope.held, true);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SpectrumPainter oldDelegate) => true;
}

/// Small inter-bar gaps with flush outer edges. On subpixel-sized compact
/// plots, cap the gap to retain positive bar widths; normal 1/12 plots get >=1 px.
Rect analyzerBarBounds(
  Rect area,
  AnalyzerBandResolution resolution,
  int index,
) {
  final cell = area.width / resolution.count;
  final gap = math.min(math.max(1.0, cell * 0.17), cell * 0.45);
  return Rect.fromLTRB(
    index == 0 ? area.left : area.left + cell * index + gap / 2,
    area.top,
    index == resolution.count - 1
        ? area.right
        : area.left + cell * (index + 1) - gap / 2,
    area.bottom,
  );
}

/// RMS fills the track; peak is a bright narrow marker, including at 0 dBFS.
class AnalyzerLevelBar extends StatelessWidget {
  const AnalyzerLevelBar({
    super.key,
    required this.peak,
    required this.rms,
    required this.clipped,
    required this.color,
    required this.height,
  });
  final double peak, rms, height;
  final bool clipped;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final range = AppSettings.instance.analyzerRange;
    double fraction(double db) => ((db + range) / range).clamp(0, 1);
    return Semantics(
      label: tr('Peak / RMS · dBFS'),
      value: '$peak / $rms',
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              Positioned.fill(child: ColoredBox(color: Palette.surf2)),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: constraints.maxWidth * fraction(rms),
                child: ColoredBox(
                  key: const ValueKey('analyzer-rms-fill'),
                  color: color,
                ),
              ),
              Positioned(
                left:
                    (constraints.maxWidth - 2).clamp(0, double.infinity) *
                    fraction(peak),
                top: 0,
                bottom: 0,
                width: 2,
                child: ColoredBox(
                  key: const ValueKey('analyzer-peak-marker'),
                  color: clipped
                      ? Palette.red
                      : Color.lerp(color, Colors.white, 0.8)!,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
