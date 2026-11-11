import 'package:adi2_remote/analyzer/analyzer_routing.dart';
import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/protocol/adi2_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Device replies can disagree with optimistic UI writes, or never arrive.
class _Device extends Adi2Controller {
  final writes = <(int, int, int)>[];
  final actual = <int, int>{};
  bool echo = true;
  @override
  int? confirmedValue(int address, int index) => actual[address << 8 | index];
  @override
  void set(int address, int index, int value) {
    writes.add((address, index, value));
    if (echo) actual[address << 8 | index] = value;
    super.set(address, index, value);
  }

  void active(int output) {
    status = Adi2Status([output]);
    notifyListeners();
  }
}

Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 1100));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = AppSettings.instance;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
  });

  Future<_Device> device([Adi2Variant variant = Adi2Variant.dac]) async {
    final c = _Device();
    await c.startOffline(variant);
    for (final a in analyzerOutputAddresses(c)) {
      c.actual[a << 8 | OutIdx.loopback] = 0;
    }
    c.state = ConnState.connected;
    c.active(0);
    addTearDown(c.dispose);
    return c;
  }

  Future<AnalyzerRouting> routing(_Device c) async {
    await settings.confirmAnalyzerLoopback();
    await settings.setAnalyzerRouting(output: 0, tap: 2);
    final r = AnalyzerRouting(c)..setActive(true);
    addTearDown(r.dispose);
    return r;
  }

  test(
    'creation, showing and unrelated settings leave existing routing alone',
    () async {
      final c = await device();
      final r = await routing(c);
      await settings.setAnalyzerColor(2);
      await settings.setAnalyzerRange(80);
      r.setActive(false);
      r.setActive(true);
      c.notifyListeners();
      await settle();
      expect(c.writes, isEmpty);
    },
  );

  test('status/value storm and stale readbacks cause at most one write per transition', () async {
    final c = await device();
    await routing(c);
    c.echo = false;
    c.active(1);
    for (var i = 0; i < 15; i++) {
      c.actual[Adi2Addr.ph12 << 8 | OutIdx.volume] = -i;
      c.active(1);
    }
    await settle();
    expect(c.writes, [(Adi2Addr.ph12, OutIdx.loopback, 2)]);
    // Late old device values must never start a reconciliation loop.
    for (var i = 0; i < 15; i++) {
      c.actual[Adi2Addr.ph12 << 8 | OutIdx.loopback] = 0;
      c.active(1);
    }
    await settle();
    expect(c.writes.length, 1);
  });

  test('one second debounce coalesces rapid output changes', () async {
    final c = await device();
    await routing(c);
    c.active(1);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(c.writes, isEmpty);
    c.active(2);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(c.writes, isEmpty);
    await settle();
    expect(c.writes, [(Adi2Addr.ph34, OutIdx.loopback, 2)]);
  });

  test(
    'confirmed values gate writes even when optimistic values disagree',
    () async {
      final c = await device();
      await routing(c);
      c.echo = false;
      // UI says 2, device still says 0: the actual transition must write.
      c.set(Adi2Addr.ph12, OutIdx.loopback, 2);
      c.writes.clear();
      c.active(1);
      await settle();
      expect(c.writes, [(Adi2Addr.ph12, OutIdx.loopback, 2)]);
      // Device already has the desired route, UI says 0: no redundant command.
      c.actual[Adi2Addr.ph34 << 8 | OutIdx.loopback] = 2;
      c.set(Adi2Addr.ph34, OutIdx.loopback, 0);
      c.writes.clear();
      c.active(2);
      await settle();
      expect(c.writes, isEmpty);
    },
  );

  test('unknown device readbacks never authorize a write', () async {
    final c = await device();
    await routing(c);
    c.actual.clear();
    c.active(1);
    await settle();
    expect(c.writes, isEmpty);
  });

  test(
    'self-test cancels pending writes and restoration is never fought',
    () async {
      final c = await device();
      final r = await routing(c);
      c.active(1);
      c.analyzerSelfTestActive = true;
      c.active(2);
      await r.configure(output: 0, tap: 3);
      await settle();
      expect(c.writes, isEmpty);
      expect(settings.analyzerLoopbackTap, 2);
      c.actual[Adi2Addr.line << 8 | OutIdx.loopback] = 1;
      c.analyzerSelfTestActive = false;
      c.notifyListeners();
      await settle();
      expect(c.writes, isEmpty);
      // Only a fresh, real output switch after restoration may route again.
      c.active(1);
      await settle();
      expect(c.writes, [
        (Adi2Addr.line, OutIdx.loopback, 0),
        (Adi2Addr.ph12, OutIdx.loopback, 2),
      ]);
    },
  );

  test(
    'hidden/background router cancels and never catches up on show',
    () async {
      final c = await device();
      final r = await routing(c);
      c.active(1);
      r.setActive(false);
      c.active(2);
      await settle();
      expect(c.writes, isEmpty);
      r.setActive(true);
      c.notifyListeners();
      await settle();
      expect(c.writes, isEmpty);
      c.active(0);
      await settle();
      expect(c.writes, [(Adi2Addr.line, OutIdx.loopback, 2)]);
    },
  );

  test(
    'manual source changes once on user action and never follows status',
    () async {
      final c = await device();
      final r = await routing(c);
      await r.configure(output: Adi2Addr.ph12, tap: 3);
      expect(c.writes, [(Adi2Addr.ph12, OutIdx.loopback, 3)]);
      // Device page/hardware changes are respected, including another USB pair.
      c.actual[Adi2Addr.ph12 << 8 | OutIdx.loopback] = 1;
      c.writes.clear();
      c.active(2);
      c.selectedOutput = Adi2Addr.line;
      await settle();
      expect(c.writes, isEmpty);
    },
  );

  for (final variant in Adi2Variant.values) {
    test(
      'explicit output/tap/off persists and preserves other pairs: $variant',
      () async {
        final c = await device(variant);
        final r = await routing(c);
        for (final a in analyzerOutputAddresses(c)) {
          await r.configure(output: a, tap: 1);
          expect(c.confirmedValue(a, OutIdx.loopback), 1);
          await settings.load();
          expect(settings.analyzerLoopbackOutput, a);
          expect(settings.analyzerLoopbackTap, 1);
        }
        await r.configure(output: 0, tap: 2);
        expect(r.address, Adi2Addr.line);
        await r.configure(output: 0, tap: 0);
        expect(c.confirmedValue(Adi2Addr.line, OutIdx.loopback), 0);
        c.writes.clear();
        c.active(1);
        await settle();
        expect(c.writes, isEmpty);
      },
    );
  }

  test('competing USB 1/2 disabled first, other USB pairs survive', () async {
    final c = await device(Adi2Variant.pro);
    final r = await routing(c);
    c.set(Adi2Addr.line, OutIdx.loopback, 2);
    c.set(Adi2Addr.ph12, OutIdx.loopback, 5);
    c.set(Adi2Addr.ph34, OutIdx.loopback, 9);
    c.writes.clear();
    await r.configure(output: Adi2Addr.ph12, tap: 2);
    expect(c.writes, [
      (Adi2Addr.line, OutIdx.loopback, 0),
      (Adi2Addr.ph12, OutIdx.loopback, 2),
    ]);
    expect(c.value(Adi2Addr.ph34, OutIdx.loopback), 9);
    c.set(Adi2Addr.ph12, OutIdx.loopback, 5);
    c.writes.clear();
    await r.configure(output: Adi2Addr.ph12, tap: 0);
    expect(c.writes, isEmpty);
  });

  test(
    'DAC status overrides page selection and auto-switch preference',
    () async {
      final c = await device();
      await routing(c);
      settings.autoSwitchOutput = false;
      c.selectedOutput = Adi2Addr.ph34;
      await settle();
      expect(c.writes, isEmpty);
      c.active(1);
      await settle();
      expect(c.writes, [(Adi2Addr.ph12, OutIdx.loopback, 2)]);
    },
  );

  test(
    'Pro follows selected output without interpreting DAC status bits',
    () async {
      final c = await device(Adi2Variant.pro);
      c.selectedOutput = Adi2Addr.line;
      await routing(c);
      c.active(2);
      await settle();
      expect(c.writes, isEmpty);
      c.selectedOutput = Adi2Addr.ph34;
      await settle();
      expect(c.writes, [(Adi2Addr.ph34, OutIdx.loopback, 2)]);
    },
  );

  test(
    'disconnect, reconnect and dispose never replay a pending transition',
    () async {
      final c = await device();
      final r = await routing(c);
      c.active(1);
      c.state = ConnState.waitingForDevice;
      c.notifyListeners();
      c.active(2);
      c.state = ConnState.connected;
      c.notifyListeners();
      await settle();
      expect(c.writes, isEmpty);
      c.active(0);
      r.dispose();
      await settle();
      expect(c.writes, isEmpty);
    },
  );

  test(
    'first-use confirmation gates writes and survives settings reload',
    () async {
      final c = await device();
      await settings.setAnalyzerRouting(output: 0, tap: 2);
      final r = AnalyzerRouting(c)..setActive(true);
      addTearDown(r.dispose);
      c.active(1);
      await settle();
      expect(c.writes, isEmpty);
      await settings.confirmAnalyzerLoopback();
      await settings.load();
      expect(settings.analyzerLoopbackConfirmed, isTrue);
      c.active(2);
      await settle();
      expect(c.writes, [(Adi2Addr.ph34, OutIdx.loopback, 2)]);
    },
  );

  test(
    'upgrade adopts existing tap without moving it when analyzer opens',
    () async {
      final c = await device();
      c.set(Adi2Addr.line, OutIdx.loopback, 3);
      c.writes.clear();
      await settings.confirmAnalyzerLoopback();
      c.active(1);
      final r = AnalyzerRouting(c)..setActive(true);
      addTearDown(r.dispose);
      expect(r.tap, 3);
      await settle();
      expect(c.writes, isEmpty);
      c.active(2);
      await settle();
      expect(c.writes, [
        (Adi2Addr.line, OutIdx.loopback, 0),
        (Adi2Addr.ph34, OutIdx.loopback, 3),
      ]);
      await r.configure(output: 0, tap: 0);
      expect(c.value(Adi2Addr.ph34, OutIdx.loopback), 0);
    },
  );
}
