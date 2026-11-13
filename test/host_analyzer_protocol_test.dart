import 'dart:convert';
import 'dart:math' as math;

import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/host/host_analyzer_cipher.dart';
import 'package:adi2_remote/host/host_analyzer_protocol.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

AnalyzerFrame transportFrame(int rate, AnalyzerBandResolution resolution) {
  final random = math.Random(12);
  List<double> bins(int size) => List.generate(
    size ~/ 2 + 1,
    (_) => math.pow(10, (-110 + random.nextDouble() * 110) / 20).toDouble(),
  );
  return AnalyzerFrame(
    sampleRate: rate,
    spectrum: bins(analyzerFastSize(rate)),
    bassSpectrum: bins(analyzerBassSize(rate)),
    bassBinHz: rate / analyzerBassSize(rate),
    bandResolution: resolution,
    bandLevels: List.filled(resolution.count, -23.4),
    peak: [-0.1, -12.3],
    rms: [-5.6, -15.8],
    meterPeak: [-0.5, -12.6],
    meterRms: [-6.7, -16.7],
    clipped: [true, false],
    seconds: 0.13333333333333333,
  );
}

void main() {
  test('ChaCha20 matches RFC 8439 section 2.4.2 published cipher vector', () {
    List<int> hex(String s) => List.generate(
      s.length ~/ 2,
      (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16),
    );
    final plain = utf8.encode(
      "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.",
    );
    final key = List.generate(32, (i) => i);
    final nonce = hex('000000000000004a00000000');
    final cipher = hostAnalyzerCipher(plain, key, nonce);
    expect(
      cipher,
      hex(
        '6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0b'
        'f91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d807'
        'ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab77937365'
        'af90bbf74a35be6b40b8eedf2785e42874d',
      ),
    );
    expect(hostAnalyzerCipher(cipher, key, nonce), plain);
  });

  test('Encrypted analyzer envelope authenticates before decrypt, sequences and directions differ', () {
    final key = randomToken();
    final sender = HostEnvelope(key, outgoing: 'server', incoming: 'client');
    final receiver = HostEnvelope(key, outgoing: 'client', incoming: 'server');
    final first = sender.seal('analyzer_error', {
      'code': 'analyzer_permission',
    });
    final second = sender.seal('analyzer_error', {
      'code': 'analyzer_permission',
    });
    expect(first, isNot(contains('analyzer_permission')));
    final a = decodeHostMessage(first), b = decodeHostMessage(second);
    expect(a['body'], isNot(b['body']));
    expect(
      () => receiver.open({...a, 'body': b['body']}),
      throwsFormatException,
    );
    expect(receiver.open(a)['code'], 'analyzer_permission');
    expect(() => receiver.open(a), throwsFormatException);
    expect(receiver.open(b)['code'], 'analyzer_permission');
    final opposite = HostEnvelope(key, outgoing: 'client', incoming: 'server');
    expect(
      decodeHostMessage(
        opposite.seal('analyzer_error', {'code': 'analyzer_permission'}),
      )['body'],
      isNot(a['body']),
    );
  });

  for (final rate in [44100, 48000, 96000, 192000, 384000, 768000]) {
    for (final resolution in AnalyzerBandResolution.values) {
      test(
        'Compact frame roundtrip and encrypted data rate $rate/$resolution',
        () {
          final source = transportFrame(rate, resolution);
          final payload = encodeHostAnalyzerFrame(source);
          payload.addAll({
            'device': 'ADI-2 Pro FS R Black Edition',
            'calibrationIdentity': {
              'hostManufacturer': 'macOS',
              'hostModel': 'MacBookPro18,3 · Studio-MacBook',
              'usbName': 'ADI-2 Pro FS R Black Edition',
              'usbSerial': '12345678',
            },
          });
          final key = randomToken();
          final wire = HostEnvelope(
            key,
            outgoing: 'server',
            incoming: 'client',
          ).seal('analyzer_frame', payload);
          final decoded = decodeHostAnalyzerFrame(
            HostEnvelope(
              key,
              outgoing: 'client',
              incoming: 'server',
            ).open(decodeHostMessage(wire)),
          );
          expect(decoded.sampleRate, rate);
          expect(decoded.seconds, source.seconds);
          expect(decoded.binHz, source.binHz);
          expect(decoded.bassBinHz, source.bassBinHz);
          expect(decoded.bandResolution, resolution);
          expect(decoded.bandLevels, source.bandLevels);
          expect(decoded.peak, source.peak);
          expect(decoded.rms, source.rms);
          expect(decoded.displayPeak, source.displayPeak);
          expect(decoded.displayRms, source.displayRms);
          expect(decoded.clipped, source.clipped);
          for (var i = 0; i < decoded.spectrum.length; i++) {
            expect(
              amplitudeDb(decoded.spectrum[i]),
              closeTo(amplitudeDb(source.spectrum[i]), 0.051),
            );
          }
          for (var i = 0; i < decoded.bassSpectrum.length; i++) {
            expect(
              amplitudeDb(decoded.bassSpectrum[i]),
              closeTo(amplitudeDb(source.bassSpectrum[i]), 0.051),
            );
          }
          // Legacy fallback retains its precision and uses a reduced rate.
          expect((utf8.encode(wire).length + 4 + 15) * 6.25, lessThan(30000));
          expect(decoded.calibrated(3).binHz, source.binHz);
        },
      );
    }
  }

  test(
    'Highest common analyzer version, including absent legacy capability',
    () {
      expect(negotiateHostAnalyzerVersion(null), 0);
      expect(negotiateHostAnalyzerVersion('2'), 0);
      expect(negotiateHostAnalyzerVersion(0), 0);
      expect(negotiateHostAnalyzerVersion(1), 1);
      expect(negotiateHostAnalyzerVersion(2), 2);
      expect(negotiateHostAnalyzerVersion(9), 2);
      expect(hostAnalyzerInterval, const Duration(milliseconds: 20));
    },
  );

  for (final rate in [44100, 48000, 96000, 192000, 384000, 768000]) {
    for (final resolution in AnalyzerBandResolution.values) {
      for (final bars in [false, true]) {
        test(
          'v2 quantization, selected data and encrypted budget $rate/$resolution/$bars',
          () {
            final source = transportFrame(rate, resolution);
            final p = encodeHostAnalyzerFrameV2(source, bars: bars);
            expect(
              p.keys,
              unorderedEquals(['v', 'ms', 'r', bars ? 'b' : 's', 'm', 'c']),
            );
            final key = randomToken();
            final wire = HostEnvelope(
              key,
              outgoing: 'server',
              incoming: 'client',
            ).seal('analyzer_frame', p);
            final decoded = decodeHostAnalyzerFrame({
              'sampleRate': rate,
              ...HostEnvelope(
                key,
                outgoing: 'client',
                incoming: 'server',
              ).open(decodeHostMessage(wire)),
            });
            expect(decoded.sampleRate, rate);
            expect(decoded.logSpectrum, isTrue);
            expect(decoded.calibrated(2).logSpectrum, isTrue);
            expect(decoded.bandResolution, resolution);
            expect(decoded.bassSpectrum, isEmpty);
            expect(decoded.clipped, source.clipped);
            expect(decoded.seconds, closeTo(source.seconds, .00051));
            for (var i = 0; i < 2; i++) {
              expect(decoded.peak[i], closeTo(source.peak[i], .25));
              expect(decoded.rms[i], closeTo(source.rms[i], .25));
              expect(
                decoded.displayPeak[i],
                closeTo(source.displayPeak[i], .25),
              );
              expect(decoded.displayRms[i], closeTo(source.displayRms[i], .25));
            }
            if (bars) {
              expect(decoded.spectrum, isEmpty);
              for (var i = 0; i < resolution.count; i++) {
                expect(
                  decoded.bandLevels[i],
                  closeTo(source.bandLevels[i], .25),
                );
              }
            } else {
              expect(decoded.spectrum, hasLength(hostAnalyzerColumns));
              expect(decoded.bandLevels, isEmpty);
              final expected = logSpectrumDb(
                analyzerLineDb(source.spectrum),
                source.binHz,
                hostAnalyzerColumns,
              );
              final bass = logSpectrumDb(
                analyzerLineDb(source.bassSpectrum),
                source.bassBinHz,
                hostAnalyzerColumns,
              );
              for (var i = 0; i < expected.length; i++) {
                final blend =
                    ((frequencyAt(i / (expected.length - 1)) - 250) / 100)
                        .clamp(0.0, 1.0);
                final db = bass[i] * (1 - blend) + expected[i] * blend;
                expect(
                  amplitudeDb(decoded.spectrum[i]),
                  closeTo(db, db < -115 ? 5 : .251),
                );
              }
            }
            // Conservative 16-digit sequence number plus WebSocket frame header.
            final bytes = utf8.encode(wire).length + 15 + 4;
            expect(bytes, lessThan(1200));
            expect(bytes * 25, lessThan(30000));
          },
        );
      }
    }
  }

  test('v2 floor, positive meter headroom and malformed data', () {
    final f = transportFrame(48000, AnalyzerBandResolution.third);
    final p = encodeHostAnalyzerFrameV2(f);
    final db = {...p, 'sampleRate': 48000};
    for (final bad in [
      {...db, 'sampleRate': null},
      {...db, 'ms': 0},
      {...db, 'ms': 2001},
      {...db, 'r': 4},
      {...db, 'c': 4},
      {...db, 'm': 'AA=='},
      {...db, 's': base64Encode(List.filled(257, 0))},
      {...db, 'b': '', 's': ''},
      {...db, 's': '!'},
    ]) {
      expect(() => decodeHostAnalyzerFrame(bad), throwsFormatException);
    }
    final extremes = {
      ...db,
      'm': base64Encode([0, 1, 255, 254, 241, 230, 1, 0]),
    };
    final decoded = decodeHostAnalyzerFrame(extremes);
    expect(decoded.peak, [-120, -115]);
    expect(decoded.rms, [12, 11.5]);
    expect(resampleLogSpectrum([-40, -1, -40, -40, -40], 2).first, -1);
  });

  test('Reject malformed/oversized frames and unsupported resolution', () {
    final p = encodeHostAnalyzerFrame(
      transportFrame(48000, AnalyzerBandResolution.third),
    );
    for (final bad in [
      {...p, 'seconds': double.nan},
      {...p, 'sampleRate': 0},
      {...p, 'bandResolution': 999},
      {...p, 'meters': 'AA=='},
      {...p, 'spectrum': base64Encode(List.filled(5000, 0))},
      {...p, 'clip': 9},
      {...p, 'v': 9},
      {...p, 'bands': ''},
    ]) {
      expect(() => decodeHostAnalyzerFrame(bad), throwsFormatException);
    }
  });
}
