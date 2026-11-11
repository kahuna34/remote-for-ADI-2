import 'dart:convert';
import 'dart:math' as math;

import 'analyzer_dsp.dart';

/// Connection IDs and Android audio port addresses are deliberately excluded.
class AnalyzerCalibrationIdentity {
  AnalyzerCalibrationIdentity._(this.key, this.label);
  final String key, label;

  static AnalyzerCalibrationIdentity? fromMap(dynamic data) {
    if (data is! Map) return null;
    final manufacturer =
        data['hostManufacturer'] ?? data['androidManufacturer'];
    final model = data['hostModel'] ?? data['androidModel'];
    final usb = data['usbName'];
    if (manufacturer is! String ||
        manufacturer.isEmpty ||
        model is! String ||
        model.isEmpty ||
        usb is! String ||
        usb.isEmpty) {
      return null;
    }
    final serial = data['usbSerial'] as String?;
    return AnalyzerCalibrationIdentity._(
      jsonEncode([
        manufacturer,
        model,
        usb,
        data['usbVendorId'],
        data['usbProductId'],
        serial,
      ]),
      '$manufacturer $model · $usb${serial == null ? '' : ' · $serial'}',
    );
  }
}

enum AnalyzerCalibrationError {
  unavailable,
  tooQuiet,
  unbalanced,
  unstable,
  outOfRange,
  toneUnavailable,
  toneInterrupted,
  volumeUnverified,
}

class AnalyzerCalibrationProposal {
  const AnalyzerCalibrationProposal(this.key, this.generation, this.offset);
  final String key;
  final int generation;
  final double offset;
}

/// Uses instantaneous, uncalibrated stereo peaks, before meter ballistics.
class AnalyzerCalibrationMeasurement {
  int _count = 0;
  double _seconds = 0;
  final _minimum = [double.infinity, double.infinity];
  final _maximum = [double.negativeInfinity, double.negativeInfinity];
  final _sum = [0.0, 0.0];
  AnalyzerCalibrationError? _error;

  void add(AnalyzerFrame frame) {
    if (frame.peak.length != 2 ||
        frame.peak.any((p) => !p.isFinite) ||
        !frame.seconds.isFinite ||
        frame.seconds <= 0) {
      _error = AnalyzerCalibrationError.unstable;
      return;
    }
    _count++;
    _seconds += frame.seconds;
    if (frame.peak.any((p) => p <= -60)) {
      _error = AnalyzerCalibrationError.tooQuiet;
    } else if ((frame.peak[0] - frame.peak[1]).abs() > 1) {
      _error ??= AnalyzerCalibrationError.unbalanced;
    }
    for (var ch = 0; ch < 2; ch++) {
      _minimum[ch] = math.min(_minimum[ch], frame.peak[ch]);
      _maximum[ch] = math.max(_maximum[ch], frame.peak[ch]);
      _sum[ch] += frame.peak[ch] * frame.seconds;
    }
  }

  double finish() {
    if (_error != null) throw _error!;
    // Coalesced events alone cannot establish stability over two seconds.
    if (_count < 20 || _seconds < 1.8) {
      throw AnalyzerCalibrationError.unavailable;
    }
    for (var ch = 0; ch < 2; ch++) {
      final mean = _sum[ch] / _seconds;
      if (mean - _minimum[ch] > 0.5 + 1e-9 ||
          _maximum[ch] - mean > 0.5 + 1e-9) {
        throw AnalyzerCalibrationError.unstable;
      }
    }
    final offset = -(_sum[0] + _sum[1]) / (2 * _seconds);
    if (offset < -40 || offset > 40) {
      throw AnalyzerCalibrationError.outOfRange;
    }
    return (offset * 10).round() / 10;
  }
}
