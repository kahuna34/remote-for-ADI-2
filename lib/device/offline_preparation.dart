import 'backup.dart';

/// App-owned setup snapshot. Slot numbers follow the device (1..9).
class OfflineSetupData {
  OfflineSetupData({
    required this.number,
    required this.name,
    required Map<int, int> values,
  }) : values = Map.unmodifiable(values);

  final int number;
  final String name;
  final Map<int, int> values;

  Map<String, dynamic> toJson() => {
    'n': number,
    'name': name,
    'values': {for (final e in values.entries) '${e.key}': e.value},
  };

  factory OfflineSetupData.fromJson(Map<String, dynamic> json) =>
      OfflineSetupData(
        number: json['n'] as int,
        name: json['name'] as String? ?? '',
        values: {
          for (final e in (json['values'] as Map).entries)
            int.parse(e.key as String): e.value as int,
        },
      );
}

/// A detached snapshot of the preparation for one model, read before transfer.
class OfflinePreparation {
  OfflinePreparation({
    Map<int, int>? settings,
    List<EqPresetData> presets = const [],
    List<OfflineSetupData> setups = const [],
  }) : settings = settings == null ? null : Map.unmodifiable(settings),
       presets = List.unmodifiable(presets),
       setups = List.unmodifiable(setups);

  final Map<int, int>? settings;
  final List<EqPresetData> presets;
  final List<OfflineSetupData> setups;
  bool get isEmpty => settings == null && presets.isEmpty && setups.isEmpty;
}

class PreparedTransferResult {
  const PreparedTransferResult({
    this.presets = 0,
    this.setups = 0,
    this.settings = 0,
  });
  final int presets;
  final int setups;
  final int settings; // Number of changed settings, excluding temporary setups.
}
