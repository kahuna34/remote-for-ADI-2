import 'dart:async';

import 'package:flutter/material.dart';

import '../analyzer/analyzer_routing.dart';
import '../app_settings.dart';
import '../device/adi2_controller.dart';
import '../host/host_client.dart';
import '../l10n/l10n.dart';
import '../media/now_playing.dart';
import '../media/player_source.dart';
import '../protocol/adi2_params.dart';
import 'theme.dart';

/// The gesture surface is confined to the graph. Buttons consume their own tap.
class AnalyzerPlayerOverlay extends StatefulWidget {
  const AnalyzerPlayerOverlay({
    super.key,
    required this.child,
    this.np,
    this.deviceController,
  });
  final Widget child;
  final NowPlaying? np;
  final Adi2Controller? deviceController;
  @override
  State<AnalyzerPlayerOverlay> createState() => _AnalyzerPlayerOverlayState();
}

class _AnalyzerPlayerOverlayState extends State<AnalyzerPlayerOverlay>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _open = false;
  PlayerSource? _source;
  bool _wasReconnecting = false;
  bool get _reconnecting =>
      widget.deviceController?.viaHost == true &&
      widget.deviceController!.host.reconnecting;

  void _connectionChanged() {
    final reconnecting = _reconnecting;
    if (_open && reconnecting != _wasReconnecting) {
      if (reconnecting) {
        _timer?.cancel();
      } else {
        _resetTimer();
      }
    }
    _wasReconnecting = reconnecting;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppSettings.instance.addListener(_settingsChanged);
    _wasReconnecting = _reconnecting;
    widget.deviceController?.addListener(_connectionChanged);
    widget.deviceController?.host.addListener(_connectionChanged);
  }

  void _settingsChanged() {
    if (!AppSettings.instance.analyzerPlayerOnTap && _open) _close();
  }

  void _close() {
    _timer?.cancel();
    if (mounted) setState(() => _open = false);
  }

  void _resetTimer() {
    _timer?.cancel();
    if (!_reconnecting) _timer = Timer(const Duration(seconds: 5), _close);
  }

  void _tap() {
    if (_open) {
      _close();
      return;
    }

    setState(() => _open = true);
    _resetTimer();
  }

  void _command(String command) {
    _resetTimer();
    unawaited(_source?.command(command));
  }

  @override
  void didUpdateWidget(AnalyzerPlayerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceController != widget.deviceController) {
      oldWidget.deviceController?.removeListener(_connectionChanged);
      oldWidget.deviceController?.host.removeListener(_connectionChanged);
      widget.deviceController?.addListener(_connectionChanged);
      widget.deviceController?.host.addListener(_connectionChanged);
      _wasReconnecting = _reconnecting;
    }
    if (oldWidget.deviceController != widget.deviceController ||
        oldWidget.np != widget.np) {
      _close();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context);
    if (_open && current == false) _close();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _close();
  }

  @override
  void dispose() {
    _timer?.cancel();
    AppSettings.instance.removeListener(_settingsChanged);
    widget.deviceController?.removeListener(_connectionChanged);
    widget.deviceController?.host.removeListener(_connectionChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String? _sourceHint() {
    final ctrl = widget.deviceController;
    if (ctrl == null || ctrl.variant == null) return null;
    final address = activeAnalyzerOutput(ctrl);
    final source = address == null ? null : ctrl.value(address, OutIdx.source);
    if (source == null || source == 0) return tr('USB-Quelle nicht bestätigt');
    final usb = ctrl.variant!.isDac
        ? source >= 3 && source <= 5
        : source == 4 || source == 5;
    return usb ? null : tr('Quelle ist nicht USB');
  }

  @override
  Widget build(BuildContext context) => PlayerSourceView(
    np: widget.np,
    deviceController: widget.deviceController,
    active: _open,
    builder: (context, source) {
      _source = source;
      return ListenableBuilder(
        listenable: Listenable.merge([
          AppSettings.instance,
          ?widget.np,
          ?widget.deviceController,
          ?widget.deviceController?.selectedOutputChanges,
          source,
        ]),
        builder: (context, _) {
          if (!AppSettings.instance.analyzerPlayerOnTap) return widget.child;
          final host = source.usesHost ? source.host : null;
          final info = source.info;
          final available = source.available;
          return GestureDetector(
            key: const ValueKey('analyzer-player-graph'),
            behavior: HitTestBehavior.opaque,
            onTap: _tap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                widget.child,
                if (_open)
                  Positioned.fill(
                    child: Material(
                      key: const ValueKey('analyzer-player-overlay'),
                      color: Palette.bg.withValues(alpha: .82),
                      clipBehavior: Clip.hardEdge,
                      child: LayoutBuilder(
                        builder: (context, bounds) {
                          final compact = bounds.maxHeight < 176;
                          final lowPlot =
                              bounds.maxHeight < 76 && bounds.maxWidth >= 180;
                          // Sehr niedriger Plot (Smartphone kompakt): Knöpfe neben
                          // dem Titel in bisheriger Größe, sonst größer.
                          final buttonSize = lowPlot
                              ? 36.0
                              : compact
                              ? 44.0
                              : 56.0;
                          // A phone's compact plot can be shorter than two text
                          // lines plus transport buttons. Put metadata beside the
                          // buttons there; larger plots keep the vertical layout.
                          final horizontal = lowPlot;
                          final contentWidth = bounds.maxWidth.clamp(
                            0.0,
                            520.0,
                          );
                          final metadata = FittedBox(
                            fit: BoxFit.scaleDown,
                            child: SizedBox(
                              width:
                                  (contentWidth -
                                          8 -
                                          (horizontal ? buttonSize * 3 + 4 : 0))
                                      .clamp(0.0, 512.0),
                              child: _metadata(
                                info,
                                host,
                                available,
                                showCover: !compact,
                                compact: compact,
                              ),
                            ),
                          );
                          final transport = _transport(
                            info,
                            available,
                            buttonSize,
                            gap: lowPlot
                                ? 4
                                : compact
                                ? 12
                                : 24,
                          );
                          return Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 520),
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical:
                                      ((bounds.maxHeight - buttonSize) / 2)
                                          .clamp(0.0, 4.0),
                                ),
                                child: horizontal
                                    ? Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Expanded(child: metadata),
                                          const SizedBox(width: 4),
                                          transport,
                                        ],
                                      )
                                    : Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Flexible(child: metadata),
                                          // Bei wenig Höhe verkleinern statt
                                          // über den Plot hinauszuragen.
                                          Flexible(child: transport),
                                        ],
                                      ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      );
    },
  );

  Widget _transport(
    NowPlayingInfo? info,
    bool available,
    double size, {
    double gap = 24,
  }) => FittedBox(
    fit: BoxFit.scaleDown,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: gap,
      children: [
        _button('previous', Icons.skip_previous, tr('Zurück'), available, size),
        _button(
          info?.playing == true ? 'pause' : 'play',
          info?.playing == true ? Icons.pause : Icons.play_arrow,
          tr(info?.playing == true ? 'Pause' : 'Wiedergabe'),
          available,
          size,
        ),
        _button('next', Icons.skip_next, tr('Weiter'), available, size),
      ],
    ),
  );

  Widget _metadata(
    NowPlayingInfo? info,
    HostClient? host,
    bool available, {
    required bool showCover,
    bool compact = false,
  }) {
    final hint = _sourceHint();
    final app = (info?.app ?? '').isNotEmpty
        ? info!.app!
        : (host != null ? tr('Computer') : tr('Smartphone'));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showCover && info?.art != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.memory(
                info!.art!,
                key: const ValueKey('analyzer-player-cover'),
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const Icon(Icons.music_note),
              ),
            ),
          ),
        Text(
          info?.hasContent == true ? info!.title! : tr('Kein Player aktiv'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: ts(compact ? 15 : 18, weight: 600),
        ),
        Text(
          [(info?.artist ?? ''), app].where((s) => s.isNotEmpty).join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: ts(compact ? 13 : 15, weight: 500, color: Palette.text),
        ),
        if (hint != null)
          Text(
            hint,
            style: ts(10, color: Palette.amber),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        if (_source?.needsHostUpdate == true || !available)
          Text(
            _source?.needsHostUpdate == true
                ? tr(
                    'Dieser Host unterstützt den Player noch nicht. Host aktualisieren.',
                  )
                : tr('Player-Zugriff nicht verfügbar'),
            style: ts(10),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
      ],
    );
  }

  Widget _button(
    String command,
    IconData icon,
    String tooltip,
    bool enabled,
    double size,
  ) => IconButton(
    key: ValueKey('analyzer-player-$command'),
    tooltip: tooltip,
    constraints: BoxConstraints.tightFor(width: size, height: size),
    style: IconButton.styleFrom(
      fixedSize: Size.square(size),
      minimumSize: Size.square(size),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    padding: EdgeInsets.zero,
    icon: Icon(icon, size: size * 0.62),
    onPressed: enabled ? () => _command(command) : null,
  );
}
