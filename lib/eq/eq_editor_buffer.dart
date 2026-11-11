import '../device/backup.dart';
import '../protocol/adi2_codec.dart';
import 'eq_library.dart';
import 'eq_model.dart';

/// Eigener Editorzustand. Adressen 13/14 haben dieselbe Indexbelegung wie
/// die Live-EQs. Bass/Treble liegen ausschließlich auf der linken Adresse.
class EqEditorBuffer {
  EqEditorBuffer() {
    clear();
  }

  String name = '';
  bool dual = false;
  final Map<int, int> _left = {};
  final Map<int, int> _right = {};

  Map<int, int> get left => Map.unmodifiable(_left);
  Map<int, int> get right => Map.unmodifiable(_right);

  int? value(int address, int index) => switch (address) {
    Adi2Addr.presetEqL => _left[index],
    Adi2Addr.presetEqR => _right[index],
    _ => null,
  };

  void set(int address, int index, int raw) {
    final left = address == Adi2Addr.presetEqL;
    if (!left && address != Adi2Addr.presetEqR) return;
    if (!isPresetStoreIndex(index, left: left)) return;
    for (final band in eqBands) {
      if (index == band.gainIdx) {
        raw = raw.clamp(eqGainMinRaw, eqGainMaxRaw);
      } else if (index == band.freqIdx) {
        raw = snapFreq(band, raw.toDouble());
      } else if (index == band.qIdx) {
        raw = raw.clamp((band.minQ * 10).round(), (band.maxQ * 10).round());
      } else if (index == band.typeIdx) {
        raw = raw.clamp(0, band.types.length - 1);
      }
    }
    (left ? _left : _right)[index] = raw;
  }

  void clear() {
    name = '';
    dual = false;
    _left.clear();
    _right.clear();
    for (final address in [Adi2Addr.presetEqL, Adi2Addr.presetEqR]) {
      for (final band in eqBands) {
        if (band.isBassTreble && address == Adi2Addr.presetEqR) continue;
        if (band.typeIdx != null) set(address, band.typeIdx!, 1);
        set(address, band.gainIdx, 0);
        set(address, band.freqIdx, band.defF);
        set(address, band.qIdx, (band.defQ * 10).round());
      }
    }
  }

  void loadAppPreset(AppEqPreset preset) {
    clear();
    name = preset.name;
    dual = preset.dual;
    for (final e in preset.left.entries) {
      set(Adi2Addr.presetEqL, e.key, e.value);
    }
    for (final e in preset.right.entries) {
      set(Adi2Addr.presetEqR, e.key, e.value);
    }
  }

  void loadDevicePreset(EqPresetData preset) {
    loadAppPreset(
      AppEqPreset(
        name: preset.name,
        dual: !preset.empty && preset.dual,
        left: preset.empty ? {} : preset.left,
        right: preset.empty ? {} : preset.right,
      ),
    );
  }

  AppEqPreset toAppPreset({String? name}) => AppEqPreset(
    name: name ?? this.name,
    dual: dual,
    left: Map.of(_left),
    right: Map.of(_right),
  );

  EqEditorBuffer copy() => EqEditorBuffer()..loadAppPreset(toAppPreset());

  void paste(EqEditorBuffer source) => loadAppPreset(source.toAppPreset());
}
