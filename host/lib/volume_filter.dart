import 'dart:math' as math;
import 'dart:typed_data';

import 'package:adi2_remote/device/volume_guard.dart';
import 'package:adi2_remote/device/volume_options.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';

/// Kein Zielpuffer, keine eigene Rampe. Jeder Eingang wird einmal begrenzt.
/// Bestätigte Antworten und bereits weitergeleitete Werte bilden die Basis.
/// Höchstens so viele Rampentakte darf eine einzelne Anhebung nachholen.
const hostRiseBurstTicks = 3;

class HostVolumeFilter {
  HostVolumeFilter({Duration Function()? clock})
    : clock = clock ?? (Stopwatch()..start()).elapsedDuration;
  final Duration Function() clock;
  final Map<int, int> _values = {};
  final Map<int, Duration> _lastRise = {};
  final Map<int, double> _carry = {};
  final Map<int, (int, Duration)> _lowering = {};
  Duration? _grant;
  Adi2Variant? _variant;
  bool limited = false;
  static const outputs = [Adi2Addr.line, Adi2Addr.ph12, Adi2Addr.ph34];

  void heartbeat() => _grant = clock();
  bool get granted => _grant != null && clock() - _grant! < hostGrantLifetime;
  void release() {
    _grant = null;
    for (final address in outputs) {
      _lastRise[address] = clock();
    }
    _carry.clear();
    _lowering.clear();
  }

  void reset() {
    release();
    _values.clear();
    _lastRise.clear();
    _variant = null;
  }

  void observe(Uint8List bytes) {
    final message = parseSysex(bytes);
    if (message == null) return;
    _variant = switch (Adi2Model.fromId(message.deviceId)) {
      Adi2Model.dac => Adi2Variant.dac,
      Adi2Model.pro => Adi2Variant.pro,
      Adi2Model.pro4 => Adi2Variant.pro4se,
      _ => null,
    };
    if (message is Adi2ParamsMessage && bytes[5] == Adi2Cmd.paramsToRemote) {
      for (final p in message.params) {
        if (outputs.contains(p.address) &&
            {
              OutIdx.volume,
              OutIdx.refLevel,
              OutIdx.mute,
              OutIdx.dim,
            }.contains(p.index)) {
          if (p.index == OutIdx.volume && _values[p.key] != p.value) {
            _lowering.remove(p.address);
          }
          _values[p.key] = p.value;
          if (p.index == OutIdx.volume) {
            _lastRise.putIfAbsent(p.address, clock);
          }
        }
      }
    }
  }

  int _allowance(int address, int volume) {
    final now = clock();
    final previous =
        _lastRise[address] ?? now - const Duration(milliseconds: volTickMs);
    // Nach Funkpause höchstens drei Takte angesparte Anhebung: So gehen
    // Schritte nicht verloren, die das WLAN ungleichmäßig liefert. Häufigere
    // Pakete teilen sich dasselbe Zeitbudget.
    final micros = math.max(
      0,
      math.min(
        (now - previous).inMicroseconds,
        hostRiseBurstTicks * volTickMs * 1000,
      ),
    );
    _lastRise[address] = now;
    final step =
        riseRateDbPerSec(volume / 10) * 10 * micros / 1000000 +
        (_carry[address] ?? 0);
    _carry[address] = step - step.floor();
    return step.floor();
  }

  Uint8List? filter(Uint8List bytes) {
    limited = false;
    if (bytes.length < 7 ||
        bytes.length > 256 ||
        bytes[1] != 0 ||
        bytes[2] != 0x20 ||
        bytes[3] != 0x0d ||
        Adi2Model.fromId(bytes[4]) == null) {
      return null;
    }
    // Laden von Setups/Werkseinstellungen kann Volume/Ref/Mute versteckt
    // anheben und lässt sich ohne vollständige Vorschau nicht begrenzen.
    if (bytes[5] == Adi2Cmd.presetRequest &&
        (bytes.length != 8 || bytes[6] < 0x0a || bytes[6] > 0x12)) {
      limited = true;
      return null;
    }
    if (bytes[5] != Adi2Cmd.paramsToDevice) {
      return {
            Adi2Cmd.request,
            Adi2Cmd.nameToDevice,
            Adi2Cmd.presetRequest,
          }.contains(bytes[5])
          ? bytes
          : null;
    }
    if ((bytes.length - 7) % 3 != 0) return null;
    final message = parseSysex(bytes);
    if (message is! Adi2ParamsMessage) return null;
    final forwarded = <Adi2Param>[];
    for (final p in message.params) {
      if (!outputs.contains(p.address)) {
        forwarded.add(p);
        continue;
      }
      final old = _values[p.key];
      var next = p.value;
      if (p.index == OutIdx.volume) {
        next = next.clamp(volMinRaw, volMaxRaw);
        if (old == null) {
          limited = true;
          continue;
        }
        if (next > old) {
          if (!granted) {
            release();
            limited = true;
            continue;
          }
          next = math.min(next, old + _allowance(p.address, old));
          if (next != p.value) limited = true;
          if (next == old) continue;
          _lowering.remove(p.address);
        } else if (next < old) {
          _lowering[p.address] = (old - next, clock());
          _carry.remove(p.address);
          _lastRise[p.address] = clock();
        }
      } else if (p.index == OutIdx.refLevel) {
        final variant = _variant;
        if (old == null || variant == null) {
          limited = true;
          continue;
        }
        final table = refTable(variant, p.address);
        if (old < 0 ||
            old >= table.length ||
            next < 0 ||
            next >= table.length) {
          limited = true;
          continue;
        }
        final delta = ((table[next] - table[old]) * 10).round();
        if (delta > 0) {
          final volume = _values[p.address << 8 | OutIdx.volume];
          final lowering = _lowering.remove(p.address);
          final compensation =
              lowering != null &&
                  clock() - lowering.$2 <= const Duration(milliseconds: 100)
              ? lowering.$1
              : 0;
          if (!granted ||
              volume == null ||
              delta - compensation > _allowance(p.address, volume)) {
            limited = true;
            continue;
          }
        }
      } else if ((p.index == OutIdx.mute || p.index == OutIdx.dim) &&
          next == 0 &&
          old != 0) {
        // Entstummen/Dim aus kann einen sprunghaften Pegelanstieg auslösen.
        if (!granted) {
          limited = true;
          continue;
        }
      }
      if ({
        OutIdx.volume,
        OutIdx.refLevel,
        OutIdx.mute,
        OutIdx.dim,
      }.contains(p.index)) {
        _values[p.key] = next;
      }
      forwarded.add(Adi2Param(p.address, p.index, next));
    }
    if (forwarded.isEmpty) return null;
    return buildSetParams(bytes[4], forwarded).single;
  }
}

extension on Stopwatch {
  Duration elapsedDuration() => elapsed;
}
