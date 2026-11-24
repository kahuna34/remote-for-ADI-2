import 'package:adi2_host/linux_instance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Instance activation accepts only versioned show and ping messages', () {
    expect(parseInstanceMessage('adi2-instance-v1 show'), 'show');
    expect(parseInstanceMessage('adi2-instance-v1 ping'), 'ping');
    for (final line in [
      '',
      'show',
      'adi2-instance-v2 show',
      'adi2-instance-v1 quit',
      'adi2-instance-v1 show extra',
      'adi2-instance-v1 show\n',
    ]) {
      expect(() => parseInstanceMessage(line), throwsFormatException);
    }
  });
}
