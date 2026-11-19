import 'dart:async';

import 'package:adi2_remote/analyzer/analyzer_controller.dart';

/// Tests prüfen das Abschalten der Aufnahme nach kurzer Zeit; der lange
/// Nachlauf der App (gegen Wiedergabe-Aussetzer beim Wischen) gilt nur
/// in der App.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AnalyzerController.localVisibilityGrace = const Duration(milliseconds: 500);
  await testMain();
}
