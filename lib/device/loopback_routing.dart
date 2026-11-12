import '../protocol/adi2_params.dart';
import '../protocol/adi2_codec.dart';
import 'adi2_controller.dart';
import 'loopback.dart';

List<int> loopbackOutputs(Adi2Controller ctrl) =>
    [
          Adi2Addr.line,
          Adi2Addr.ph12,
          if (ctrl.variant?.hasPhones34 == true) Adi2Addr.ph34,
        ]
        .where(
          (a) =>
              ctrl.value(a, OutIdx.loopback) != null &&
              hasOwnLoopback(ctrl.variant!, a),
        )
        .toList();

/// Address used to display the shared DAC value, even for inconsistent replies.
int? dacLoopbackAddress(Adi2Controller ctrl) {
  final outputs = loopbackOutputs(ctrl);
  final active = switch (ctrl.status?.activeOutput) {
    0 => Adi2Addr.line,
    1 => Adi2Addr.ph12,
    2 => Adi2Addr.ph34,
    _ => Adi2Addr.line,
  };
  return outputs.contains(active) ? active : outputs.firstOrNull;
}

/// Uses optimistic values for occupancy so rapid consecutive edits also work.
List<int> loopbackOccupants(Adi2Controller ctrl, int address, int pair) => [
  if (ctrl.variant?.hasInput == true)
    for (final other in loopbackOutputs(ctrl))
      if (other != address)
        if (decodeLoopback(ctrl.value(other, OutIdx.loopback)!, hasInput: true)
            case (tap: final tap, pair: final target)
            when tap != 0 && target == pair)
          other,
];

/// Separate set calls deliberately produce separate MIDI messages: release
/// occupied pairs before assigning the new source. DAC has one shared value.
void setLoopbackRoute(
  Adi2Controller ctrl,
  int address, {
  required int tap,
  required int pair,
  void Function(int address, int pair)? onDisplaced,
}) {
  final variant = ctrl.variant;
  if (variant == null || ctrl.analyzerSelfTestActive) return;
  final raw = encodeLoopback(tap: tap, pair: pair, hasInput: variant.hasInput);
  final outputs = loopbackOutputs(ctrl);
  if (!outputs.contains(address)) return;
  if (tap != 0) {
    for (final other in loopbackOccupants(ctrl, address, pair)) {
      ctrl.set(other, OutIdx.loopback, 0);
      onDisplaced?.call(other, pair);
    }
  }
  ctrl.set(address, OutIdx.loopback, raw);
}
