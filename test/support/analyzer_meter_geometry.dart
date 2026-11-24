import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Query canvas geometry instead of the removed Positioned/ColoredBox children.
dynamic meterPainter(WidgetTester tester, Finder bar) => tester
    .widget<CustomPaint>(
      find.descendant(of: bar, matching: find.byType(CustomPaint)),
    )
    .painter;

Rect meterTrack(WidgetTester tester, Finder bar) =>
    meterPainter(tester, bar).trackRect(tester.getSize(bar)) as Rect;
Rect meterRms(WidgetTester tester, Finder bar) =>
    meterPainter(tester, bar).rmsRect(tester.getSize(bar)) as Rect;
Rect meterPeak(WidgetTester tester, Finder bar) =>
    meterPainter(tester, bar).peakRect(tester.getSize(bar)) as Rect;
