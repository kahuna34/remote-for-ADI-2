import 'package:adi2_remote/device/loopback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final hasInput in [false, true]) {
    test('Loopback round trip, hasInput=$hasInput', () {
      final selections = [
        (tap: 0, pair: 0),
        for (var pair = 0; pair < (hasInput ? 3 : 1); pair++)
          for (var tap = 1; tap <= 3; tap++) (tap: tap, pair: pair),
      ];
      for (var raw = 0; raw < selections.length; raw++) {
        final selection = selections[raw];
        expect(decodeLoopback(raw, hasInput: hasInput), selection);
        expect(
          encodeLoopback(
            tap: selection.tap,
            pair: selection.pair,
            hasInput: hasInput,
          ),
          raw,
        );
        expect(
          decodeLoopback(
            encodeLoopback(
              tap: selection.tap,
              pair: selection.pair,
              hasInput: hasInput,
            ),
            hasInput: hasInput,
          ),
          selection,
        );
      }
      for (var pair = 0; pair < (hasInput ? 3 : 1); pair++) {
        expect(encodeLoopback(tap: 0, pair: pair, hasInput: hasInput), 0);
      }
      for (final raw in [-1, hasInput ? 10 : 4]) {
        expect(() => decodeLoopback(raw, hasInput: hasInput), throwsRangeError);
      }
      for (final tap in [-1, 4]) {
        expect(
          () => encodeLoopback(tap: tap, pair: 0, hasInput: hasInput),
          throwsRangeError,
        );
      }
      for (final pair in [-1, hasInput ? 3 : 1]) {
        expect(
          () => encodeLoopback(tap: 1, pair: pair, hasInput: hasInput),
          throwsRangeError,
        );
      }
    });
  }
}
