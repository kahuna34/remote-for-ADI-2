import 'package:flutter/material.dart';

import '../device/adi2_controller.dart';
import '../l10n/l10n.dart';
import 'outputs_page.dart';

void showLoopbackDisplaced(
  BuildContext context,
  Adi2Controller ctrl,
  int address,
  int pair,
) {
  final name = outputsFor(ctrl.variant!)
      .firstWhere((o) => o.address == address)
      .name;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text(
        trf(
          'Loopback von {Ausgang} ausgeschaltet, weil {Paar} jetzt belegt ist',
          {
            'Ausgang': name,
            'Paar': ['1/2', '3/4', '5/6'][pair],
          },
        ),
      ),
    ),
  );
}

/// Rückfrage, bevor ein bereits belegtes USB-Paar übernommen wird. Der andere
/// Ausgang verliert dabei seinen Loopback. true = übernehmen.
Future<bool> confirmLoopbackTakeover(
  BuildContext context,
  Adi2Controller ctrl,
  List<int> occupants,
  int pair,
) async {
  final names = outputsFor(ctrl.variant!)
      .where((o) => occupants.contains(o.address))
      .map((o) => o.name)
      .join(', ');
  final answer = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('loopback-takeover-dialog'),
      title: Text(
        trf('USB {Paar} ist belegt', {
          'Paar': ['1/2', '3/4', '5/6'][pair],
        }),
      ),
      content: Text(
        trf(
          '{Ausgang} nutzt dieses Paar. Übernehmen schaltet dort den Loopback aus.',
          {'Ausgang': names},
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(tr('Abbrechen')),
        ),
        TextButton(
          key: const ValueKey('loopback-takeover-confirm'),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr('Übernehmen')),
        ),
      ],
    ),
  );
  return answer == true;
}
