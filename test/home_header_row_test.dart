import 'package:adi2_remote/ui/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, double screen, double actions) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(screen, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            // Dieselben Einrückungen wie in der Kopfzeile.
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
            child: HomeHeaderRow(
              badge: const SizedBox(key: Key('badge'), width: 72, height: 22),
              title: Container(key: const Key('title'), height: 40),
              actions: SizedBox(
                key: const Key('actions'),
                width: actions,
                height: 44,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Offline-Hinweis steht mittig zur Displaybreite', (tester) async {
    await pump(tester, 440, 164);
    final badge = tester.getRect(find.byKey(const Key('badge')));
    expect(badge.center.dx, closeTo(220, .01));
    expect(
      badge.center.dy,
      closeTo(tester.getRect(find.byKey(const Key('actions'))).center.dy, .01),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Auf schmalen Geräten berührt er nichts', (tester) async {
    await pump(tester, 360, 200);
    final badge = tester.getRect(find.byKey(const Key('badge')));
    final title = tester.getRect(find.byKey(const Key('title')));
    final actions = tester.getRect(find.byKey(const Key('actions')));
    expect(badge.right, lessThanOrEqualTo(actions.left - 6));
    expect(title.right, lessThanOrEqualTo(badge.left - 6));
    expect(tester.takeException(), isNull);
  });
}
