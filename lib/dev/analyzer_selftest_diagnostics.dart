import 'package:flutter/foundation.dart';

/// Enabled for this process by the existing hidden developer entry.
final analyzerDeveloperMode = ValueNotifier(false);

String analyzerDiagnosticText(Map data) {
  final capture = data['capture'] is Map ? data['capture'] as Map : data;
  final routed = capture['routedDevice'];
  final requested = capture['requestedDevice'];
  String device(dynamic value) => value is Map
      ? '${value['name']} (Typ ${value['type']}, ID ${value['id']})'
      : 'unbekannt';
  String format(dynamic value) {
    if (value is! Map || value.isEmpty) return 'nicht gemeldet';
    final encoding = switch (value['encoding']) {
      2 => 'PCM16',
      4 => 'PCM_FLOAT',
      final v => '$v',
    };
    return '${value['sampleRate']} Hz / ${value['channels']} Kanäle / $encoding';
  }

  final source = capture['audioSource'];
  final sourceName = switch (source) {
    1 => 'MIC',
    6 => 'VOICE_RECOGNITION',
    7 => 'VOICE_COMMUNICATION',
    9 => 'UNPROCESSED',
    _ => '$source',
  };
  String number(dynamic value) =>
      value is num && value.isFinite ? value.toStringAsFixed(1) : 'unbekannt';
  final quiet = data['quiet'] ?? capture['signal'];
  final timing = data['timing'];
  return [
    'Aufnahmeroute: ${device(routed)}; verlangt: ${device(requested)}',
    'Format verlangt: ${format(capture['requestedFormat'])}; tatsächlich (App): ${format(capture['actualFormat'])}; Hardware: ${format(capture['hardwareFormat'])}',
    'AudioSource: $sourceName ($source); Skalierung: ${capture['pcmScaling']}; Routing: ${capture['communicationRouting']}',
    if (capture['message'] != null) '${capture['message']}',
    if (quiet is Map && quiet['channels'] is List)
      for (final (i, channel) in (quiet['channels'] as List).indexed)
        if (channel is Map)
          '${i == 0 ? 'L' : 'R'}: ${number(channel['peakDbfs'])} dBFS Peak / ${number(channel['rmsDbfs'])} dBFS RMS; dominant ${number(channel['dominantHz'])} Hz (Raster ${number(channel['binHz'])} Hz); ${channel['shape']}',
    if (timing is Map)
      'Ruheprüfung (monoton, ns): ${timing['quietStartNs']}–${timing['quietEndNs']}; erster Testton angefordert: ${timing['firstToneCommandNs'] ?? 'noch nicht'}; geschrieben: ${timing['firstToneWrittenNs'] ?? 'noch nicht'}; Testton aktiv: ${timing['testPlaybackActive']}; Abstand zum ersten Testton: ${number(timing['quietEndToFirstToneMs'])} ms',
    if (quiet is Map) 'Spektrumform ist ein Hinweis; Sprache/Raumgeräusch beweist keine Mikrofonroute.',
  ].join('\n');
}
