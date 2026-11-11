import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../device/adi2_controller.dart';
import '../protocol/adi2_codec.dart';
import '../protocol/adi2_params.dart';
import 'theme.dart';
import 'signal_flow.dart';
import 'signal_flow_data.dart';

/// Allgemeine Zeile für einen Parameter: Schalter, Auswahl oder Regler.
class ParamTile extends StatelessWidget {
  const ParamTile({
    super.key,
    required this.ctrl,
    required this.address,
    required this.def,
    this.formatOverride,
  });

  final Adi2Controller ctrl;
  final int address;
  final ParamDef def;
  final String Function(int raw)? formatOverride;

  @override
  Widget build(BuildContext context) {
    // Parameter, die das Gerät nicht meldet (z. B. bei ADI-2 Pro mit Line
    // geteilte Phones-1/2-Einstellungen), werden nicht angezeigt.
    if (ctrl.value(address, def.index) == null) return const SizedBox.shrink();
    final raw = ctrl.valueOr(address, def.index, def.def);
    final fmt = formatOverride ?? def.format;
    if (def.isSwitch) {
      return SwitchListTile(
        title: Text(tr(def.name)),
        value: raw != 0,
        onChanged: (v) => ctrl.set(address, def.index, v ? 1 : 0),
      );
    }
    if (def.isChoice || formatOverride != null && def.max - def.min < 16) {
      final basicMode = address == Adi2Addr.device && def.index == 6;
      // Wie am Gerät: In Preamp (3) und Dig Thru (4) ist die Quelle gesperrt.
      final digitalOutLocked =
          address == Adi2Addr.device &&
          def.index == 7 &&
          const {3, 4}.contains(ctrl.value(Adi2Addr.device, 6));
      // Lange Listen (z. B. Tastenbelegung): Eintrag mit scrollbarer Auswahl.
      if (def.max - def.min + 1 > 12) {
        return ListTile(
          title: Text(tr(def.name)),
          subtitle: Text(fmt(raw), style: ts(14, color: Palette.amber)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final picked = await showModalBottomSheet<int>(
              context: context,
              isScrollControlled: true,
              builder: (c) => DraggableScrollableSheet(
                expand: false,
                initialChildSize: 0.7,
                builder: (c, sc) => ListView(
                  controller: sc,
                  children: [
                    for (var i = def.min; i <= def.max; i++)
                      ListTile(
                        title: Text(fmt(i)),
                        enabled: !ctrl.isParamValueDisabled(
                          address,
                          def.index,
                          i,
                        ),
                        trailing: i == raw
                            ? const Icon(Icons.check, color: Palette.amber)
                            : null,
                        onTap: () => Navigator.pop(c, i),
                      ),
                  ],
                ),
              ),
            );
            if (picked != null) ctrl.set(address, def.index, picked);
          },
        );
      }
      // Auswahl als Kacheln nebeneinander (statt Liste zum Aufklappen).
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(tr(def.name), style: ts(15, weight: 500)),
                if (basicMode)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.info_outline,
                        size: 14,
                        color: Palette.muted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        tr('Gedrückt halten für Info'),
                        style: ts(12, color: Palette.muted),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ParamChoices(
              labels: [for (var i = def.min; i <= def.max; i++) fmt(i)],
              selected: raw - def.min,
              disabledIndices: {
                for (var i = def.min; i <= def.max; i++)
                  if (digitalOutLocked ||
                      ctrl.isParamValueDisabled(address, def.index, i))
                    i - def.min,
              },
              onSelected: (i) => ctrl.set(address, def.index, i + def.min),
              onLongPress: basicMode
                  ? (i) => showSignalFlow(
                      context,
                      SignalFlowMode.values[i + def.min],
                    )
                  : null,
            ),
            if (digitalOutLocked)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  tr('In Preamp und Dig Thru nicht wählbar.'),
                  style: ts(12, color: Palette.muted),
                ),
              ),
          ],
        ),
      );
    }
    return _SliderTile(ctrl: ctrl, address: address, def: def, raw: raw);
  }
}

/// Gemeinsame Auswahlkacheln für Parameter und zusammengesetzte Bedienfelder.
class ParamChoices extends StatelessWidget {
  const ParamChoices({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.onLongPress,
    this.disabledIndices = const {},
    this.markedIndices = const {},
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;
  final ValueChanged<int>? onLongPress;
  final Set<int> disabledIndices;
  final Set<int> markedIndices;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final short = labels.length <= 6 && labels.every((s) => s.length <= 8);
      if (!short) {
        return Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < labels.length; i++)
              _ChoiceTile(
                label: labels[i],
                selected: i == selected,
                enabled: !disabledIndices.contains(i),
                marked: markedIndices.contains(i),
                onTap: () => onSelected(i),
                onLongPress: onLongPress == null ? null : () => onLongPress!(i),
              ),
          ],
        );
      }
      final cellWidth =
          (constraints.maxWidth - 6 * (labels.length - 1)) / labels.length;
      final fits = labels.every((label) {
        final painter = TextPainter(
          text: TextSpan(text: label, style: ts(14, weight: 600)),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final fits =
            painter.width + 4 + (markedIndices.isEmpty ? 0 : 12) <= cellWidth;
        painter.dispose();
        return fits;
      });
      final columns = fits ? labels.length : (labels.length == 6 ? 3 : 2);
      final width = (constraints.maxWidth - 6 * (columns - 1)) / columns;
      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < labels.length; i++)
            SizedBox(
              width: width,
              child: _ChoiceTile(
                label: labels[i],
                selected: i == selected,
                compact: true,
                enabled: !disabledIndices.contains(i),
                marked: markedIndices.contains(i),
                onTap: () => onSelected(i),
                onLongPress: onLongPress == null ? null : () => onLongPress!(i),
              ),
            ),
        ],
      );
    },
  );
}

class _SliderTile extends StatefulWidget {
  const _SliderTile({
    required this.ctrl,
    required this.address,
    required this.def,
    required this.raw,
  });
  final Adi2Controller ctrl;
  final int address;
  final ParamDef def;
  final int raw;

  @override
  State<_SliderTile> createState() => _SliderTileState();
}

class _SliderTileState extends State<_SliderTile> {
  int? _drag;
  Timer? _t;

  void _send(int v) {
    _t?.cancel();
    _t = Timer(
      const Duration(milliseconds: 40),
      () => widget.ctrl.set(widget.address, widget.def.index, v),
    );
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.def;
    final v = (_drag ?? widget.raw).clamp(d.min, d.max);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(tr(d.name))),
              IconButton(
                icon: const Icon(Icons.remove),
                onPressed: v > d.min
                    ? () => widget.ctrl.set(widget.address, d.index, v - 1)
                    : null,
              ),
              SizedBox(
                width: 80,
                child: Text(
                  d.format(v),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: v < d.max
                    ? () => widget.ctrl.set(widget.address, d.index, v + 1)
                    : null,
              ),
            ],
          ),
          Slider(
            min: d.min.toDouble(),
            max: d.max.toDouble(),
            divisions: d.max - d.min,
            value: v.toDouble(),
            onChanged: (x) {
              setState(() => _drag = x.round());
              _send(x.round());
            },
            onChangeEnd: (x) {
              _t?.cancel();
              widget.ctrl.set(widget.address, d.index, x.round());
              setState(() => _drag = null);
            },
          ),
        ],
      ),
    );
  }
}

/// Wählbare Kachel; die gewählte ist bernsteinfarben umrandet.
class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
    this.onLongPress,
    this.enabled = true,
    this.marked = false,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;
  final VoidCallback? onLongPress;
  final bool enabled;
  final bool marked;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      textAlign: TextAlign.center,
      style: ts(
        14,
        weight: selected ? 600 : 500,
        color: selected && enabled ? Palette.text : Palette.muted,
      ),
    );
    return Material(
      color: selected && enabled ? Palette.surf2 : Palette.bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected && enabled ? Palette.amber : Palette.line,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: !enabled || selected ? null : onTap,
        onLongPress: enabled ? onLongPress : null,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 2 : 12,
            vertical: 9,
          ),
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: marked
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(child: text),
                      Text(' *', style: ts(10, color: Palette.muted)),
                    ],
                  )
                : text,
          ),
        ),
      ),
    );
  }
}
