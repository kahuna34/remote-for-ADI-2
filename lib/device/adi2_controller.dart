// Verbindung zum ADI-2 über USB-MIDI und Spiegel des Gerätezustands.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../host/host_client.dart';
import '../host/host_errors.dart';
import '../host/host_discovery.dart';
import '../protocol/adi2_codec.dart';
import '../protocol/adi2_params.dart';
import '../protocol/adi2_status.dart';
import 'volume_guard.dart';
import 'volume_options.dart';
import '../eq/eq_model.dart';
import '../app_settings.dart';
import 'supported_models.dart';
import 'backup.dart';
import 'offline_defaults.dart';
import 'usb_cc_mode.dart';

enum ConnState {
  idle,
  searching,
  connecting,
  waitingForDevice,
  connected,
  offline,
}

class Adi2Controller extends ChangeNotifier {
  Adi2Controller({
    MidiCommand? midi,
    HostClient? host,
    Future<UsbCcMode> Function()? ccModeReader,
  }) : host = host ?? HostClient(),
       _midi = midi ?? MidiCommand(),
       _ccModeReader = ccModeReader ?? readUsbCcMode;

  final Future<UsbCcMode> Function() _ccModeReader;
  UsbCcMode _ccMode = UsbCcMode.unknown;
  UsbCcMode get ccMode => _ccMode;
  int _ccModeRequest = 0;

  Future<void> refreshCcMode() async {
    final request = ++_ccModeRequest;
    var mode = UsbCcMode.unknown;
    if (!offline && device != null && !_viaHost) {
      try {
        mode = await _ccModeReader();
      } catch (_) {
        // Unavailable platform, permission or detached device.
      }
    }
    if (request != _ccModeRequest) return;
    if (_ccMode != mode) {
      _ccMode = mode;
      notifyListeners();
    }
  }

  // Temporary developer self-test lease and genuine device readbacks.
  bool _analyzerSelfTestActive = false;
  bool get analyzerSelfTestActive => _analyzerSelfTestActive;
  set analyzerSelfTestActive(bool value) {
    if (_analyzerSelfTestActive == value) return;
    _analyzerSelfTestActive = value;
    if (value) _daFilterPauseGeneration++;
    _maybeProbeDaFilter();
    notifyListeners();
  }

  final analyzerSelfTestReadbacks = StreamController<List<Adi2Param>>.broadcast(
    sync: true,
  );

  final HostClient host;
  bool _viaHost = false;
  bool get viaHost => _viaHost;
  String? get hostName => _viaHost ? host.hostName : null;

  /// Kennung des Hosts, über den gerade verbunden ist.
  String? get hostId => _viaHost ? _preferredHost?.host.id : null;
  bool get hostAvailable => Platform.isAndroid || Platform.isIOS;
  List<HostCredentials> pairedHosts = [];
  final HostDiscovery _hostDiscovery = HostDiscovery();
  HostDiscovery get hostDiscovery => _hostDiscovery;
  StreamSubscription<Uint8List>? _hostRx;
  Timer? _hostRetry;
  bool _hostConnecting = false;
  bool _hostForeground = true;
  HostCredentials? _preferredHost;

  Future<void> savePairedHost(HostCredentials credentials) async {
    final updated = [
      credentials,
      ...pairedHosts.where((h) => h.host.id != credentials.host.id),
    ];
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      'paired_hosts_v1',
      jsonEncode(updated.map((h) => h.toJson()).toList()),
    )) {
      throw StateError(tr('Kopplung konnte nicht gespeichert werden'));
    }
    pairedHosts = updated;
    notifyListeners();
  }

  Future<void> forgetHost(String id) async {
    final updated = pairedHosts.where((h) => h.host.id != id).toList();
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      'paired_hosts_v1',
      jsonEncode(updated.map((h) => h.toJson()).toList()),
    )) {
      throw StateError(tr('Kopplung konnte nicht gespeichert werden'));
    }
    pairedHosts = updated;
    if (_preferredHost?.host.id == id) {
      _preferredHost = null;
      if (_viaHost) disconnect();
    }
    notifyListeners();
  }

  void setHostForeground(bool foreground) {
    _hostForeground = foreground;
    host.setForeground(foreground);
    if (!foreground) stopAllVolumeRamps();
    if (foreground && (device == null || _viaHost)) unawaited(_autoConnect());
  }

  Future<void> connectHost(HostCredentials credentials) async {
    if (_hostConnecting || _disposed || offline || !hostAvailable) return;
    if (device != null && !_viaHost) return;
    final discovered = hostDiscovery.hosts[credentials.host.id];
    if (discovered != null) {
      credentials = HostCredentials(
        discovered,
        credentials.deviceId,
        credentials.key,
      );
    }
    _preferredHost = credentials;
    _hostConnecting = true;
    _reset();
    _offlineVariant = null;
    _offlineLabel = null;
    _viaHost = true;
    error = null;
    state = ConnState.connecting;
    notifyListeners();
    try {
      await host.connect(credentials);
      if (_disposed || !_viaHost || !host.connected) return;
      device = MidiDevice(
        'host:${credentials.host.id}',
        host.deviceName!,
        MidiDeviceType.network,
        true,
      );
      state = ConnState.waitingForDevice;
      _probe(); // immer frisch lesen, keine alten Werte oder Befehle übernehmen
    } catch (e) {
      if (_viaHost && !_disposed) {
        _reset();
        error = hostErrorText(e.toString());
        state = ConnState.searching;
      }
    } finally {
      _hostConnecting = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _hostChanged() {
    if (!_viaHost || host.connected || _hostConnecting || _disposed) return;
    _reset();
    error = hostErrorText(host.error ?? '');
    state = ConnState.searching;
    notifyListeners();
  }

  final MidiCommand _midi;
  final SysexAssembler _assembler = SysexAssembler();
  StreamSubscription? _rxSub;
  StreamSubscription? _setupSub;
  Timer? _probeTimer;
  Timer? _watchdog;
  Timer? _volTimer;
  final VolumeGuard volGuard = VolumeGuard();
  final Map<int, int> _lastSentVol = {};
  final Map<int, DateTime> _lastVolSentAt = {};

  /// Zeitpunkt eigener Schreibbefehle je Parameter (außer Lautstärke).
  final Map<int, DateTime> _ownWriteAt = {};

  /// Über den Host kommen Antworten bis zu gut einer Sekunde verspätet (die
  /// vollständige Antwort des Geräts dauert etwa 0,7 s). Eine abweichende
  /// Antwort kurz nach einem eigenen Befehl ist daher meist noch der alte
  /// Stand und darf die Anzeige nicht zurücksetzen.
  static const hostOwnWriteHold = Duration(milliseconds: 1500);

  bool _isStaleOwnWrite(Adi2Param p) {
    if (!_viaHost || p.index == OutIdx.volume) return false;
    final at = _ownWriteAt[p.key];
    return at != null &&
        DateTime.now().difference(at) < hostOwnWriteHold &&
        _values[p.key] != p.value;
  }

  void _noteOwnWrites(Iterable<Adi2Param> params) {
    if (!_viaHost) return;
    final now = DateTime.now();
    for (final p in params) {
      _ownWriteAt[p.key] = now;
    }
  }

  final Set<int> _limitHit = {};
  VolumeOptions opts = VolumeOptions();
  final Map<int, int> _eqTarget = {}; // key: address<<8|index
  List<Adi2Param>? _capture; // Daten einer laufenden Preset-Abfrage
  int? _capturePreset, _incomingPreset;
  List<EqPresetData>? _eqPresets;
  Future<List<EqPresetData>>? _presetRead;
  int _presetSession = 0;
  Future<void> _presetAccess = Future.value();
  double? eqPresetReadProgress;

  /// Zwischengespeicherte Presets der aktuellen Verbindung (vollständig: 20).
  List<EqPresetData>? get eqPresets => _eqPresets;
  DateTime _lastCapture = DateTime.fromMillisecondsSinceEpoch(0);
  static const volumeAddresses = [Adi2Addr.line, Adi2Addr.ph12, Adi2Addr.ph34];
  DateTime _lastRx = DateTime.fromMillisecondsSinceEpoch(0);

  ConnState state = ConnState.idle;
  String? error;
  List<MidiDevice> devices = [];
  MidiDevice? device;

  Adi2Model? model;
  Adi2Status? status;
  final Map<int, int> _values = {}; // key: address<<8 | index
  final Map<int, int> _confirmedValues = {};
  final Map<int, int> _confirmedMessages = {};
  int _connectionSession = 0;
  int _daFilterAttemptSession = -1;
  int _daFilterPauseCount = 0;
  int _daFilterPauseGeneration = 0;
  Future<void>? _daFilterProbe;
  bool _disposed = false;
  final Map<int, String> names = {}; // Slot -> Name (EQ-Presets, Setups)

  Adi2Variant? _offlineVariant;
  Timer? _offlineSave;
  Timer? _readbackTimer;
  DateTime? _readbackSent;
  int _watchdogTicks = 0;

  Adi2Variant? get variant =>
      _offlineVariant ??
      (model == null ? null : variantFor(model!, ex: status?.isEx ?? false));

  /// Bedienbar: echtes Gerät verbunden oder Offline-Modus.
  bool get isConnected =>
      state == ConnState.connected || state == ConnState.offline;

  bool get offline => state == ConnState.offline;

  /// Wird [address] vom Gerät automatisch stummgeschaltet (z. B. Line Out,
  /// weil ein Kopfhörer steckt)? Gemessen am ADI-2 DAC: Statusbyte 6 Bit 1..0
  /// = aktiver Ausgang (0 = Line). Für Pro/2-4 noch nicht verifiziert -> false.
  bool autoMuted(int address) {
    final v = variant, s = status;
    if (v == null || s == null || offline) return false;
    if (v.isDac && address == Adi2Addr.line) {
      final muteVs = valueOr(Adi2Addr.device, 1, 0); // "Mute Line vs."
      return muteVs != 0 && s.activeOutput != 0;
    }
    return false;
  }

  /// Ref-Level eines Ausgangs umschalten. Mit [compensate] wird die
  /// Lautstärke vorher um den Pegelunterschied gesenkt (bzw. danach langsam
  /// angehoben), sodass es gleich laut bleibt. Die dBu-Grenze gilt immer.
  void setRefLevel(int address, int index, {bool compensate = true}) {
    final v = variant;
    if (v == null) return;
    final table = refTable(v, address);
    final cur = value(address, OutIdx.refLevel);
    final vol = value(address, OutIdx.volume);
    if (compensate &&
        cur != null &&
        vol != null &&
        cur < table.length &&
        index < table.length) {
      final deltaRaw = ((table[index] - table[cur]) * 10).round();
      if (deltaRaw > 0) {
        // lauter: Lautstärke senken und umschalten in EINER Nachricht
        // (Absenkung zuerst). Über den Host darf keine Geräteantwort
        // zwischen beide geraten, sonst gilt die Umschaltung als
        // unausgeglichen und wird gesperrt.
        final lowered = (vol - deltaRaw).clamp(volMinRaw, volMaxRaw);
        volGuard.cancel(address);
        _lastSentVol[address] = lowered;
        setMany([
          Adi2Param(address, OutIdx.volume, lowered),
          Adi2Param(address, OutIdx.refLevel, index),
        ]);
        // Grenze des neuen Ref Levels danach anwenden (senkt nur).
        _applyLimits(sendNow: true);
        return;
      }
      if (deltaRaw < 0) {
        // leiser: erst umschalten, dann langsam wieder auf gleiche Lautheit
        set(address, OutIdx.refLevel, index);
        setVolume(address, vol - deltaRaw, followLink: false);
        return;
      }
    }
    set(address, OutIdx.refLevel, index);
  }

  /// Wechselt die Hauptansicht zum aktiven Ausgang, wenn das Gerät einen
  /// neuen meldet (z. B. Kopfhörer eingesteckt). Gemessen am ADI-2 DAC:
  /// Statusbyte 6 Bit 1..0 = 0 Line, 1 Phones, 2 IEM (alle drei am Gerät
  /// bestätigt, 2026-11-05). Beim Pro/2-4 sind die
  /// Bits anders belegt (noch nicht vermessen) -> dort kein Wechsel.
  void _maybeSwitchOutput(int? prev, int now) {
    if (prev == null || prev == now) return;
    if (!AppSettings.instance.autoSwitchOutput) return;
    if (variant?.isDac != true) return;
    const map = {0: Adi2Addr.line, 1: Adi2Addr.ph12, 2: Adi2Addr.ph34};
    final addr = map[now];
    if (addr != null) selectedOutput = addr;
  }

  /// Gerät mit ESS-Wandler (hat Brickwall-Filter und Expert Settings).
  /// Gemessen: ADI-2 DAC mit ESS meldet Geräte-Revision 2 (2026-11-05).
  /// Für Pro/2-4 noch nicht vermessen -> false.
  bool get hasEss =>
      variant == Adi2Variant.dac && (status?.deviceRevision ?? 0) >= 2;

  /// Auf der Hauptseite gewählter Ausgang (Adresse 3/6/9), null = Standard.
  final selectedOutputChanges = ValueNotifier<int?>(null);
  int? get selectedOutput => selectedOutputChanges.value;
  set selectedOutput(int? value) => selectedOutputChanges.value = value;

  String? _offlineLabel;

  /// Seriennummer aus dem USB-Namen, falls das Gerät sie meldet.
  String? get deviceSerial =>
      RegExp(r'\((\d+)\)').firstMatch(device?.name ?? '')?.group(1);

  /// Anzeigename des Geräts. Der ADI-2 Pro EX meldet sich mit derselben
  /// Geräte-ID und demselben USB-Namen wie der ADI-2 Pro und ist nur an der
  /// Seriennummer zu erkennen.
  String get deviceLabel {
    if (offline && _offlineLabel != null) return _offlineLabel!;
    if (variant == Adi2Variant.pro &&
        isProExSerial(deviceSerial) &&
        AppSettings.instance.daFilterSdLd(deviceSerial) != false) {
      return 'ADI-2 Pro EX';
    }
    return variant?.label ?? 'ADI-2';
  }

  /// AD-Wandler des verbundenen Geräts, soweit sicher bekannt.
  String? get adConverter => offline
      ? null
      : switch (variant) {
          Adi2Variant.pro => 'AK5574',
          Adi2Variant.pro4se => 'ES9822Pro',
          Adi2Variant.pro4ex => 'ES9823Pro',
          _ => null,
        };

  /// DA-Wandler des verbundenen Geräts. AK4490 und AK4493 unterscheidet erst
  /// die einmalige SD-LD-Prüfung; bis dahin bleibt der Wert unbekannt.
  String? get daConverter {
    if (offline) return null;
    final v = variant;
    if (v == Adi2Variant.pro4se) return 'ES9038Q2M';
    if (v == Adi2Variant.pro4ex) return 'ES9039Q2M';
    if (v == Adi2Variant.dac && hasEss) return 'ES9028Q2M';
    if (v != Adi2Variant.pro && v != Adi2Variant.dac) return null;
    return switch (AppSettings.instance.daFilterSdLd(deviceSerial)) {
      true => 'AK4493',
      false => 'AK4490',
      null => null,
    };
  }

  int? value(int address, int index) => _values[address << 8 | index];

  /// Only MIDI readbacks, never optimistic UI writes or offline defaults.
  int? confirmedValue(int address, int index) =>
      _confirmedValues[address << 8 | index];

  bool isParamValueDisabled(int address, int index, int value) =>
      volumeAddresses.contains(address) &&
      index == OutIdx.daFilter &&
      value == 5 &&
      !hasEss &&
      const {Adi2Variant.pro, Adi2Variant.dac}.contains(variant) &&
      AppSettings.instance.daFilterSdLd(deviceSerial) == false;

  /// Verschiebt die Filterprüfung bis zum Ende einer Messung/Übertragung.
  /// Ein bereits laufender Versuch wird zuerst inklusive Rückstellung beendet.
  Future<T> withDaFilterProbePaused<T>(Future<T> Function() action) async {
    _daFilterPauseCount++;
    try {
      final probe = _daFilterProbe;
      if (probe != null) await probe;
      return await action();
    } finally {
      _daFilterPauseCount--;
      _maybeProbeDaFilter();
    }
  }

  bool get _daFilterBlocked =>
      analyzerSelfTestActive || _daFilterPauseCount != 0;

  bool get _daFilterEligible =>
      !_disposed &&
      state == ConnState.connected &&
      device != null &&
      deviceSerial != null &&
      status != null &&
      !hasEss &&
      const {Adi2Variant.pro, Adi2Variant.dac}.contains(variant) &&
      confirmedValue(Adi2Addr.line, OutIdx.daFilter) != null;

  void _maybeProbeDaFilter() {
    if (!_daFilterEligible ||
        _daFilterBlocked ||
        _daFilterProbe != null ||
        _daFilterAttemptSession == _connectionSession) {
      return;
    }
    final session = _connectionSession;
    _daFilterAttemptSession = session;
    // Erst im nächsten Microtask starten, damit auch synchrone MIDI-Antworten
    // keinen zweiten Versuch beginnen können.
    final probe = Future<void>.microtask(() => _probeDaFilter(session));
    _daFilterProbe = probe;
    unawaited(
      probe.whenComplete(() {
        _daFilterProbe = null;
        _maybeProbeDaFilter();
      }),
    );
  }

  Future<void> _probeDaFilter(int session) async {
    final serial = deviceSerial;
    final target = device;
    final id = model?.id;
    final pauseGeneration = _daFilterPauseGeneration;
    if (serial == null || target == null || id == null) return;
    final settings = AppSettings.instance;
    bool current() =>
        session == _connectionSession &&
        identical(device, target) &&
        deviceSerial == serial &&
        model?.id == id &&
        _daFilterEligible &&
        !analyzerSelfTestActive &&
        pauseGeneration == _daFilterPauseGeneration;

    bool write(int value) {
      if (!current()) return false;
      for (final packet in buildSetParams(id, [
        Adi2Param(Adi2Addr.line, OutIdx.daFilter, value),
      ])) {
        if (!current()) return false;
        _send(packet);
      }
      return true;
    }

    Future<int?> readFresh({int? expected}) async {
      for (var attempt = 0; attempt < 3; attempt++) {
        if (!current()) return null;
        final fresh = await refreshConfirmedValues(
          requiredKeys: [Adi2Addr.line << 8 | OutIdx.daFilter],
        );
        if (!current()) return null;
        final value = confirmedValue(Adi2Addr.line, OutIdx.daFilter);
        if (fresh && value != null && (expected == null || value == expected)) {
          return value;
        }
      }
      return null;
    }

    try {
      await settings.loadDaFilterSettings();
      if (!current()) return;
      final pending = settings.daFilterProbePending(serial);
      if (pending != null) {
        if (!write(pending) || await readFresh(expected: pending) == null) {
          return;
        }
        if (!current()) return;
        await settings.setDaFilterProbePending(serial, null);
        if (!current()) return;
      }
      if (settings.daFilterSdLd(serial) != null) return;
      final original = confirmedValue(Adi2Addr.line, OutIdx.daFilter);
      if (original == null || original < 0 || original > 5) return;
      if (original == 5) {
        await settings.setDaFilterSdLd(serial, true);
        return;
      }
      await settings.setDaFilterProbePending(serial, original);
      if (!write(5)) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final tested = await readFresh();
      // Auch bei fehlender Testantwort den Ausgangsfilter zurückstellen.
      if (!write(original)) return;
      final restored = await readFresh(expected: original);
      if (tested == null || restored == null || !current()) return;
      await settings.setDaFilterSdLd(serial, tested == 5);
      if (!current()) return;
      await settings.setDaFilterProbePending(serial, null);
    } catch (error) {
      debugPrint('DA filter probe failed: $error');
    } finally {
      if (!_disposed && session == _connectionSession) {
        // Nur ein zwischenzeitlicher Sperrgrund erlaubt einen weiteren Anlauf
        // in derselben Verbindung. Timeouts warten auf das nächste Verbinden.
        if (pauseGeneration != _daFilterPauseGeneration) {
          _daFilterAttemptSession = -1;
        }
        notifyListeners();
      }
    }
  }

  int valueOr(int address, int index, int fallback) =>
      _values[address << 8 | index] ?? fallback;

  /// Rear TRS wird unter Phones 3/4 bedient. Die gemeldete Adresse hat
  /// Vorrang; ältere Zustände und Offline-Defaults führen ihn bei Line (3).
  int outputParamAddress(int address, int index) {
    if (variant?.isPro4 == true &&
        address == Adi2Addr.ph34 &&
        index == OutIdx.rearTrsSource &&
        value(address, index) == null) {
      return Adi2Addr.line;
    }
    return address;
  }

  // -------------------------------------------------------------------------

  Future<void> start() async {
    if (hostAvailable && _hostRx == null) {
      unawaited(hostDiscovery.start());
      _hostRx ??= host.packets.stream.listen((bytes) {
        if (!_viaHost || !host.connected || device == null) return;
        final message = parseSysex(bytes);
        if (message != null) _handle(message);
      });
      host.addListener(_hostChanged);
      try {
        final prefs = await SharedPreferences.getInstance();
        pairedHosts =
            ((jsonDecode(prefs.getString('paired_hosts_v1') ?? '[]')) as List)
                .map((j) => HostCredentials.fromJson(j as Map<String, dynamic>))
                .toList();
      } catch (_) {
        pairedHosts = [];
      }
      _hostRetry ??= Timer.periodic(const Duration(seconds: 3), (_) {
        if (!_disposed &&
            !offline &&
            _hostForeground &&
            !_hostConnecting &&
            (device == null || (_viaHost && !host.connected))) {
          unawaited(_autoConnect());
        }
      });
    }
    _midi.configureBleTransport(null);
    _midi.configureTransportPolicy(
      const MidiTransportPolicy(excludedTransports: {MidiTransport.ble}),
    );
    _rxSub ??= _midi.onMidiPacketReceived?.listen(_onPacket);
    _setupSub ??= _midi.onMidiSetupChanged?.listen((_) => _autoConnect());
    await _autoConnect();
  }

  Future<void> refreshDevices() async {
    final found = (await _midi.devices) ?? [];
    if (_disposed) return;
    devices = found;
    notifyListeners();
  }

  static bool _looksLikeAdi(MidiDevice d) {
    final n = d.name.toLowerCase();
    return n.contains('adi-2') || n.contains('adi2') || n.contains('adi 2');
  }

  /// CoreMIDI meldet das ADI-2 teils nur als "Port 1". Auf Apple-Geräten gilt
  /// deshalb ein einzelnes so benanntes Gerät als Kandidat; die Abfrage danach
  /// zeigt, ob wirklich ein ADI-2 antwortet.
  static List<MidiDevice> autoConnectCandidates(
    List<MidiDevice> devices,
    TargetPlatform platform,
  ) {
    final named = devices.where(_looksLikeAdi).toList();
    if (named.isNotEmpty) return named;
    final apple =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
    final genericPort = RegExp(r'^port \d+$', caseSensitive: false);
    return apple &&
            devices.length == 1 &&
            genericPort.hasMatch(devices.single.name.trim())
        ? devices
        : const [];
  }

  Future<void> _autoConnect() async {
    await refreshDevices();
    if (_disposed || offline) {
      return; // im Offline-Modus nicht automatisch verbinden
    }
    final usb = autoConnectCandidates(devices, defaultTargetPlatform);
    if (_viaHost && usb.isNotEmpty) {
      host.disconnect();
      _viaHost = false;
      _reset();
      await connect(usb.first);
      return;
    }
    if (_viaHost && host.connected) return;
    if (device != null) {
      final stillThere = devices.any((d) => d.id == device!.id);
      if (!stillThere) _lost(tr('Gerät getrennt'));
      return;
    }
    final cand = autoConnectCandidates(devices, defaultTargetPlatform);
    if (cand.isEmpty) {
      final preferred = _preferredHost ?? pairedHosts.firstOrNull;
      if (hostAvailable &&
          preferred != null &&
          _hostForeground &&
          !_hostConnecting) {
        await connectHost(preferred);
        return;
      }
      state = ConnState.searching;
      notifyListeners();
      return;
    }
    await connect(cand.first);
  }

  Future<void> connect(MidiDevice d) async {
    if (_viaHost) {
      host.disconnect();
    } else if (device != null) {
      _midi.disconnectDevice(device!);
    }
    _viaHost = false;
    _reset();
    _offlineVariant = null;
    _offlineLabel = null;
    final session = _connectionSession;
    _ccModeRequest++;
    _ccMode = UsbCcMode.unknown;
    error = null;
    state = ConnState.connecting;
    device = d;
    notifyListeners();
    try {
      await _midi.connectToDevice(d);
    } catch (e) {
      if (session != _connectionSession) return;
      error = trf('Verbindung fehlgeschlagen: {fehler}', {'fehler': e});
      device = null;
      state = ConnState.searching;
      notifyListeners();
      return;
    }
    if (session != _connectionSession) return;
    state = ConnState.waitingForDevice;
    unawaited(refreshCcMode());
    notifyListeners();
    _probe();
  }

  /// Fragt alle Geräte-IDs ab (oder die aus dem Namen erratene), bis eine
  /// Antwort kommt.
  /// Anzahl unbeantworteter Abfragen seit dem Verbinden.
  int probeTries = 0;

  /// Ein ADI-2 ist per USB da, antwortet aber nicht über MIDI
  /// (typisch: MIDI Control am Gerät ausgeschaltet).
  bool get noMidiAnswer =>
      state == ConnState.waitingForDevice && probeTries >= 3;

  void _probe() {
    _probeTimer?.cancel();
    probeTries = 0;
    void send() {
      if (state == ConnState.connected || device == null) {
        _probeTimer?.cancel();
        return;
      }
      final ids = _guessIds(device!.name);
      for (final id in ids) {
        _send(buildRequestAll(id));
      }
      probeTries++;
      if (probeTries == 3) notifyListeners();
    }

    send();
    _probeTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => send(),
    );
  }

  List<int> _guessIds(String name) {
    final n = name.toLowerCase();
    if (n.contains('dac')) return [Adi2Model.dac.id];
    if (n.contains('2/4') ||
        n.contains('2-4') ||
        n.contains(' se') ||
        n.contains(' ex')) {
      return [Adi2Model.pro4.id];
    }
    return Adi2Model.values.map((m) => m.id).toList();
  }

  void disconnect() {
    if (_viaHost) {
      host.disconnect();
      _viaHost = false;
    } else if (device != null) {
      _midi.disconnectDevice(device!);
    }
    _reset();
    state = ConnState.idle;
    notifyListeners();
  }

  void _lost(String why) {
    _reset();
    error = why;
    state = ConnState.searching;
    notifyListeners();
  }

  void _reset() {
    _connectionSession++;
    _ccModeRequest++;
    _ccMode = UsbCcMode.unknown;
    _probeTimer?.cancel();
    _watchdog?.cancel();
    _volTimer?.cancel();
    _volTimer = null;
    _readbackTimer?.cancel();
    _readbackTimer = null;
    volGuard.cancelAll();
    _lastSentVol.clear();
    _eqTarget.clear();
    device = null;
    model = null;
    selectedOutput = null;
    status = null;
    _values.clear();
    _confirmedValues.clear();
    _confirmedMessages.clear();
    names.clear();
    _presetSession++;
    _eqPresets = null;
    _presetRead = null;
    _presetAccess = Future.value();
    _capture = null;
    _capturePreset = _incomingPreset = null;
    eqPresetReadProgress = null;
  }

  // -------------------------------------------------------------------------
  // Empfang

  void _onPacket(MidiPacket p) {
    if (_viaHost || offline) return;
    if (device != null && p.device.id != device!.id) return;
    for (final msg in _assembler.add(p.data)) {
      final m = parseSysex(msg);
      if (m != null) _handle(m);
    }
  }

  void _handle(Adi2Message m) {
    _lastRx = DateTime.now();
    if (model == null || model!.id != m.deviceId) {
      model = Adi2Model.fromId(m.deviceId);
    }
    if (state != ConnState.connected) {
      state = ConnState.connected;
      unawaited(refreshCcMode());
      error = null;
      _probeTimer?.cancel();
      _startWatchdog();
      _send(buildRequestAll(m.deviceId));
      _loadOptions();
      Future.delayed(const Duration(milliseconds: 600), requestPresetNames);
      _volTimer ??= Timer.periodic(
        const Duration(milliseconds: volTickMs),
        (_) => _volTick(),
      );
    }
    switch (m) {
      case Adi2ParamsMessage(:final params):
        _paramsMessages++;
        analyzerSelfTestReadbacks.add(params);
        for (final p in params) {
          if (_isStaleVolumeReadback(p) || _isStaleOwnWrite(p)) continue;
          _values[p.key] = p.value;
          _confirmedValues[p.key] = p.value;
          _confirmedMessages[p.key] = _paramsMessages;
          // Der Host verteilt auch Presetantworten anderer Clients. Der
          // vorangestellte Flag-Wert ordnet die folgenden Daten einem Slot zu.
          if (p.address == Adi2Addr.presetEqL &&
              p.index == EqIdx2.presetFlags) {
            _incomingPreset = p.value >> 4;
          }
          if (_capture != null &&
              _incomingPreset == _capturePreset &&
              (p.address == Adi2Addr.presetEqL ||
                  p.address == Adi2Addr.presetEqR)) {
            _capture!.add(p);
            _lastCapture = DateTime.now();
          }
          if (p.index == OutIdx.volume && volumeAddresses.contains(p.address)) {
            _onDeviceVolume(p.address, p.value);
          }
          if (p.index == OutIdx.refLevel &&
              volumeAddresses.contains(p.address)) {
            _applyLimits();
          }
        }
      case Adi2NameMessage(:final slot, :final name):
        names[slot] = name;
      case Adi2StatusMessage(:final data):
        final prev = status?.activeOutput;
        status = Adi2Status(data);
        _maybeSwitchOutput(prev, status!.activeOutput);
    }
    _maybeProbeDaFilter();
    notifyListeners();
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      // Über den Host fragt der Host selbst laufend ab (mit Pausen für die
      // Statusmeldung des Geräts); hier daher wie bei USB alle 10 s.
      if (++_watchdogTicks % 5 == 0 && _readbackTimer == null) _readback();
      if (DateTime.now().difference(_lastRx) > const Duration(seconds: 5)) {
        // Kein Status mehr -> neu anfragen
        state = ConnState.waitingForDevice;
        _connectionSession++;
        status = null;
        _confirmedValues.clear();
        _confirmedMessages.clear();
        notifyListeners();
        _watchdog?.cancel();
        _probe();
      }
    });
  }

  // -------------------------------------------------------------------------
  // Senden

  void _send(Uint8List data) {
    if (device == null || offline) return;
    try {
      if (_viaHost) {
        host.sendMidi(data);
      } else {
        _midi.sendData(data, deviceId: device!.id);
      }
    } catch (e) {
      debugPrint('MIDI senden fehlgeschlagen: $e');
    }
  }

  /// Setzt einen Parameter (optimistisch lokal, dann ans Gerät).
  void set(int address, int index, int value) {
    if (isParamValueDisabled(address, index, value)) return;
    final id = model?.id;
    if (id == null) return;
    if (index == OutIdx.volume && volumeAddresses.contains(address)) {
      setVolume(address, value); // nie ohne Schutz
      return;
    }
    if (index == OutIdx.refLevel && volumeAddresses.contains(address)) {
      // Erst Grenze für den neuen Ref-Level setzen und eine zu hohe
      // Lautstärke sofort senken – danach erst umschalten.
      _values[address << 8 | index] = value;
      _applyLimits(sendNow: true);
    }
    _values[address << 8 | index] = value;
    if (variant?.isDac == true &&
        volumeAddresses.contains(address) &&
        index == OutIdx.loopback) {
      for (final output in volumeAddresses) {
        if (_values.containsKey(output << 8 | index)) {
          _values[output << 8 | index] = value;
        }
      }
    }
    _noteOwnWrites([Adi2Param(address, index, value)]);
    notifyListeners();
    if (offline) _scheduleOfflineSave();
    for (final m in buildSetParams(id, [Adi2Param(address, index, value)])) {
      _send(m);
    }
    _scheduleReadback();
  }

  void setMany(List<Adi2Param> params) {
    final id = model?.id;
    if (id == null || params.isEmpty) return;
    for (final p in params) {
      _values[p.key] = p.value;
    }
    _noteOwnWrites(params);
    notifyListeners();
    if (offline) _scheduleOfflineSave();
    for (final m in buildSetParams(id, params)) {
      _send(m);
    }
    _scheduleReadback();
  }

  // -------------------------------------------------------------------------
  // Das Gerät ist die Quelle: Nach Änderungen und regelmäßig wird sein echter
  // Zustand zurückgelesen, weil es per MIDI gesetzte Werte nicht immer meldet.

  bool get _readbackPossible =>
      !offline &&
      device != null &&
      state == ConnState.connected &&
      !analyzerSelfTestActive;

  bool get _readbackBusy =>
      !volGuard.isIdle || _eqTarget.isNotEmpty || _capture != null;

  void _scheduleReadback() {
    if (!_readbackPossible) return;
    _readbackTimer?.cancel();
    _readbackTimer = Timer(const Duration(milliseconds: 400), _readback);
  }

  void _readback() {
    _readbackTimer = null;
    if (!_readbackPossible) return;
    if (_readbackBusy) {
      _scheduleReadback();
      return;
    }
    _readbackSent = DateTime.now();
    requestAll();
  }

  /// Eine Antwort, die während einer laufenden Rampe eintrifft, ist älter als
  /// das gerade Gesendete und darf die Rampe weder stoppen noch zurücksetzen.
  bool _isStaleVolumeReadback(Adi2Param p) {
    if (p.index != OutIdx.volume || !volumeAddresses.contains(p.address)) {
      return false;
    }
    final sent = _readbackSent;
    if (sent != null &&
        !volGuard.isIdle &&
        DateTime.now().difference(sent) < const Duration(seconds: 1)) {
      return true;
    }
    // Über den Host kommen laufend Antworten seiner Abfrage. Sie können eine
    // gerade gesendete Lautstärke noch nicht enthalten und würden die Anzeige
    // zurückspringen lassen.
    if (_viaHost) {
      if (volGuard.target(p.address) != null) return true;
      final at = _lastVolSentAt[p.address];
      if (at != null &&
          DateTime.now().difference(at) < const Duration(milliseconds: 600)) {
        return true;
      }
    }
    return false;
  }

  // -------------------------------------------------------------------------
  // Lautstärke mit Schutz (Rampe, Sendebremse, Obergrenze)

  /// Ziel-Lautstärke (Rohwert, 0,1 dB). Lauter geht nur langsam, leiser
  /// sofort. Gekoppelte Ausgänge folgen um denselben Betrag.
  void setVolume(int address, int raw, {bool followLink = true}) {
    if (followLink && opts.linked.contains(address) && opts.linked.length > 1) {
      final base = volGuard.target(address) ?? value(address, OutIdx.volume);
      if (base != null) {
        final delta = raw - base;
        for (final o in opts.linked) {
          if (o == address) continue;
          final ob = volGuard.target(o) ?? value(o, OutIdx.volume);
          if (ob != null) _request(o, ob + delta);
        }
      }
    }
    _request(address, raw);
    notifyListeners();
  }

  void _request(int address, int raw) {
    if (volGuard.request(address, raw)) {
      _limitHit.add(address);
    } else {
      _limitHit.remove(address);
    }
  }

  int? volumeTarget(int address) => volGuard.target(address);

  /// true, wenn der letzte Wunsch an der Obergrenze abgeschnitten wurde.
  bool limitHit(int address) => _limitHit.contains(address);

  /// Hält eine laufende Anhebung an (auch die gekoppelter Ausgänge). Gibt
  /// das noch offene Ziel zurück, falls es lauter als der aktuelle Wert war
  /// (für eine Rückfrage), sonst null.
  int? stopVolumeRamp(int address) {
    final t = volGuard.target(address);
    final cur = value(address, OutIdx.volume);
    volGuard.cancel(address);
    if (opts.linked.contains(address)) {
      for (final o in opts.linked) {
        volGuard.cancel(o);
      }
    }
    notifyListeners();
    return (t != null && cur != null && t > cur) ? t : null;
  }

  /// Hält alle Anhebungen an (z. B. App im Hintergrund).
  void stopAllVolumeRamps() {
    if (volGuard.isIdle) return;
    volGuard.cancelAll();
    notifyListeners();
  }

  int volumeLimit(int address) => volGuard.limitFor(address);

  /// Ausgangspegel in dBu bei 0 dBFS für den aktuellen Ref-Level.
  double? currentRefDbu(int address) {
    final v = variant;
    if (v == null) return null;
    return refDbu(v, address, value(address, OutIdx.refLevel));
  }

  // --- Optionen (in der App gespeichert) ---

  Future<void> setLimitDbu(int address, double? dbu) async {
    opts.of(address).limitDbu = dbu?.clamp(limitDbuMin, limitDbuMax).toDouble();
    _applyLimits();
    await _saveOptions();
  }

  Future<void> setRiseMode(RiseMode m) async {
    opts.rise = m;
    volGuard.rate = m.rate;
    notifyListeners();
    await _saveOptions();
  }

  Future<void> setRecall(int address, int? raw) async {
    opts.of(address).recallRaw = raw;
    notifyListeners();
    await _saveOptions();
  }

  /// Merk-Lautstärke abrufen (läuft über die Rampe).
  void recall(int address) {
    final r = opts.of(address).recallRaw;
    if (r != null) setVolume(address, r, followLink: false);
  }

  Future<void> setLinked(int address, bool on) async {
    on ? opts.linked.add(address) : opts.linked.remove(address);
    notifyListeners();
    await _saveOptions();
  }

  /// Berechnet die Obergrenzen aus dBu-Grenze und Ref-Level und holt zu
  /// hohe Werte herunter.
  void _applyLimits({bool sendNow = false}) {
    final v = variant;
    if (v == null) return;
    final lower = <Adi2Param>[];
    for (final a in volumeAddresses) {
      final lim = maxVolumeRaw(
        opts.of(a).limitDbu,
        currentRefDbu(a),
        refTable(v, a),
      );
      volGuard.setLimit(a, lim);
      final t = volGuard.target(a);
      if (t != null && t > lim) volGuard.request(a, lim);
      final cur = value(a, OutIdx.volume);
      // Grenze neu bewerten: liegt die Lautstärke darunter, ist sie nicht
      // (mehr) erreicht – z. B. nachdem die Grenze angehoben wurde.
      if (cur == null || cur < lim) _limitHit.remove(a);
      if (cur != null && cur > lim) {
        _limitHit.add(a);
        if (sendNow) {
          volGuard.cancel(a);
          _lastSentVol[a] = lim;
          lower.add(Adi2Param(a, OutIdx.volume, lim));
        } else {
          volGuard.request(a, lim);
        }
      }
    }
    if (lower.isNotEmpty) setMany(lower); // leiser: sofort senden
    notifyListeners();
  }

  Future<void> _loadOptions() async {
    final id = model?.id;
    if (id == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      opts = VolumeOptions.decode(prefs.getString('vopts_$id'));
    } catch (e) {
      debugPrint('Optionen laden fehlgeschlagen: $e');
      opts = VolumeOptions();
    }
    volGuard.rate = opts.rise.rate;
    _applyLimits();
  }

  Future<void> _saveOptions() async {
    final id = model?.id;
    if (id == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('vopts_$id', opts.encode());
    } catch (e) {
      debugPrint('Optionen speichern fehlgeschlagen: $e');
    }
  }

  void _onDeviceVolume(int address, int raw) {
    // Am Gerät gedreht (kein Echo unserer eigenen Werte): laufende Rampe stoppen.
    if (_lastSentVol[address] != raw) volGuard.cancel(address);
    // Obergrenze auch gegen den Drehknopf durchsetzen.
    if (raw > volGuard.limitFor(address)) {
      volGuard.request(address, volGuard.limitFor(address));
    }
  }

  void _volTick() {
    if (analyzerSelfTestActive) return;
    _eqTick();
    if (volGuard.isIdle) return;
    final out = volGuard.tick((a) => value(a, OutIdx.volume));
    if (out.isEmpty) return;
    final params = [
      for (final e in out.entries) Adi2Param(e.key, OutIdx.volume, e.value),
    ];
    final now = DateTime.now();
    for (final e in out.entries) {
      _lastSentVol[e.key] = e.value;
      _lastVolSentAt[e.key] = now;
    }
    setMany(params);
  }

  // -------------------------------------------------------------------------
  // EQ: Gain-Anhebung gebremst (10 dB/s), alles andere gebündelt gesendet

  static final Set<int> _eqGainIdx = {for (final b in eqBands) b.gainIdx};

  /// EQ-Parameter setzen. Die Anzeige folgt sofort dem Ziel, gesendet wird
  /// im 50-ms-Takt; Gain-Anhebungen höchstens 0,5 dB pro Takt.
  void setEq(int address, int index, int raw) {
    _eqTarget[address << 8 | index] = raw;
    notifyListeners();
  }

  /// Wert für die Anzeige: Ziel, falls noch unterwegs, sonst Gerätewert.
  int? eqValue(int address, int index) =>
      _eqTarget[address << 8 | index] ?? value(address, index);

  void _eqTick() {
    if (_eqTarget.isEmpty) return;
    final out = <Adi2Param>[];
    for (final key in _eqTarget.keys.toList()) {
      final a = key >> 8, i = key & 0xFF;
      final t = _eqTarget[key]!;
      final cur = value(a, i);
      int next = t;
      if (_eqGainIdx.contains(i) && cur != null && t > cur) {
        next = cur + 1; // +0,5 dB je Takt
      }
      if (next == t) _eqTarget.remove(key);
      if (next != cur) out.add(Adi2Param(a, i, next));
    }
    if (out.isNotEmpty) setMany(out);
  }

  /// EQ eines Kanals auf linear zurücksetzen (Gerätefunktion „Clear“).
  /// Offline: Werkseinstellungen der EQ-Werte eintragen.
  void resetEq(int channelAddr) {
    final v = variant;
    if (v == null) return;
    _eqTarget.removeWhere((k, _) {
      final a = k >> 8;
      return a == channelAddr + 1 || a == channelAddr + 2;
    });
    // Werkswerte der Bänder direkt schreiben (beide Seiten, Bass/Treble).
    // EQ an/aus, Bass/Treble an/aus und die Presetwahl bleiben unverändert.
    const keep = {
      EqIdx2.enable,
      EqIdx2.btEnable,
      EqIdx2.loadBtWithPreset,
      EqIdx2.presetSelect,
      EqIdx2.presetFlags,
    };
    final d = offlineDefaults(v);
    final ps = <Adi2Param>[];
    for (final e in d.entries) {
      final a = e.key >> 8, i = e.key & 0xFF;
      if ((a == channelAddr + 1 || a == channelAddr + 2) &&
          !keep.contains(i) &&
          value(a, i) != e.value) {
        if (!offline && _eqGainIdx.contains(i)) {
          setEq(a, i, e.value); // Anheben sanft, Absenken sofort
        } else {
          ps.add(Adi2Param(a, i, e.value));
        }
      }
    }
    setMany(ps);
  }

  /// Namen der 20 EQ-Presets anfordern (Gerät antwortet je Preset).
  Future<void> requestPresetNames() async {
    if (offline || !isConnected || _eqPresets?.length == 20) return;
    try {
      await readEqPresets();
    } catch (e) {
      debugPrint('EQ preset read failed: $e');
    }
  }

  /// EQ-Preset auswählen ([select] wie Geräteparameter: 2..21 = Preset 1..20).
  /// Wählt man das bereits aktive Preset erneut, schaltet das Gerät auf den
  /// Manual-Stand um, statt neu zu laden (am ADI-2 DAC gemessen). Deshalb
  /// dann erst kurz Manual wählen und danach das Preset.
  Future<void> loadEqPreset(int leftAddr, int select) async {
    if (select >= 2 &&
        !offline &&
        value(leftAddr, EqIdx2.presetSelect) == select) {
      set(leftAddr, EqIdx2.presetSelect, 0);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    set(leftAddr, EqIdx2.presetSelect, select);
  }

  String presetName(int n) {
    final s = names[n + 1];
    return (s == null || s.isEmpty) ? trf('Preset {n}', {'n': n + 1}) : s;
  }

  Future<T> _withPresetAccess<T>(Future<T> Function() action) async {
    final session = _presetSession;
    return withDaFilterProbePaused(() async {
      final previous = _presetAccess;
      final done = Completer<void>();
      _presetAccess = done.future;
      try {
        await previous;
        if (session != _presetSession) throw StateError(tr('Nicht verbunden'));
        return await action();
      } finally {
        done.complete();
      }
    });
  }

  /// Aktuellen EQ eines Kanals (linke/rechte Adresse) als Preset [n] (0..19)
  /// im Gerät speichern und danach auswählen.
  Future<void> storeEqPreset(
    int leftAddr,
    int rightAddr,
    int n,
    String name,
    bool dual,
  ) async {
    await _withPresetAccess(() async {
      final session = _presetSession;
      final id = model?.id;
      if (id == null || offline) return;
      final left = <int, int>{
        for (var i = 3; i <= 26; i++)
          if (value(leftAddr, i) != null) i: value(leftAddr, i)!,
      };
      final right = <int, int>{
        for (var i = 3; i <= 19; i++)
          if (value(rightAddr, i) != null) i: value(rightAddr, i)!,
      };
      await _sendStore(id, n, left, right, dual, name);
      names[n + 1] = nameBytes(name)
          .take(nameLength)
          .map(String.fromCharCode)
          .join()
          .trim();
      _cacheStoredPreset(n, left, right, dual);
      // Gespeichertes Preset auswählen (2..21 = Preset 1..20).
      await Future.delayed(const Duration(milliseconds: 400));
      if (session != _presetSession) throw StateError(tr('Nicht verbunden'));
      set(leftAddr, EqIdx2.presetSelect, n + 2);
      _send(buildRequestEqPreset(id, n));
      await Future.delayed(const Duration(milliseconds: 250));
      if (session != _presetSession) throw StateError(tr('Nicht verbunden'));
      Future.delayed(const Duration(milliseconds: 500), requestAll);
      notifyListeners();
    });
  }

  /// Fertige EQ-Daten (z. B. aus der App-Bibliothek) als Preset [n] (0..19)
  /// im Gerät speichern, ohne den aktuellen EQ zu verändern.
  Future<void> storeEqPresetData(
    int n,
    Map<int, int> left,
    Map<int, int> right,
    bool dual,
    String name,
  ) async {
    await _withPresetAccess(() async {
      final session = _presetSession;
      final id = model?.id;
      if (id == null || offline) return;
      await _sendStore(id, n, left, right, dual, name);
      names[n + 1] = nameBytes(name)
          .take(nameLength)
          .map(String.fromCharCode)
          .join()
          .trim();
      _cacheStoredPreset(n, left, right, dual);
      await Future.delayed(const Duration(milliseconds: 300));
      if (session != _presetSession) throw StateError(tr('Nicht verbunden'));
      _send(buildRequestEqPreset(id, n));
      await Future.delayed(const Duration(milliseconds: 250));
      if (session != _presetSession) throw StateError(tr('Nicht verbunden'));
      Future.delayed(const Duration(milliseconds: 500), requestAll);
      notifyListeners();
    });
  }

  void _cacheStoredPreset(
    int n,
    Map<int, int> left,
    Map<int, int> right,
    bool dual,
  ) {
    final cache = _eqPresets ?? [];
    final stored = EqPresetData(
      number: n,
      name: names[n + 1] ?? '',
      empty: false,
      dual: dual,
      left: Map.unmodifiable({
        for (final entry in left.entries)
          if (isPresetStoreIndex(entry.key, left: true)) entry.key: entry.value,
      }),
      right: Map.unmodifiable({
        for (final entry in right.entries)
          if (isPresetStoreIndex(entry.key, left: false))
            entry.key: entry.value,
      }),
    );
    final updated = [
      for (final preset in cache)
        if (preset.number != n) preset,
      stored,
    ]..sort((a, b) => a.number.compareTo(b.number));
    _eqPresets = List.unmodifiable(updated);
  }

  /// Sendet einen Speichervorgang mit kleinen Pausen (Kennung zuletzt).
  Future<void> _sendStore(
    int id,
    int n,
    Map<int, int> left,
    Map<int, int> right,
    bool dual,
    String? name,
  ) async {
    final session = _presetSession;
    for (final m in buildStoreEqPreset(id, n, left, right, dual, name)) {
      if (session != _presetSession || offline || model?.id != id) {
        throw StateError(tr('Nicht verbunden'));
      }
      _send(m);
      await Future.delayed(const Duration(milliseconds: 40));
    }
    if (session != _presetSession) throw StateError(tr('Nicht verbunden'));
  }

  // -------------------------------------------------------------------------
  // Offline-Modus: Einstellungen ohne Gerät festlegen, später übertragen

  static String _offlineKey(Adi2Variant v) => 'offline_${v.name}';

  /// Offline arbeiten mit Modell [v]. Lädt den zuletzt gespeicherten
  /// Offline-Stand oder die Werkseinstellungen.
  Future<void> startOffline(Adi2Variant v, {String? label}) async {
    if (_viaHost) {
      host.disconnect();
      _viaHost = false;
    } else if (device != null) {
      _midi.disconnectDevice(device!);
    }
    _reset();
    _offlineVariant = v;
    _offlineLabel = label;
    model = modelOf(v);
    _values.addAll(offlineDefaults(v));
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_offlineKey(v));
      if (saved != null) {
        final j = jsonDecode(saved) as Map<String, dynamic>;
        for (final e in j.entries) {
          _values[int.parse(e.key)] = e.value as int;
        }
      }
    } catch (e) {
      debugPrint('Offline-Stand laden fehlgeschlagen: $e');
    }
    error = null;
    state = ConnState.offline;
    _volTimer ??= Timer.periodic(
      const Duration(milliseconds: volTickMs),
      (_) => _volTick(),
    );
    await _loadOptions();
    notifyListeners();
  }

  /// Offline-Modus verlassen und wieder nach Geräten suchen.
  Future<void> leaveOffline() async {
    await _saveOffline();
    _reset();
    _offlineVariant = null;
    _offlineLabel = null;
    state = ConnState.searching;
    notifyListeners();
    await _autoConnect();
  }

  /// Offline-Stand auf Werkseinstellungen zurücksetzen.
  Future<void> resetOffline() async {
    final v = _offlineVariant;
    if (v == null) return;
    _values
      ..clear()
      ..addAll(offlineDefaults(v));
    await _saveOffline();
    notifyListeners();
  }

  void _scheduleOfflineSave() {
    _offlineSave?.cancel();
    _offlineSave = Timer(const Duration(milliseconds: 500), _saveOffline);
  }

  Future<void> _saveOffline() async {
    final v = _offlineVariant;
    if (v == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _offlineKey(v),
        jsonEncode({for (final e in _values.entries) '${e.key}': e.value}),
      );
    } catch (e) {
      debugPrint('Offline-Stand speichern fehlgeschlagen: $e');
    }
  }

  /// Gibt es einen gespeicherten Offline-Stand für das verbundene Gerät?
  Future<bool> hasOfflineData() async {
    final v = variant;
    if (v == null) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_offlineKey(v)) != null;
  }

  /// Offline-Stand auf das verbundene Gerät übertragen. Lautstärken werden
  /// nur übernommen, wenn sie leiser sind als am Gerät (nie lauter).
  /// Gibt die Zahl der gesendeten Parameter zurück.
  Future<int> transferOffline() async {
    final session = _connectionSession;
    return withDaFilterProbePaused(() async {
      if (session != _connectionSession) return 0;
      final v = variant;
      if (v == null || offline || model == null) return 0;
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_offlineKey(v));
      if (saved == null) return 0;
      final j = jsonDecode(saved) as Map<String, dynamic>;
      return _applyValues({
        for (final e in j.entries) int.parse(e.key): e.value as int,
      });
    });
  }

  /// Schreibt einen Satz Werte ins Gerät: nur Abweichungen, Lautstärken nur
  /// leiser, Ref-Level-Wechsel erst nach dem Senken. Gibt die Anzahl zurück.
  int _applyValues(Map<int, int> vals) {
    final out = <Adi2Param>[];
    for (final e in vals.entries) {
      final a = e.key >> 8, i = e.key & 0xFF, val = e.value;
      if (isTransferExcluded(a, i)) continue;
      if (i == OutIdx.volume && volumeAddresses.contains(a)) {
        final cur = value(a, i);
        final lim = volGuard.limitFor(a);
        if (cur == null || val >= cur) continue; // nie lauter
        out.add(Adi2Param(a, i, val.clamp(volMinRaw, lim)));
        continue;
      }
      if (value(a, i) == val) continue; // schon gleich
      out.add(Adi2Param(a, i, val));
    }
    // Erst neue Ref-Level eintragen und zu hohe Lautstärken sofort senken,
    // dann alles senden (Ref-Level zuerst).
    for (final p in out) {
      if (p.index == OutIdx.refLevel && volumeAddresses.contains(p.address)) {
        _values[p.key] = p.value;
      }
    }
    _applyLimits(sendNow: true);
    for (var n = 0; n < out.length; n++) {
      final p = out[n];
      if (p.index == OutIdx.volume && volumeAddresses.contains(p.address)) {
        out[n] = Adi2Param(
          p.address,
          p.index,
          p.value.clamp(volMinRaw, volGuard.limitFor(p.address)),
        );
      }
    }
    out.sort(
      (x, y) => (y.index == OutIdx.refLevel ? 1 : 0).compareTo(
        x.index == OutIdx.refLevel ? 1 : 0,
      ),
    );
    setMany(out);
    Future.delayed(const Duration(milliseconds: 500), requestAll);
    return out.length;
  }

  // -------------------------------------------------------------------------
  // Backup

  /// Liest alle 20 Presets. Parallele Aufrufer teilen dieselbe Abfrage.
  /// Bei Verbindungsabbruch oder Timeout bleibt der letzte vollständige Cache erhalten.
  Future<List<EqPresetData>> readEqPresets({
    void Function(double)? progress,
  }) async {
    final pending = _presetRead;
    if (pending != null) {
      final result = await pending;
      progress?.call(1);
      return result;
    }
    final id = model?.id;
    if (id == null || offline || !isConnected) {
      throw StateError(tr('Nicht verbunden'));
    }
    final session = _presetSession;
    final read = _withPresetAccess(() => _readEqPresets(id, session, progress));
    _presetRead = read;
    try {
      return await read;
    } finally {
      if (session == _presetSession) {
        _presetRead = null;
        _capture = null;
        _capturePreset = _incomingPreset = null;
        eqPresetReadProgress = null;
        requestAll();
        _maybeProbeDaFilter();
        notifyListeners();
      }
    }
  }

  Future<List<EqPresetData>> _readEqPresets(
    int id,
    int session,
    void Function(double)? progress,
  ) async {
    void checkConnection() {
      if (session != _presetSession ||
          !isConnected ||
          offline ||
          model?.id != id) {
        throw StateError(tr('Nicht verbunden'));
      }
    }

    eqPresetReadProgress = 0;
    final presets = <EqPresetData>[];
    for (var n = 0; n < 20; n++) {
      checkConnection();
      _capture = [];
      _capturePreset = n;
      _incomingPreset = null;
      _send(buildRequestEqPreset(id, n));
      // Über den Host teilen mehrere Clients die Abfragewarteschlange und
      // die Statuspause. USB behält das bisherige Zeitlimit von zwei Sekunden.
      final timeout = _viaHost
          ? const Duration(seconds: 5)
          : const Duration(seconds: 2);
      final start = DateTime.now();
      while (true) {
        await Future.delayed(const Duration(milliseconds: 50));
        checkConnection();
        final elapsed = DateTime.now().difference(start);
        final gotFlags = _capture!.any(
          (p) =>
              p.address == Adi2Addr.presetEqL && p.index == EqIdx2.presetFlags,
        );
        final quiet =
            DateTime.now().difference(_lastCapture) >
            const Duration(milliseconds: 200);
        if ((gotFlags &&
                quiet &&
                elapsed > const Duration(milliseconds: 200)) ||
            elapsed > timeout) {
          break;
        }
      }
      final cap = _capture!;
      _capture = null;
      _capturePreset = _incomingPreset = null;
      final flags = cap
          .where(
            (p) =>
                p.address == Adi2Addr.presetEqL &&
                p.index == EqIdx2.presetFlags,
          )
          .map((p) => p.value)
          .lastOrNull;
      if (flags == null) {
        throw TimeoutException(
          tr('EQ-Presets konnten nicht eingelesen werden.'),
        );
      }
      final empty = (flags & 0x0F) == 0x0F;
      presets.add(
        EqPresetData(
          number: n,
          name: names[n + 1] ?? '',
          empty: empty,
          dual: !empty && (flags & 1) == 1,
          left: Map.unmodifiable({
            for (final p in cap)
              if (p.address == Adi2Addr.presetEqL &&
                  p.index != EqIdx2.presetFlags)
                p.index: p.value,
          }),
          right: Map.unmodifiable({
            for (final p in cap)
              if (p.address == Adi2Addr.presetEqR) p.index: p.value,
          }),
        ),
      );
      eqPresetReadProgress = (n + 1) / 20;
      progress?.call(eqPresetReadProgress!);
      notifyListeners();
    }
    checkConnection();
    _eqPresets = List.unmodifiable(presets);
    return _eqPresets!;
  }

  /// Liest Gerätezustand und alle 20 EQ-Presets. [progress] 0..1.
  Future<Adi2Backup?> createBackup({void Function(double)? progress}) async {
    return withDaFilterProbePaused(() async {
      final v = variant, id = model?.id;
      if (v == null || id == null || offline) return null;
      requestAll();
      await Future.delayed(const Duration(milliseconds: 700));
      final presets = await readEqPresets(progress: progress);
      requestAll();
      return Adi2Backup(
        variant: v.name,
        label: deviceLabel,
        created: DateTime.now(),
        values: {
          for (final e in _values.entries)
            if (e.key >> 8 != Adi2Addr.presetEqL &&
                e.key >> 8 != Adi2Addr.presetEqR)
              e.key: e.value,
        },
        presets: presets,
        setupNames: {
          for (var n = 1; n <= 9; n++)
            if (names[0x20 + n] != null) n: names[0x20 + n]!,
        },
      );
    });
  }

  /// Backup ins Gerät schreiben. Lautstärken nur leiser; EQ-Presets nur,
  /// wenn [withPresets] gesetzt ist. Gibt die Zahl geänderter Werte zurück.
  Future<int> restoreBackup(Adi2Backup b, {bool withPresets = false}) async {
    return _withPresetAccess(() async {
      final id = model?.id;
      if (id == null || offline) return 0;
      final n = _applyValues(b.values);
      if (withPresets) {
        for (final p in b.presets) {
          if (p.empty) continue;
          await _sendStore(id, p.number, p.left, p.right, p.dual, p.name);
          names[p.number + 1] = p.name;
          _cacheStoredPreset(p.number, p.left, p.right, p.dual);
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }
      for (final e in b.setupNames.entries) {
        if (names[0x20 + e.key] != e.value) {
          _send(buildSendName(id, 0x20 + e.key, e.value));
          names[0x20 + e.key] = e.value;
        }
      }
      Future.delayed(const Duration(milliseconds: 600), requestAll);
      notifyListeners();
      return n;
    });
  }

  void requestAll() {
    final id = model?.id;
    if (id != null) _send(buildRequestAll(id));
  }

  int _paramsMessages = 0;

  /// Fragt alle Werte am Gerät ab und wartet auf dessen Antwort. Für sicher-
  /// heitsrelevante Prüfungen: Über MIDI geschriebene Werte meldet das Gerät
  /// nicht immer von selbst zurück. Ohne Antwort false.
  /// Mit [requiredKeys] muss jeder Schlüssel seit Abfragebeginn bestätigt sein.
  Future<bool> refreshConfirmedValues({List<int>? requiredKeys}) async {
    if (model == null || offline || state != ConnState.connected) return false;
    final before = _paramsMessages;
    requestAll();
    var seen = before, quietTicks = 0;
    for (var waited = 0; waited < 2000; waited += 25) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (state != ConnState.connected) return false;
      if (_paramsMessages == before) continue;
      quietTicks = _paramsMessages == seen ? quietTicks + 1 : 0;
      seen = _paramsMessages;
      // Die Antwort besteht aus mehreren Nachrichten: erst die Pause zählt.
      if (quietTicks >= 4 &&
          (requiredKeys == null ||
              requiredKeys.every(
                (key) => (_confirmedMessages[key] ?? 0) > before,
              ))) {
        return true;
      }
    }
    return false;
  }

  void loadSetup(int n) {
    final session = _connectionSession;
    unawaited(
      withDaFilterProbePaused(() async {
        if (session != _connectionSession) return;
        final id = model?.id;
        if (id == null) return;
        _send(buildLoadSetup(id, n));
        await Future<void>.delayed(const Duration(milliseconds: 400));
        requestAll();
      }),
    );
  }

  void saveSetup(int n) {
    final session = _connectionSession;
    unawaited(
      withDaFilterProbePaused(() async {
        if (session != _connectionSession) return;
        final id = model?.id;
        if (id != null) _send(buildSaveSetup(id, n));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }),
    );
  }

  void loadFactory() {
    final session = _connectionSession;
    unawaited(
      withDaFilterProbePaused(() async {
        if (session != _connectionSession) return;
        final id = model?.id;
        if (id == null || offline) return;
        _send(buildLoadFactory(id));
        await Future<void>.delayed(const Duration(milliseconds: 400));
        requestAll();
      }),
    );
  }

  void renameSetup(int n, String name) {
    final session = _connectionSession;
    unawaited(
      withDaFilterProbePaused(() async {
        if (session != _connectionSession) return;
        final id = model?.id;
        if (id == null || offline || n < 1 || n > 9) return;
        _send(buildSendName(id, 0x20 + n, name));
        names[0x20 + n] = String.fromCharCodes(nameBytes(name).take(nameLength))
            .trim();
        notifyListeners();
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }),
    );
  }

  void toggleOutputs() => set(Adi2Addr.device, DevIdx.doToggleOutputs, 0);

  @override
  void dispose() {
    _disposed = true;
    _hostRetry?.cancel();
    hostDiscovery.dispose();
    _hostRx?.cancel();
    host.removeListener(_hostChanged);
    host.dispose();
    _connectionSession++;
    _ccModeRequest++;
    _presetSession++;
    _capture = null;
    _capturePreset = _incomingPreset = null;
    _rxSub?.cancel();
    _setupSub?.cancel();
    _probeTimer?.cancel();
    _watchdog?.cancel();
    _volTimer?.cancel();
    _offlineSave?.cancel();
    _readbackTimer?.cancel();
    if (!_viaHost && device != null) _midi.disconnectDevice(device!);
    _viaHost = false;
    analyzerSelfTestReadbacks.close();
    selectedOutputChanges.dispose();
    super.dispose();
  }
}
