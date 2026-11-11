import 'package:adi2_remote/ui/start_animation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Startsymbol erscheint und gibt danach die Startseite frei', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: StartAnimation(child: Text('Startseite'))),
    );
    expect(find.byKey(const ValueKey('start-icon')), findsOneWidget);
    expect(find.text('Startseite'), findsOneWidget);
    await tester.pump(
      StartAnimation.duration + const Duration(milliseconds: 50),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('start-icon')), findsNothing);
    expect(find.text('Startseite'), findsOneWidget);
  });

  testWidgets('Ohne Animationen sofort die Startseite', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(home: StartAnimation(child: Text('Startseite'))),
      ),
    );
    expect(find.byKey(const ValueKey('start-icon')), findsNothing);
  });
}
