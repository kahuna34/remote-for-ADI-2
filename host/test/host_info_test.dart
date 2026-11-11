import 'dart:io';

import 'package:adi2_host/host_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('host version matches pubspec version and build number', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec must contain version + build');
    expect(hostVersion, '${match![1]} (${match[2]})');
  });
}
