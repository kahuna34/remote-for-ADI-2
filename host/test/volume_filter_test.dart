import 'dart:typed_data';

import 'package:adi2_host/volume_filter.dart';
import 'package:adi2_remote/device/volume_guard.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List set(List<Adi2Param> params) => buildSetParams(0x71, params).single;
Adi2Param volume(int value) => Adi2Param(Adi2Addr.line, OutIdx.volume, value);
Adi2Param ref(int value) => Adi2Param(Adi2Addr.line, OutIdx.refLevel, value);
Uint8List reply(List<Adi2Param> params) =>
    set(params)..[5] = Adi2Cmd.paramsToRemote;
int value(Uint8List bytes, int index) =>
    (parseSysex(bytes) as Adi2ParamsMessage).params
        .firstWhere((p) => p.index == index)
        .value;

void main() {
  late Duration now;
  late HostVolumeFilter filter;
  setUp(() {
    now = Duration.zero;
    filter = HostVolumeFilter(clock: () => now);
    filter.observe(
      reply([volume(-400), ref(0), const Adi2Param(3, OutIdx.mute, 0)]),
    );
  });

  test('Absenken, Mute und Dim gehen sofort ohne Freigabe', () {
    expect(value(filter.filter(set([volume(-600)]))!, OutIdx.volume), -600);
    expect(filter.filter(set([const Adi2Param(3, OutIdx.mute, 1)])), isNotNull);
    expect(filter.filter(set([const Adi2Param(3, OutIdx.dim, 1)])), isNotNull);
    expect(filter.filter(set([volume(-100)])), isNull);
  });

  test('Anheben nur mit Freigabe, maximal gemeinsame Rampenrate', () {
    filter.heartbeat();
    now += const Duration(milliseconds: volTickMs);
    final expected =
        -400 + (riseRateDbPerSec(-40) * 10 * volTickMs / 1000).floor();
    expect(value(filter.filter(set([volume(0)]))!, OutIdx.volume), expected);
    expect(filter.limited, isTrue);
    expect(filter.filter(set([volume(0)])), isNull);
  });

  test('Paketschwemme und erneute Freigabe vervielfachen Rate nicht', () {
    filter.heartbeat();
    now += const Duration(milliseconds: volTickMs);
    final first = filter.filter(set([volume(0)]));
    expect(first, isNotNull);
    for (var i = 0; i < 20; i++) {
      filter.release();
      filter.heartbeat();
      expect(filter.filter(set([volume(0)])), isNull);
    }
  });

  test('Freigabe läuft mitten in Anhebung aus, keine Nachholung', () {
    filter.heartbeat();
    now += const Duration(milliseconds: volTickMs);
    expect(filter.filter(set([volume(0)])), isNotNull);
    now += hostGrantLifetime;
    expect(filter.filter(set([volume(0)])), isNull);
    filter.heartbeat();
    now += const Duration(milliseconds: volTickMs);
    final next = filter.filter(set([volume(0)]))!;
    expect(value(next, OutIdx.volume), lessThanOrEqualTo(-380));
    expect(filter.filter(set([volume(-700)])), isNotNull);
  });

  test('Ref-Level-Erhöhung braucht Freigabe und kompensierte Absenkung', () {
    expect(filter.filter(set([ref(1)])), isNull);
    filter.heartbeat();
    now += const Duration(milliseconds: volTickMs);
    expect(filter.filter(set([ref(1)])), isNull);
    expect(filter.filter(set([volume(-460), ref(1)])), isNotNull);
    expect(filter.filter(set([ref(0)])), isNotNull);
    filter.release();
    // Ohne Freigabe nur, wenn die Absenkung den Pegelsprung voll ausgleicht.
    final result = filter.filter(set([volume(-520), ref(1)]))!;
    expect((parseSysex(result) as Adi2ParamsMessage).params, [
      volume(-520),
      ref(1),
    ]);
    expect(filter.filter(set([ref(0)])), isNotNull);
    final partial = filter.filter(set([volume(-540), ref(1)]))!;
    expect((parseSysex(partial) as Adi2ParamsMessage).params, [volume(-540)]);
  });

  test('App-Ablauf: getrennte Absenkung, dann Ref-Level ohne Freigabe', () {
    expect(filter.filter(set([volume(-460)])), isNotNull);
    now += const Duration(milliseconds: 20);
    expect(filter.filter(set([ref(1)])), isNotNull);
  });

  test('Geräteänderung verwirft eine frühere Ref-Level-Kompensation', () {
    filter.heartbeat();
    now += const Duration(milliseconds: volTickMs);
    expect(filter.filter(set([volume(-460)])), isNotNull);
    // Beispielsweise eine parallele Änderung mit dem Drehknopf.
    filter.observe(reply([volume(-400)]));
    expect(filter.filter(set([ref(1)])), isNull);
  });

  test('Abriss, USB weg und neue Sitzung verwerfen Zustand und Freigabe', () {
    filter.heartbeat();
    filter.reset();
    now += const Duration(seconds: 4);
    expect(filter.filter(set([volume(0)])), isNull);
    filter.observe(reply([volume(-600)]));
    expect(filter.filter(set([volume(0)])), isNull);
    expect(filter.filter(set([volume(-700)])), isNotNull);
  });

  test('Unbekannter Ausgangswert und verstecktes Setup-Laden gesperrt', () {
    expect(filter.filter(set([const Adi2Param(6, OutIdx.volume, 0)])), isNull);
    expect(filter.filter(buildLoadSetup(0x71, 1)), isNull);
    expect(filter.filter(buildLoadFactory(0x71)), isNull);
    expect(filter.filter(buildSaveSetup(0x71, 1)), isNotNull);
    expect(filter.filter(buildRequestAll(0x71)), isNotNull);
  });
  test(
    'Freigabe gilt nur für den sendenden Client, Release lässt B laufen',
    () {
      filter.heartbeat('B');
      now += const Duration(milliseconds: volTickMs);
      expect(filter.filter(set([volume(0)]), client: 'A'), isNull);
      expect(filter.grantedFor('B'), isTrue);
      filter.heartbeat('A');
      filter.release('A');
      expect(filter.grantedFor('A'), isFalse);
      expect(filter.grantedFor('B'), isTrue);
      // A hat weder das Zeitbudget noch den beobachteten Gerätestand gelöscht.
      expect(
        value(filter.filter(set([volume(0)]), client: 'B')!, OutIdx.volume),
        -390,
      );
      expect(filter.filter(set([volume(-700)]), client: 'A'), isNotNull);
      expect(
        filter.filter(set([const Adi2Param(3, OutIdx.mute, 1)]), client: 'A'),
        isNotNull,
      );
      expect(
        filter.filter(set([const Adi2Param(3, OutIdx.mute, 0)]), client: 'A'),
        isNull,
      );
      expect(
        filter.filter(set([const Adi2Param(3, OutIdx.mute, 0)]), client: 'B'),
        isNotNull,
      );
      expect(
        filter.filter(set([const Adi2Param(3, OutIdx.dim, 1)]), client: 'A'),
        isNotNull,
      );
      expect(
        filter.filter(set([const Adi2Param(3, OutIdx.dim, 0)]), client: 'A'),
        isNull,
      );
    },
  );

  test('Zwei Anheber teilen pro Ausgang Rate und Bruchteile', () {
    filter.observe(reply([volume(0)]));
    filter.heartbeat('A');
    filter.heartbeat('B');
    var last = 0;
    for (var tick = 0; tick < 10; tick++) {
      now += const Duration(milliseconds: volTickMs);
      for (final client in ['A', 'B']) {
        final bytes = filter.filter(set([volume(60)]), client: client);
        if (bytes != null) last = value(bytes, OutIdx.volume);
      }
    }
    // Bei 0 dB höchstens 2,5 dB/s: nach 500 ms maximal 1,2 dB.
    expect(last, inInclusiveRange(10, 12));
  });

  test('Release von A erhält Bruchteile und Zeitbudget der Rampe von B', () {
    filter.observe(reply([volume(0)]));
    filter.heartbeat('A');
    filter.heartbeat('B');
    now += const Duration(milliseconds: volTickMs);
    expect(
      value(filter.filter(set([volume(60)]), client: 'B')!, OutIdx.volume),
      1,
    ); // 0,25 Rohwert bleibt übrig.
    now += const Duration(milliseconds: 10);
    filter.release('A');
    now += const Duration(milliseconds: 25);
    expect(
      value(filter.filter(set([volume(60)]), client: 'B')!, OutIdx.volume),
      2,
    );
  });

  test('Ablauf einer Freigabe betrifft nur diesen Client', () {
    filter.heartbeat('A');
    now += const Duration(milliseconds: 600);
    filter.heartbeat('B');
    now += const Duration(milliseconds: 450);
    expect(filter.filter(set([volume(0)]), client: 'A'), isNull);
    expect(filter.grantedFor('B'), isTrue);
    expect(filter.filter(set([volume(0)]), client: 'B'), isNotNull);
  });

  test('Ref-Kompensation gehört zum absenkenden Client und gilt einmalig', () {
    expect(filter.filter(set([volume(-460)]), client: 'A'), isNotNull);
    now += const Duration(milliseconds: 20);
    expect(filter.filter(set([ref(1)]), client: 'B'), isNull);
    expect(filter.filter(set([ref(1)]), client: 'A'), isNotNull);
    expect(filter.filter(set([ref(0)]), client: 'B'), isNotNull);
    expect(filter.filter(set([ref(1)]), client: 'A'), isNull);
  });

  test('Ref-Kompensation verfällt nach 100 ms und bei fremder Anhebung', () {
    expect(filter.filter(set([volume(-460)]), client: 'A'), isNotNull);
    now += const Duration(milliseconds: 101);
    expect(filter.filter(set([ref(1)]), client: 'A'), isNull);
    expect(filter.filter(set([volume(-520)]), client: 'A'), isNotNull);
    filter.heartbeat('B');
    now += const Duration(milliseconds: volTickMs);
    expect(filter.filter(set([volume(-510)]), client: 'B'), isNotNull);
    expect(filter.filter(set([ref(1)]), client: 'A'), isNull);
  });
}
