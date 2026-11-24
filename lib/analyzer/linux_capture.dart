import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

class LinuxAudioSource {
  const LinuxAudioSource(
    this.name,
    this.description,
    this.rate,
    this.properties,
  );
  final String name, description;
  final int rate;
  final Map<String, dynamic> properties;
}

bool _adi(String value) =>
    RegExp('ADI-2|RME', caseSensitive: false).hasMatch(value);

/// PulseAudio and pipewire-pulse use the same JSON schema. Never use monitors.
List<LinuxAudioSource> parsePactlJson(String output) {
  final rows = jsonDecode(output) as List;
  return [
    for (final row in rows.whereType<Map>())
      if (row['name'] is String &&
          !(row['name'] as String).endsWith('.monitor') &&
          (row['monitor_of_sink'] == null ||
              row['monitor_of_sink'] == 4294967295) &&
          _adi('${row['name']} ${row['description'] ?? ''}'))
        LinuxAudioSource(
          row['name'] as String,
          row['description'] as String? ?? row['name'] as String,
          _sampleRate('${row['sample_specification'] ?? ''}'),
          Map<String, dynamic>.from(row['properties'] as Map? ?? {}),
        ),
  ];
}

int _sampleRate(String value) =>
    int.tryParse(
      RegExp(r'(\d+)\s*Hz', caseSensitive: false).firstMatch(value)?[1] ?? '',
    ) ??
    48000;

List<LinuxAudioSource> parsePactlShort(String output) => [
  for (final line in const LineSplitter().convert(output))
    if (line.trim().isNotEmpty)
      ...(() {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length < 2 ||
            fields[1].endsWith('.monitor') ||
            !_adi(fields[1])) {
          return <LinuxAudioSource>[];
        }
        return [
          LinuxAudioSource(fields[1], fields[1], _sampleRate(line), const {}),
        ];
      })(),
];

/// Keeps incomplete stereo frames between arbitrary stdout chunks.
class LinuxFloat32StereoDecoder {
  Uint8List _tail = Uint8List(0);
  List<double> add(List<int> bytes, {Endian endian = Endian.little}) {
    final data = _tail.isEmpty && bytes is Uint8List
        ? bytes
        : (Uint8List(_tail.length + bytes.length)
            ..setRange(0, _tail.length, _tail)
            ..setRange(_tail.length, _tail.length + bytes.length, bytes));
    final count = data.length ~/ 8 * 8;
    final view = ByteData.sublistView(data);
    final samples = Float32List(count ~/ 4);
    for (var i = 0; i < count; i += 4) {
      final value = view.getFloat32(i, endian);
      if (!value.isFinite) {
        throw const FormatException('Invalid audio samples');
      }
      samples[i ~/ 4] = value;
    }
    _tail = Uint8List.fromList(Uint8List.sublistView(data, count));
    return samples;
  }
}

/// pw-record versions emit either WAV or AU on stdout. Headers can be split
/// across reads; WAV may contain additional, padded chunks before its data.
class LinuxRecordingDecoder {
  final _pcm = LinuxFloat32StereoDecoder();
  final _header = <int>[];
  bool _ready = false, _wave = false, _format = false;
  int _skip = 0;
  Endian _endian = Endian.little;
  List<double> add(List<int> bytes) {
    if (_ready) return _pcm.add(bytes, endian: _endian);
    _header.addAll(bytes);
    if (!_wave) {
      if (_header.length < 24) return [];
      final view = ByteData.sublistView(Uint8List.fromList(_header));
      final magic = ascii.decode(_header.take(4).toList(), allowInvalid: true);
      if (magic == '.snd') {
        final offset = view.getUint32(4);
        if (offset < 24 ||
            offset > 1048576 ||
            view.getUint32(12) != 6 ||
            view.getUint32(20) != 2) {
          throw const FormatException('Expected Float32 stereo (AU)');
        }
        if (_header.length < offset) return [];
        _endian = Endian.big;
        _skip = offset;
        _ready = true;
      } else {
        if ((magic != 'RIFF' && magic != 'RF64') ||
            ascii.decode(_header.sublist(8, 12)) != 'WAVE') {
          throw const FormatException('Expected WAV/AU from pw-record');
        }
        _wave = true;
        _skip = 12;
      }
    }
    while (!_ready && _header.length >= _skip + 8) {
      final view = ByteData.sublistView(Uint8List.fromList(_header));
      final id = ascii.decode(
        _header.sublist(_skip, _skip + 4),
        allowInvalid: true,
      );
      final size = view.getUint32(_skip + 4, Endian.little);
      if (id == 'data') {
        if (!_format) throw const FormatException('WAV without Float32 format');
        _skip += 8;
        _ready = true;
        break;
      }
      if (size > 1048576) throw const FormatException('WAV header too large');
      if (_header.length < _skip + 8 + size + size % 2) return [];
      if (id == 'fmt ') {
        if (size < 16) throw const FormatException('Invalid WAV format');
        final format = view.getUint16(_skip + 8, Endian.little);
        final float =
            format == 3 ||
            (format == 0xfffe &&
                size >= 40 &&
                view.getUint16(_skip + 32, Endian.little) == 3);
        if (!float ||
            view.getUint16(_skip + 10, Endian.little) != 2 ||
            view.getUint16(_skip + 22, Endian.little) != 32) {
          throw const FormatException('Expected Float32 stereo (WAV)');
        }
        _format = true;
      }
      _skip += 8 + size + size % 2;
    }
    if (!_ready) return [];
    final payload = _header.sublist(_skip);
    _header.clear();
    return _pcm.add(payload, endian: _endian);
  }
}

typedef LinuxProcessRunner = Future<ProcessResult> Function(
  String command,
  List<String> args,
);
typedef LinuxProcessStarter = Future<Process> Function(
  String command,
  List<String> args,
);

/// Stereo ring buffer, bounded to 250 ms. Its clock follows the sample rate,
/// with fractional frames carried forward; a late timer never emits a burst.
class LinuxPcmPacer {
  LinuxPcmPacer(this.sampleRate)
    : _buffer = Float32List((sampleRate / 4).ceil() * 2);
  final int sampleRate;
  final Float32List _buffer;
  int _head = 0, _length = 0;
  double _fraction = 0;
  int droppedSamples = 0;
  int get bufferedSamples => _length;
  void add(List<double> samples) {
    assert(samples.length.isEven);
    for (var i = 0; i < samples.length; i += 2) {
      if (_length == _buffer.length) {
        _head = (_head + 2) % _buffer.length;
        _length -= 2;
        droppedSamples += 2;
      }
      final tail = (_head + _length) % _buffer.length;
      _buffer[tail] = samples[i];
      _buffer[tail + 1] = samples[i + 1];
      _length += 2;
    }
  }

  List<double> take(Duration elapsed) {
    // Bound a delayed callback too, so DSP work cannot monopolize the UI.
    final due =
        sampleRate * math.min(elapsed.inMicroseconds / 1e6, .05) + _fraction;
    final frames = due.floor();
    _fraction = due - frames;
    final count = math.min(frames * 2, _length);
    final result = List<double>.generate(
      count,
      (i) => _buffer[(_head + i) % _buffer.length],
    );
    _head = (_head + count) % _buffer.length;
    _length -= count;
    return result;
  }
}

/// Shared by the local app and host. No system default route is changed.
class LinuxAnalyzerCapture {
  LinuxAnalyzerCapture({
    LinuxProcessRunner? run,
    this.elapsed,
    this.readDmi,
    LinuxProcessStarter? startProcess,
  }) : _run = run ?? Process.run,
       _startProcess = startProcess ?? Process.start;
  final Duration Function()? elapsed;
  final Future<String> Function(String)? readDmi;
  final LinuxProcessRunner _run;
  final LinuxProcessStarter _startProcess;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;
  Process? _capture, _tone;
  LinuxAudioSource? _source;
  StreamSubscription<List<int>>? _stdout, _stderr;
  Timer? _watch, _toneExpiry, _pcmTimer;
  bool _checking = false;
  bool _disposed = false;
  int _generation = 0;

  Future<List<LinuxAudioSource>> _devices(String kind) async {
    try {
      final result = await _run('pactl', [
        '-f',
        'json',
        'list',
        kind,
      ]).timeout(const Duration(seconds: 3));
      if (result.exitCode == 0) return parsePactlJson(result.stdout as String);
    } on FormatException {
      // Older pactl does not implement JSON.
    } on ProcessException catch (error) {
      if (error.errorCode != 2) rethrow;
      throw const LinuxCaptureException(
        'captureFailed',
        'pactl is missing. Please install pulseaudio-utils.',
      );
    }
    final result = await _run('pactl', [
      'list',
      kind,
      'short',
    ]).timeout(const Duration(seconds: 3));
    if (result.exitCode != 0) {
      throw const LinuxCaptureException(
        'captureFailed',
        'PipeWire/PulseAudio is not reachable.',
      );
    }
    return parsePactlShort(result.stdout as String);
  }

  /// Aufnahme bitgenau: Lautstärke der ADI-2-Quelle auf 100 % und nicht stumm.
  /// Nur diese Quelle, keine Standardgeräte. Damit braucht Linux keine Kalibrierung.
  Future<void> _unityGain(String name) async {
    for (final args in [
      ['set-source-volume', name, '100%'],
      ['set-source-mute', name, '0'],
    ]) {
      try {
        await _run('pactl', args).timeout(const Duration(seconds: 3));
      } on Object {
        // Ohne pactl-Steuerung bleibt die Quelle, wie sie ist.
      }
    }
  }

  Future<void> start() async {
    if (_disposed) return;
    await stop();
    final token = _generation;
    try {
      final sources = await _devices('sources');
      if (token != _generation) return;
      if (sources.length != 1) {
        throw const LinuxCaptureException(
          'usbUnavailable',
          'No unique ADI-2/RME capture source found.',
        );
      }
      final source = sources.single;
      _source = source;
      await _unityGain(source.name);
      final identity = <String, dynamic>{
        'hostManufacturer': await _dmi('sys_vendor'),
        'hostModel': await _dmi('product_name'),
        'usbName': source.description,
        'usbSerial': source.properties['device.serial'],
        'usbVendorId': source.properties['device.vendor.id'],
        'usbProductId': source.properties['device.product.id'],
      };
      Process process;
      var wave = false;
      try {
        process = await _startProcess('parec', [
          '--device=${source.name}',
          '--format=float32le',
          '--channels=2',
          '--rate=${source.rate}',
          '--raw',
          '--latency-msec=10',
          '--process-time-msec=5',
        ]);
      } on ProcessException catch (error) {
        if (error.errorCode != 2) rethrow;
        wave = true;
        try {
          process = await _startProcess('pw-record', [
            '--target',
            source.name,
            '--format',
            'f32',
            '--rate',
            '${source.rate}',
            '--channels',
            '2',
            '--properties',
            '{"node.dont-reconnect":true,"node.dont-fallback":true}',
            '-',
          ]);
        } on ProcessException catch (error) {
          if (error.errorCode != 2) rethrow;
          throw const LinuxCaptureException(
            'captureFailed',
            'parec and pw-record are missing. Please install pulseaudio-utils.',
          );
        }
      }
      if (token != _generation) {
        await _terminate(process);
        return;
      }
      _capture = process;
      final raw = LinuxFloat32StereoDecoder();
      final container = LinuxRecordingDecoder();
      final pacer = LinuxPcmPacer(source.rate);
      final clock = Stopwatch();
      var previous = Duration.zero;
      Duration? started;
      _pcmTimer = Timer.periodic(const Duration(microseconds: 16667), (_) {
        if (token != _generation || !clock.isRunning) return;
        final now = elapsed == null ? clock.elapsed : elapsed!() - started!;
        // A small startup reserve absorbs typical stdout pipe jitter.
        if (now < const Duration(milliseconds: 50)) {
          previous = now;
          return;
        }
        final samples = pacer.take(now - previous);
        previous = now;
        if (samples.isEmpty) return;
        _events.add({
          'pcm': samples,
          'sampleRate': source.rate,
          'device': source.description,
          'calibrationIdentity': identity,
          'routeVerified': true,
          'mediaStreamVolume': 100,
          'mediaStreamMax': 100,
        });
      });
      var detail = '';
      _stderr = process.stderr.listen((bytes) {
        detail = (detail + utf8.decode(bytes, allowMalformed: true));
        if (detail.length > 2048) {
          detail = detail.substring(detail.length - 2048);
        }
      });
      _stdout = process.stdout.listen(
        (bytes) {
          if (token != _generation) return;
          try {
            final samples = wave ? container.add(bytes) : raw.add(bytes);
            pacer.add(samples);
            if (samples.isNotEmpty && !clock.isRunning) {
              started = elapsed?.call();
              clock.start();
            }
          } catch (error) {
            unawaited(_fail('captureFailed', '$error', token));
          }
        },
        onError: (Object error) =>
            unawaited(_fail('captureFailed', '$error', token)),
      );
      unawaited(
        process.exitCode.then(
          (code) => _fail(
            'usbUnavailable',
            'Capture ended ($code). ${detail.trim()}',
            token,
          ),
        ),
      );
      _watch = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_checkRoute(token)),
      );
    } on LinuxCaptureException catch (error) {
      await _fail(error.code, error.detail, token);
    } catch (error) {
      await _fail('captureFailed', '$error', token);
    }
  }

  Future<String> _dmi(String name) async {
    if (readDmi != null) return readDmi!(name);
    try {
      final value = (await File(
        '/sys/class/dmi/id/$name',
      ).readAsString()).trim();
      if (value.isNotEmpty) return value;
    } catch (_) {
      /* Virtual machines may omit DMI. */
    }
    return 'Linux (DMI unknown)';
  }

  Future<void> _checkRoute(int token) async {
    if (_checking || token != _generation) return;
    _checking = true;
    try {
      final sources = await _devices('sources');
      if (!sources.any(
        (s) => s.name == _source?.name && s.rate == _source?.rate,
      )) {
        await _fail(
          'usbUnavailable',
          'ADI-2 capture device was disconnected or reconfigured.',
          token,
        );
      }
    } catch (error) {
      await _fail('usbUnavailable', '$error', token);
    } finally {
      _checking = false;
    }
  }

  Future<void> _fail(String code, String detail, int token) async {
    if (token != _generation) return;
    final stopped = token + 1;
    await stop();
    if (!_disposed && _generation == stopped) {
      _events.add({'status': code, 'detail': detail});
    }
  }

  Future<void> startCalibrationTone() async {
    await stopCalibrationTone();
    final token = _generation;
    final source = _source;
    if (_capture == null || source == null) {
      throw StateError('No ADI-2 capture');
    }
    final sinks = (await _devices('sinks'))
        .where(
          (s) =>
              s.name.toLowerCase().contains('adi-2') ||
              s.description.toLowerCase().contains('adi-2'),
        )
        .toList();
    // Bind playback to the same ALSA card as capture when JSON exposes it.
    final card =
        source.properties['alsa.card'] ?? source.properties['device.serial'];
    final matches = sinks
        .where(
          (s) =>
              card == null ||
              (s.properties['alsa.card'] ?? s.properties['device.serial']) ==
                  card,
        )
        .toList();
    if (token != _generation || matches.length != 1) {
      throw StateError('No unique ADI-2 output');
    }
    final process = await _startProcess('pacat', [
      '--playback',
      '--device=${matches.single.name}',
      '--format=float32le',
      '--channels=2',
      '--rate=${source.rate}',
      '--raw',
    ]);
    if (token != _generation) {
      await _terminate(process);
      throw StateError('Capture ended');
    }
    _tone = process;
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    _toneExpiry = Timer(
      const Duration(milliseconds: 3700),
      () => unawaited(stopCalibrationTone()),
    );
    unawaited(
      process.exitCode.then((code) {
        if (identical(_tone, process) && code != 0) {
          return _fail(
            'usbUnavailable',
            'ADI-2 test tone ended ($code).',
            token,
          );
        }
      }),
    );
    // Same finite 1 kHz full-scale signal, lead-in and fades as macOS.
    unawaited(() async {
      try {
        final total = (source.rate * 3.6).floor();
        final lead = (source.rate * .25).floor(),
            fade = (source.rate * .02).floor();
        for (
          var start = 0;
          start < total && identical(_tone, process);
          start += 1024
        ) {
          final frames = math.min(1024, total - start);
          final data = ByteData(frames * 8);
          for (var i = 0; i < frames; i++) {
            final frame = start + i;
            final gain = frame < lead
                ? 0.0
                : math.min(
                    1.0,
                    math.min((frame - lead) / fade, (total - 1 - frame) / fade),
                  );
            final value =
                gain *
                math.sin(2 * math.pi * 1000 * (frame - lead) / source.rate);
            data.setFloat32(i * 8, value, Endian.little);
            data.setFloat32(i * 8 + 4, value, Endian.little);
          }
          process.stdin.add(data.buffer.asUint8List());
          await process.stdin.flush();
        }
        await process.stdin.close();
      } catch (_) {
        if (identical(_tone, process)) {
          await _fail('captureFailed', 'Could not play the test tone.', token);
        }
      }
    }());
  }

  Future<void> stopCalibrationTone() async {
    _toneExpiry?.cancel();
    _toneExpiry = null;
    final process = _tone;
    _tone = null;
    if (process != null) await _terminate(process);
  }

  Future<void> stop() async {
    _generation++;
    _watch?.cancel();
    _watch = null;
    _pcmTimer?.cancel();
    _pcmTimer = null;
    await stopCalibrationTone();
    final process = _capture;
    _capture = null;
    _source = null;
    if (process != null) await _terminate(process);
    await _stdout?.cancel();
    await _stderr?.cancel();
    _stdout = _stderr = null;
  }

  Future<void> _terminate(Process process) async {
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
    await _events.close();
  }
}

class LinuxCaptureException implements Exception {
  const LinuxCaptureException(this.code, this.detail);
  final String code, detail;
}
