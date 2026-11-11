import 'package:flutter/material.dart';

import '../analyzer/header_content.dart';
import '../l10n/l10n.dart';
import 'theme.dart';

class HeaderContentPicker extends StatelessWidget {
  const HeaderContentPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final HeaderContent value;
  final ValueChanged<HeaderContent> onChanged;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('Anzeige unter der Kopfzeile'), style: ts(14, weight: 600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final item in HeaderContent.values)
              ChoiceChip(
                key: ValueKey('header-${item.name}'),
                label: Text(
                  tr(switch (item) {
                    HeaderContent.player => 'Player',
                    HeaderContent.status => 'Status',
                    HeaderContent.analyzer => 'Analyzer',
                    HeaderContent.none => 'nichts',
                  }),
                ),
                selected: item == value,
                onSelected: (_) => onChanged(item),
              ),
          ],
        ),
        if (value == HeaderContent.analyzer) ...[
          const SizedBox(height: 8),
          Text(
            tr('Quelle: Automatisch (Loopback, sonst Eingang)'),
            style: ts(12, color: Palette.muted),
          ),
        ],
      ],
    ),
  );
}
