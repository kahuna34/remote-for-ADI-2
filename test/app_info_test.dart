import 'dart:io';

import 'package:adi2_remote/app_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('displayed app version matches pubspec version and build number', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec must contain version + build');
    expect(appVersion, '${match![1]} (${match[2]})');
  });
}
