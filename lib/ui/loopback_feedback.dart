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
