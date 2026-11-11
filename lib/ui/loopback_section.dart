import 'package:flutter/material.dart';

import '../device/adi2_controller.dart';
import '../device/loopback.dart';
import '../device/usb_cc_mode.dart';
import '../l10n/l10n.dart';
import '../protocol/adi2_params.dart';
import 'outputs_page.dart';
import 'param_tile.dart';
import 'theme.dart';

class LoopbackSection extends StatelessWidget {
  const LoopbackSection({super.key, required this.ctrl});

  final Adi2Controller ctrl;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ctrl,
    builder: (context, _) {
      final v = ctrl.variant!;
      final outputs = outputsFor(v)
          .where((o) => ctrl.value(o.address, OutIdx.loopback) != null)
          .toList();
      if (outputs.isEmpty) return const SizedBox.shrink();
      return Panel(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('Loopback zu USB'),
                    style: ts(16, weight: 600),
                  ),
                ),
                IconButton(
                  tooltip: tr('Info'),
                  icon: const Icon(Icons.info_outline),
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (context) => SafeArea(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tr('Loopback zu USB'),
                              style: ts(20, weight: 600),
                            ),
                            const SizedBox(height: 12),
                            for (final text in [
                              tr(
                                'Ausgangssignal per USB am Computer aufnehmen.',
                              ),
                              tr('pre FX = vor EQ/Effekten'),
                              tr('post FX = nach EQ/Effekten'),
                              tr(
                                'post −6 dB = nach EQ/Effekten mit 6 dB Reserve',
                              ),
                              tr('USB-Ziel = Aufnahmekanäle am Computer'),
                              if (v.hasInput)
                                tr(
                                  '5/6 nur mit CC-Modus Multi-channel. Am Gerät unter SETUP → Options → Device Mode / DSD → CC-Mode umstellen; dafür darf keine USB-Verbindung bestehen.',
                                ),
                            ])
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('•  ', style: ts(14)),
                                    Expanded(child: Text(text, style: ts(14))),
                                  ],
                                ),
                              ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: Text(tr('Schließen')),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Text(
              tr('Abgriff für die USB-Aufnahme wählen.'),
              style: ts(13, color: Palette.muted),
            ),
            const SizedBox(height: 12),
            for (final o in outputs) ...[
              if (o != outputs.first) const Divider(height: 24),
              _LoopbackOutput(
                key: ValueKey('loopback-${o.address}'),
                ctrl: ctrl,
                output: o,
                hasInput: v.hasInput,
              ),
            ],
          ],
        ),
      );
    },
  );
}

class _LoopbackOutput extends StatelessWidget {
  const _LoopbackOutput({
    super.key,
    required this.ctrl,
    required this.output,
    required this.hasInput,
  });

  final Adi2Controller ctrl;
  final OutputInfo output;
  final bool hasInput;

  @override
  Widget build(BuildContext context) {
    final stereo = ctrl.ccMode == UsbCcMode.stereo;
    final selection = decodeLoopback(
      ctrl.value(output.address, OutIdx.loopback)!,
      hasInput: hasInput,
    );
    void set(int tap, int pair) => ctrl.set(
      output.address,
      OutIdx.loopback,
      encodeLoopback(tap: tap, pair: pair, hasInput: hasInput),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(output.name, style: ts(15, weight: 600)),
        const SizedBox(height: 8),
        ParamChoices(
          labels: [tr('Aus'), tr('pre FX'), tr('post FX'), tr('post −6 dB')],
          selected: selection.tap,
          onSelected: (tap) => set(tap, selection.pair),
        ),
        if (selection.tap != 0) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Text(tr('USB-Ziel'), style: ts(13, color: Palette.muted)),
              const SizedBox(width: 10),
              if (hasInput)
                Expanded(
                  child: ParamChoices(
                    labels: [tr('1/2'), tr('3/4'), tr('5/6')],
                    selected: selection.pair,
                    markedIndices: const {2},
                    disabledIndices: stereo ? const {2} : const {},
                    onSelected: (pair) => set(selection.tap, pair),
                  ),
                )
              else
                Text(tr('1/2'), style: ts(13)),
            ],
          ),
          if (hasInput) ...[
            const SizedBox(height: 6),
            Text(
              tr(
                '5/6 nur mit CC-Modus Multi-channel (am Gerät ohne USB-Verbindung umstellen).',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ts(12, color: Palette.muted),
            ),
            if (stereo && selection.pair == 2)
              Text(
                tr('5/6 (im Stereo-Modus nicht verfügbar)'),
                style: ts(12, color: Palette.muted),
              ),
          ],
        ],
      ],
    );
  }
}
