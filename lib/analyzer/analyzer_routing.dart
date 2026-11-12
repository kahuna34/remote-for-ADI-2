import 'dart:async';

import '../app_settings.dart';
import '../device/adi2_controller.dart';
import '../device/loopback.dart';
import '../device/loopback_routing.dart';
import '../protocol/adi2_codec.dart';
import '../protocol/adi2_params.dart';

List<int> analyzerOutputAddresses(Adi2Controller ctrl) => loopbackOutputs(ctrl);

/// DAC status bits are verified for Line/Phones/IEM. Pro status bits have a
/// different meaning; use the selected output there rather than guessing.
int? activeAnalyzerOutput(Adi2Controller ctrl) {
  final outputs = analyzerOutputAddresses(ctrl);
  if (ctrl.variant?.isDac == true && ctrl.status != null) {
    final address = switch (ctrl.status!.activeOutput) {
      0 => Adi2Addr.line,
      1 => Adi2Addr.ph12,
      2 => Adi2Addr.ph34,
      _ => null,
    };
    if (outputs.contains(address)) return address;
  }
  if (outputs.contains(ctrl.selectedOutput)) return ctrl.selectedOutput;
  return outputs.firstOrNull;
}

/// Preserve other USB pairs; the DAC value is shared across all outputs.
void routeAnalyzerLoopback(
  Adi2Controller ctrl,
  int address,
  int tap, {
  void Function(int address, int pair)? onDisplaced,
}) {
  if (ctrl.analyzerSelfTestActive ||
      (ctrl.state != ConnState.connected && !ctrl.offline) ||
      ctrl.variant == null) {
    return;
  }
  final outputs = analyzerOutputAddresses(ctrl);
  if (!outputs.contains(address) ||
      (!ctrl.offline &&
          outputs.any(
            (a) => ctrl.confirmedValue(a, OutIdx.loopback) == null,
          ))) {
    return;
  }
  final current = ctrl.offline
      ? ctrl.value(address, OutIdx.loopback)
      : ctrl.confirmedValue(address, OutIdx.loopback);
  if (current == tap && loopbackOccupants(ctrl, address, 0).isEmpty) return;
  setLoopbackRoute(ctrl, address, tap: tap, pair: 0, onDisplaced: onDisplaced);
}

/// Only real output transitions while visible may schedule automatic writes.
/// Readbacks and unrelated settings never reconcile a manually changed route.
class AnalyzerRouting {
  AnalyzerRouting(this.ctrl, {this.onDisplaced}) {
    _lastAddress = address;
    _lastConfiguration = _configuration;
    _connected = ctrl?.state == ConnState.connected;
    ctrl?.addListener(_observe);
    ctrl?.selectedOutputChanges.addListener(_observe);
    AppSettings.instance.addListener(_observe);
  }
  final Adi2Controller? ctrl;
  final void Function(int address, int pair)? onDisplaced;
  bool _active = false, _disposed = false;
  bool _connected = false;
  int? _lastAddress;
  late (int, int, bool) _lastConfiguration;
  Timer? _debounce;

  (int, int, bool) get _configuration => (
    AppSettings.instance.analyzerLoopbackOutput,
    AppSettings.instance.analyzerLoopbackTap,
    AppSettings.instance.analyzerLoopbackConfirmed,
  );

  void setActive(bool active) {
    if (_disposed || _active == active) return;
    _active = active;
    _cancel();
    // Showing/reopening the analyzer must not overwrite existing routing.
    _lastAddress = address;
  }

  bool get _canAutomate =>
      _active &&
      ctrl?.state == ConnState.connected &&
      ctrl?.variant?.isDac == false &&
      ctrl?.analyzerSelfTestActive == false &&
      AppSettings.instance.analyzerLoopbackOutput == 0 &&
      AppSettings.instance.analyzerLoopbackConfirmed &&
      tap != 0;

  int? get address {
    final c = ctrl;
    if (c == null || c.variant == null) return null;
    if (c.variant!.isDac) return dacLoopbackAddress(c);
    final selected = AppSettings.instance.analyzerLoopbackOutput;
    return selected == 0
        ? activeAnalyzerOutput(c)
        : analyzerOutputAddresses(c).where((a) => a == selected).firstOrNull ??
              activeAnalyzerOutput(c);
  }

  /// Adopt a pre-existing USB 1/2 tap on upgrade, until the user chooses one.
  int get tap {
    final settings = AppSettings.instance;
    if (settings.analyzerRoutingConfigured || ctrl?.variant == null) {
      return settings.analyzerLoopbackTap;
    }
    if (ctrl!.variant!.isDac) {
      final address = dacLoopbackAddress(ctrl!);
      return address == null ? 0 : ctrl!.value(address, OutIdx.loopback)!;
    }
    for (final address in analyzerOutputAddresses(ctrl!)) {
      final value = decodeLoopback(
        ctrl!.value(address, OutIdx.loopback)!,
        hasInput: ctrl!.variant!.hasInput,
      );
      if (value.tap != 0 && value.pair == 0) return value.tap;
    }
    return 0;
  }

  Future<void> configure({required int output, required int tap}) async {
    if (_disposed || ctrl?.analyzerSelfTestActive == true) return;
    _cancel();
    final previous = address;
    // Persist the explicit user action. Settings notifications alone never write.
    final saved = AppSettings.instance.setAnalyzerRouting(
      output: ctrl?.variant?.isDac == true ? 0 : output,
      tap: tap,
    );
    _cancel();
    _lastAddress = address;
    if (AppSettings.instance.analyzerLoopbackConfirmed && ctrl != null) {
      final target = tap == 0 ? previous : address;
      final raw = target == null
          ? null
          : (ctrl!.offline
                ? ctrl!.value(target, OutIdx.loopback)
                : ctrl!.confirmedValue(target, OutIdx.loopback));
      // Off must preserve recordings on other USB pairs.
      if (raw != null &&
          (tap != 0 ||
              decodeLoopback(raw, hasInput: ctrl!.variant!.hasInput).pair ==
                  0)) {
        routeAnalyzerLoopback(ctrl!, target!, tap, onDisplaced: onDisplaced);
      }
    }
    await saved;
  }

  void _cancel() {
    _debounce?.cancel();
    _debounce = null;
  }

  void _observe() {
    if (_disposed) return;
    final target = address;
    final changed = _lastAddress != null && target != _lastAddress;
    _lastAddress = target;
    final configuration = _configuration;
    final connected = ctrl?.state == ConnState.connected;
    final reset =
        configuration != _lastConfiguration || connected != _connected;
    _lastConfiguration = configuration;
    _connected = connected;
    if (reset || !_canAutomate) {
      _cancel();
      return;
    }
    if (!changed) return;
    _cancel();
    if (target == null) return;
    final selectedTap = tap;
    _debounce = Timer(const Duration(seconds: 1), () {
      _debounce = null;
      if (!_canAutomate || address != target || tap != selectedTap) return;
      // One attempt per transition, even if a late/stale readback disagrees.
      routeAnalyzerLoopback(
        ctrl!,
        target,
        selectedTap,
        onDisplaced: onDisplaced,
      );
    });
  }

  void dispose() {
    _disposed = true;
    _cancel();
    ctrl?.removeListener(_observe);
    ctrl?.selectedOutputChanges.removeListener(_observe);
    AppSettings.instance.removeListener(_observe);
  }
}
