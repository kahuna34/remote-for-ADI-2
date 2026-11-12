// Einstellungen der App selbst (nicht des Geräts), gespeichert auf dem Handy.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'easy/easy_layout.dart';
import 'analyzer/header_content.dart';
import 'analyzer/analyzer_dsp.dart';
import 'protocol/adi2_params.dart';

enum TabletExtraContent { eq, analyzer, status, player }

class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  /// Hauptansicht wechselt zum Ausgang, den das Gerät als aktiv meldet
  /// (z. B. beim Einstecken eines Kopfhörers). Wie im Original: Standard an.
  bool autoSwitchOutput = true;

  bool updateCheck = true;
  DateTime? lastUpdateCheck;
  String? skippedUpdateVersion;
  String? availableUpdateVersion;
  String? availableUpdateUrl;

  Future<void> setUpdateCheck(bool value) {
    updateCheck = value;
    notifyListeners();
    return _persistEasy((prefs) => prefs.setBool('update_check', value));
  }

  Future<void> saveUpdateState(
    DateTime? last,
    String? skipped, {
    String? version,
    String? url,
  }) {
    availableUpdateVersion = version;
    availableUpdateUrl = url;
    lastUpdateCheck = last;
    skippedUpdateVersion = skipped;
    return _persistEasy((prefs) async {
      if (last != null) {
        await prefs.setString('last_update_check', last.toIso8601String());
      }
      if (skipped != null) {
        await prefs.setString('skipped_update_version', skipped);
      }
      if (version != null && url != null) {
        await prefs.setString('available_update_version', version);
        await prefs.setString('available_update_url', url);
      } else {
        await prefs.remove('available_update_version');
        await prefs.remove('available_update_url');
      }
      return true;
    });
  }

  /// Status-Seite: Lautstärke als Ausgangspegel in dBu statt dBFS.
  bool statusInDbu = false;

  /// EQ-Seiten dürfen durch Drehen automatisch ins Vollbild wechseln.
  bool autoFullscreenEq = true;

  TabletExtraContent tabletExtraContent = TabletExtraContent.eq;

  Future<void> setTabletExtraContent(TabletExtraContent content) {
    tabletExtraContent = content;
    notifyListeners();
    return _persistEasy(
      (prefs) => prefs.setString('tablet_extra_content', content.name),
    );
  }

  bool easyMode = false;
  bool showAnalyzer = false;
  AnalyzerBandResolution analyzerBandResolution = AnalyzerBandResolution.third;

  final Map<String, bool> _daFilterSdLd = {};
  final Map<String, int> _daFilterProbePending = {};
  Future<void>? _daFilterLoad;
  Future<void>? _daFilterWrites;

  bool? daFilterSdLd(String? serial) => _daFilterSdLd[serial];
  int? daFilterProbePending(String serial) => _daFilterProbePending[serial];

  Future<void> loadDaFilterSettings() =>
      _daFilterLoad ??= _loadDaFilterSettings();

  Future<void> _loadDaFilterSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _daFilterSdLd.clear();
    _daFilterProbePending.clear();
    for (final key in ['da_filter_sd_ld', 'da_filter_probe_pending']) {
      try {
        final stored = jsonDecode(prefs.getString(key) ?? '{}');
        if (stored is! Map) continue;
        for (final entry in stored.entries) {
          if (entry.key is! String || (entry.key as String).isEmpty) continue;
          final serial = entry.key as String, value = entry.value;
          if (key == 'da_filter_sd_ld' && value is bool) {
            _daFilterSdLd[serial] = value;
          } else if (key == 'da_filter_probe_pending' &&
              value is int &&
              value >= 0 &&
              value <= 5) {
            _daFilterProbePending[serial] = value;
          }
        }
      } on FormatException {
        // Beschädigte Einträge gelten als unbekannt.
      }
    }
  }

  Future<void> setDaFilterSdLd(String serial, bool available) =>
      _persistDaFilter('da_filter_sd_ld', _daFilterSdLd, serial, available);

  Future<void> setDaFilterProbePending(String serial, int? original) =>
      _persistDaFilter(
        'da_filter_probe_pending',
        _daFilterProbePending,
        serial,
        original,
      );

  Future<void> _persistDaFilter<T>(
    String key,
    Map<String, T> values,
    String serial,
    T? value,
  ) {
    Future<void> persist() async {
      await loadDaFilterSettings();
      final next = Map<String, T>.of(values);
      if (value == null) {
        next.remove(serial);
      } else {
        next[serial] = value;
      }
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(key, jsonEncode(next))) {
        throw StateError('DA filter probe could not be saved');
      }
      values.clear();
      values.addAll(next);
      notifyListeners();
    }

    final pending =
        _daFilterWrites?.then(
          (_) => persist(),
          onError: (Object _, StackTrace _) => persist(),
        ) ??
        persist();
    _daFilterWrites = pending;
    return pending.whenComplete(() {
      if (identical(_daFilterWrites, pending)) _daFilterWrites = null;
    });
  }

  final Map<String, bool> _analyzerCalibrationAnswers = {};
  final Set<String> _analyzerCalibrationPrompts = {};
  bool claimAnalyzerCalibrationPrompt(String key) =>
      !_analyzerCalibrationAnswers.containsKey(key) &&
      _analyzerCalibrationPrompts.add(key);
  void releaseAnalyzerCalibrationPrompt(String key) =>
      _analyzerCalibrationPrompts.remove(key);
  Future<void> answerAnalyzerCalibrationPrompt(
    String key,
    bool accepted,
  ) async {
    _analyzerCalibrationAnswers[key] = accepted;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(
        'analyzer_calibration_answers',
        jsonEncode(_analyzerCalibrationAnswers),
      )) {
        throw StateError('Calibration answer could not be saved');
      }
    } catch (_) {
      _analyzerCalibrationAnswers.remove(key);
      rethrow;
    }
  }

  final Map<String, double> _analyzerCalibrations = {};
  Future<void>? _calibrationWrites;
  double analyzerCalibration(String? key) => _analyzerCalibrations[key] ?? 0;

  Future<void> setAnalyzerCalibration(String key, double offset) {
    if (!offset.isFinite || offset < -40 || offset > 40) {
      throw ArgumentError.value(offset, 'offset');
    }
    Future<void> persist() async {
      final next = Map<String, double>.of(_analyzerCalibrations);
      if (offset == 0) {
        next.remove(key);
      } else {
        next[key] = (offset * 10).round() / 10;
      }
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString('analyzer_calibrations', jsonEncode(next))) {
        throw StateError('Calibration could not be saved');
      }
      _analyzerCalibrations.clear();
      _analyzerCalibrations.addAll(next);
      notifyListeners();
    }

    // A failed write is reported to its caller and does not block later writes.
    final pending =
        _calibrationWrites?.then(
          (_) => persist(),
          onError: (Object _, StackTrace _) => persist(),
        ) ??
        persist();
    _calibrationWrites = pending;
    return pending.whenComplete(() {
      if (identical(_calibrationWrites, pending)) _calibrationWrites = null;
    });
  }

  Future<void> setAnalyzerBandResolution(AnalyzerBandResolution value) {
    analyzerBandResolution = value;
    notifyListeners();
    return _persistEasy(
      (prefs) =>
          prefs.setInt('analyzer_bands_per_octave', value.bandsPerOctave),
    );
  }

  /// Überleben das Neuaufbauen der Anzeige, z. B. beim Drehen des Tablets.
  /// Ohne notifyListeners: Nur der AnalyzerController liest sie beim Erzeugen.
  bool analyzerBars = false;
  bool analyzerPeakHold = true;

  /// Zero means infinite hold; the previous fixed duration was one second.
  static const analyzerPeakHoldOptions = [1, 2, 3, 5, 10, 0];
  int analyzerPeakHoldSeconds = 1;

  Future<void> setAnalyzerPeakHoldSeconds(int value) {
    if (!analyzerPeakHoldOptions.contains(value)) return Future.value();
    analyzerPeakHoldSeconds = value;
    notifyListeners();
    return _persistEasy(
      (prefs) => prefs.setInt('analyzer_peak_hold_seconds', value),
    );
  }

  AnalyzerBallistics analyzerBallistics = AnalyzerBallistics.medium;

  Future<void> setAnalyzerBars(bool value) {
    analyzerBars = value;
    return _persistEasy((prefs) => prefs.setBool('analyzer_bars', value));
  }

  Future<void> setAnalyzerPeakHold(bool value) {
    analyzerPeakHold = value;
    return _persistEasy((prefs) => prefs.setBool('analyzer_peak_hold', value));
  }

  Future<void> setAnalyzerBallistics(AnalyzerBallistics value) {
    analyzerBallistics = value;
    return _persistEasy(
      (prefs) => prefs.setString('analyzer_ballistics', value.name),
    );
  }

  /// -1 follows the device's Meter-Farbe parameter; 0–5 use its palette.
  int analyzerColor = -1;
  int analyzerRange = 60;
  bool analyzerLoopbackConfirmed = false;

  /// 0 follows the active output; otherwise an output address (3/6/9).
  int analyzerLoopbackOutput = 0;
  int analyzerLoopbackTap = 0;
  bool analyzerRoutingConfigured = false;

  Future<void> setAnalyzerRouting({required int output, required int tap}) {
    analyzerRoutingConfigured = true;
    analyzerLoopbackOutput = output;
    analyzerLoopbackTap = tap;
    notifyListeners();
    return _persistEasy((prefs) async {
      await prefs.setInt('analyzer_loopback_output', output);
      return prefs.setInt('analyzer_loopback_tap', tap);
    });
  }

  Future<void> setAnalyzerColor(int value) {
    analyzerColor = value;
    notifyListeners();
    return _persistEasy((prefs) => prefs.setInt('analyzer_color', value));
  }

  Future<void> setAnalyzerRange(int value) {
    analyzerRange = value;
    notifyListeners();
    return _persistEasy((prefs) => prefs.setInt('analyzer_range', value));
  }

  Future<void> confirmAnalyzerLoopback() {
    analyzerLoopbackConfirmed = true;
    return _persistEasy(
      (prefs) => prefs.setBool('analyzer_loopback_confirmed', true),
    );
  }

  HeaderContent get headerContent =>
      headerContentFromLegacy(showPlayer, showStatus, showAnalyzer);

  Future<void> setHeaderContent(HeaderContent content) {
    showAnalyzer = content == HeaderContent.analyzer;
    showPlayer = content == HeaderContent.player;
    showStatus =
        content == HeaderContent.player || content == HeaderContent.status;
    notifyListeners();
    return _persistEasy((prefs) async {
      await prefs.setBool('show_player', showPlayer);
      await prefs.setBool('show_status', showStatus);
      return prefs.setBool('show_analyzer', showAnalyzer);
    });
  }

  bool showPlayer = true;
  bool showStatus = true;
  final Map<Adi2Variant, EasySlots> _easySlots = {};
  Future<void>? _easyWrites;

  EasySlots easySlots(Adi2Variant variant) =>
      _easySlots[variant] ?? EasySlots.defaults(variant);

  EasyLayout easyLayout(Adi2Variant variant) {
    final slots = easySlots(variant);
    return slots.layouts[slots.active] ?? EasyLayout.defaults(variant);
  }

  Future<void> _setEasySlots(Adi2Variant variant, EasySlots slots) {
    _easySlots[variant] = slots;
    final json = slots.encode();
    notifyListeners();
    return _persistEasy(
      (prefs) => prefs.setString('easy_slots_${variant.name}', json),
    );
  }

  Future<void> saveEasySlot(
    Adi2Variant variant,
    int index,
    EasyLayout layout, {
    String? name,
  }) => _setEasySlots(
    variant,
    easySlots(variant).save(index, layout, name: name),
  );

  Future<void> activateEasySlot(Adi2Variant variant, int index) =>
      _setEasySlots(variant, easySlots(variant).activate(index));

  Future<void> clearEasySlot(Adi2Variant variant, int index) =>
      _setEasySlots(variant, easySlots(variant).clear(index));

  Future<void> setShowPlayer(bool on) {
    showAnalyzer = false;
    showPlayer = on;
    notifyListeners();
    return _persistEasy((prefs) async {
      await prefs.setBool('show_analyzer', false);
      return prefs.setBool('show_player', on);
    });
  }

  Future<void> setShowStatus(bool on) {
    showAnalyzer = false;
    showStatus = on;
    notifyListeners();
    return _persistEasy((prefs) async {
      await prefs.setBool('show_analyzer', false);
      return prefs.setBool('show_status', on);
    });
  }

  Future<void> setEasyMode(bool on) {
    easyMode = on;
    notifyListeners();
    return _persistEasy((prefs) => prefs.setBool('easy_mode', on));
  }

  Future<void> setEasyLayout(Adi2Variant variant, EasyLayout layout) {
    final slots = easySlots(variant);
    return saveEasySlot(
      variant,
      slots.active,
      layout,
      name: slots.names[slots.active],
    );
  }

  Future<void> _persistEasy(Future<bool> Function(SharedPreferences) write) {
    Future<void> persist() async {
      try {
        await write(await SharedPreferences.getInstance());
      } catch (_) {}
    }

    final pending = _easyWrites?.then((_) => persist()) ?? persist();
    _easyWrites = pending;
    return pending.whenComplete(() {
      if (identical(_easyWrites, pending)) _easyWrites = null;
    });
  }

  Future<void> load() async {
    try {
      _daFilterLoad = null;
      await loadDaFilterSettings();
      final prefs = await SharedPreferences.getInstance();
      _analyzerCalibrationAnswers.clear();
      try {
        final answers = jsonDecode(
          prefs.getString('analyzer_calibration_answers') ?? '{}',
        );
        if (answers is Map) {
          for (final entry in answers.entries) {
            if (entry.key is String && entry.value is bool) {
              _analyzerCalibrationAnswers[entry.key as String] =
                  entry.value as bool;
            }
          }
        }
      } on FormatException {
        // A corrupt answer must not suppress first use for another device.
      }
      _analyzerCalibrationPrompts.clear();
      _analyzerCalibrations.clear();
      try {
        final stored = jsonDecode(
          prefs.getString('analyzer_calibrations') ?? '{}',
        );
        if (stored is Map) {
          for (final entry in stored.entries) {
            final value = entry.value;
            if (entry.key is String &&
                value is num &&
                value.isFinite &&
                value >= -40 &&
                value <= 40) {
              _analyzerCalibrations[entry.key as String] =
                  (value * 10).round() / 10;
            }
          }
        }
      } on FormatException {
        // An unreadable calibration never leaks into another combination.
      }
      tabletExtraContent =
          TabletExtraContent.values
              .where(
                (content) =>
                    content.name == prefs.getString('tablet_extra_content'),
              )
              .firstOrNull ??
          TabletExtraContent.eq;
      updateCheck = prefs.getBool('update_check') ?? true;
      lastUpdateCheck = DateTime.tryParse(
        prefs.getString('last_update_check') ?? '',
      );
      skippedUpdateVersion = prefs.getString('skipped_update_version');
      availableUpdateVersion = prefs.getString('available_update_version');
      availableUpdateUrl = prefs.getString('available_update_url');
      easyMode = prefs.getBool('easy_mode') ?? false;
      _easySlots.clear();
      for (final variant in Adi2Variant.values) {
        final stored = prefs.getString('easy_slots_${variant.name}');
        final legacy = prefs.getString('easy_layout_${variant.name}');
        if (stored != null) {
          final slots = EasySlots.decode(stored, variant);
          _easySlots[variant] = slots;
          if (slots.encode() != stored) {
            await prefs.setString('easy_slots_${variant.name}', slots.encode());
          }
        } else if (legacy != null) {
          final slots = EasySlots(
            layouts: [EasyLayout.decode(legacy, variant), null, null, null],
          );
          _easySlots[variant] = slots;
          await prefs.setString('easy_slots_${variant.name}', slots.encode());
        }
      }
      analyzerBandResolution =
          AnalyzerBandResolution.values
              .where(
                (r) =>
                    r.bandsPerOctave ==
                    prefs.getInt('analyzer_bands_per_octave'),
              )
              .firstOrNull ??
          AnalyzerBandResolution.third;
      analyzerBars = prefs.getBool('analyzer_bars') ?? false;
      analyzerPeakHold = prefs.getBool('analyzer_peak_hold') ?? true;
      analyzerPeakHoldSeconds = prefs.getInt('analyzer_peak_hold_seconds') ?? 1;
      if (!analyzerPeakHoldOptions.contains(analyzerPeakHoldSeconds)) {
        analyzerPeakHoldSeconds = 1;
      }
      analyzerBallistics =
          AnalyzerBallistics.values
              .where((b) => b.name == prefs.getString('analyzer_ballistics'))
              .firstOrNull ??
          AnalyzerBallistics.medium;
      analyzerColor = prefs.getInt('analyzer_color') ?? -1;
      if (analyzerColor < -1 || analyzerColor > 5) analyzerColor = -1;
      analyzerRange = prefs.getInt('analyzer_range') ?? 60;
      if (![60, 80, 100].contains(analyzerRange)) analyzerRange = 60;
      analyzerLoopbackConfirmed =
          prefs.getBool('analyzer_loopback_confirmed') ?? false;
      analyzerLoopbackOutput = prefs.getInt('analyzer_loopback_output') ?? 0;
      if (![0, 3, 6, 9].contains(analyzerLoopbackOutput)) {
        analyzerLoopbackOutput = 0;
      }
      analyzerLoopbackTap = prefs.getInt('analyzer_loopback_tap') ?? 0;
      analyzerRoutingConfigured = prefs.containsKey('analyzer_loopback_tap');
      if (analyzerLoopbackTap < 0 || analyzerLoopbackTap > 3) {
        analyzerLoopbackTap = 0;
      }
      showAnalyzer = prefs.getBool('show_analyzer') ?? false;
      showPlayer = prefs.getBool('show_player') ?? true;
      showStatus = prefs.getBool('show_status') ?? true;
      autoSwitchOutput = prefs.getBool('auto_switch_output') ?? true;
      statusInDbu = prefs.getBool('status_in_dbu') ?? false;
      autoFullscreenEq = prefs.getBool('auto_fullscreen_eq') ?? true;
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setAutoSwitchOutput(bool on) async {
    autoSwitchOutput = on;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('auto_switch_output', on);
    } catch (_) {}
  }

  Future<void> setStatusInDbu(bool on) async {
    statusInDbu = on;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('status_in_dbu', on);
    } catch (_) {}
  }

  Future<void> setAutoFullscreenEq(bool on) async {
    autoFullscreenEq = on;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('auto_fullscreen_eq', on);
    } catch (_) {}
  }
}
