import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/analyzer/analyzer_filter_bank.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/dev/analyzer_selftest.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TestSelfTestDevice extends SelfTestDevice {
  TestSelfTestDevice(this.events) {
    for (final a in outputs) {
      values.addAll({
        a << 8 | OutIdx.mute: a == 6 ? 1 : 0,
        a << 8 | OutIdx.volume: -230 - a,
        a << 8 | OutIdx.source: 2,
        a << 8 | OutIdx.loopback: a == 9 ? 8 : 2,
      });
    }
  }
  final List<String> events;
  final values = <int, int>{};
  final writes = <SelfTestValues>[];
  bool leased = false;
  int? failWrite;
  Future<void> Function()? afterWrite;
  SelfTestValues Function()? onRead;
  @override
  bool connected = true;
  @override
  String identity = 'original-device';
  SelfTestIdentity? hardwareIdentity;
  Future<void>? readiness;
  @override
  SelfTestIdentity get recoveryIdentity =>
      hardwareIdentity ?? super.recoveryIdentity;
  @override
  Future<void> waitUntilReady({bool requireSerial = false}) async {
    await readiness;
    await super.waitUntilReady(requireSerial: requireSerial);
  }

  @override
  List<int> get outputs => [3, 6, 9];
  @override
  int get usbSource => 4;
  @override
  String sourceLabel(int output, int value) =>
      value == 4 ? 'USB 1/2' : 'SPDIF optical';
  @override
  bool get hasInput => true;
  @override
  void acquire() {
    if (leased) throw StateError('busy');
    leased = true;
  }

  @override
  void release() {
    leased = false;
  }

  @override
  Future<SelfTestValues> read() async => onRead?.call() ?? Map.of(values);
  @override
  Future<void> write(SelfTestValues next) async {
    events.add('write');
    writes.add(Map.of(next));
    values.addAll(next);
    if (failWrite == writes.length) throw StateError('MIDI readback timeout');
    await afterWrite?.call();
  }
}

class TestSelfTestAudio extends SelfTestAudio {
  TestSelfTestAudio(this.events);
  final List<String> events;
  Map<String, dynamic>? journal;
  final saved = <String, Map<String, dynamic>>{};
  int tones = 0, stops = 0;
  bool noPreSignal = false, stopFails = false, saveFails = false;
  bool wrongRate = false;
  Map<String, dynamic> preparation = {
    'sampleRate': 48000,
    'playback': {'bitPerfect': true},
  };
  PlatformException? prepareError;
  Future<void> Function()? onPrepare;
  Future<Map<String, dynamic>> Function(AnalyzerBandResolution, int)? onTone;
  @override
  Future<Map<String, dynamic>> prepare() async {
    events.add('prepare');
    if (prepareError != null) throw prepareError!;
    await onPrepare?.call();
    return preparation;
  }

  static Map<String, dynamic> measurement(
    AnalyzerBandResolution r,
    int i, {
    double gain = 0,
  }) => {
    'sampleRate': 48000,
    'broadbandRmsDbfs': [-23.01029995664 + gain, -23.01029995664 + gain],
    'playbackBefore': {'bitPerfect': true},
    'playbackAfter': {'bitPerfect': true},
    'levels': List.generate(r.count, (b) => (b == i ? -20.0 : -35.0) + gain),
    'trace': [
      {'seconds': .016666667, 'db': -40.0 + gain},
      {'seconds': .033333333, 'db': -21.0 + gain},
      {'seconds': .05, 'db': -20.5 + gain},
      {'seconds': .066666667, 'db': -20.1 + gain},
      {'seconds': .083333333, 'db': -20.0 + gain},
    ],
  };
  @override
  Future<Map<String, dynamic>> tone(AnalyzerBandResolution r, int i) async {
    events.add('tone');
    tones++;
    if (noPreSignal && tones == 1) throw PlatformException(code: 'noSignal');
    if (onTone != null) return onTone!(r, i);
    return {
      ...measurement(r, i),
      'sampleRate': wrongRate && tones > 1 ? 44100 : 48000,
    };
  }

  @override
  Future<bool> permission() async => true;
  @override
  Future<void> stop() async {
    events.add('stop');
    stops++;
    if (stopFails) throw StateError('stop barrier failed');
  }

  @override
  Future<String> save(String name, Map<String, dynamic> data) async {
    events.add('save');
    if (saveFails) throw StateError('disk full');
    if (name.contains('recovery')) {
      journal = data;
    } else {
      saved[name] = data;
    }
    return 'files/$name';
  }

  @override
  Future<SelfTestLastResult?> lastResult() async => saved.isEmpty
      ? null
      : SelfTestLastResult(
          jsonDecode(jsonEncode(saved.values.last)) as Map<String, dynamic>,
          'files/${saved.keys.last}',
        );
  @override
  Future<Map<String, dynamic>?> recovery() async => journal;
  @override
  Future<void> clearRecovery() async {
    events.add('clear');
    journal = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('stored JSON loads through platform channel without changing recovery state', () async {
    final device = TestSelfTestDevice([]);
    final audio = TestSelfTestAudio([]);
    final original = AnalyzerSelfTest(device, audio, silence: Duration.zero);
    addTearDown(original.dispose);
    await original.run(device.outputs.first);
    final json = jsonEncode(original.report);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SelfTestAudio.channel, (call) async {
      expect(call.method, 'lastResult');
      return {'path': 'files/last.json', 'json': json};
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SelfTestAudio.channel, null),
    );
    final reopened = AnalyzerSelfTest(device, SelfTestAudio());
    addTearDown(reopened.dispose);
    reopened.restored = false;
    await reopened.loadLastResult();
    expect(reopened.lastResult!.report, original.report);
    expect(reopened.lastResult!.path, 'files/last.json');
    expect(reopened.restored, isFalse);
    messenger.setMockMethodCallHandler(
      SelfTestAudio.channel,
      (_) async => {'path': 'files/broken.json', 'json': '{broken'},
    );
    await reopened.loadLastResult();
    expect(reopened.lastResultError, contains('Letztes Ergebnis nicht lesbar'));
    expect(reopened.restored, isFalse);
  });

  for (final resolution in AnalyzerBandResolution.values) {
    test(
      'simulated loopback: every ${resolution.bandsPerOctave} band at -20 dBFS, separation and response',
      () {
        const rate = 48000;
        var maximumError = 0.0;
        final separationDeviations = <int>[];
        for (var index = 0; index < resolution.count; index++) {
          final bank = AnalyzerFilterBank(rate, resolution);
          final settling = selfTestSettling(resolution, index);
          final samples =
              ((settling + selfTestWindow(resolution, index) + .04) * rate)
                  .ceil();
          final sums = List.filled(resolution.count, 0.0);
          final trace = <Map<String, double>>[];
          var windows = 0;
          for (var sample = 0; sample < samples; sample++) {
            final v =
                .1 *
                math.sin(
                  2 * math.pi * resolution.centre(index) * sample / rate,
                );
            bank.process(v, v);
            if ((sample + 1) % 800 != 0) continue;
            final levels = bank.levels;
            final seconds = (sample + 1) / rate;
            trace.add({'seconds': seconds, 'db': levels[index]});
            if (seconds >= settling) {
              for (var i = 0; i < sums.length; i++) {
                sums[i] += math.pow(10, levels[i] / 10).toDouble();
              }
              windows++;
            }
          }
          final measured = SelfTestBandResult(resolution, index, {
            'levels': sums
                .map((p) => 10 * math.log(p / windows) / math.ln10)
                .toList(),
            'trace': trace,
          });
          maximumError = math.max(maximumError, (measured.db + 20).abs());
          expect(
            measured.levelOk,
            isTrue,
            reason: '${resolution.centre(index)} Hz: ${measured.db}',
          );
          if (!measured.separationOk) separationDeviations.add(index);
          expect(measured.responseMs, isNotNull);
          expect(measured.responseMs!, lessThan(settling * 1000));
        }
        // All bands must meet the unchanged 9 dB criterion, including 15.8 kHz.
        expect(separationDeviations, <int>[]);
        // Captured in the test log for the development calibration report.
        // ignore: avoid_print
        print(
          'SELFTEST_SIMULATION: 1/${resolution.bandsPerOctave}, ${resolution.count} bands, maximum error $maximumError dB, separation deviations $separationDeviations',
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  late TestSelfTestDevice device;
  late TestSelfTestAudio audio;
  late AnalyzerSelfTest session;
  late SelfTestValues original;
  late List<String> events;
  setUp(() {
    events = [];
    device = TestSelfTestDevice(events);
    audio = TestSelfTestAudio(events);
    original = Map.of(device.values);
    session = AnalyzerSelfTest(device, audio, silence: Duration.zero);
  });
  tearDown(() {
    session.dispose();
  });

  test(
    'developer self-test remains uncalibrated with a saved analyzer offset',
    () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.instance.load();
      await AppSettings.instance.setAnalyzerCalibration('test combination', 20);
      await session.run(6);
      expect(session.report['captureCalibration'], 'uncalibrated');
      expect(
        session.text,
        contains(
          tr('USB-Messwerte unkalibriert (Analyzer-Offset nicht angewendet)'),
        ),
      );
      expect(
        session.results,
        everyElement(
          predicate<SelfTestBandResult>((r) => (r.db + 20).abs() < 0.01),
        ),
      );
      await AppSettings.instance.setAnalyzerCalibration('test combination', 0);
    },
  );

  test('206 bands discard raw data and keep JSON below 1 MB', () async {
    final raw = List.filled(32768, -120.0);
    audio.onTone = (r, i) async {
      session.metadata['samples'] = raw;
      session.metadata['diagnostics'] = {
        'quiet': {
          'channels': [
            {'rmsDbfs': -90.0, 'spectrumDbfs': raw, 'samples': raw},
            {'rmsDbfs': -91.0, 'spectrumDbfs': raw},
          ],
        },
      };
      return {
        ...TestSelfTestAudio.measurement(r, i),
        'samples': raw,
        'spectrumDbfs': raw,
        'quietBeforeTone': session.metadata['diagnostics'],
      };
    };
    await session.run(6);
    expect(session.results.length, 206);
    final json = const JsonEncoder.withIndent('  ').convert(session.report);
    expect(utf8.encode(json).length, lessThan(SelfTestAudio.writeLimit));
    for (final rawKey in [
      'samples',
      'spectrumDbfs',
      'trace',
      'measurement',
      'levels',
    ]) {
      expect(json, isNot(contains('"$rawKey":')));
    }
    expect(session.report['bands'], everyElement(containsPair('ok', true)));
    expect(session.report, contains('diagnosticText'));
    // ignore: avoid_print
    print(
      'SELFTEST_COMPACT_JSON: ${utf8.encode(json).length} bytes / 206 bands',
    );
  });

  test(
    'write limit rejects UTF-8 payload before MethodChannel transfer',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var calls = 0;
      messenger.setMockMethodCallHandler(SelfTestAudio.channel, (_) async {
        calls++;
        return 'unexpected';
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SelfTestAudio.channel, null),
      );
      await expectLater(
        SelfTestAudio().save('analyzer_selftest_1.json', {
          'value': List.filled(400000, '€').join(),
        }),
        throwsFormatException,
      );
      expect(calls, 0);
    },
  );

  test(
    'discard notice survives loading with and without a retained result',
    () async {
      await session.run(6);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final reopened = AnalyzerSelfTest(device, SelfTestAudio());
      addTearDown(reopened.dispose);
      addTearDown(
        () => messenger.setMockMethodCallHandler(SelfTestAudio.channel, null),
      );
      const notice = '1 Selbsttest-Ergebnisdatei(en) zu groß, verworfen.';
      for (final keepResult in [false, true]) {
        messenger.setMockMethodCallHandler(
          SelfTestAudio.channel,
          (_) async => {
            'notice': notice,
            if (keepResult) 'path': session.path,
            if (keepResult) 'json': jsonEncode(session.report),
          },
        );
        await reopened.loadLastResult();
        expect(reopened.lastResultError, notice);
        expect(reopened.lastResult != null, keepResult);
      }
      messenger.setMockMethodCallHandler(
        SelfTestAudio.channel,
        (_) async => {
          'path': 'files/oversized.json',
          'json': ' ' * (SelfTestAudio.readLimit + 1),
        },
      );
      await reopened.loadLastResult();
      expect(reopened.lastResultError, contains('zu groß, verworfen'));
    },
  );

  test('initial quiet check completes before the first 1 kHz probe', () async {
    final quietStarted = Completer<void>();
    final quietFinished = Completer<void>();
    audio.onPrepare = () async {
      events.add('quietStart');
      quietStarted.complete();
      await quietFinished.future;
      events.add('quietEnd');
    };
    final run = session.run(6);
    await quietStarted.future;
    expect(audio.tones, 0);
    audio.onTone = (resolution, index) async {
      expect(events.indexOf('quietEnd'), lessThan(events.indexOf('tone')));
      if (audio.tones == 1) {
        expect(resolution, AnalyzerBandResolution.third);
        expect(index, 16); // The probe also follows the initial quiet check.
      }
      return TestSelfTestAudio.measurement(resolution, index);
    };
    quietFinished.complete();
    await run;
    expect(session.error, isNull);
    expect(audio.tones, 207);
  });

  test('full sweep, confirmed mute before playback, exact snapshot restoration and JSON/CSV', () async {
    await session.run(6);
    expect(session.results.length, 206);
    expect(session.results.every((r) => r.ok), isTrue);
    expect(device.writes.first, {
      for (final a in device.outputs) a << 8 | OutIdx.mute: 1,
    });
    expect(events.indexOf('write'), lessThan(events.indexOf('prepare')));
    expect(device.values, original);
    expect(session.restored, isTrue);
    expect(device.leased, isFalse);
    expect(session.report['grade'], 'OK');
    expect(audio.saved.values.single['restored'], isTrue);
    expect(session.path, startsWith('files/analyzer_selftest_'));
    expect(session.csv.split('\n').length, 208);
    expect(audio.journal, isNull);
    expect(session.results.first.responseMs, closeTo(33.333333, .001));
  });
  for (final initialSource in [0, 2, 5]) {
    test(
      'forces USB from source $initialSource and journals exact recovery',
      () async {
        device.values[6 << 8 | OutIdx.source] = initialSource;
        final before = Map.of(device.values);
        audio.onTone = (r, i) async {
          expect(device.values[6 << 8 | OutIdx.source], device.usbSource);
          expect(
            audio.journal!['values']['${6 << 8 | OutIdx.source}'],
            initialSource,
          );
          return TestSelfTestAudio.measurement(r, i);
        };
        await session.run(6);
        expect(device.values, before);
        expect(device.writes[1][6 << 8 | OutIdx.source], device.usbSource);
      },
    );
  }
  test(
    'failed source confirmation prevents audio and restores source',
    () async {
      device.failWrite = 2;
      await session.run(6);
      expect(events, isNot(contains('prepare')));
      expect(device.values, original);
      expect(session.restored, isTrue);
    },
  );
  test(
    'busy message contains measured levels and fresh output source in German',
    () async {
      audio.onTone = (_, _) async {
        device.values[6 << 8 | OutIdx.source] = 2;
        throw PlatformException(
          code: 'signalBusy',
          details: {'peakDbfs': -42.0, 'rmsDbfs': -51.5},
        );
      };
      await session.run(6);
      expect(session.error, contains('−42.0 dBFS Peak'));
      expect(session.error, contains('−51.5 dBFS RMS'));
      expect(session.error, contains('Quelle des Ausgangs: SPDIF optical'));
      expect(session.error, isNot(contains('PlatformException')));
      expect(session.text, contains(session.error!));
      expect(device.values, original);
    },
  );
  test(
    'busy preparation reports levels before restoration and never plays a tone',
    () async {
      audio.prepareError = PlatformException(
        code: 'signalBusy',
        details: {'peakDbfs': -55.0, 'rmsDbfs': -65.0},
      );
      await session.run(6);
      expect(audio.tones, 0);
      expect(session.error, contains('−55.0 dBFS Peak'));
      expect(session.error, contains('−65.0 dBFS RMS'));
      expect(session.error, contains('Quelle des Ausgangs: USB 1/2'));
      expect(device.values, original);
      expect(session.restored, isTrue);
    },
  );
  test(
    'routing failure survives restoration, export and shows actual input',
    () async {
      audio.prepareError = PlatformException(
        code: 'routeMismatch',
        details: {
          'diagnostics': {
            'capture': {
              'routedDevice': {'name': 'Handy-Mikrofon', 'type': 15, 'id': 8},
              'requestedDevice': {'name': 'ADI-2 DAC', 'type': 11, 'id': 17},
              'requestedFormat': {
                'sampleRate': 48000,
                'channels': 2,
                'encoding': 4,
              },
              'actualFormat': {
                'sampleRate': 48000,
                'channels': 2,
                'encoding': 4,
              },
              'audioSource': 6,
            },
          },
        },
      );
      await session.run(6);
      expect(audio.tones, 0);
      expect(
        session.error,
        contains('Aufnahme läuft über Handy-Mikrofon statt über den ADI-2'),
      );
      expect(session.diagnosticText, contains('Typ 15, ID 8'));
      expect(session.text, contains('PCM_FLOAT'));
      expect(session.text, contains('VOICE_RECOGNITION'));
      expect(audio.saved.values.last['metadata'], session.metadata);
      expect(session.restored, isTrue);
      expect(device.values, original);
    },
  );

  test(
    'loud USB input exports separate quiet summaries and pre-tone timing',
    () async {
      audio.prepareError = PlatformException(
        code: 'signalBusy',
        details: {
          'peakDbfs': -6.2,
          'rmsDbfs': -11.3,
          'diagnostics': {
            'capture': {
              'routedDevice': {'name': 'ADI-2 DAC', 'type': 11, 'id': 17},
            },
            'quiet': {
              'channels': [
                {
                  'peakDbfs': -6.2,
                  'rmsDbfs': -11.3,
                  'dominantHz': 50.0,
                  'binHz': 11.7,
                  'shape': 'Brummen um 50 Hz',
                },
                {
                  'peakDbfs': -80.0,
                  'rmsDbfs': -90.0,
                  'dominantHz': 1000.0,
                  'binHz': 11.7,
                  'shape': 'schmalbandig / Ton',
                },
              ],
            },
            'timing': {
              'quietStartNs': 100,
              'quietEndNs': 200,
              'firstToneCommandNs': null,
              'firstToneWrittenNs': null,
              'testPlaybackActive': false,
            },
          },
        },
      );
      await session.run(6);
      expect(audio.tones, 0);
      expect(session.error, contains('−6.2 dBFS Peak'));
      expect(session.diagnosticText, contains('L: -6.2'));
      expect(session.diagnosticText, contains('R: -80.0'));
      expect(session.diagnosticText, contains('Brummen um 50 Hz'));
      expect(session.diagnosticText, contains('Testton aktiv: false'));
      expect(session.text, contains('100–200'));
      expect(session.report['metadata'], contains('diagnostics'));
      expect(session.restored, isTrue);
    },
  );

  test('silent muted pre FX uses explicit low-volume post FX fallback and restores volume', () async {
    audio.noPreSignal = true;
    await session.run(9);
    expect(session.fallback, isTrue);
    expect(session.report['grade'], 'OK (post FX)');
    final low = device.writes.indexWhere(
      (w) => w[9 << 8 | OutIdx.volume] == -1000,
    );
    final unmute = device.writes.indexWhere(
      (w) => w[9 << 8 | OutIdx.mute] == 0,
    );
    expect(low, greaterThan(0));
    expect(unmute, greaterThan(low));
    expect(device.values, original);
    expect(session.restored, isTrue);
  });
  test(
    'cancel during tone stops output before restore and leaves partial report',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      audio.onTone = (_, _) => pending.future;
      final run = session.run(3);
      while (audio.tones == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final cancel = session.cancel();
      pending.completeError(PlatformException(code: 'cancelled'));
      await cancel;
      await run;
      expect(session.cancelled, isTrue);
      expect(session.report['grade'], 'Abgebrochen');
      expect(device.values, original);
      expect(session.restored, isTrue);
      expect(events.indexOf('stop'), lessThan(events.lastIndexOf('write')));
    },
  );
  test(
    'failed safety write never starts audio; mutated values still restored',
    () async {
      device.failWrite = 1;
      await session.run(3);
      expect(audio.tones, 0);
      expect(events, isNot(contains('prepare')));
      expect(device.values, original);
      expect(session.restored, isTrue);
      expect(session.error, contains('MIDI readback timeout'));
    },
  );
  test('no recovery journal means no writes when storage fails', () async {
    audio.saveFails = true;
    await session.run(3);
    expect(device.writes, isEmpty);
    expect(audio.tones, 0);
  });
  test(
    'disconnect retains recovery; another device never receives restoration',
    () async {
      audio.onTone = (_, _) async {
        device.connected = false;
        throw StateError('USB removed');
      };
      await session.run(3);
      expect(session.restored, isFalse);
      expect(audio.journal, isNotNull);
      final writes = device.writes.length;
      device.connected = true;
      device.identity = 'other-device';
      await session.retryRestore();
      expect(device.writes.length, writes);
      expect(session.restored, isFalse);
      device.identity = 'original-device';
      await session.retryRestore();
      expect(device.values, original);
      expect(session.restored, isTrue);
      expect(audio.journal, isNull);
    },
  );
  test(
    'failed playback stop keeps Mute/volume protection and journal for retry',
    () async {
      audio.onTone = (_, _) async {
        audio.stopFails = true;
        throw StateError('audio failure');
      };
      await session.run(3);
      expect(session.restored, isFalse);
      expect(audio.journal, isNotNull);
      for (final a in device.outputs) {
        expect(device.values[a << 8 | OutIdx.mute], 1);
      }
      audio.stopFails = false;
      await session.retryRestore();
      expect(device.values, original);
      expect(session.restored, isTrue);
    },
  );
  test('wrong capture sample rate aborts and restores', () async {
    audio.wrongRate = true;
    await session.run(3);
    expect(session.error, contains('Abtastrate'));
    expect(session.restored, isTrue);
    expect(device.values, original);
  });
  test(
    'recovery journal restores state in a new session after process restart',
    () async {
      audio.onTone = (_, _) async {
        device.connected = false;
        throw StateError('lost');
      };
      await session.run(6);
      device.connected = true;
      // Simulate process death releasing only the in-memory ownership flag.
      device.leased = false;
      final recovered = AnalyzerSelfTest(device, audio);
      await recovered.loadRecovery();
      expect(recovered.restored, isFalse);
      await recovered.retryRestore();
      expect(recovered.restored, isTrue);
      expect(device.values, original);
      recovered.dispose();
    },
  );
  test(
    'legacy journal restores after MIDI endpoint changes on app restart',
    () async {
      audio.journal = {
        'device': 'old-midi-endpoint/${Adi2Model.dac.id}',
        'values': {for (final e in original.entries) '${e.key}': e.value},
      };
      device.identity = 'new-midi-endpoint/${Adi2Model.dac.id}';
      device.hardwareIdentity = SelfTestIdentity(
        model: Adi2Model.dac.id,
        variant: 'dac',
      );
      device.values.updateAll(
        (key, value) => (key & 255) == OutIdx.mute ? 1 : 0,
      );
      await session.loadRecovery();
      await session.retryRestore();
      expect(session.restored, isTrue);
      expect(device.values, original);
      expect(audio.journal, isNull);
    },
  );

  test('restart waits for late serial and variant before writes or journal deletion', () async {
    audio.journal = {
      'device': {
        'model': Adi2Model.pro.id,
        'variant': 'pro',
        'serial': 'ab-12 34',
      },
      'values': {for (final e in original.entries) '${e.key}': e.value},
    };
    device.hardwareIdentity = SelfTestIdentity(model: Adi2Model.pro.id);
    final ready = Completer<void>();
    device.readiness = ready.future;
    device.values.updateAll((key, value) => (key & 255) == OutIdx.mute ? 1 : 0);
    await session.loadRecovery();
    final pending = session.retryRestore();
    await Future<void>.delayed(Duration.zero);
    expect(session.running, isTrue);
    expect(device.writes, isEmpty);
    expect(audio.journal, isNotNull);
    device.hardwareIdentity = SelfTestIdentity(
      model: Adi2Model.pro.id,
      variant: 'pro',
      serial: ' AB:1234 ',
    );
    ready.complete();
    await pending;
    expect(session.restored, isTrue);
    expect(device.values, original);
    expect(audio.journal, isNull);
    expect(events.indexOf('clear'), greaterThan(events.lastIndexOf('write')));
  });

  for (final mismatch in ['model', 'variant', 'serial', 'missing serial']) {
    test('$mismatch mismatch retains recovery without device writes', () async {
      audio.journal = {
        'device': {
          'model': Adi2Model.pro.id,
          'variant': 'pro',
          'serial': '1234',
        },
        'values': {for (final e in original.entries) '${e.key}': e.value},
      };
      device.hardwareIdentity = SelfTestIdentity(
        model: mismatch == 'model' ? Adi2Model.dac.id : Adi2Model.pro.id,
        variant: mismatch == 'variant' ? 'pro4ex' : 'pro',
        serial: mismatch == 'serial'
            ? '5678'
            : mismatch == 'missing serial'
            ? null
            : '1234',
      );
      await session.loadRecovery();
      await session.retryRestore();
      expect(session.restored, isFalse);
      expect(device.writes, isEmpty);
      expect(audio.journal, isNotNull);
      expect(
        session.restoreError,
        contains(switch (mismatch) {
          'model' => 'Modell',
          'variant' => 'Variante',
          _ => 'Seriennummer',
        }),
      );
      expect(session.restoreError, isNot(contains('Bad state')));
    });
  }

  test(
    'failed restore confirmation preserves journal until a successful retry',
    () async {
      audio.journal = {
        'device': device.identity,
        'values': {for (final e in original.entries) '${e.key}': e.value},
      };
      await session.loadRecovery();
      device.failWrite = 2;
      await session.retryRestore();
      expect(session.restored, isFalse);
      expect(audio.journal, isNotNull);
      expect(events, isNot(contains('clear')));
      device.failWrite = null;
      await session.retryRestore();
      expect(session.restored, isTrue);
      expect(device.values, original);
      expect(audio.journal, isNull);
    },
  );

  test(
    'final readback mismatch preserves recovery until exact values return',
    () async {
      audio.journal = {
        'device': device.identity,
        'values': {for (final e in original.entries) '${e.key}': e.value},
      };
      await session.loadRecovery();
      device.onRead = () => {...device.values, 9 << 8 | OutIdx.source: 0};
      await session.retryRestore();
      expect(session.restored, isFalse);
      expect(session.restoreError, contains('Geräterücklesung'));
      expect(audio.journal, isNotNull);
      expect(events, isNot(contains('clear')));
      device.onRead = null;
      await session.retryRestore();
      expect(session.restored, isTrue);
      expect(audio.journal, isNull);
    },
  );

  test(
    'device change during restoration prevents remaining writes and deletion',
    () async {
      audio.journal = {
        'device': device.identity,
        'values': {for (final e in original.entries) '${e.key}': e.value},
      };
      await session.loadRecovery();
      device.afterWrite = () async {
        device.identity = 'different-endpoint';
      };
      await session.retryRestore();
      expect(session.restored, isFalse);
      // The initial Mute was confirmed; no source, volume or original Mute may follow.
      expect(device.writes.length, 1);
      expect(
        device.writes.single.keys.every((key) => (key & 255) == OutIdx.mute),
        isTrue,
      );
      expect(audio.journal, isNotNull);
    },
  );

  test(
    'emergency reset changes only source and loopback on all outputs',
    () async {
      await session.loadRecovery();
      await session.resetTestState();
      for (final a in device.outputs) {
        expect(device.values[a << 8 | OutIdx.source], 0);
        expect(device.values[a << 8 | OutIdx.loopback], 0);
        expect(
          device.values[a << 8 | OutIdx.mute],
          original[a << 8 | OutIdx.mute],
        );
        expect(
          device.values[a << 8 | OutIdx.volume],
          original[a << 8 | OutIdx.volume],
        );
      }
      expect(device.writes.single.length, 6);
      expect(events.indexOf('stop'), lessThan(events.indexOf('write')));
      expect(session.status, contains('Mute am Gerät prüfen'));
      expect(device.leased, isFalse);
      expect(audio.journal, isNull);
    },
  );

  test(
    'emergency reset cannot bypass a valid or corrupt recovery file',
    () async {
      audio.journal = {'device': device.identity, 'values': <String, int>{}};
      // Even before loading the journal, the emergency action rechecks storage.
      await session.resetTestState();
      expect(device.writes, isEmpty);
      expect(audio.journal, isNotNull);
      expect(session.canResetTestState, isFalse);
      await session.loadRecovery();
      await session.resetTestState();
      expect(device.writes, isEmpty);
      expect(audio.journal, isNotNull);
    },
  );

  test(
    'emergency discovery loads a valid journal for immediate restore retry',
    () async {
      audio.journal = {
        'device': device.identity,
        'values': {for (final e in original.entries) '${e.key}': e.value},
      };
      await session.resetTestState();
      expect(device.writes, isEmpty);
      expect(session.canResetTestState, isFalse);
      expect(audio.journal, isNotNull);
      await session.retryRestore();
      expect(session.restored, isTrue);
      expect(device.values, original);
      expect(audio.journal, isNull);
    },
  );

  test('failed emergency playback stop prevents all routing writes', () async {
    audio.stopFails = true;
    await session.resetTestState();
    expect(device.writes, isEmpty);
    expect(session.status, contains('nicht aufgehoben'));
    expect(device.leased, isFalse);
  });

  test('failed ownership acquisition never stops another test or deletes its journal', () async {
    device.leased = true;
    audio.journal = {'device': 'another test'};
    await session.run(3);
    expect(audio.stops, 0);
    expect(device.writes, isEmpty);
    expect(audio.journal, isNotNull);
    expect(device.leased, isTrue);
  });
  test('invalid recovery cannot be discarded or reported restored', () async {
    audio.journal = {'device': device.identity, 'values': <String, int>{}};
    await session.loadRecovery();
    expect(session.restored, isFalse);
    await session.retryRestore();
    expect(session.restored, isFalse);
    expect(audio.journal, isNotNull);
    expect(device.writes, isEmpty);
  });
  test(
    'evaluation rejects gain errors, missing neighbours and absent response',
    () {
      final r = AnalyzerBandResolution.third;
      final high = SelfTestBandResult(
        r,
        16,
        TestSelfTestAudio.measurement(r, 16, gain: 2),
      );
      expect(high.ok, isFalse);
      final leaking = TestSelfTestAudio.measurement(r, 16);
      (leaking['levels'] as List)[15] = -22.0;
      expect(SelfTestBandResult(r, 16, leaking).separationOk, isFalse);
      expect(
        () => SelfTestBandResult(r, 16, {
          'levels': [double.nan],
          'trace': [],
        }),
        throwsStateError,
      );
      final noResponse = TestSelfTestAudio.measurement(r, 16);
      noResponse['trace'] = <Map>[];
      expect(SelfTestBandResult(r, 16, noResponse).ok, isFalse);
    },
  );

  test(
    'relative sine reference uses the louder channel and rejects missing RMS',
    () {
      final r = AnalyzerBandResolution.third;
      final boosted = TestSelfTestAudio.measurement(r, 16, gain: 14);
      boosted['broadbandRmsDbfs'] = [-90.0, -9.01029995664];
      final relative = SelfTestBandResult(r, 16, boosted, bitPerfect: false);
      expect(relative.absoluteLevelOk, isFalse);
      expect(relative.relativeDeviationDb, closeTo(0, .00001));
      expect(relative.ok, isTrue);
      expect(SelfTestBandResult(r, 16, boosted).ok, isFalse);
      boosted.remove('broadbandRmsDbfs');
      expect(SelfTestBandResult(r, 16, boosted, bitPerfect: false).ok, isFalse);
    },
  );

  test('relative evaluation detects analyzer error, clipping and neighbour leakage', () {
    final r = AnalyzerBandResolution.third;
    for (final extra in [
      {
        'broadbandRmsDbfs': [-12.0, -12.0],
      },
      {'clipped': true},
      {'measurementValid': false},
      {'trace': <Map>[]},
    ]) {
      expect(
        SelfTestBandResult(r, 16, {
          ...TestSelfTestAudio.measurement(r, 16, gain: 14),
          ...extra,
        }, bitPerfect: false).ok,
        isFalse,
      );
    }
    final leaking = TestSelfTestAudio.measurement(r, 16, gain: 14);
    (leaking['levels'] as List)[15] = -8.0;
    expect(SelfTestBandResult(r, 16, leaking, bitPerfect: false).ok, isFalse);
  });

  for (final reason in [
    'API < 34',
    'Kein Bit-Perfect-Mixer',
    'Mixer abgelehnt',
    'Status unbekannt',
  ]) {
    test('normal playback uses per-tone relative grading: $reason', () async {
      audio.preparation = {
        'sampleRate': 48000,
        'playback': {
          'bitPerfect': false,
          'mixerFallbackReason': reason,
          'availableEffects': 'Klangeffekt (Hersteller)',
          'outputEffects': 'Aktivierung unbekannt',
        },
      };
      audio.onTone = (r, i) async =>
          TestSelfTestAudio.measurement(r, i, gain: i % 2 == 0 ? 14 : -7);
      await session.run(6);
      expect(session.report['grade'], 'OK');
      expect(session.report['evaluationBasis'], 'relative');
      expect(
        session.results.every((r) => !r.absoluteLevelOk && r.relativeLevelOk),
        isTrue,
      );
      expect(
        session.warnings,
        contains('System-Klangeffekte können die Messung verfälschen'),
      );
      expect(session.text, contains('Wiedergabe: normal + Effekte'));
      expect(session.text, contains('Δ absolut'));
      expect(session.text, contains('Δ relativ'));
      expect(session.csv, contains('relative_deviation_db'));
      expect(session.lastResult!.text, contains('Δ relativ'));
      expect(session.lastResult!.text, contains('Klangeffekt (Hersteller)'));
      final bands = session.report['bands'] as List;
      expect(bands, everyElement(containsPair('evaluationBasis', 'relative')));
      expect((bands.first as Map)['absoluteLevelOk'], isFalse);
      expect(session.restored, isTrue);
      expect(
        utf8.encode(jsonEncode(session.report)).length,
        lessThan(SelfTestAudio.writeLimit),
      );
    });
  }

  test(
    'missing playback status uses relative grading and cannot pass without RMS',
    () async {
      audio.preparation = {'sampleRate': 48000};
      audio.onTone = (r, i) async =>
          TestSelfTestAudio.measurement(r, i)..remove('broadbandRmsDbfs');
      await session.run(6);
      expect(session.report['grade'], 'Abweichung');
      expect(session.bitPerfect, isFalse);
      expect(session.results.every((r) => !r.levelOk), isTrue);
    },
  );

  test('verified bit-perfect retains absolute grading despite correct relative values', () async {
    audio.onTone = (r, i) async =>
        TestSelfTestAudio.measurement(r, i, gain: 14);
    await session.run(6);
    expect(session.report['grade'], 'Abweichung');
    expect(session.report['evaluationBasis'], 'absolute');
    expect(session.text, contains('Wiedergabe: bit-perfect'));
    expect(
      session.results.every((r) => r.relativeLevelOk && !r.absoluteLevelOk),
      isTrue,
    );
  });

  test('losing bit-perfect during a tone switches earlier and later bands to relative', () async {
    var calls = 0;
    audio.onTone = (r, i) async => {
      ...TestSelfTestAudio.measurement(r, i, gain: 14),
      if (++calls == 4) 'playbackAfter': {'bitPerfect': false},
    };
    await session.run(6);
    expect(session.report['grade'], 'OK');
    expect(session.bitPerfect, isFalse);
    expect(
      session.results.every((r) => r.evaluationBasis == 'relative'),
      isTrue,
    );
    expect(session.warnings.join(), contains('nicht durchgehend bestätigt'));
  });

  test('normal playback post FX probe is calibrated relative to RMS', () async {
    audio.noPreSignal = true;
    audio.preparation = {
      'sampleRate': 48000,
      'playback': {'bitPerfect': false},
    };
    audio.onTone = (r, i) async =>
        TestSelfTestAudio.measurement(r, i, gain: 14);
    await session.run(6);
    expect(session.report['grade'], 'OK (post FX)');
    expect(session.fallback, isTrue);
    expect(session.restored, isTrue);
  });

  test(
    'broadband RMS and playback diagnostics survive JSON/CSV/history',
    () async {
      audio.onTone = (r, i) async => {
        ...TestSelfTestAudio.measurement(r, i),
        'broadbandRmsDbfs': [-23.0103, -23.0103],
        'broadbandPeakDbfs': [-20.0, -20.0],
        'bandMinusBroadbandSineDb': 0.0,
        'stable': true,
        'measurementValid': true,
        'stableWindowSeconds': .4,
        'invalidReason': '',
        'stabilityLimitDb': .5,
        'playbackBefore': {
          'encoding': 4,
          'bitPerfect': true,
          'trackGain': 1,
          'appVolumeShaper': false,
        },
        'underrunDelta': 0,
        'commandToCaptureMs': 105.0,
      };
      await session.run(6);
      expect(session.report['grade'], 'OK');
      final bands = session.report['bands'] as List;
      expect((bands.first as Map)['broadbandPeakDbfs'], [-20.0, -20.0]);
      expect(
        bands,
        everyElement(containsPair('broadbandRmsDbfs', [-23.0103, -23.0103])),
      );
      expect(
        (bands.first as Map)['playbackBefore'],
        containsPair('trackGain', 1),
      );
      expect(
        session.csv,
        contains('broadband_rms_l_dbfs,broadband_rms_r_dbfs'),
      );
      expect(session.csv, contains('-23.0103,-23.0103,true'));
      expect(
        session.lastResult!.text,
        contains('Breitband-RMS L/R -23.0/-23.0 dBFS'),
      );
      expect(
        utf8.encode(jsonEncode(session.report)).length,
        lessThan(SelfTestAudio.writeLimit),
      );
    },
  );

  test('specific invalid-window reasons survive all report formats', () async {
    audio.onTone = (r, i) async => {
      ...TestSelfTestAudio.measurement(r, i),
      'stable': false,
      'measurementValid': false,
      'invalidReason': 'bandSpan, underrun',
      'bandSpanDb': .6,
      'stabilityLimitDb': .5,
      'underrunDelta': 1,
    };
    await session.run(6);
    expect(session.report['grade'], 'Abweichung');
    expect(session.results.every((r) => !r.measurementValid), isTrue);
    expect(session.text, contains('Messfenster ungültig (bandSpan, underrun)'));
    expect(
      session.lastResult!.text,
      contains('Messfenster ungültig (bandSpan, underrun)'),
    );
    expect(session.csv, contains('evaluation_basis,invalid_reason'));
    expect(session.csv, contains(',"bandSpan, underrun"'));
    expect(
      (session.report['bands'] as List).first,
      containsPair('stabilityLimitDb', .5),
    );
  });

  test(
    'unstable, clipped, underrunning or volume-changing tones cannot pass',
    () {
      final r = AnalyzerBandResolution.third;
      for (final invalid in [
        {'stable': false},
        {'measurementValid': false},
        {'clipped': true},
        {'underrunDelta': 1},
        {'volumeStable': false},
        {'playbackStable': false},
        {'dropout': true},
      ]) {
        final result = SelfTestBandResult(r, 16, {
          ...TestSelfTestAudio.measurement(r, 16),
          ...invalid,
        });
        expect(result.levelOk, isTrue);
        expect(result.separationOk, isTrue);
        expect(result.ok, isFalse);
      }
      expect(
        () => SelfTestBandResult(r, 16, {
          ...TestSelfTestAudio.measurement(r, 16),
          'broadbandRmsDbfs': [-23, double.nan],
        }),
        throwsStateError,
      );
    },
  );

  test(
    'response ignores an isolated overshoot and reports the sustained crossing',
    () {
      final result = SelfTestBandResult(AnalyzerBandResolution.third, 16, {
        ...TestSelfTestAudio.measurement(AnalyzerBandResolution.third, 16),
        'trace': [
          {'seconds': 1 / 60, 'db': -21},
          {'seconds': 2 / 60, 'db': -40},
          for (var frame = 3; frame <= 7; frame++)
            {'seconds': frame / 60, 'db': -20},
        ],
      });
      expect(result.responseMs, closeTo(50, .001));
      final tooShort = TestSelfTestAudio.measurement(
        AnalyzerBandResolution.third,
        16,
      );
      tooShort['trace'] = [
        {'seconds': 1 / 60, 'db': -20},
      ];
      expect(
        SelfTestBandResult(AnalyzerBandResolution.third, 16, tooShort).ok,
        isFalse,
      );
    },
  );
}
