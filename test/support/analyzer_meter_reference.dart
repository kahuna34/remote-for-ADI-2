// Frozen widget-based meter rendering from before the painter optimization.
// Used only as a visual reference; changes belong in the production painters.
import 'package:flutter/material.dart';
import 'package:adi2_remote/analyzer/analyzer_controller.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/ui/theme.dart';

class ReferenceCompactLevels extends StatelessWidget {
  const ReferenceCompactLevels({
    super.key,
    required this.controller,
    required this.color,
  });
  final AnalyzerController controller;
  final Color color;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final frame = controller.frame!;
        return Column(
          key: const ValueKey('reference-analyzer-compact-levels'),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              tr('Peak / RMS · dBFS'),
              style: ts(10, color: Palette.muted, height: 1),
            ),
            for (var ch = 0; ch < 2; ch++)
              Row(
                children: [
                  // Feste Breite, damit L- und R-Balken bündig beginnen.
                  SizedBox(
                    width: 14,
                    child: Text(
                      ch == 0 ? 'L' : 'R',
                      style: ts(14, height: 1.2),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: ReferenceLevelBar(
                      peak: frame.displayPeak[ch],
                      rms: frame.displayRms[ch],
                      clipped: frame.clipped[ch],
                      color: color,
                      height: 10,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${frame.displayPeak[ch].toStringAsFixed(1)} / ${frame.displayRms[ch].toStringAsFixed(1)}',
                    key: ValueKey('reference-analyzer-compact-values-$ch'),
                    style: ts(
                      14,
                      height: 1.2,
                      color: frame.clipped[ch] ? Palette.red : Palette.text,
                    ),
                  ),
                ],
              ),
          ],
        );
      },
    ),
  );
}

class ReferenceHorizontalLevels extends StatelessWidget {
  const ReferenceHorizontalLevels({
    super.key,
    required this.controller,
    required this.color,
  });
  final Color color;
  final AnalyzerController controller;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final frame = controller.frame!;
        return Column(
          key: const ValueKey('reference-analyzer-fullscreen-levels'),
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
                      key: ValueKey('reference-analyzer-channel-$ch'),
                      width: 18,
                      child: Text(tr(ch == 0 ? 'L' : 'R'), style: ts(18)),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: ReferenceLevelBar(
                        key: ValueKey('reference-analyzer-track-$ch'),
                        peak: frame.displayPeak[ch],
                        rms: frame.displayRms[ch],
                        clipped: frame.clipped[ch],
                        color: color,
                        height: 18,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      key: ValueKey('reference-analyzer-values-$ch'),
                      width: 112,
                      child: Row(
                        children: [
                          for (var metric = 0; metric < 2; metric++) ...[
                            if (metric == 1) Text(' / ', style: ts(18)),
                            Expanded(
                              child: FittedBox(
                                key: ValueKey(
                                  'reference-analyzer-number-$ch-$metric',
                                ),
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
      },
    ),
  );
}

class ReferenceLevelBar extends StatelessWidget {
  const ReferenceLevelBar({
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
                  key: const ValueKey('reference-analyzer-rms-fill'),
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
                  key: const ValueKey('reference-analyzer-peak-marker'),
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
