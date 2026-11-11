import 'package:adi2_remote/analyzer/header_content.dart';
import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/easy/easy_layout.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final settings = AppSettings.instance;
  test(
    'band resolution defaults to third, persists and rejects unknown values',
    () async {
      for (final stored in [null, 99]) {
        SharedPreferences.setMockInitialValues({
          'analyzer_bands_per_octave': ?stored,
        });
        await settings.load();
        expect(settings.analyzerBandResolution, AnalyzerBandResolution.third);
      }
      for (final resolution in AnalyzerBandResolution.values) {
        SharedPreferences.setMockInitialValues({
          'analyzer_bands_per_octave': resolution.bandsPerOctave,
        });
        await settings.load();
        expect(settings.analyzerBandResolution, resolution);
        await settings.setAnalyzerBandResolution(resolution);
        await settings.load();
        expect(settings.analyzerBandResolution, resolution);
      }
    },
  );
  test(
    'legacy header switches migrate without losing player fallback',
    () async {
      for (final player in [false, true]) {
        for (final status in [false, true]) {
          SharedPreferences.setMockInitialValues({
            'show_player': player,
            'show_status': status,
          });
          await settings.load();
          expect(
            settings.headerContent,
            player
                ? HeaderContent.player
                : status
                ? HeaderContent.status
                : HeaderContent.none,
          );
          expect(settings.showStatus, status);
        }
      }
    },
  );
  test('each header choice persists; legacy setters clear analyzer', () async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
    for (final value in HeaderContent.values) {
      await settings.setHeaderContent(value);
      await settings.load();
      expect(settings.headerContent, value);
    }
    await settings.setHeaderContent(HeaderContent.analyzer);
    await settings.setShowPlayer(true);
    await settings.load();
    expect(settings.headerContent, HeaderContent.player);
    await settings.setHeaderContent(HeaderContent.analyzer);
    await settings.setShowStatus(true);
    await settings.load();
    expect(settings.headerContent, HeaderContent.status);
  });
  test(
    'analyzer survives custom slots, page copies and independent outputs',
    () async {
      SharedPreferences.setMockInitialValues({});
      await settings.load();
      final base = EasyLayout(tiles: [])
          .withHeaderContent(HeaderContent.analyzer);
      var split = base.setSamePageForAllOutputs(false, [
        3,
        6,
        9,
      ], selectedOutput: 6);
      split = split.withPage(
        3,
        split.pageFor(3).withHeaderContent(HeaderContent.none),
      );
      split = split.copyPageTo(6, [9]);
      await settings.saveEasySlot(Adi2Variant.pro, 2, split);
      await settings.activateEasySlot(Adi2Variant.pro, 2);
      await settings.load();
      final read = settings.easyLayout(Adi2Variant.pro);
      expect(read.pageFor(3).headerContent, HeaderContent.none);
      expect(read.pageFor(6).headerContent, HeaderContent.analyzer);
      expect(read.pageFor(9).headerContent, HeaderContent.analyzer);
      expect(
        read.setSamePageForAllOutputs(true, [
          3,
          6,
          9,
        ], selectedOutput: 9).headerContent,
        HeaderContent.analyzer,
      );
    },
  );
}
