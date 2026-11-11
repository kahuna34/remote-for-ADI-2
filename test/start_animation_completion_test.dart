import 'package:adi2_remote/ui/start_animation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final reduced in [false, true]) {
    testWidgets('start completion fires once, reduced motion: $reduced', (
      tester,
    ) async {
      var completions = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: StartAnimation(
              onComplete: () => completions++,
              child: const SizedBox(),
            ),
          ),
        ),
      );
      if (!reduced) {
        expect(completions, 0);
        await tester.pump();
        await tester.pump(
          StartAnimation.duration + const Duration(milliseconds: 50),
        );
        await tester.pump();
      }
      expect(completions, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(completions, 1);
    });
  }
}
