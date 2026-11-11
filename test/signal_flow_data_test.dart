import 'dart:math' as math;

import 'package:adi2_remote/ui/signal_flow_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

bool _reaches(
  SignalFlowDiagram diagram,
  String from,
  String to, {
  bool options = false,
}) {
  final pending = [from];
  final visited = <String>{};
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    if (current == to) return true;
    if (!visited.add(current)) continue;
    pending.addAll(
      diagram.wires
          .where((w) => w.from == current && (options || !w.dashed))
          .map((w) => w.to),
    );
  }
  return false;
}

bool _onSegment(Offset point, Offset a, Offset b) =>
    point.dx >= math.min(a.dx, b.dx) &&
    point.dx <= math.max(a.dx, b.dx) &&
    point.dy >= math.min(a.dy, b.dy) &&
    point.dy <= math.max(a.dy, b.dy);

// A branch may start on another route from the same source. Follow the
// shared stems back to the source tile, including optional dashed routes.
bool _connectedToSource(SignalFlowDiagram diagram, SignalFlowWire wire) {
  final source = diagram.nodes.singleWhere((n) => n.id == wire.from);
  final pending = [wire];
  final visited = <SignalFlowWire>{};
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    if (!visited.add(current)) continue;
    if (source.rect.inflate(2.01).contains(current.points.first)) return true;
    for (final candidate in diagram.wires) {
      if (candidate.from != wire.from ||
          candidate.color != wire.color ||
          candidate.dashed != wire.dashed) {
        continue;
      }
      for (var i = 1; i < candidate.points.length; i++) {
        if (_onSegment(
          current.points.first,
          candidate.points[i - 1],
          candidate.points[i],
        )) {
          pending.add(candidate);
          break;
        }
      }
    }
  }
  return false;
}

List<String> _closeParallelSegments(
  List<SignalFlowWire> wires, {
  double minimum = 8,
  bool sameColor = true,
}) {
  final segments = [
    for (final wire in wires)
      for (var i = 1; i < wire.points.length; i++)
        (wire: wire, a: wire.points[i - 1], b: wire.points[i]),
  ];
  final conflicts = <String>[];
  for (var i = 0; i < segments.length; i++) {
    final first = segments[i];
    final horizontal = first.a.dy == first.b.dy;
    for (final second in segments.skip(i + 1)) {
      if ((first.wire.color == second.wire.color) != sameColor ||
          horizontal != (second.a.dy == second.b.dy)) {
        continue;
      }
      final gap = horizontal
          ? (first.a.dy - second.a.dy).abs()
          : (first.a.dx - second.a.dx).abs();
      final overlap = horizontal
          ? math.min(
                  math.max(first.a.dx, first.b.dx),
                  math.max(second.a.dx, second.b.dx),
                ) -
                math.max(
                  math.min(first.a.dx, first.b.dx),
                  math.min(second.a.dx, second.b.dx),
                )
          : math.min(
                  math.max(first.a.dy, first.b.dy),
                  math.max(second.a.dy, second.b.dy),
                ) -
                math.max(
                  math.min(first.a.dy, first.b.dy),
                  math.min(second.a.dy, second.b.dy),
                );
      if (gap < minimum && overlap > 0) {
        conflicts.add(
          '${first.wire.from}->${first.wire.to} ${first.a}–${first.b} / '
          '${second.wire.from}->${second.wire.to} ${second.a}–${second.b}, Abstand $gap',
        );
      }
    }
  }
  return conflicts;
}

// Count a visible crossing once per position and color pair, even if a shared
// stem is split there. Dashed option routes participate in the same count.
int _differentColorCrossings(List<SignalFlowWire> wires) {
  final segments = [
    for (final wire in wires)
      for (var i = 1; i < wire.points.length; i++)
        (color: wire.color, a: wire.points[i - 1], b: wire.points[i]),
  ];
  final crossings = <(Offset, int, int)>{};
  for (var i = 0; i < segments.length; i++) {
    final first = segments[i];
    final horizontal = first.a.dy == first.b.dy;
    for (final second in segments.skip(i + 1)) {
      if (first.color == second.color ||
          horizontal == (second.a.dy == second.b.dy)) {
        continue;
      }
      final point = horizontal
          ? Offset(second.a.dx, first.a.dy)
          : Offset(first.a.dx, second.a.dy);
      if (_onSegment(point, first.a, first.b) &&
          _onSegment(point, second.a, second.b)) {
        final firstColor = first.color.toARGB32();
        final secondColor = second.color.toARGB32();
        crossings.add((
          point,
          math.min(firstColor, secondColor),
          math.max(firstColor, secondColor),
        ));
      }
    }
  }
  return crossings.length;
}

void main() {
  test(
    'Kreuzungszählung berücksichtigt Farben, Knicke und geteilte Stämme',
    () {
      SignalFlowWire wire(List<Offset> points, Color color) =>
          SignalFlowWire('source', 'target', points, color);
      final horizontal = wire([
        const Offset(0, 10),
        const Offset(20, 10),
      ], Colors.red);
      final vertical = wire([
        const Offset(10, 20),
        const Offset(10, 0),
      ], Colors.blue);
      expect(_differentColorCrossings([horizontal, vertical]), 1);
      expect(_differentColorCrossings([horizontal, horizontal]), 0);
      expect(
        _differentColorCrossings([
          horizontal,
          wire([const Offset(0, 20), const Offset(20, 20)], Colors.blue),
          wire([const Offset(30, 0), const Offset(30, 20)], Colors.blue),
        ]),
        0,
      );
      expect(
        _differentColorCrossings([
          horizontal,
          wire([
            const Offset(10, 0),
            const Offset(10, 10),
            const Offset(30, 10),
          ], Colors.blue),
          wire([const Offset(10, 10), const Offset(10, 20)], Colors.blue),
        ]),
        1,
      );
      expect(
        _differentColorCrossings([
          horizontal,
          vertical,
          wire([const Offset(10, 0), const Offset(10, 20)], Colors.green),
        ]),
        2,
      );
      expect(
        _differentColorCrossings([
          horizontal,
          SignalFlowWire(
            'source',
            'target',
            vertical.points,
            Colors.blue,
            dashed: true,
          ),
        ]),
        1,
      );
    },
  );

  // Measured before fix2 with the same counter. The new caps also guard against
  // regressions that would still fall below the old crossing counts.
  for (final (mode, multi, before, maximum) in [
    (SignalFlowMode.auto, false, 0, 0),
    (SignalFlowMode.adda, false, 7, 7),
    (SignalFlowMode.preamp, false, 7, 7),
    (SignalFlowMode.digThru, false, 6, 6),
    (SignalFlowMode.dac, false, 10, 3),
    (SignalFlowMode.usb, false, 11, 6),
    (SignalFlowMode.usb, true, 25, 8),
  ]) {
    test(
      'Farbkreuzungen ${mode.name} multi=$multi höchstens $maximum (vorher $before)',
      () {
        final diagram = signalFlowDiagram(mode, usbMulti: multi);
        final crossings = _differentColorCrossings(diagram.wires);
        expect(crossings, lessThanOrEqualTo(maximum));
        if (maximum < before) expect(crossings, lessThan(before));
      },
    );
  }

  for (final (mode, multi) in [
    (SignalFlowMode.dac, false),
    (SignalFlowMode.usb, false),
    (SignalFlowMode.usb, true),
  ]) {
    test('USB-Korridor und Eingangsreihenfolge ${mode.name} multi=$multi', () {
      final diagram = signalFlowDiagram(mode, usbMulti: multi);
      final inputs =
          diagram.nodes
              .where((n) => n.kind == SignalFlowNodeKind.input)
              .toList()
            ..sort((a, b) => a.rect.top.compareTo(b.rect.top));
      final usbInputs = inputs.where((n) => n.color == SignalFlowColors.usb);
      expect(inputs.skip(usbInputs.length).map((n) => n.id), [
        'analog',
        'aes',
        'coax',
        'optical',
      ]);
      for (final input in usbInputs) {
        expect(input.rect.bottom, lessThan(inputs[usbInputs.length].rect.top));
      }
      final usbWires = diagram.wires.where(
        (w) => w.color == SignalFlowColors.usb,
      );
      final otherWires = diagram.wires.where(
        (w) => w.color != SignalFlowColors.usb,
      );
      for (final wire in usbWires) {
        expect(
          _closeParallelSegments([wire, ...otherWires], sameColor: false),
          isEmpty,
        );
      }
      expect(
        _differentColorCrossings(diagram.wires) -
            _differentColorCrossings(otherWires.toList()),
        lessThanOrEqualTo(multi ? 1 : 0),
      );
      // Distinct playback pairs must stay visibly separate, even though all
      // USB routes share a color. Only branches of one pair share a stem.
      for (final wire in usbWires) {
        for (final other in usbWires.where((w) => w.from != wire.from)) {
          expect(_closeParallelSegments([wire, other]), isEmpty);
          expect(
            _differentColorCrossings([
              wire,
              SignalFlowWire(other.from, other.to, other.points, Colors.white),
            ]),
            0,
          );
        }
      }
    });
  }

  for (final multi in [false, true]) {
    test('USB-Zuführungen zu Phones bleiben senkrecht multi=$multi', () {
      final diagram = signalFlowDiagram(SignalFlowMode.usb, usbMulti: multi);
      final phones = diagram.nodes.singleWhere((n) => n.id == 'phones').rect;
      final wires = diagram.wires
          .where((w) => w.to == 'phones' && w.color == SignalFlowColors.usb)
          .toList();
      expect(wires.map((w) => w.from), multi ? ['usb12', 'usb34'] : ['usb']);
      for (final wire in wires) {
        final end = wire.points.last;
        final previous = wire.points[wire.points.length - 2];
        expect(end.dx, inExclusiveRange(phones.left, phones.right));
        // Preserve the diagram's two-unit clearance before the top edge.
        expect(end.dy, phones.top - 2);
        expect(previous.dx, end.dx);
        expect(previous.dy, lessThan(end.dy));
        var length = 0.0;
        for (var i = 1; i < wire.points.length; i++) {
          length += (wire.points[i] - wire.points[i - 1]).distance;
        }
        // The whole final third must be on the straight downward segment.
        expect((end - previous).distance, greaterThanOrEqualTo(length / 3));
        if (wire.from != 'usb34') {
          // Shared-stem branches start above Phones and descend without a jog.
          expect(wire.points.every((p) => p.dx == end.dx), isTrue);
        }
      }
      expect(_closeParallelSegments(wires, minimum: 16), isEmpty);
    });
  }

  test(
    'Parallelprüfung erkennt enge und doppelte Segmente beider Richtungen',
    () {
      SignalFlowWire wire(Offset a, Offset b, {Color color = Colors.red}) =>
          SignalFlowWire('source', 'target', [a, b], color);
      for (final vertical in [false, true]) {
        Offset point(double along, double across) =>
            vertical ? Offset(across, along) : Offset(along, across);
        final base = wire(point(0, 0), point(20, 0));
        for (final gap in [0.0, 6.0, 7.99]) {
          expect(
            _closeParallelSegments([
              base,
              wire(point(30, gap), point(10, gap)),
            ]),
            hasLength(1),
          );
        }
        expect(
          _closeParallelSegments([base, wire(point(10, 8), point(30, 8))]),
          isEmpty,
        );
        expect(
          _closeParallelSegments([base, wire(point(20, 1), point(30, 1))]),
          isEmpty,
        );
        expect(
          _closeParallelSegments([
            base,
            wire(point(10, 1), point(30, 1), color: Colors.blue),
          ]),
          isEmpty,
        );
        expect(
          _closeParallelSegments([
            base,
            wire(point(10, 1), point(30, 1), color: Colors.blue),
          ], sameColor: false),
          hasLength(1),
        );
        expect(
          _closeParallelSegments([
            base,
            wire(point(10, 1), point(30, 1)),
          ], sameColor: false),
          isEmpty,
        );
      }
    },
  );

  test(
    'USB-Mehrkanal hält im digitalen Ausgangsbereich 24 Einheiten Abstand',
    () {
      final diagram = signalFlowDiagram(SignalFlowMode.usb, usbMulti: true);
      final digitalNodes = diagram.nodes
          .where(
            (n) => [
              'digitalAes',
              'digitalSpdif',
              'aesOut',
              'coaxOut',
              'opticalOut',
            ].contains(n.id),
          )
          .toList();
      for (var i = 0; i < digitalNodes.length; i++) {
        final a = digitalNodes[i].rect;
        for (final node in digitalNodes.skip(i + 1)) {
          final b = node.rect;
          final overlapX =
              math.min(a.right, b.right) - math.max(a.left, b.left);
          if (overlapX > 0) {
            expect(
              math.max(a.top, b.top) - math.min(a.bottom, b.bottom),
              greaterThanOrEqualTo(24),
            );
          }
        }
      }
      final upperWires = [
        for (final wire in diagram.wires)
          for (var i = 1; i < wire.points.length; i++)
            if (wire.points[i - 1].dy <= 190 && wire.points[i].dy <= 190)
              SignalFlowWire(wire.from, wire.to, [
                wire.points[i - 1],
                wire.points[i],
              ], wire.color),
      ];
      expect(_closeParallelSegments(upperWires, minimum: 24), isEmpty);
    },
  );

  for (final mode in SignalFlowMode.values.where(
    (m) => m != SignalFlowMode.auto,
  )) {
    for (final multi in mode == SignalFlowMode.usb ? [false, true] : [false]) {
      test('Gültige Knoten und Leitungen ${mode.name} multi=$multi', () {
        final diagram = signalFlowDiagram(mode, usbMulti: multi);
        final nodes = {for (final n in diagram.nodes) n.id: n};
        expect(diagram.nodes, isNotEmpty);
        expect(diagram.wires, isNotEmpty);
        expect(nodes.length, diagram.nodes.length);
        final bounds = Rect.fromLTWH(
          0,
          0,
          SignalFlowDiagram.width,
          diagram.height,
        );
        for (final node in diagram.nodes) {
          expect(bounds.contains(node.rect.topLeft), isTrue, reason: node.id);
          expect(
            bounds.contains(node.rect.bottomRight),
            isTrue,
            reason: node.id,
          );
        }
        expect(_closeParallelSegments(diagram.wires), isEmpty);
        for (final wire in diagram.wires) {
          expect(nodes.containsKey(wire.from), isTrue, reason: wire.from);
          expect(nodes.containsKey(wire.to), isTrue, reason: wire.to);
          expect(wire.points.length, greaterThanOrEqualTo(2));
          // Der freigegebene SVG-Entwurf lässt 2 Einheiten vor Kacheln frei.
          expect(
            _connectedToSource(diagram, wire),
            isTrue,
            reason: '${wire.from} -> ${wire.to} Start',
          );
          expect(
            nodes[wire.to]!.rect.inflate(2.01).contains(wire.points.last),
            isTrue,
            reason: '${wire.from} -> ${wire.to} Ende',
          );
          for (var i = 0; i < wire.points.length; i++) {
            expect(bounds.contains(wire.points[i]), isTrue);
            if (i == 0) continue;
            final a = wire.points[i - 1];
            final b = wire.points[i];
            for (final node in diagram.nodes) {
              final rect = node.rect.deflate(0.01);
              final crosses = a.dx == b.dx
                  ? a.dx > rect.left &&
                        a.dx < rect.right &&
                        math.max(a.dy, b.dy) > rect.top &&
                        math.min(a.dy, b.dy) < rect.bottom
                  : a.dy > rect.top &&
                        a.dy < rect.bottom &&
                        math.max(a.dx, b.dx) > rect.left &&
                        math.min(a.dx, b.dx) < rect.right;
              expect(
                crosses,
                isFalse,
                reason: '${wire.from}->${wire.to} kreuzt ${node.id}',
              );
            }
            final segment = wire.points[i] - wire.points[i - 1];
            expect(segment.distance, greaterThan(0));
            expect(segment.dx == 0 || segment.dy == 0, isTrue);
          }
        }
      });
    }
  }

  test('Auto ist eine Entscheidung ohne Blockschaltbild', () {
    final diagram = signalFlowDiagram(SignalFlowMode.auto);
    expect(diagram.nodes, isEmpty);
    expect(diagram.wires, isEmpty);
  });

  test('AD/DA erhält die Koordinaten der freigegebenen Vorlage', () {
    final diagram = signalFlowDiagram(SignalFlowMode.adda);
    expect(diagram.height, 345);
    final expected = {
      'analog': const Rect.fromLTWH(40, 58, 86, 24),
      'aes': const Rect.fromLTWH(40, 138, 86, 24),
      'coax': const Rect.fromLTWH(40, 184, 86, 24),
      'optical': const Rect.fromLTWH(40, 218, 86, 24),
      'usb': const Rect.fromLTWH(40, 270, 86, 24),
      'adc': const Rect.fromLTWH(164, 56, 94, 28),
      'spdif': const Rect.fromLTWH(164, 186, 76, 54),
      'main': const Rect.fromLTWH(320, 136, 82, 56),
      'phones': const Rect.fromLTWH(320, 230, 82, 64),
      'mainDsp': const Rect.fromLTWH(440, 150, 94, 28),
      'phonesDsp': const Rect.fromLTWH(440, 248, 94, 28),
      'digital': const Rect.fromLTWH(442, 52, 94, 38),
      'aesOut': const Rect.fromLTWH(568, 30, 72, 20),
      'coaxOut': const Rect.fromLTWH(568, 60, 72, 20),
      'opticalOut': const Rect.fromLTWH(568, 90, 72, 20),
      'xlr': const Rect.fromLTWH(568, 154, 72, 20),
      'ts': const Rect.fromLTWH(568, 186, 72, 20),
      'ph12': const Rect.fromLTWH(568, 218, 72, 20),
      'ph34': const Rect.fromLTWH(568, 252, 72, 20),
    };
    expect({for (final node in diagram.nodes) node.id: node.rect}, expected);
    expect(
      diagram.wires
          .singleWhere((w) => w.from == 'mainDsp' && w.to == 'digital')
          .points,
      [const Offset(486, 148), const Offset(486, 92)],
    );
  });

  test('Preamp und AD/DA nach Handbuch S. 37–38', () {
    final preamp = signalFlowDiagram(SignalFlowMode.preamp);
    final adda = signalFlowDiagram(SignalFlowMode.adda);
    for (final output in [
      'aesOut',
      'coaxOut',
      'opticalOut',
      'xlr',
      'ts',
      'ph12',
      'ph34',
    ]) {
      expect(_reaches(preamp, 'analog', output), isTrue);
    }
    expect(_reaches(preamp, 'aes', 'xlr'), isFalse);
    expect(_reaches(adda, 'aes', 'xlr'), isTrue);
    expect(_reaches(adda, 'coax', 'ph12'), isTrue);
    expect(_reaches(adda, 'aes', 'aesOut'), isFalse);
    expect(_reaches(adda, 'aes', 'aesOut', options: true), isTrue);
    for (final mode in [preamp, adda]) {
      expect(_reaches(mode, 'usb', 'ph34'), isTrue);
      expect(_reaches(mode, 'usb', 'xlr'), isFalse);
    }
  });

  test('USB-Stereo nimmt nur Analog auf und spielt auf allen Ausgängen', () {
    final diagram = signalFlowDiagram(SignalFlowMode.usb);
    for (final output in [
      'aesOut',
      'coaxOut',
      'opticalOut',
      'xlr',
      'ts',
      'ph12',
      'ph34',
    ]) {
      expect(_reaches(diagram, 'usb', output), isTrue);
    }
    expect(_reaches(diagram, 'analog', 'record12'), isTrue);
    expect(_reaches(diagram, 'aes', 'record12'), isFalse);
    expect(_reaches(diagram, 'coax', 'record12'), isFalse);
    expect(_reaches(diagram, 'coax', 'ph34'), isTrue);
  });

  test('USB-Mehrkanal folgt der Kanaltabelle auf S. 40', () {
    final diagram = signalFlowDiagram(SignalFlowMode.usb, usbMulti: true);
    for (final pair in [
      ('analog', 'record12'),
      ('aes', 'record34'),
      ('coax', 'record56'),
      ('optical', 'record56'),
      ('usb12', 'xlr'),
      ('usb12', 'ph34'),
      ('usb34', 'ph34'),
      ('usb56', 'aesOut'),
      ('usb78', 'coaxOut'),
      ('usb78', 'opticalOut'),
    ]) {
      expect(_reaches(diagram, pair.$1, pair.$2), isTrue, reason: '$pair');
    }
    expect(_reaches(diagram, 'usb34', 'xlr'), isFalse);
    expect(_reaches(diagram, 'usb56', 'coaxOut'), isFalse);
    expect(_reaches(diagram, 'usb78', 'aesOut'), isFalse);
    expect(_reaches(diagram, 'analog', 'record34'), isFalse);
    expect(_reaches(diagram, 'aes', 'record56'), isFalse);
    expect(_reaches(diagram, 'usb12', 'aesOut', options: true), isTrue);
  });

  test(
    'Dig Thru umgeht den Ausgangs-DSP und bietet kein Main-Out-Override',
    () {
      final diagram = signalFlowDiagram(SignalFlowMode.digThru);
      expect(_reaches(diagram, 'aes', 'aesOut'), isTrue);
      expect(_reaches(diagram, 'optical', 'xlr'), isTrue);
      expect(_reaches(diagram, 'mainDsp', 'aesOut'), isFalse);
      expect(_reaches(diagram, 'analog', 'aesOut'), isFalse);
      expect(_reaches(diagram, 'analog', 'ph34'), isTrue);
      expect(diagram.wires.any((w) => w.dashed), isFalse);
    },
  );

  test('DAC hat eine gemeinsame Quelle vor den zwei Ausgangs-DSPs', () {
    final diagram = signalFlowDiagram(SignalFlowMode.dac);
    expect(diagram.nodes.any((n) => n.id == 'phones'), isFalse);
    expect(diagram.wires.singleWhere((w) => w.to == 'phonesDsp').from, 'main');
    expect(diagram.wires.singleWhere((w) => w.to == 'mainDsp').from, 'main');
    for (final input in ['analog', 'aes', 'coax', 'optical', 'usb']) {
      expect(_reaches(diagram, input, 'xlr'), isTrue);
      expect(_reaches(diagram, input, 'ph34'), isTrue);
    }
    expect(_reaches(diagram, 'usb', 'aesOut'), isTrue);
    expect(_reaches(diagram, 'aes', 'aesOut'), isFalse);
  });
}
