import 'dart:io';
import 'dart:math' as math;

import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/dev/analyzer_selftest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('run 4 level replay: 203/206 OK if capture window is stable', () {
    // TXT has no PCM, drift, clipping, underrun or per-window timestamps.
    // This replays measured levels, NOT the missing window validity evidence.
    final lines = File('test/fixtures/selftest_hw_run4.txt').readAsLinesSync();
    final row = RegExp(r'^1/(3|6|12) ([\d.]+) Hz: (.*)$');
    final results = <SelfTestBandResult>[];
    var previouslyInvalid = 0;
    var knownNeighbours = 0;
    for (final line in lines) {
      final match = row.firstMatch(line);
      if (match == null) continue;
      final resolution = AnalyzerBandResolution.values.singleWhere(
        (r) => r.bandsPerOctave == int.parse(match[1]!),
      );
      final hz = double.parse(match[2]!);
      final index = List.generate(resolution.count, (i) => i).reduce(
        (a, b) =>
            (resolution.centre(a) - hz).abs() <
                (resolution.centre(b) - hz).abs()
            ? a
            : b,
      );
      expect((resolution.centre(index) - hz).abs(), lessThan(.051));
      final text = match[3]!;
      final db = double.parse(RegExp(r'(-?[\d.]+) dBFS').firstMatch(text)![1]!);
      final rms = RegExp(r'Breitband-RMS L/R (-?[\d.]+)/(-?[\d.]+)')
          .firstMatch(text)!;
      final levels = List<double>.filled(resolution.count, -120);
      levels[index] = db;
      final neighbours = RegExp(r'Nachb\. ([-\d./]+) dBFS').firstMatch(text);
      if (neighbours != null) {
        final values = neighbours[1]!.split('/').map(double.parse).toList();
        expect(
          values.length,
          index == 0 || index == resolution.count - 1 ? 1 : 2,
        );
        if (index > 0) levels[index - 1] = values.first;
        if (index + 1 < levels.length) levels[index + 1] = values.last;
        knownNeighbours++;
      } else {
        // Already-OK rows omit neighbours/response; no invented measurements.
        expect(text, startsWith('OK;'));
      }
      if (text.contains('Messfenster ungültig')) previouslyInvalid++;
      final response = RegExp(r'([\d.]+) ms').firstMatch(text);
      final start = response == null ? .1 : double.parse(response[1]!) / 1000;
      final result = SelfTestBandResult(resolution, index, {
        'levels': levels,
        'broadbandRmsDbfs': [double.parse(rms[1]!), double.parse(rms[2]!)],
        // Controlled stable-window assumption; native PCM tests check the rule.
        'stable': true,
        'measurementValid': true,
        'clipped': false,
        'dropout': false,
        'underrunDelta': 0,
        'volumeStable': true,
        'playbackStable': true,
        'trace': [
          for (var i = 0; i <= 4; i++) {'seconds': start + i / 60, 'db': db},
        ],
      }, bitPerfect: false);
      expect(
        result.relativeDeviationDb,
        closeTo(
          double.parse(RegExp(r'Δ relativ (-?[\d.]+)').firstMatch(text)![1]!),
          .16,
        ),
      );
      if (neighbours != null) expect(result.separationOk, isTrue);
      if (response != null) {
        expect(result.responseMs, closeTo(start * 1000, .001));
      }
      results.add(result);
    }
    expect(results.length, 206);
    expect(
      results.map((r) => '${r.resolution}/${r.index}').toSet().length,
      206,
    );
    expect(previouslyInvalid, 175);
    expect(knownNeighbours, 175);
    expect(results.where((r) => r.ok).length, 203);
    expect(
      results
          .where((r) => !r.ok)
          .every(
            (r) =>
                r.resolution.centre(r.index) < 40 &&
                !r.relativeLevelOk &&
                r.measurementValid,
          ),
      isTrue,
    );
    // Do not silently clear real failure flags on otherwise accurate levels.
    final sample = results.firstWhere((r) => r.ok);
    for (final failure in [
      {'stable': false},
      {'clipped': true},
      {'dropout': true},
      {'underrunDelta': 1},
      {'volumeStable': false},
      {'playbackStable': false},
    ]) {
      final levels = List<double>.filled(sample.resolution.count, -120);
      levels[sample.index] = sample.db;
      final invalid = SelfTestBandResult(sample.resolution, sample.index, {
        'levels': levels,
        'trace': <Map<String, double>>[],
        'broadbandRmsDbfs': sample.broadbandRmsDbfs,
        ...failure,
      }, bitPerfect: false);
      expect(invalid.measurementValid, isFalse);
    }
  });

  test('low bands receive 40 periods, other windows >=200 ms / 10 periods per half', () {
    for (final r in AnalyzerBandResolution.values) {
      for (var i = 0; i < r.count; i++) {
        final hz = r.centre(i);
        final window = selfTestWindow(r, i);
        expect(window / 2, greaterThanOrEqualTo(math.max(.2, 10 / hz) - 1e-9));
        if (hz < 40) {
          expect(window * hz, greaterThanOrEqualTo(40 - 1e-9));
          expect(selfTestSettling(r, i) * hz, greaterThanOrEqualTo(40 - 1e-9));
        }
      }
    }
  });
}
