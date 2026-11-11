import 'easy_layout.dart';

enum EasyLongPressAction {
  none,
  volumeDown,
  volumeUp,
  phones,
  mute,
  dimInfo,
  loudness,
  crossfeed,
  recall,
  link,
  lock,
  bass,
  treble,
  balance,
  refLevel,
  daFilter,
  source,
  eq,
  limit,
  outputSettings,
  setup,
  signalFlow,
}

/// Operating-mode policy. Exhaustive so new tile types require a decision.
/// Direct choices have no secondary action; the editor uses separate controls.
EasyLongPressAction easyLongPressAction(EasyTileType type) => switch (type) {
  EasyTileType.volumeRing ||
  EasyTileType.volumeDirect ||
  EasyTileType.sourceDirect ||
  EasyTileType.appPreset => EasyLongPressAction.none,
  EasyTileType.volumeDown => EasyLongPressAction.volumeDown,
  EasyTileType.volumeUp => EasyLongPressAction.volumeUp,
  EasyTileType.outputSelect => EasyLongPressAction.phones,
  EasyTileType.mute || EasyTileType.toggleOutputs => EasyLongPressAction.mute,
  EasyTileType.dim => EasyLongPressAction.dimInfo,
  EasyTileType.loudness => EasyLongPressAction.loudness,
  EasyTileType.crossfeed => EasyLongPressAction.crossfeed,
  EasyTileType.recall => EasyLongPressAction.recall,
  EasyTileType.link => EasyLongPressAction.link,
  EasyTileType.lock => EasyLongPressAction.lock,
  EasyTileType.bass => EasyLongPressAction.bass,
  EasyTileType.treble => EasyLongPressAction.treble,
  EasyTileType.balance => EasyLongPressAction.balance,
  EasyTileType.refLevel => EasyLongPressAction.refLevel,
  EasyTileType.daFilter => EasyLongPressAction.daFilter,
  EasyTileType.source => EasyLongPressAction.source,
  EasyTileType.eqEnable ||
  EasyTileType.eqPage ||
  EasyTileType.eqPreset => EasyLongPressAction.eq,
  EasyTileType.limit => EasyLongPressAction.limit,
  EasyTileType.outputSettings => EasyLongPressAction.outputSettings,
  EasyTileType.setup => EasyLongPressAction.setup,
  EasyTileType.basicMode => EasyLongPressAction.signalFlow,
};
