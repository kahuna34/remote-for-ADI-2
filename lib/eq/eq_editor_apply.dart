import '../device/adi2_controller.dart';
import '../protocol/adi2_params.dart';
import 'eq_editor_buffer.dart';

/// Gemeinsamer Ladeweg für den App-Preset-Editor und den Ausgangs-EQ.
void applyEqEditor(
  Adi2Controller controller,
  int target,
  EqEditorBuffer editor, {
  bool enableBassTreble = false,
}) {
  for (final entry in editor.left.entries) {
    controller.setEq(target + 1, entry.key, entry.value);
  }
  final dualIndex = target == 0 ? 8 : OutIdx.dualEq;
  if (controller.valueOr(target, dualIndex, 0) != (editor.dual ? 1 : 0)) {
    controller.set(target, dualIndex, editor.dual ? 1 : 0);
  }
  // Rechts nur mit Dual EQ schreiben: Ohne Dual EQ übernimmt der ADI-2
  // Werte des rechten Kanals auch links (gemessen am ADI-2 DAC, 2026-11-16:
  // Typ Shelf rechts setzte Band 1/5 links auf Shelf).
  if (editor.dual) {
    for (final entry in editor.right.entries) {
      controller.setEq(target + 2, entry.key, entry.value);
    }
  }
  if (enableBassTreble) controller.setEq(target + 1, 20, 1);
}
