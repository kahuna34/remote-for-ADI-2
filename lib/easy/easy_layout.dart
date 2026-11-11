import 'dart:convert';

import '../analyzer/header_content.dart';

import '../eq/eq_library.dart';
import '../protocol/adi2_params.dart';

/// Stable names are persisted. Unknown types are ignored when reading a layout.
enum EasyTileType {
  volumeRing,
  volumeDown,
  volumeUp,
  outputSelect,
  mute,
  dim,
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
  eqEnable,
  eqPage,
  limit,
  outputSettings,
  setup,
  eqPreset,
  sourceDirect,
  toggleOutputs,
  basicMode,
  volumeDirect,
  appPreset,
}

/// Horizontal resolution preserves halves, thirds, quarters and fifths exactly.
const easyGridUnits = 60;
const easyQuarterUnits = easyGridUnits ~/ 4;
const easySnapEdges = [0, 12, 15, 20, 24, 30, 36, 40, 45, 48, 60];

/// Stable persisted names, ordered from narrow to wide.
enum EasyTileSize {
  fifth(12, '1/5'),
  single(15, '¼'),
  third(20, '1/3'),
  twoFifths(24, '2/5'),
  wide(30, '½'),
  threeFifths(36, '3/5'),
  twoThirds(40, '2/3'),
  threeQuarters(45, '¾'),
  fourFifths(48, '4/5'),
  full(60, '1');

  const EasyTileSize(this.units, this.fraction);
  final int units;
  final String fraction;
}

/// Central size limits used by the catalog, both pickers and persisted layouts.
class EasyTileSizeRule {
  const EasyTileSizeRule({
    this.minWidth = 12,
    this.maxWidth = 30,
    this.minHeight = 0.5,
    this.maxHeight = 1,
    this.tallMaxWidth,
    this.shortMinWidth = 12,
    required this.defaultSize,
    required this.defaultHeight,
  });

  final int minWidth, maxWidth, shortMinWidth;
  final int? tallMaxWidth;
  final double minHeight, maxHeight, defaultHeight;
  final EasyTileSize defaultSize;

  bool supports(EasyTileSize size, double height) =>
      const [0.5, 1.0, 1.5, 2.0].contains(height) &&
      size.units >= minWidth &&
      size.units <= maxWidth &&
      height >= minHeight &&
      height <= maxHeight &&
      (height != 0.5 || size.units >= shortMinWidth) &&
      (height <= 1 || tallMaxWidth == null || size.units <= tallMaxWidth!);

  static EasyTileSizeRule forType(EasyTileType type) => switch (type) {
    EasyTileType.volumeRing => const EasyTileSizeRule(
      minWidth: 30,
      minHeight: 2,
      maxHeight: 2,
      maxWidth: easyGridUnits,
      defaultSize: EasyTileSize.wide,
      defaultHeight: 2,
    ),
    EasyTileType.outputSelect => const EasyTileSizeRule(
      minWidth: 30,
      maxWidth: easyGridUnits,
      defaultSize: EasyTileSize.full,
      defaultHeight: 0.5,
    ),
    EasyTileType.volumeDown || EasyTileType.volumeUp => const EasyTileSizeRule(
      shortMinWidth: 30,
      maxWidth: easyGridUnits,
      maxHeight: 2,
      tallMaxWidth: 30,
      defaultSize: EasyTileSize.single,
      defaultHeight: 1,
    ),
    EasyTileType.refLevel => const EasyTileSizeRule(
      minWidth: easyQuarterUnits,
      shortMinWidth: 30,
      maxWidth: easyGridUnits,
      maxHeight: 2,
      defaultSize: EasyTileSize.wide,
      defaultHeight: 1,
    ),
    EasyTileType.bass ||
    EasyTileType.treble ||
    EasyTileType.balance ||
    EasyTileType.source ||
    EasyTileType.daFilter => const EasyTileSizeRule(
      minWidth: easyQuarterUnits,
      shortMinWidth: 30,
      maxWidth: easyGridUnits,
      maxHeight: 2,
      tallMaxWidth: 30,
      defaultSize: EasyTileSize.wide,
      defaultHeight: 1,
    ),
    EasyTileType.setup ||
    EasyTileType.eqPreset ||
    EasyTileType.sourceDirect ||
    EasyTileType.toggleOutputs ||
    EasyTileType.basicMode ||
    EasyTileType.volumeDirect ||
    EasyTileType.appPreset => const EasyTileSizeRule(
      defaultSize: EasyTileSize.single,
      defaultHeight: 0.5,
    ),
    _ => const EasyTileSizeRule(
      defaultSize: EasyTileSize.single,
      defaultHeight: 1,
    ),
  };
}

/// Stable palette keys; Flutter colors are defined in the UI layer.
enum EasyTileColor {
  graphite,
  blue,
  petrol,
  green,
  olive,
  amber,
  copper,
  red,
  violet,
  rose,
}

/// Coordinates use sixtieths horizontally and half-quarter-widths vertically.
class EasyPlacement {
  const EasyPlacement(this.index, this.x, this.y, this.width, this.height);
  final int index, x, y, width, height;
}

/// Reserve valid pins first, then repair conflicting pins in list order, then
/// first-fit all floating tiles. Results always retain their input indices.
List<EasyPlacement> packEasyTiles(List<EasyTile> tiles) {
  final result = <int, EasyPlacement>{};
  bool fits(int x, int y, int w, int h) =>
      x >= 0 &&
      x + w <= easyGridUnits &&
      y >= 0 &&
      !result.values.any(
        (p) =>
            x < p.x + p.width &&
            x + w > p.x &&
            y < p.y + p.height &&
            y + h > p.y,
      );
  void place(int i, int x, int y) {
    final t = tiles[i];
    final h = (t.heightUnits * 2).round();
    result[i] = EasyPlacement(i, x, y, t.widthUnits, h);
  }

  // Valid, nonconflicting anchors win over repairs and floating tiles.
  for (var i = 0; i < tiles.length; i++) {
    final t = tiles[i];
    if (t.pinned &&
        t.x != null &&
        t.y != null &&
        t.y! <= 10000 &&
        fits(t.x!, t.y!, t.widthUnits, (t.heightUnits * 2).round())) {
      place(i, t.x!, t.y!);
    }
  }
  for (final pinned in [true, false]) {
    for (var i = 0; i < tiles.length; i++) {
      final t = tiles[i];
      if (t.pinned != pinned || result.containsKey(i)) continue;
      if (!pinned &&
          t.x != null &&
          t.y != null &&
          t.y! <= 10000 &&
          fits(t.x!, t.y!, t.widthUnits, (t.heightUnits * 2).round())) {
        place(i, t.x!, t.y!);
        continue;
      }
      // A broken anchor moves to the next free cell, wrapping to the next row.
      final start = pinned && t.y != null && t.y! >= 0 && t.y! <= 10000
          ? t.y! * easyGridUnits + (t.x ?? 0).clamp(0, easyGridUnits)
          : 0;
      for (var cell = start; ; cell++) {
        final x = cell % easyGridUnits, y = cell ~/ easyGridUnits;
        if (fits(x, y, t.widthUnits, (t.heightUnits * 2).round())) {
          place(i, x, y);
          break;
        }
      }
    }
  }
  return [for (var i = 0; i < tiles.length; i++) result[i]!];
}

class EasyTile {
  const EasyTile({
    required this.type,
    this.size = EasyTileSize.single,
    this.height = 1,
    this.color,
    this.pinned = false,
    this.x,
    this.y,
    this.output,
    this.param,
    this.label,
  }) : assert(height == 0.5 || height == 1 || height == 1.5 || height == 2);

  final EasyTileType type;
  final EasyTileSize size;
  final double height;
  final EasyTileColor? color;
  final bool pinned;

  /// x in sixtieths, y in half-quarter-width rows, independent of visual guides.
  final int? x, y;

  EasyTile withPosition({required bool pinned, int? x, int? y}) => EasyTile(
    type: type,
    size: size,
    height: height,
    color: color,
    output: output,
    param: param,
    label: label,
    pinned: pinned,
    x: x,
    y: y,
  );

  static bool isStepper(EasyTileType type) => {
    EasyTileType.bass,
    EasyTileType.treble,
    EasyTileType.balance,
    EasyTileType.volumeDown,
    EasyTileType.volumeUp,
  }.contains(type);

  static bool supportsType(EasyTileType type, Adi2Variant variant) =>
      type != EasyTileType.basicMode || !variant.isDac;

  factory EasyTile.defaults(EasyTileType type) {
    final rule = EasyTileSizeRule.forType(type);
    return EasyTile(
      type: type,
      size: rule.defaultSize,
      height: rule.defaultHeight,
      param: switch (type) {
        EasyTileType.setup || EasyTileType.eqPreset => 1,
        EasyTileType.sourceDirect => 0,
        EasyTileType.basicMode => 2,
        EasyTileType.volumeDirect => -30.0,
        EasyTileType.appPreset => AppEqPreset(
          name: 'EQ',
          dual: false,
          left: {4: 0},
          right: {},
        ).toJson(),
        _ => null,
      },
    );
  }

  static bool supportsShape(
    EasyTileType type,
    EasyTileSize size,
    double height,
  ) => EasyTileSizeRule.forType(type).supports(size, height);

  /// Nearest shape measured in quarter-width / height units.
  EasyTile normalizeShape() {
    if (supportsShape(type, size, height)) return this;
    var bestSize = size;
    var bestHeight = height;
    var distance = double.infinity;
    for (final s in EasyTileSize.values) {
      for (final h in heightsFor(type)) {
        if (!supportsShape(type, s, h)) continue;
        final dx = (s.units - size.units) / easyQuarterUnits;
        final dy = h - height;
        final nextDistance = dx * dx + dy * dy;
        if (nextDistance < distance) {
          distance = nextDistance;
          bestSize = s;
          bestHeight = h;
        }
      }
    }
    return withShape(bestSize, bestHeight);
  }

  EasyTile withShape(EasyTileSize size, double height) => EasyTile(
    type: type,
    size: size,
    height: height,
    color: color,
    pinned: pinned,
    x: x,
    y: y,
    output: output,
    param: param,
    label: label,
  );

  int get widthUnits =>
      type == EasyTileType.volumeRing && size.units < 30 ? 30 : size.units;

  /// The ring keeps its proportions: its height follows the chosen width
  /// (½ = 2, ¾ = 3, full = 4), rounded to half rows.
  double get heightUnits => type == EasyTileType.volumeRing
      ? (widthUnits / easyQuarterUnits * 2).round() / 2
      : height;
  static List<double> heightsFor(EasyTileType type) => [
    for (final h in const [0.5, 1.0, 1.5, 2.0])
      if (EasyTileSize.values.any((s) => supportsShape(type, s, h))) h,
  ];

  /// Null follows the output selected in the main view. Otherwise 3, 6 or 9.
  final int? output;

  /// Slot number, source/mode raw value, dB value, or an AppEqPreset JSON snapshot.
  final Object? param;
  final String? label;

  bool get hasOutput => !{
    EasyTileType.outputSelect,
    EasyTileType.setup,
    EasyTileType.toggleOutputs,
    EasyTileType.basicMode,
  }.contains(type);

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'size': widthUnits == size.units ? size.name : EasyTileSize.wide.name,
    // The ring's height is derived from its width; decode expects the fixed 2.
    'height': type == EasyTileType.volumeRing ? 2 : heightUnits,
    if (color != null) 'color': color!.name,
    'pinned': pinned,
    if (x != null) 'x': x,
    if (y != null) 'y': y,
    if (output != null) 'output': output,
    if (param != null) 'param': param,
    if (label != null) 'label': label,
  };

  static EasyTile? fromJson(
    Object? json,
    Adi2Variant variant, {
    int version = EasyLayout.version,
    int columns = 2,
  }) {
    if (json is! Map<String, dynamic>) return null;
    final type = EasyTileType.values
        .where((t) => t.name == json['type'])
        .firstOrNull;
    var size = EasyTileSize.values
        .where((s) => s.name == json['size'])
        .firstOrNull;
    final rawHeight = json['height'];
    final rawColor = json['color'];
    final color = EasyTileColor.values
        .where((c) => c.name == rawColor)
        .firstOrNull;
    if (version >= 2 &&
        (rawHeight is! num ||
            ![0.5, 1, 1.5, 2].contains(rawHeight) ||
            rawColor != null && color == null)) {
      return null;
    }
    final output = json['output'];
    final label = json['label'];
    final param = json['param'];
    if (type == null ||
        !supportsType(type, variant) ||
        size == null ||
        (output != null && (output is! int || ![3, 6, 9].contains(output))) ||
        (label != null && label is! String)) {
      return null;
    }
    if (version == 1) {
      // Preserve the old column-relative width, then switch to fixed units.
      final units = switch (size) {
        EasyTileSize.single => easyGridUnits ~/ columns,
        EasyTileSize.wide => columns == 3 ? 40 : easyGridUnits,
        EasyTileSize.full => easyGridUnits,
        _ => 0,
      };
      size = EasyTileSize.values.where((s) => s.units == units).firstOrNull;
      if (size == null) return null;
    }
    bool inRange(int min, int max) =>
        param is int && param >= min && param <= max;
    switch (type) {
      case EasyTileType.setup:
        if (!inRange(1, 9)) return null;
      case EasyTileType.eqPreset:
        if (!inRange(1, 20)) return null;
      case EasyTileType.sourceDirect:
        final source = outputParams(
          variant,
          phones: output != 3,
        ).firstWhere((d) => d.index == OutIdx.source);
        if (!inRange(source.min, source.max)) return null;
      case EasyTileType.basicMode:
        if (variant.isDac || !inRange(0, 5)) return null;
      case EasyTileType.volumeDirect:
        if (param is! num || !param.isFinite || param < -114.5 || param > 6) {
          return null;
        }
      case EasyTileType.appPreset:
        try {
          if (param is! Map<String, dynamic>) return null;
          AppEqPreset.fromJson(param);
        } catch (_) {
          return null;
        }
      default:
        if (param != null) return null;
    }
    return EasyTile(
      type: type,
      size: size,
      height: type == EasyTileType.volumeRing
          ? 2
          : version == 1
          ? 1.5
          : (rawHeight as num).toDouble(),
      color: color,
      pinned: version >= 3 && json['pinned'] == true,
      x: version >= 3 && json['x'] is int
          ? (json['x'] as int) * (version < 6 ? 5 : 1)
          : null,
      y: version >= 3 && json['y'] is int ? json['y'] as int : null,
      output: output as int?,
      param: param,
      label: label is String && label.trim().isNotEmpty ? label.trim() : null,
    ).normalizeShape();
  }
}

class EasyLayout {
  EasyLayout({
    this.defaultColor = EasyTileColor.graphite,
    this.showAnalyzer = false,
    this.showPlayer = true,
    this.showStatus = true,
    this.positionsAdjusted = false,
    required List<EasyTile> tiles,
    this.samePageForAllOutputs = true,
    Map<int, EasyLayout> outputPages = const {},
  }) : tiles = List.unmodifiable(tiles),
       outputPages = Map.unmodifiable({
         for (final entry in outputPages.entries)
           entry.key: entry.value.asPage(),
       });

  static const version = 6;
  final bool samePageForAllOutputs;
  final Map<int, EasyLayout> outputPages;

  /// A page snapshot has no nested output pages. Tiles are immutable.
  EasyLayout asPage() => EasyLayout(
    defaultColor: defaultColor,
    showAnalyzer: showAnalyzer,
    showPlayer: showPlayer,
    showStatus: showStatus,
    positionsAdjusted: positionsAdjusted,
    tiles: tiles,
  );

  EasyLayout pageFor(int output) =>
      samePageForAllOutputs ? asPage() : outputPages[output] ?? asPage();

  EasyLayout withPage(int output, EasyLayout page) => samePageForAllOutputs
      ? copyWith(
          defaultColor: page.defaultColor,
          showAnalyzer: page.showAnalyzer,
          showPlayer: page.showPlayer,
          showStatus: page.showStatus,
          positionsAdjusted: page.positionsAdjusted,
          tiles: page.tiles,
        )
      : copyWith(outputPages: {...outputPages, output: page.asPage()});

  /// Existing independent pages survive a temporary return to shared mode.
  /// The first split (and any newly supported output) starts with the shared page.
  EasyLayout setSamePageForAllOutputs(
    bool same,
    Iterable<int> outputs, {
    required int selectedOutput,
  }) {
    if (same == samePageForAllOutputs) return this;
    if (same) {
      final page = pageFor(selectedOutput);
      return copyWith(
        samePageForAllOutputs: true,
        defaultColor: page.defaultColor,
        showAnalyzer: page.showAnalyzer,
        showPlayer: page.showPlayer,
        showStatus: page.showStatus,
        positionsAdjusted: page.positionsAdjusted,
        tiles: page.tiles,
      );
    }
    return copyWith(
      samePageForAllOutputs: false,
      outputPages: {
        ...outputPages,
        for (final output in outputs)
          if (!outputPages.containsKey(output)) output: asPage(),
      },
    );
  }

  EasyLayout copyPageTo(int source, Iterable<int> targets) => copyWith(
    outputPages: {
      ...outputPages,
      for (final target in targets) target: pageFor(source).asPage(),
    },
  );
  final EasyTileColor defaultColor;
  final bool showPlayer, showStatus, showAnalyzer;
  HeaderContent get headerContent =>
      headerContentFromLegacy(showPlayer, showStatus, showAnalyzer);
  EasyLayout withHeaderContent(HeaderContent content) => copyWith(
    showAnalyzer: content == HeaderContent.analyzer,
    showPlayer: content == HeaderContent.player,
    showStatus:
        content == HeaderContent.player || content == HeaderContent.status,
  );
  final bool positionsAdjusted;
  final List<EasyTile> tiles;

  EasyLayout copyWith({
    EasyTileColor? defaultColor,
    bool? showAnalyzer,
    bool? showPlayer,
    bool? showStatus,
    List<EasyTile>? tiles,
    bool? positionsAdjusted,
    bool? samePageForAllOutputs,
    Map<int, EasyLayout>? outputPages,
  }) => EasyLayout(
    defaultColor: defaultColor ?? this.defaultColor,
    showAnalyzer: showAnalyzer ?? this.showAnalyzer,
    showPlayer: showPlayer ?? this.showPlayer,
    showStatus: showStatus ?? this.showStatus,
    tiles: tiles ?? this.tiles,
    positionsAdjusted: positionsAdjusted ?? this.positionsAdjusted,
    samePageForAllOutputs: samePageForAllOutputs ?? this.samePageForAllOutputs,
    outputPages: outputPages ?? this.outputPages,
  );

  EasyLayout resolvePins() {
    final placements = packEasyTiles(tiles);
    var adjusted = false;
    final resolved = [...tiles];
    for (final p in placements) {
      final tile = tiles[p.index];
      if ((tile.pinned || tile.x != null || tile.y != null) &&
          (tile.x != p.x || tile.y != p.y)) {
        adjusted = adjusted || tile.pinned;
        resolved[p.index] = tile.withPosition(
          pinned: tile.pinned,
          x: p.x,
          y: p.y,
        );
      }
    }
    return copyWith(
      tiles: resolved,
      positionsAdjusted: positionsAdjusted || adjusted,
    );
  }

  /// Closest position whose left or right edge meets a quarter/third/half/fifth
  /// guide. Fixed tiles reserve their complete area before movable tiles.
  (int, int) snapTarget(int index, double x, double y) {
    final tile = tiles[index];
    final xs =
        <int>{
              for (final edge in easySnapEdges) ...[
                edge,
                edge - tile.widthUnits,
              ],
            }
            .where((x) => x >= 0 && x + tile.widthUnits <= easyGridUnits)
            .toList()
          ..sort();
    final fixed = packEasyTiles(tiles)
        .where((p) => p.index != index && tiles[p.index].pinned);
    final h = (tile.heightUnits * 2).round();
    final maxY =
        fixed.fold(
          y.ceil().clamp(0, 10000),
          (int end, p) => end > p.y + p.height ? end : p.y + p.height,
        ) +
        h;
    var best = (xs.first, 0);
    var distance = double.infinity;
    for (var yy = 0; yy <= maxY; yy++) {
      for (final xx in xs) {
        if (fixed.any(
          (p) =>
              xx < p.x + p.width &&
              xx + tile.widthUnits > p.x &&
              yy < p.y + p.height &&
              yy + h > p.y,
        )) {
          continue;
        }
        final d =
            (xx - x) * (xx - x) +
            (yy - y) *
                (yy - y) *
                (easyQuarterUnits / 2) *
                (easyQuarterUnits / 2);
        if (d < distance) {
          distance = d;
          best = (xx, yy);
        }
      }
    }
    return best;
  }

  /// The dragged tile wins over floating tiles; every other fixed tile keeps
  /// its anchor. Save resolved floating positions without changing pin state.
  EasyLayout moveTile(int index, int x, int y) {
    final target = snapTarget(index, x.toDouble(), y.toDouble());
    final moving = tiles[index];
    final placements = packEasyTiles([
      for (var i = 0; i < tiles.length; i++)
        if (i != index) tiles[i],
      moving.withPosition(pinned: true, x: target.$1, y: target.$2),
    ]);
    final order = [
      for (var i = 0; i < tiles.length; i++)
        if (i != index) i,
      index,
    ];
    final resolved = [...tiles];
    for (final p in placements) {
      final i = order[p.index];
      resolved[i] = tiles[i].withPosition(
        pinned: tiles[i].pinned,
        x: p.x,
        y: p.y,
      );
    }
    return copyWith(tiles: resolved, positionsAdjusted: false);
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'samePageForAllOutputs': samePageForAllOutputs,
    if (outputPages.isNotEmpty)
      'outputPages': {
        for (final entry in outputPages.entries)
          '${entry.key}': entry.value.toJson(),
      },
    'defaultColor': defaultColor.name,
    if (showAnalyzer) 'showAnalyzer': true,
    'showPlayer': showPlayer,
    'showStatus': showStatus,
    'tiles': [for (final t in tiles) t.toJson()],
  };

  String encode() => jsonEncode(toJson());

  factory EasyLayout.decode(String source, Adi2Variant variant) {
    try {
      final json = jsonDecode(source);
      if (json is! Map<String, dynamic> ||
          ![1, 2, 3, 4, 5, version].contains(json['version']) ||
          json['tiles'] is! List) {
        return EasyLayout.defaults(variant);
      }
      // Only v1 encoded widths relative to columns. Newer layouts use
      // absolute units; pre-v6 horizontal positions are scaled by five.
      final legacyColumns =
          json['version'] == 1 && [2, 3].contains(json['columns'])
          ? json['columns'] as int
          : 2;
      return EasyLayout(
        samePageForAllOutputs: (json['version'] as int) >= 5
            ? json['samePageForAllOutputs'] != false
            : true,
        outputPages: {
          if ((json['version'] as int) >= 5 && json['outputPages'] is Map)
            for (final entry in (json['outputPages'] as Map).entries)
              if (int.tryParse(entry.key.toString()) case final int address)
                if ([3, 6, 9].contains(address) && entry.value is Map)
                  address: EasyLayout.decode(
                    jsonEncode({
                      ...entry.value as Map,
                      'outputPages': null,
                      'samePageForAllOutputs': true,
                    }),
                    variant,
                  ),
        },
        defaultColor:
            EasyTileColor.values
                .where((c) => c.name == json['defaultColor'])
                .firstOrNull ??
            EasyTileColor.graphite,
        showAnalyzer: json['showAnalyzer'] == true,
        showPlayer: json['showPlayer'] is bool
            ? json['showPlayer'] as bool
            : true,
        showStatus: json['showStatus'] is bool
            ? json['showStatus'] as bool
            : true,
        tiles: [
          for (final entry in json['tiles'])
            ?EasyTile.fromJson(
              entry,
              variant,
              version: json['version'] as int,
              columns: legacyColumns,
            ),
        ],
      ).resolvePins();
    } catch (_) {
      return EasyLayout.defaults(variant);
    }
  }

  factory EasyLayout.defaults(Adi2Variant variant) => EasyLayout(
    tiles: [
      const EasyTile(
        type: EasyTileType.outputSelect,
        size: EasyTileSize.full,
        height: 0.5,
        x: 0,
        y: 0,
      ),
      const EasyTile(
        type: EasyTileType.volumeRing,
        size: EasyTileSize.wide,
        height: 2,
        pinned: true,
        x: easyQuarterUnits,
        y: 1,
      ),
      for (final entry in [
        EasyTileType.mute,
        EasyTileType.volumeDown,
        EasyTileType.volumeUp,
        EasyTileType.dim,
      ].indexed)
        EasyTile(type: entry.$2, x: entry.$1 * easyQuarterUnits, y: 5),
      for (var n = 1; n <= 4; n++)
        EasyTile(
          type: EasyTileType.setup,
          param: n,
          height: 0.5,
          x: (n - 1) * easyQuarterUnits,
          y: 7,
        ),
    ],
  );
}

/// Four independent setups for one device model. Empty active slots use the
/// default layout until the first edit, without occupying the slot on selection.
class EasySlots {
  EasySlots({
    required List<EasyLayout?> layouts,
    List<String?>? names,
    this.active = 0,
  }) : assert(layouts.length == 4),
       assert(active >= 0 && active < 4),
       layouts = List.unmodifiable(layouts),
       names = List.unmodifiable(names ?? List<String?>.filled(4, null));

  final List<EasyLayout?> layouts;
  final List<String?> names;
  final int active;

  factory EasySlots.defaults(Adi2Variant variant) =>
      EasySlots(layouts: [EasyLayout.defaults(variant), null, null, null]);

  EasySlots activate(int index) {
    RangeError.checkValidIndex(index, layouts);
    return EasySlots(layouts: layouts, names: names, active: index);
  }

  EasySlots save(int index, EasyLayout layout, {String? name}) {
    RangeError.checkValidIndex(index, layouts);
    return EasySlots(
      layouts: [...layouts]..[index] = layout,
      names: [...names]
        ..[index] = name?.trim().isNotEmpty == true ? name!.trim() : null,
      active: index,
    );
  }

  EasySlots clear(int index) {
    RangeError.checkValidIndex(index, layouts);
    return EasySlots(
      layouts: [...layouts]..[index] = null,
      names: [...names]..[index] = null,
      active: active,
    );
  }

  String encode() => jsonEncode({
    'version': 2,
    'active': active,
    'slots': [
      for (var i = 0; i < 4; i++)
        if (layouts[i] == null)
          null
        else
          {
            'layout': layouts[i]!.toJson(),
            if (names[i] != null) 'name': names[i],
          },
    ],
  });

  factory EasySlots.decode(String source, Adi2Variant variant) {
    try {
      final json = jsonDecode(source);
      if (json is! Map ||
          ![1, 2].contains(json['version']) ||
          json['slots'] is! List ||
          (json['slots'] as List).length != 4) {
        return EasySlots.defaults(variant);
      }
      final entries = json['slots'] as List;
      final active = json['active'];
      return EasySlots(
        active: active is int && active >= 0 && active < 4 ? active : 0,
        layouts: [
          for (final e in entries)
            e is Map && e['layout'] is Map
                ? EasyLayout.decode(jsonEncode(e['layout']), variant)
                : null,
        ],
        names: [
          for (final e in entries)
            e is Map && e['layout'] is Map && e['name'] is String
                ? e['name'] as String
                : null,
        ],
      );
    } catch (_) {
      return EasySlots.defaults(variant);
    }
  }
}
