import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../device/adi2_controller.dart';
import '../easy/easy_layout.dart';
import 'outputs_page.dart';

/// The real operating widget, scaled from the same 328 px panel and 8 px gaps.
/// A fixed canvas keeps the proportions of different shapes comparable.
class EasyTilePreview extends StatelessWidget {
  const EasyTilePreview({
    super.key,
    required this.ctrl,
    required this.tile,
    this.defaultColor = EasyTileColor.graphite,
    this.output,
    this.fillPreview = false,
  });

  final Adi2Controller ctrl;
  final EasyTile tile;
  final EasyTileColor defaultColor;
  final int? output;

  /// Use the tile itself as the canvas for large catalog previews.
  final bool fillPreview;

  // Match the grid's minimum target for half-height fifths.
  double get _tileHeight =>
      tile.heightUnits *
          (tile.size == EasyTileSize.fifth && tile.heightUnits == 0.5
              ? 104
              : 84) -
      8;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.contain,
    child: SizedBox(
      width: fillPreview
          ? tile.widthUnits * (328 + 8) / easyGridUnits - 8
          : 328,
      height: fillPreview ? _tileHeight : math.max(160, _tileHeight),
      child: Center(
        child: SizedBox(
          width: tile.widthUnits * (328 + 8) / easyGridUnits - 8,
          height: _tileHeight,
          child: OutputsPage(
            ctrl: ctrl,
            previewTile: tile,
            previewColor: defaultColor,
            editorOutput: output,
          ),
        ),
      ),
    ),
  );
}
