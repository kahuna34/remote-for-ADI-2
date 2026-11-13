import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/host/host_analyzer_protocol.dart';
import 'package:flutter/services.dart';

abstract class HostAnalyzerCapture {
  Stream<dynamic> get events;
  Future<void> start();
  Future<void> stop();
}

class NativeHostAnalyzerCapture implements HostAnalyzerCapture {
  static const _method = MethodChannel('adi2/analyzer');
  static const _events = EventChannel('adi2/analyzer/events');
  @override
  Stream<dynamic> get events => _events.receiveBroadcastStream();
  @override
  Future<void> start() async {
    if (await _method.invokeMethod<bool>('requestPermission') != true) {
      throw PlatformException(code: 'analyzer_permission');
    }
    await _method.invokeMethod<void>('start');
  }

  @override
  Future<void> stop() => _method.invokeMethod<void>('stop');
}

typedef HostAnalyzerSend = void Function(
  String type,
  Map<String, dynamic> data,
);

class _Client {
  _Client(this.resolution, this.send, this.version, this.bars);
  final AnalyzerBandResolution resolution;
  final HostAnalyzerSend send;
  final int version;
  final bool bars;
  String? metadata;
  Duration? sentAt;
  AnalyzerFrame? pending;
  // Flusskontrolle: gesendete und von der App bestätigte Bilder.
  int sent = 0;
  int? acked;
  bool get behind => acked != null && sent - acked! > hostAnalyzerMaxInFlight;
}

/// Höchstens so viele unbestätigte Bilder (≈ 0,5 s) dürfen unterwegs sein.
/// Sonst stauen sich Bilder im WLAN und verzögern MIDI und WebSocket-Pings.
const hostAnalyzerMaxInFlight = 25;

class _Analysis {
  _Analysis(AnalyzerBandResolution resolution)
    : dsp = AnalyzerDsp()..bandResolution = resolution;
  final AnalyzerDsp dsp;
  double seconds = 0;
  final peak = [-120.0, -120.0], squares = [0.0, 0.0];
  final clipped = [false, false];
  Duration? sentAt;
  int? rate;
  Timer? timer;
  AnalyzerFrame? latest;
  Map<String, dynamic> metadata = {};
  void reset() {
    seconds = 0;
    for (var i = 0; i < 2; i++) {
      peak[i] = -120;
      squares[i] = 0;
      clipped[i] = false;
    }
  }
}

/// One native stream and at most one continuous DSP per requested resolution.
/// No PCM storage beyond the DSP windows, no file output or Internet endpoint.
class HostAnalyzer {
  HostAnalyzer({required this.capture, Duration Function()? now})
    : _now = now ?? (Stopwatch()..start()).elapsedDuration;
  final HostAnalyzerCapture capture;
  final Duration Function() _now;
  final _clients = <Object, _Client>{};
  final _analyses = <AnalyzerBandResolution, _Analysis>{};
  StreamSubscription<dynamic>? _subscription;
  Future<void> _work = Future.value();
  bool _running = false, _disposed = false, _restartRequired = false;
  int _generation = 0;
  int get analysisCount => _analyses.length;

  Future<void> start(
    Object client,
    AnalyzerBandResolution resolution,
    HostAnalyzerSend send, {
    int version = 1,
    bool bars = false,
  }) {
    if (_disposed) return Future.value();
    final previous = _clients[client];
    _clients[client] = _Client(resolution, send, version, bars)
      ..metadata = previous?.version == version ? previous?.metadata : null;
    _refreshAnalyses();
    return _queue();
  }

  /// Die App meldet mit dem Lebenszeichen, wie viele Bilder sie seit dem
  /// letzten analyzer_start empfangen hat.
  void acknowledge(Object client, Object? received) {
    final c = _clients[client];
    if (c != null && received is int && received >= 0) c.acked = received;
  }

  Future<void> stop(Object client) {
    _clients.remove(client);
    _refreshAnalyses();
    // Invalidate queued events immediately, before the platform stop barrier.
    if (_clients.isEmpty) {
      _generation++;
      _restartRequired = true;
    }
    return _queue();
  }

  void _refreshAnalyses() {
    final wanted = _clients.values.map((v) => v.resolution).toSet();
    _analyses.removeWhere((r, a) {
      if (wanted.contains(r)) return false;
      a.timer?.cancel();
      return true;
    });
    for (final r in wanted) {
      _analyses.putIfAbsent(r, () => _Analysis(r));
    }
  }

  Future<void> _queue() {
    _work = _work.then((_) => _reconcile());
    return _work;
  }

  Future<void> _stopCapture() async {
    _running = false;
    _generation++;
    try {
      await capture.stop();
    } catch (_) {
      /* Already unavailable. */
    }
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _reconcile() async {
    if (_restartRequired) {
      _restartRequired = false;
      if (_running || _subscription != null) await _stopCapture();
    }
    if (_disposed || _clients.isEmpty) {
      if (_running || _subscription != null) await _stopCapture();
      return;
    }
    if (_running) return;
    final generation = ++_generation;
    _running = true;
    try {
      _subscription = capture.events.listen(
        (data) {
          if (_running && generation == _generation) _event(data);
        },
        onError: (Object error) {
          if (_running && generation == _generation) {
            _fail(
              error is PlatformException ? error.code : 'analyzer_no_input',
            );
          }
        },
        onDone: () {
          if (_running && generation == _generation) _fail('analyzer_no_input');
        },
      );
      await capture.start();
      if (_clients.isEmpty || _disposed || generation != _generation) {
        await _stopCapture();
      }
    } catch (error) {
      _fail(error is PlatformException ? error.code : 'analyzer_no_input');
    }
  }

  void _fail(String status) {
    final code = status == 'permissionDenied' || status == 'analyzer_permission'
        ? 'analyzer_permission'
        : 'analyzer_no_input';
    final clients = _clients.values.toList();
    _clients.clear();
    for (final a in _analyses.values) {
      a.timer?.cancel();
    }
    _analyses.clear();
    _restartRequired = true;
    _generation++;
    for (final client in clients) {
      client.send('analyzer_error', {'code': code});
    }
    unawaited(_queue());
  }

  void _event(dynamic data) {
    if (data is! Map || _clients.isEmpty) return;
    if (data['status'] case final String status) {
      _fail(status);
      return;
    }
    try {
      final rate = data['sampleRate'] as int;
      final pcm = (data['pcm'] as List)
          .cast<num>()
          .map((v) => v.toDouble())
          .toList();
      if (pcm.length > rate || pcm.any((v) => !v.isFinite)) {
        throw const FormatException('Analyzer PCM');
      }
      for (final entry in _analyses.entries.toList()) {
        final a = entry.value;
        if (a.rate != rate) {
          a.reset();
          a.timer?.cancel();
          a.timer = null;
          a.latest = null;
          a.sentAt = null;
          a.rate = rate;
        }
        for (final f in a.dsp.add(pcm, rate)) {
          a.seconds += f.seconds;
          for (var ch = 0; ch < 2; ch++) {
            a.peak[ch] = math.max(a.peak[ch], f.peak[ch]);
            a.squares[ch] += math.pow(10, f.rms[ch] / 10) * f.seconds;
            a.clipped[ch] |= f.clipped[ch];
          }
          a.latest = f;
          a.metadata = {
            'sampleRate': rate,
            'device': data['device'],
            'calibrationIdentity': data['calibrationIdentity'],
          };
          final remaining = a.sentAt == null
              ? Duration.zero
              : hostAnalyzerInterval - (_now() - a.sentAt!);
          if (remaining <= Duration.zero) {
            _emit(entry.key, a);
          } else {
            a.timer ??= Timer(remaining, () {
              a.timer = null;
              if (_running && _analyses[entry.key] == a) _emit(entry.key, a);
            });
          }
        }
      }
    } catch (_) {
      _fail('analyzer_no_input');
    }
  }

  void _emit(AnalyzerBandResolution resolution, _Analysis a) {
    final f = a.latest;
    if (f == null || a.seconds <= 0) return;
    a.timer?.cancel();
    a.timer = null;
    a.latest = null;
    final now = _now();
    // Coalesced samples keep elapsed time, peak/RMS and clipping; there
    // is no burst after a stall and no per-client audio/DSP duplication.
    final frame = AnalyzerFrame(
      sampleRate: f.sampleRate,
      spectrum: f.spectrum,
      spectrumBinHz: f.binHz,
      bassSpectrum: f.bassSpectrum,
      bassBinHz: f.bassBinHz,
      bandLevels: f.bandLevels,
      bandResolution: f.bandResolution,
      meterPeak: f.meterPeak,
      meterRms: f.meterRms,
      peak: List.of(a.peak),
      rms: a.squares.map((v) => amplitudeDb(math.sqrt(v / a.seconds))).toList(),
      clipped: List.of(a.clipped),
      seconds: a.seconds,
    );
    final metadata = a.metadata;
    final signature = jsonEncode(metadata);
    for (final client in _clients.values.toList()) {
      if (client.resolution != resolution) continue;
      if (client.version >= 2) {
        if (client.metadata != signature) {
          client.send('analyzer_metadata', {'v': 2, ...metadata});
          client.metadata = signature;
        }
        // App hängt hinterher: zusammenfassen statt weiter stauen.
        final out = coalesceAnalyzerFrames(client.pending, frame);
        if (client.behind) {
          client.pending = out;
          continue;
        }
        client.pending = null;
        client.send(
          'analyzer_frame',
          encodeHostAnalyzerFrameV2(out, bars: client.bars),
        );
        client.sent++;
      } else {
        client.pending = coalesceAnalyzerFrames(client.pending, frame);
        if (client.sentAt != null &&
            now - client.sentAt! < hostAnalyzerLegacyInterval) {
          continue;
        }
        final legacy = client.pending!;
        client.pending = null;
        client.sentAt = now;
        client.send('analyzer_frame', {
          ...encodeHostAnalyzerFrame(legacy),
          if (metadata['device'] != null) 'device': metadata['device'],
          if (metadata['calibrationIdentity'] != null)
            'calibrationIdentity': metadata['calibrationIdentity'],
        });
      }
    }
    a.sentAt = now;
    a.reset();
    // Anchor the next send to this deadline, rather than rounding the interval
    // from the next PCM arrival (60 Hz and 50 Hz do not divide evenly).
    a.timer = Timer(hostAnalyzerInterval, () {
      a.timer = null;
      if (_running && _analyses[resolution] == a) _emit(resolution, a);
    });
  }

  Future<void> dispose() async {
    _disposed = true;
    _clients.clear();
    for (final a in _analyses.values) {
      a.timer?.cancel();
    }
    _analyses.clear();
    _generation++;
    await _queue();
  }
}

extension on Stopwatch {
  Duration elapsedDuration() => elapsed;
}
