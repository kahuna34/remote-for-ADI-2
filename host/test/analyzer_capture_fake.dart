import 'dart:async';

import 'package:adi2_host/host_analyzer.dart';

class FakeAnalyzerCapture implements HostAnalyzerCapture {
  final input = StreamController<dynamic>.broadcast(sync: true);
  int starts = 0, stops = 0;
  Object? failure;
  Completer<void>? starting;
  @override
  Stream<dynamic> get events => input.stream;
  @override
  Future<void> start() async {
    starts++;
    await starting?.future;
    if (failure case final error?) throw error;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}
