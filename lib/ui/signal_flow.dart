import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../l10n/l10n.dart';
import 'eq_display_mode.dart';
import 'signal_flow_data.dart';
import 'theme.dart';

Future<void> showSignalFlow(BuildContext context, SignalFlowMode mode) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.94,
        child: SignalFlowSheet(initialMode: mode),
      ),
    );

class _Selection {
  const _Selection(this.mode, {this.usbMulti = false});
  final SignalFlowMode mode;
  final bool usbMulti;
}

class SignalFlowSheet extends StatefulWidget {
  const SignalFlowSheet({super.key, required this.initialMode});
  final SignalFlowMode initialMode;

  @override
  State<SignalFlowSheet> createState() => _SignalFlowSheetState();
}

class _SignalFlowSheetState extends State<SignalFlowSheet>
    with WidgetsBindingObserver {
  late final ValueNotifier<_Selection> _selection;
  Route<void>? _fullscreenRoute;
  bool _current = false;
  bool _waitForPortrait = false;
  bool _checkScheduled = false;

  @override
  void initState() {
    super.initState();
    _selection = ValueNotifier(_Selection(widget.initialMode));
    WidgetsBinding.instance.addObserver(this);
    AppSettings.instance.addListener(_scheduleOrientationCheck);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _current = ModalRoute.isCurrentOf(context) ?? true;
    MediaQuery.orientationOf(context);
    _scheduleOrientationCheck();
  }

  @override
  void didChangeMetrics() => _scheduleOrientationCheck();

  void _scheduleOrientationCheck() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted) return;
      final size = MediaQuery.sizeOf(context);
      final landscape = size.width > size.height;
      if (!landscape) _waitForPortrait = false;
      final auto = AppSettings.instance.autoFullscreenEq;
      EqDisplayMode.allowRotation(this, _current && auto && !_waitForPortrait);
      if (_current &&
          auto &&
          landscape &&
          !_waitForPortrait &&
          _fullscreenRoute == null) {
        _openFullscreen(automatic: true);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _openFullscreen({bool automatic = false}) async {
    if (_fullscreenRoute != null) return;
    final route = PageRouteBuilder<void>(
      settings: const RouteSettings(name: 'signal-flow-fullscreen'),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => _SignalFlowFullscreen(
        selection: _selection,
        automatic: automatic,
        onClosing: () {
          _waitForPortrait = true;
          EqDisplayMode.allowRotation(this, false);
        },
      ),
    );
    _fullscreenRoute = route;
    await Navigator.of(context).push(route);
    _fullscreenRoute = null;
    if (mounted) _scheduleOrientationCheck();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppSettings.instance.removeListener(_scheduleOrientationCheck);
    EqDisplayMode.allowRotation(this, false);
    final route = _fullscreenRoute;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
        _selection.dispose();
      });
    } else {
      _selection.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _SignalFlowContent(selection: _selection, onFullscreen: _openFullscreen);
}

class _SignalFlowFullscreen extends StatefulWidget {
  const _SignalFlowFullscreen({
    required this.selection,
    required this.automatic,
    required this.onClosing,
  });
  final ValueNotifier<_Selection> selection;
  final bool automatic;
  final VoidCallback onClosing;

  @override
  State<_SignalFlowFullscreen> createState() => _SignalFlowFullscreenState();
}

class _SignalFlowFullscreenState extends State<_SignalFlowFullscreen>
    with WidgetsBindingObserver {
  bool _closing = false;

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
      if (!mounted || _closing) return;
      final size = MediaQuery.sizeOf(context);
      if (size.height > size.width &&
          ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    EqDisplayMode.leaveFullscreen(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop || _closing) return;
      _closing = true;
      widget.onClosing();
    },
    child: Scaffold(
      body: SafeArea(
        child: _SignalFlowContent(
          selection: widget.selection,
          fullscreen: true,
        ),
      ),
    ),
  );
}

class _SignalFlowContent extends StatelessWidget {
  const _SignalFlowContent({
    required this.selection,
    this.fullscreen = false,
    this.onFullscreen,
  });
  final ValueNotifier<_Selection> selection;
  final bool fullscreen;
  final VoidCallback? onFullscreen;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppLang.instance,
    builder: (context, _) => ValueListenableBuilder<_Selection>(
      valueListenable: selection,
      builder: (context, selected, _) {
        final diagram = signalFlowDiagram(
          selected.mode,
          usbMulti: selected.usbMulti,
        );
        final title = trf('Signalplan · {mode}', {
          'mode': tr(selected.mode.label),
        });
        final modes = [
          for (final mode in SignalFlowMode.values)
            _ModeTile(
              label: tr(mode.label),
              selected: selected.mode == mode,
              onTap: () => selection.value = _Selection(
                mode,
                usbMulti: selected.usbMulti,
              ),
            ),
        ];
        final usbModes = [
          for (final multi in [false, true])
            _ModeTile(
              label: multi ? tr('Mehrkanal · 6/8') : tr('Stereo · 2/2'),
              selected: selected.usbMulti == multi,
              onTap: () =>
                  selection.value = _Selection(selected.mode, usbMulti: multi),
            ),
        ];
        final details = [
          const SizedBox(height: 12),
          Text(diagram.explanation, style: ts(14, height: 1.4)),
          for (final note in diagram.notes)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                note,
                style: ts(12, color: Palette.muted, height: 1.4),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            tr('Schema ADI-2 Pro · Handbuch Kapitel 17, Seiten 36–42.'),
            style: ts(11, color: Palette.muted),
          ),
        ];
        if (fullscreen) {
          return Column(
            children: [
              Tooltip(
                message: title,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final tile in modes)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: tile,
                                ),
                              if (selected.mode == SignalFlowMode.usb)
                                for (final tile in usbModes)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 6),
                                    child: tile,
                                  ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: tr('Vollbild schließen'),
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.fullscreen_exit),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) => SingleChildScrollView(
                    key: ValueKey((selected.mode, selected.usbMulti)),
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (selected.mode == SignalFlowMode.auto)
                          const _AutoDecision()
                        else
                          // Im Vollbild ist der gesamte Plan auf einmal sichtbar.
                          // Die Erklärungen folgen darunter im selben Scrollbereich.
                          SizedBox(
                            height: math.max(1, box.maxHeight - 24),
                            child: FittedBox(
                              child: SizedBox(
                                width: SignalFlowDiagram.width,
                                height: diagram.height,
                                child: SignalFlow(diagram: diagram),
                              ),
                            ),
                          ),
                        ...details,
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        return SingleChildScrollView(
          key: ValueKey((selected.mode, selected.usbMulti)),
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(title, style: ts(18, weight: 600))),
                  IconButton(
                    tooltip: tr('Vollbild'),
                    onPressed: onFullscreen,
                    icon: const Icon(Icons.fullscreen),
                  ),
                  IconButton(
                    tooltip: tr('Schließen'),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Wrap(spacing: 6, runSpacing: 6, children: modes),
              if (selected.mode == SignalFlowMode.usb)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Wrap(spacing: 6, runSpacing: 6, children: usbModes),
                ),
              const SizedBox(height: 12),
              if (selected.mode == SignalFlowMode.auto)
                const _AutoDecision()
              else
                SignalFlow(diagram: diagram),
              ...details,
            ],
          ),
        );
      },
    ),
  );
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? Palette.surf2 : Palette.bg,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide(color: selected ? Palette.amber : Palette.line),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Text(
          label,
          style: ts(
            14,
            weight: selected ? 600 : 500,
            color: selected ? Palette.text : Palette.muted,
          ),
        ),
      ),
    ),
  );
}

class _AutoDecision extends StatelessWidget {
  const _AutoDecision();

  @override
  Widget build(BuildContext context) => Panel(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('USB erkannt → USB'),
          style: ts(15, color: SignalFlowColors.usb),
        ),
        const SizedBox(height: 12),
        Text(
          tr('Sonst Digitalsignal erkannt → AD/DA'),
          style: ts(15, color: SignalFlowColors.spdif),
        ),
        const SizedBox(height: 12),
        Text(
          tr('Sonst → Preamp'),
          style: ts(15, color: SignalFlowColors.analog),
        ),
        const SizedBox(height: 16),
        Text(
          tr('Dig Thru und DAC nur manuell'),
          style: ts(12, color: Palette.muted),
        ),
      ],
    ),
  );
}

/// Ein festes Koordinatensystem, proportional auf die verfügbare Breite skaliert.
class SignalFlow extends StatelessWidget {
  const SignalFlow({super.key, required this.diagram});
  final SignalFlowDiagram diagram;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: '${tr('Signalplan')}. ${diagram.explanation}',
    child: AspectRatio(
      aspectRatio: SignalFlowDiagram.width / diagram.height,
      child: CustomPaint(painter: _SignalFlowPainter(diagram)),
    ),
  );
}

class _SignalFlowPainter extends CustomPainter {
  const _SignalFlowPainter(this.diagram);
  final SignalFlowDiagram diagram;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / SignalFlowDiagram.width);
    for (final wire in diagram.wires) {
      final path = Path()..moveTo(wire.points.first.dx, wire.points.first.dy);
      for (final point in wire.points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      final paint = Paint()
        ..color = wire.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6;
      if (wire.dashed) {
        for (final metric in path.computeMetrics()) {
          for (double distance = 0; distance < metric.length; distance += 7) {
            canvas.drawPath(
              metric.extractPath(
                distance,
                math.min(distance + 4, metric.length),
              ),
              paint,
            );
          }
        }
      } else {
        canvas.drawPath(path, paint);
      }
      final end = wire.points.last;
      final previous = wire.points[wire.points.length - 2];
      final direction = (end - previous) / (end - previous).distance;
      final normal = Offset(-direction.dy, direction.dx);
      final arrow = Path()
        ..moveTo(end.dx, end.dy)
        ..lineTo(
          (end - direction * 6 + normal * 3).dx,
          (end - direction * 6 + normal * 3).dy,
        )
        ..lineTo(
          (end - direction * 6 - normal * 3).dx,
          (end - direction * 6 - normal * 3).dy,
        )
        ..close();
      canvas.drawPath(arrow, Paint()..color = wire.color);
    }
    for (final node in diagram.nodes) {
      final processing = node.kind == SignalFlowNodeKind.processing;
      final shape = RRect.fromRectAndRadius(
        node.rect,
        const Radius.circular(4),
      );
      canvas.drawRRect(
        shape,
        Paint()
          ..color = processing
              ? Palette.surf2
              : Color.alphaBlend(
                  node.color.withValues(alpha: 0.16),
                  Palette.bg,
                ),
      );
      canvas.drawRRect(
        shape,
        Paint()
          ..color = node.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      _text(
        canvas,
        node.text,
        node.rect,
        size: 11,
        color: Palette.text,
        weight: 600,
      );
    }
    _text(
      canvas,
      tr('Eingänge'),
      const Rect.fromLTWH(40, 6, 86, 20),
      size: 12,
      color: Palette.muted,
    );
    _text(
      canvas,
      tr('Ausgänge'),
      const Rect.fromLTWH(568, 6, 72, 20),
      size: 12,
      color: Palette.muted,
    );
    canvas.restore();
  }

  void _text(
    Canvas canvas,
    String text,
    Rect rect, {
    required double size,
    required Color color,
    double weight = 500,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: ts(size, color: color, weight: weight, height: 1.1),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: rect.width - 4);
    painter.paint(
      canvas,
      Offset(
        rect.center.dx - painter.width / 2,
        rect.center.dy - painter.height / 2,
      ),
    );
    painter.dispose();
  }

  @override
  bool shouldRepaint(_SignalFlowPainter oldDelegate) =>
      oldDelegate.diagram != diagram;
}
