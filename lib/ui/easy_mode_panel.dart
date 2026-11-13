part of 'outputs_page.dart';

String easyTileTitle(EasyTile tile, Adi2Controller ctrl) {
  if (tile.label != null) return tile.label!;
  return switch (tile.type) {
    EasyTileType.volumeRing => tr('Lautstärke'),
    EasyTileType.volumeDown => tr('−0,5 dB'),
    EasyTileType.volumeUp => tr('+0,5 dB'),
    EasyTileType.outputSelect => tr('Ausgangswahl'),
    EasyTileType.mute => tr('Mute'),
    EasyTileType.dim => tr('Dim'),
    EasyTileType.loudness => tr('Loudness'),
    EasyTileType.crossfeed => tr('Crossfeed'),
    EasyTileType.recall => tr('Recall'),
    EasyTileType.link => tr('Link'),
    EasyTileType.lock => tr('Lock'),
    EasyTileType.bass => tr('Bass'),
    EasyTileType.treble => tr('Treble'),
    EasyTileType.balance => tr('Balance'),
    EasyTileType.refLevel => tr('Ref Level'),
    EasyTileType.daFilter => tr('DA-Filter'),
    EasyTileType.source => tr('Quelle'),
    EasyTileType.eqEnable => tr('EQ an/aus'),
    EasyTileType.eqPage => tr('EQ-Seite öffnen'),
    EasyTileType.limit => tr('Limit'),
    EasyTileType.outputSettings => tr('Settings'),
    EasyTileType.setup =>
      ctrl.names[0x20 + (tile.param as int)]?.trim().isNotEmpty == true
          ? ctrl.names[0x20 + (tile.param as int)]!
          : trf('Setup {n}', {'n': tile.param}),
    EasyTileType.eqPreset => ctrl.presetName((tile.param as int) - 1),
    EasyTileType.sourceDirect => trf('Quelle {name}', {
      'name': outputParams(
        ctrl.variant!,
        phones: false,
      ).firstWhere((d) => d.index == OutIdx.source).format(tile.param as int),
    }),
    EasyTileType.toggleOutputs => tr('Ausgänge umschalten'),
    EasyTileType.basicMode => trf('Basic Mode {name}', {
      'name': deviceParams(ctrl.variant!)
          .firstWhere((d) => d.index == 6)
          .format(tile.param as int),
    }),
    EasyTileType.volumeDirect => fmtDb((tile.param as num).toDouble()),
    EasyTileType.appPreset =>
      (tile.param as Map<String, dynamic>)['name'] as String? ??
          tr('App-EQ-Preset'),
  };
}

int? _easyParamIndex(EasyTileType type) => switch (type) {
  EasyTileType.mute => OutIdx.mute,
  EasyTileType.dim => OutIdx.dim,
  EasyTileType.loudness => OutIdx.loudness,
  EasyTileType.crossfeed => OutIdx.crossfeed,
  EasyTileType.lock => OutIdx.lockVolume,
  EasyTileType.balance => OutIdx.balance,
  EasyTileType.refLevel => OutIdx.refLevel,
  EasyTileType.daFilter => OutIdx.daFilter,
  EasyTileType.source || EasyTileType.sourceDirect => OutIdx.source,
  _ => null,
};

/// Scale each line independently so long names do not shrink the status/icon.
Widget _easyText(String text, TextStyle style, {Key? key}) => Center(
  child: FittedBox(
    fit: BoxFit.scaleDown,
    child: Text(text, key: key, maxLines: 1, style: style),
  ),
);

/// The volume step has the same inline symbol/text arrangement as a soft button.
Widget _easySoftFace(
  BuildContext context,
  String title,
  String value,
  IconData icon,
) => Center(
  child: FittedBox(
    fit: BoxFit.scaleDown,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: Palette.muted),
            const SizedBox(width: 4),
            Text(title, maxLines: 1, style: buttonLabelStyle(context)),
          ],
        ),
        if (value.isNotEmpty)
          Text(value, maxLines: 1, style: buttonStatusStyle(context)),
      ],
    ),
  ),
);

Widget _easyFace(
  BuildContext context, {
  required String title,
  String value = '',
  IconData? icon,
  bool active = false,
  Color accent = Palette.amber,
}) => LayoutBuilder(
  builder: (context, box) {
    final label = buttonLabelStyle(context);
    final status = buttonStatusStyle(
      context,
      active: active,
    ).copyWith(color: active ? accent : Palette.text);
    final scale = MediaQuery.textScalerOf(context);
    final height =
        (icon == null ? 0 : 24) +
        scale.scale(label.fontSize!) * 1.3 +
        (value.isEmpty ? 0 : scale.scale(status.fontSize!) * 1.3);
    return Center(
      child: SizedBox(
        height: math.min(height, box.maxHeight),
        child: Column(
          children: [
            if (icon != null)
              Flexible(
                flex: 24,
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Icon(
                      icon,
                      size: 20,
                      color: active ? accent : Palette.muted,
                    ),
                  ),
                ),
              ),
            Flexible(flex: 20, child: _easyText(title, label)),
            if (value.isNotEmpty)
              Flexible(flex: 18, child: _easyText(value, status)),
          ],
        ),
      ),
    );
  },
);

extension _EasyOutputs on _OutputsPageState {
  Widget _buildEasyPanel(EasyLayout setup) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      if (c.variant == null) return const SizedBox.shrink();
      final outs = outputsFor(c.variant!);
      if (widget.editorOutput == null &&
          !c.variant!.isDac &&
          c.valueOr(Adi2Addr.device, 8, 0) == 0 &&
          _sel == Adi2Addr.ph12) {
        _sel = outs.last.address;
      }
      final selected = widget.editorOutput == null
          ? _current(outs)
          : outs.firstWhere((o) => o.address == widget.editorOutput);
      final layout = setup.pageFor(selected.address);
      final ringOutputs = {
        for (final tile in layout.tiles)
          if (tile.type == EasyTileType.volumeRing)
            (outs.where((o) => o.address == tile.output).firstOrNull ??
                    selected)
                .address,
      };
      final panel = TabletContent(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            key: const ValueKey('easy-panel'),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            child: layout.tiles.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      tr(
                        'Füge im Editor für die eigene Ansicht Kacheln hinzu.',
                      ),
                      style: ts(16, color: Palette.muted),
                    ),
                  )
                : EasyTileGrid(
                    layout: layout,
                    availableHeight:
                        isTablet(context) && constraints.hasBoundedHeight
                        ? math.max(0, constraints.maxHeight - 28)
                        : null,
                    onMove: widget.onMoveTile,
                    itemBuilder: (context, index) => _easyTile(
                      layout.tiles[index],
                      index,
                      selected,
                      outs,
                      layout.defaultColor,
                      ringOutputs,
                    ),
                  ),
          ),
        ),
      );
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: [
            for (final child in previous) IgnorePointer(child: child),
            ?current,
          ],
        ),
        child: KeyedSubtree(
          key: ValueKey(
            setup.samePageForAllOutputs ? 'shared' : selected.address,
          ),
          child: panel,
        ),
      );
    },
  );

  Widget _easyTile(
    EasyTile tile,
    int index,
    OutputInfo selected,
    List<OutputInfo> outs,
    EasyTileColor defaultColor,
    Set<int> ringOutputs,
  ) {
    final o =
        outs.where((o) => o.address == tile.output).firstOrNull ?? selected;
    final a = o.address;
    final t = tile.type;
    final hideVolumeValue =
        {EasyTileType.volumeUp, EasyTileType.volumeDown}.contains(t) &&
        ringOutputs.contains(a);
    final paramIndex = _easyParamIndex(t);
    final locked = c.valueOr(a, OutIdx.lockVolume, 0) != 0;
    final fixedRef = t == EasyTileType.refLevel && _fixedRef(o);
    final unavailable =
        !fixedRef && paramIndex != null && c.value(a, paramIndex) == null;
    final active = switch (t) {
      EasyTileType.mute => c.valueOr(a, OutIdx.mute, 0) != 0 || c.autoMuted(a),
      EasyTileType.dim ||
      EasyTileType.loudness ||
      EasyTileType.crossfeed ||
      EasyTileType.lock => c.valueOr(a, paramIndex!, 0) != 0,
      EasyTileType.eqEnable ||
      EasyTileType.eqPage => c.valueOr(a + 1, EqIdx2.enable, 0) != 0,
      EasyTileType.sourceDirect => c.value(a, OutIdx.source) == tile.param,
      EasyTileType.eqPreset =>
        c.value(a + 1, EqIdx2.presetSelect) == (tile.param as int) + 1,
      EasyTileType.basicMode => c.value(Adi2Addr.device, 6) == tile.param,
      EasyTileType.link =>
        c.opts.linked.contains(a) && c.opts.linked.length > 1,
      EasyTileType.volumeDirect =>
        c.value(a, OutIdx.volume) == ((tile.param as num) * 10).round(),
      EasyTileType.recall => _recallFlash,
      _ => false,
    };
    final base = easyTileBackground(tile.color ?? defaultColor);
    final accent = t == EasyTileType.mute ? Palette.red : Palette.amber;
    final background = active
        ? Color.alphaBlend(accent.withValues(alpha: 0.14), base)
        : base;
    const foreground = Palette.text;
    final title = easyTileTitle(tile, c);
    final edit = widget.onEditTile;
    final longPress = _easyLongPress(tile, o, outs);
    final repeatStep = switch (easyLongPressAction(t)) {
      EasyLongPressAction.volumeDown => -5,
      EasyLongPressAction.volumeUp => 5,
      _ => 0,
    };
    final canRepeat = edit == null && !locked && repeatStep != 0;
    // Consume inert holds so releasing them cannot trigger the short-tap
    // action (e.g. load a preset or jump to a fixed volume).
    final suppressHoldTap =
        edit == null &&
        t != EasyTileType.volumeRing &&
        (easyLongPressAction(t) == EasyLongPressAction.none ||
            t == EasyTileType.outputSelect && c.variant!.isDac);
    final volumeAction = {
      EasyTileType.volumeUp,
      EasyTileType.volumeDown,
      EasyTileType.volumeDirect,
      EasyTileType.recall,
    }.contains(t);
    // Smaller editor controls leave room around the centered content.
    final flatEditor =
        edit != null && tile.heightUnits == 0.5 && tile.widthUnits < 30;
    final segmented =
        {
          EasyTileType.outputSelect,
          EasyTileType.source,
          EasyTileType.daFilter,
        }.contains(t) ||
        t == EasyTileType.refLevel &&
            !fixedRef &&
            tile.widthUnits >= 45 &&
            tile.heightUnits >= 1;
    final stepper =
        !fixedRef &&
        EasyTile.isStepper(t) &&
        !({EasyTileType.volumeDown, EasyTileType.volumeUp}.contains(t) &&
            (tile.size == EasyTileSize.fifth ||
                tile.size == EasyTileSize.single && tile.height == 1));
    Widget child;
    if (t == EasyTileType.volumeRing) {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 24,
            child: _easyText(title, buttonLabelStyle(context)),
          ),
          Expanded(
            child: FittedBox(
              // A ring widened by the user must grow on tablets as well.
              fit: isTablet(context) && tile.widthUnits <= 30
                  ? BoxFit.scaleDown
                  : BoxFit.contain,
              child: SizedBox(
                width: 300,
                height: 249,
                child: VolumeRing(
                  actualDb: c.valueOr(a, OutIdx.volume, -1145) / 10,
                  targetDb: c.volumeTarget(a) == null
                      ? null
                      : c.volumeTarget(a)! / 10,
                  limitDb: c.volumeLimit(a) / 10,
                  muted: c.valueOr(a, OutIdx.mute, 0) != 0 || c.autoMuted(a),
                  enabled: !locked && edit == null,
                  onChanged: (db) => c.setVolume(a, (db * 10).round()),
                  onRelease: () => _onRelease(o),
                  levelText: _levelText(
                    c.variant!,
                    a,
                    c.valueOr(a, OutIdx.volume, -1145),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            height: 22,
            child: _easyText(o.name, buttonStatusStyle(context)),
          ),
        ],
      );
    } else {
      final value = switch (t) {
        EasyTileType.outputSelect => selected.name,
        EasyTileType.mute ||
        EasyTileType.dim ||
        EasyTileType.loudness ||
        EasyTileType.lock ||
        EasyTileType.link ||
        EasyTileType.eqEnable => tr(active ? 'An' : 'Aus'),
        EasyTileType.crossfeed =>
          outputParams(c.variant!, phones: o.phones, ess: c.hasEss)
              .firstWhere((d) => d.index == OutIdx.crossfeed)
              .format(c.valueOr(a, OutIdx.crossfeed, 0)),
        EasyTileType.volumeUp ||
        EasyTileType.volumeDown when hideVolumeValue => '',
        EasyTileType.volumeUp ||
        EasyTileType.volumeDown ||
        EasyTileType.volumeDirect => fmtDb(
          c.valueOr(a, OutIdx.volume, -1145) / 10,
        ),
        EasyTileType.recall =>
          c.opts.of(a).recallRaw == null
              ? tr('speichern')
              : fmtDb(c.opts.of(a).recallRaw! / 10),
        EasyTileType.bass => fmtGain(c.eqValue(a + 1, eqBands[5].gainIdx) ?? 0),
        EasyTileType.treble => fmtGain(
          c.eqValue(a + 1, eqBands.last.gainIdx) ?? 0,
        ),
        EasyTileType.balance => _easyBalanceValue(o),
        EasyTileType.refLevel when fixedRef => '',
        EasyTileType.refLevel || EasyTileType.daFilter || EasyTileType.source =>
          unavailable
              ? tr('wie Line')
              : outputParams(c.variant!, phones: o.phones, ess: c.hasEss)
                    .firstWhere((d) => d.index == paramIndex)
                    .format(c.valueOr(a, paramIndex!, 0)),
        _ => tile.hasOutput ? o.name : '',
      };
      final icon = switch (t) {
        EasyTileType.refLevel when fixedRef => Icons.lock_outline,
        EasyTileType.outputSelect ||
        EasyTileType.toggleOutputs => Icons.speaker_group_outlined,
        EasyTileType.volumeUp => Icons.add,
        EasyTileType.volumeDown => Icons.remove,
        EasyTileType.volumeDirect => Icons.volume_up_outlined,
        EasyTileType.mute => Icons.volume_off_outlined,
        EasyTileType.dim => Icons.brightness_low_outlined,
        EasyTileType.loudness => Icons.graphic_eq,
        EasyTileType.crossfeed => Icons.spatial_audio_off,
        EasyTileType.recall => Icons.bookmark_outline,
        EasyTileType.link => Icons.link,
        EasyTileType.lock => active ? Icons.lock : Icons.lock_open,
        EasyTileType.source || EasyTileType.sourceDirect => Icons.input,
        EasyTileType.daFilter => Icons.filter_alt_outlined,
        EasyTileType.setup => Icons.layers_outlined,
        EasyTileType.eqPreset ||
        EasyTileType.appPreset => Icons.library_music_outlined,
        EasyTileType.limit => Icons.shield_outlined,
        EasyTileType.outputSettings => Icons.settings_outlined,
        _ => Icons.tune,
      };
      child = LayoutBuilder(
        builder: (context, box) {
          final tall = tile.type == EasyTileType.balance
              ? false
              : {EasyTileType.bass, EasyTileType.treble}.contains(tile.type)
              ? tile.heightUnits >= 1
              : tile.widthUnits < tile.heightUnits * easyQuarterUnits;
          if (t == EasyTileType.refLevel) {
            return _easyRefTile(
              tile,
              index,
              o,
              outs,
              title,
              segmented,
              unavailable,
            );
          }
          if (stepper) {
            return _easyStepper(
              tile,
              index,
              o,
              title,
              value,
              tall,
              unavailable || locked && volumeAction,
            );
          }
          if (segmented) {
            return _easySegments(tile, index, o, outs, tall, unavailable);
          }
          if (t == EasyTileType.volumeUp || t == EasyTileType.volumeDown) {
            return _easySoftFace(context, title, value, icon);
          }
          return _easyFace(
            context,
            title: title,
            value: value,
            icon: icon,
            active: active,
            accent: accent,
          );
        },
      );
    }
    return Material(
      key: ValueKey('easy-tile-$index'),
      color: background,
      shape: _controlShape.copyWith(
        side: BorderSide(color: active ? accent : Palette.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            onLongPressStart: canRepeat
                ? (_) => _startRepeat(a, repeatStep)
                : suppressHoldTap
                ? (_) {}
                : null,
            onLongPressEnd: canRepeat ? (_) => _stopRepeat(a) : null,
            onLongPressCancel: canRepeat ? () => _stopRepeat(a) : null,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: edit != null
                  ? () => edit(index)
                  : unavailable ||
                        locked && volumeAction ||
                        t == EasyTileType.volumeRing ||
                        segmented ||
                        stepper && !volumeAction
                  ? null
                  : () => _easyAction(tile, o, outs),
              onLongPress: longPress,
              child: Padding(
                // Output segments own every point of the operating tile.
                // Editor controls overlay the surface without shifting content.
                padding: edit == null && t == EasyTileType.outputSelect
                    ? EdgeInsets.zero
                    : const EdgeInsets.all(2),
                child: edit != null ? IgnorePointer(child: child) : child,
              ),
            ),
          ),
          if (edit == null && longPress != null && t != EasyTileType.volumeRing)
            const Positioned(
              top: 3,
              right: 3,
              child: IgnorePointer(
                child: Icon(Icons.more_horiz, size: 14, color: Palette.muted),
              ),
            ),
          if (edit != null && widget.onPinTile != null)
            Positioned(
              top: 0,
              left: 0,
              child: IconButton(
                key: ValueKey('easy-pin-$index'),
                tooltip: tile.pinned
                    ? tr('Kachel lösen')
                    : tr('Kachel fixieren'),
                isSelected: tile.pinned,
                constraints: BoxConstraints.tightFor(
                  width: 28,
                  height: flatEditor ? 16 : 28,
                ),
                padding: EdgeInsets.zero,
                style: IconButton.styleFrom(
                  minimumSize: Size(28, flatEditor ? 16 : 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                iconSize: flatEditor ? 14 : 16,
                color: tile.pinned ? Palette.amber : foreground,
                icon: Icon(
                  tile.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                ),
                onPressed: () => widget.onPinTile!(index),
              ),
            ),
          if (edit != null)
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                key: ValueKey('easy-edit-$index'),
                tooltip: tr('Kachel bearbeiten'),
                constraints: BoxConstraints.tightFor(
                  width: 28,
                  height: flatEditor ? 16 : 28,
                ),
                padding: EdgeInsets.zero,
                style: IconButton.styleFrom(
                  minimumSize: Size(28, flatEditor ? 16 : 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                iconSize: flatEditor ? 14 : 16,
                color: foreground,
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => edit(index),
              ),
            ),
        ],
      ),
    );
  }

  String _easyBalanceValue(OutputInfo o) {
    return formatBalance(c.valueOr(o.address, OutIdx.balance, 0));
  }

  Widget _easyStepper(
    EasyTile tile,
    int index,
    OutputInfo o,
    String title,
    String value,
    bool tall,
    bool disabled,
  ) => LayoutBuilder(
    builder: (context, box) {
      // Keep two 48 px targets whenever the axis also has room for text.
      final axisExtent = tall ? box.maxHeight : box.maxWidth;
      final buttonExtent = math.min(
        math.max(0.0, (axisExtent - 16) / 2),
        math.max(48.0, axisExtent * 0.35),
      );
      final crossExtent = tall ? box.maxWidth : box.maxHeight;
      final textScale = (math.min(buttonExtent, crossExtent) / 44).clamp(
        1.0,
        2.0,
      );
      Widget button(int direction) {
        final name = direction > 0 ? 'plus' : 'minus';
        void step() => _easyStep(tile, o, direction);
        return SizedBox(
          width: tall ? double.infinity : buttonExtent,
          height: tall ? buttonExtent : double.infinity,
          child: Semantics(
            label: '$title ${direction > 0 ? '+' : '−'}',
            button: true,
            enabled: !disabled && widget.onEditTile == null,
            child: GestureDetector(
              onLongPressStart: disabled
                  ? null
                  : (_) {
                      if (direction > 0 &&
                          {
                            EasyTileType.volumeUp,
                            EasyTileType.volumeDown,
                            EasyTileType.volumeDirect,
                          }.contains(tile.type)) {
                        _holdingUp = true;
                      }
                      _startRepeat(o.address, direction, onStep: step);
                    },
              onLongPressEnd: (_) => _stopRepeat(o.address),
              onLongPressCancel: () => _stopRepeat(o.address),
              child: InkWell(
                key: ValueKey('easy-step-$index-$name'),
                onTap: disabled ? null : step,
                borderRadius: BorderRadius.circular(10),
                child: Ink(
                  decoration: const ShapeDecoration(shape: _controlShape),
                  child: Center(
                    child: _easyText(
                      direction > 0 ? '+' : '−',
                      buttonLabelStyle(context)
                          .copyWith(fontSize: 18 * textScale),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }

      final valueLine = _easyText(
        value,
        buttonStatusStyle(
          context,
          active: !disabled,
        ).copyWith(fontSize: buttonStatusStyle(context).fontSize! * textScale),
        key: ValueKey('easy-step-$index-value'),
      );
      final titleLine = _easyText(title, buttonLabelStyle(context));
      if (tall &&
          {EasyTileType.bass, EasyTileType.treble}.contains(tile.type)) {
        return Column(
          key: ValueKey('easy-step-$index-vertical'),
          children: [
            Expanded(child: titleLine),
            button(1),
            Expanded(child: valueLine),
            button(-1),
          ],
        );
      }
      // Keep the value key on the actual status line for inspection.
      final centerWithKey = Expanded(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(child: titleLine),
            if (value.isNotEmpty) Flexible(child: valueLine),
          ],
        ),
      );
      return Flex(
        key: ValueKey('easy-step-$index-${tall ? 'vertical' : 'horizontal'}'),
        direction: tall ? Axis.vertical : Axis.horizontal,
        children: [button(tall ? 1 : -1), centerWithKey, button(tall ? -1 : 1)],
      );
    },
  );

  void _easyStep(EasyTile tile, OutputInfo o, int direction) {
    final a = o.address;
    switch (tile.type) {
      case EasyTileType.bass || EasyTileType.treble:
        _stepTone(
          a + 1,
          tile.type == EasyTileType.bass ? eqBands[5] : eqBands.last,
          direction,
        );
      case EasyTileType.balance:
        final def = outputParams(
          c.variant!,
          phones: o.phones,
          ess: c.hasEss,
        ).firstWhere((d) => d.index == OutIdx.balance);
        c.set(
          a,
          def.index,
          (c.valueOr(a, def.index, def.def) + direction).clamp(
            def.min,
            def.max,
          ),
        );
      default:
        if (c.valueOr(a, OutIdx.lockVolume, 0) != 0) return;
        c.setVolume(a, c.valueOr(a, OutIdx.volume, -1145) + direction * 5);
    }
  }

  Widget _easyRefTile(
    EasyTile tile,
    int index,
    OutputInfo o,
    List<OutputInfo> outs,
    String title,
    bool segmented,
    bool unavailable,
  ) {
    final fixed = _fixedRef(o);
    final def = outputParams(
      c.variant!,
      phones: o.phones,
      ess: c.hasEss,
    ).firstWhere((d) => d.index == OutIdx.refLevel);
    final current = c.valueOr(o.address, OutIdx.refLevel, 0);
    final auto = c.value(o.address, OutIdx.autoRef);
    final rca = c.variant!.isDac && o.address == Adi2Addr.line;
    Widget label(int n, {bool selected = false}) => FittedBox(
      fit: BoxFit.scaleDown,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            n == -1 ? tr('Auto') : def.format(n),
            style: buttonStatusStyle(context, active: selected),
          ),
          if (rca && n != -1)
            Text(_refXlr(o, n), style: buttonStatusStyle(context)),
        ],
      ),
    );
    if (segmented) {
      final options = [
        if (auto != null) -1,
        for (var n = def.min; n <= def.max; n++) n,
      ];
      return Column(
        children: [
          SizedBox(
            height: 24,
            child: _easyText(title, buttonLabelStyle(context)),
          ),
          Expanded(
            child: Row(
              key: ValueKey('easy-segments-$index-horizontal'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final n in options)
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final selected = n == -1
                            ? auto == 1
                            : auto != 1 && current == n;
                        return InkWell(
                          key: ValueKey('easy-segment-$index-$n'),
                          onTap: widget.onEditTile != null || unavailable
                              ? null
                              : () => _selectRef(o, n),
                          onLongPress: _easyLongPress(tile, o, outs),
                          child: Ink(
                            decoration: BoxDecoration(
                              color: selected
                                  ? Palette.amber.withValues(alpha: 0.14)
                                  : null,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: selected ? Palette.amber : Palette.line,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Center(
                                child: label(n, selected: selected),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }
    final value = fixed
        ? '−3 dBu'
        : unavailable
        ? tr('wie Line')
        : '${auto == 1 ? '${tr('Auto')} ' : ''}${def.format(current)}';
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  fixed ? Icons.lock_outline : Icons.tune,
                  size: 16,
                  color: Palette.muted,
                ),
                const SizedBox(width: 4),
                Text(title, style: buttonLabelStyle(context)),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: buttonStatusStyle(
                    context,
                    active: !fixed && !unavailable,
                  ),
                ),
              ],
            ),
            if (rca && !unavailable)
              Text(_refXlr(o, current), style: buttonStatusStyle(context)),
          ],
        ),
      ),
    );
  }

  Widget _easySegments(
    EasyTile tile,
    int index,
    OutputInfo o,
    List<OutputInfo> outs,
    bool tall,
    bool unavailable,
  ) {
    final isOutput = tile.type == EasyTileType.outputSelect;
    final def = isOutput
        ? null
        : outputParams(
            c.variant!,
            phones: o.phones,
            ess: c.hasEss,
          ).firstWhere((d) => d.index == _easyParamIndex(tile.type));
    if (unavailable) {
      return _easyFace(
        context,
        title: easyTileTitle(tile, c),
        value: tr('wie Line'),
        icon: tile.type == EasyTileType.daFilter
            ? Icons.filter_alt_outlined
            : Icons.input,
      );
    }
    if (isOutput) {
      final disabled =
          !c.variant!.isDac && c.valueOr(Adi2Addr.device, 8, 0) == 0
          ? {Adi2Addr.ph12}
          : <int>{};
      return LayoutBuilder(
        builder: (context, box) {
          final vertical = box.maxHeight > box.maxWidth;
          final segmentWidth = vertical
              ? box.maxWidth
              : box.maxWidth / outs.length;

          return Flex(
            key: ValueKey(
              'easy-segments-$index-${vertical ? 'vertical' : 'horizontal'}',
            ),
            direction: vertical ? Axis.vertical : Axis.horizontal,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final out in outs)
                Expanded(
                  child: InkWell(
                    key: ValueKey('easy-segment-$index-${out.address}'),
                    onTap:
                        widget.onEditTile != null ||
                            disabled.contains(out.address)
                        ? null
                        : () => _selectEasyOutput(out.address),
                    // Keep the main view's Phones settings on long press.
                    onLongPress: _easyLongPress(tile, o, outs),
                    child: Ink(
                      decoration: BoxDecoration(
                        color: out.address == o.address
                            ? Palette.amber.withValues(alpha: 0.14)
                            : null,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: out.address == o.address
                              ? Palette.amber
                              : Palette.line,
                        ),
                      ),
                      child: Center(
                        child: SizedBox(
                          width: (segmentWidth - 8).clamp(0.0, double.infinity),
                          height: vertical
                              ? box.maxHeight / outs.length - 4
                              : box.maxHeight - 4,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              out.name,
                              maxLines: 1,
                              style: buttonLabelStyle(context).copyWith(
                                color: disabled.contains(out.address)
                                    ? Palette.muted
                                    : out.address == o.address
                                    ? Palette.amber
                                    : Palette.text,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      );
    }
    final options = {
      for (var n = def!.min; n <= def.max; n++) n: def.format(n),
    };
    final current = c.valueOr(o.address, def.index, def.def);
    final disabledValues = {
      for (final n in options.keys)
        if (c.isParamValueDisabled(o.address, def.index, n)) n,
    };
    return Column(
      children: [
        Flexible(
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    tile.type == EasyTileType.daFilter
                        ? Icons.filter_alt_outlined
                        : Icons.input,
                    size: 16,
                    color: Palette.muted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    easyTileTitle(tile, c),
                    style: buttonLabelStyle(context),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          flex: tile.heightUnits == 0.5 ? 1 : 3,
          child: Flex(
            key: ValueKey(
              'easy-segments-$index-${tall ? 'vertical' : 'horizontal'}',
            ),
            direction: tall ? Axis.vertical : Axis.horizontal,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final entry in options.entries)
                Expanded(
                  child: TextButton(
                    key: ValueKey('easy-segment-$index-${entry.key}'),
                    style: TextButton.styleFrom(
                      backgroundColor: current == entry.key
                          ? Palette.amber.withValues(alpha: 0.14)
                          : null,
                      padding: const EdgeInsets.all(2),
                      minimumSize: Size.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(
                          color: current == entry.key
                              ? Palette.amber
                              : Palette.line,
                        ),
                      ),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed:
                        widget.onEditTile != null ||
                            disabledValues.contains(entry.key)
                        ? null
                        : () => c.set(o.address, def.index, entry.key),
                    child: _easyText(
                      entry.value,
                      buttonStatusStyle(
                        context,
                        active: current == entry.key,
                      ).copyWith(
                        color: disabledValues.contains(entry.key)
                            ? Palette.muted.withValues(alpha: 0.45)
                            : null,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  void _easyAction(EasyTile tile, OutputInfo o, List<OutputInfo> outs) {
    final a = o.address;
    switch (tile.type) {
      case EasyTileType.setup:
        c.loadSetup(tile.param as int);
      case EasyTileType.eqPreset:
        unawaited(c.loadEqPreset(a + 1, (tile.param as int) + 1));
      case EasyTileType.sourceDirect:
        c.set(a, OutIdx.source, tile.param as int);
      case EasyTileType.toggleOutputs:
        c.toggleOutputs();
      case EasyTileType.basicMode:
        c.set(Adi2Addr.device, 6, tile.param as int);
      case EasyTileType.volumeDirect:
        c.setVolume(a, ((tile.param as num) * 10).round());
      case EasyTileType.volumeDown:
        c.setVolume(a, c.valueOr(a, OutIdx.volume, -1145) - 5);
      case EasyTileType.volumeUp:
        c.setVolume(a, c.valueOr(a, OutIdx.volume, -1145) + 5);
      case EasyTileType.appPreset:
        final buffer = EqEditorBuffer()
          ..loadAppPreset(
            AppEqPreset.fromJson(tile.param as Map<String, dynamic>),
          );
        c.set(a, OutIdx.dualEq, buffer.dual ? 1 : 0);
        for (final e in buffer.left.entries) {
          c.setEq(a + 1, e.key, e.value);
        }
        for (final e in buffer.right.entries) {
          c.setEq(a + 2, e.key, e.value);
        }
      case EasyTileType.mute ||
          EasyTileType.dim ||
          EasyTileType.loudness ||
          EasyTileType.lock:
        final idx = _easyParamIndex(tile.type)!;
        c.set(a, idx, c.valueOr(a, idx, 0) == 0 ? 1 : 0);
      case EasyTileType.crossfeed:
        final current = c.valueOr(a, OutIdx.crossfeed, 0);
        if (current > 0) _lastCrossfeed[a] = current;
        c.set(a, OutIdx.crossfeed, current == 0 ? (_lastCrossfeed[a] ?? 1) : 0);
      case EasyTileType.recall:
        if (c.opts.of(a).recallRaw == null) {
          _storeRecall(a, c.valueOr(a, OutIdx.volume, -1145));
        } else {
          c.recall(a);
          _flashRecall();
        }
      case EasyTileType.eqEnable:
        c.set(
          a + 1,
          EqIdx2.enable,
          c.valueOr(a + 1, EqIdx2.enable, 0) == 0 ? 1 : 0,
        );
      case EasyTileType.link:
        if (c.opts.linked.contains(a) && c.opts.linked.length > 1) {
          for (final x in c.opts.linked.toList()) {
            c.setLinked(x, false);
          }
        } else {
          _linkSheet(outs, a);
        }
      case EasyTileType.refLevel:
        _pickRef(o);
      case EasyTileType.outputSelect ||
          EasyTileType.source ||
          EasyTileType.daFilter ||
          EasyTileType.bass ||
          EasyTileType.treble ||
          EasyTileType.balance:
        break;
      default:
        _easyLongPress(tile, o, outs)?.call();
    }
  }

  VoidCallback? _easyLongPress(
    EasyTile tile,
    OutputInfo o,
    List<OutputInfo> outs,
  ) {
    if (widget.onEditTile != null) return null;
    final action = easyLongPressAction(tile.type);
    if (action == EasyLongPressAction.none ||
        action == EasyLongPressAction.volumeDown ||
        action == EasyLongPressAction.volumeUp ||
        action == EasyLongPressAction.phones && c.variant!.isDac) {
      return null;
    }
    final index = _easyParamIndex(tile.type);
    if (tile.type == EasyTileType.refLevel && _fixedRef(o)) {
      return _showFixedRef;
    }
    if (index != null && c.value(o.address, index) == null) return null;
    return () => _runEasyLongPress(action, tile, o, outs);
  }

  void _runEasyLongPress(
    EasyLongPressAction action,
    EasyTile tile,
    OutputInfo o,
    List<OutputInfo> outs,
  ) {
    final a = o.address;
    final defs = outputParams(c.variant!, phones: o.phones, ess: c.hasEss);
    switch (action) {
      case EasyLongPressAction.none ||
          EasyLongPressAction.volumeDown ||
          EasyLongPressAction.volumeUp:
        break; // Holds are handled by the gesture lifecycle, never a menu.
      case EasyLongPressAction.bass || EasyLongPressAction.treble:
        _toneSheet(
          o,
          action == EasyLongPressAction.bass ? eqBands[5] : eqBands.last,
        );
      case EasyLongPressAction.mute:
        _muteSheet();
      case EasyLongPressAction.dimInfo:
        _dimInfo();
      case EasyLongPressAction.loudness:
        _paramSheet(
          trf('Loudness, {name}', {'name': o.name}),
          a,
          defs
              .where(
                (d) =>
                    d.index >= OutIdx.loudness &&
                    d.index <= OutIdx.loudLowVolRef,
              )
              .toList(),
          note: tr(
            'Hebt Bass und Höhen bei leiser Lautstärke an. Unterhalb von „Low Vol Ref“ wirkt die volle Anhebung, 20 dB darüber keine mehr.',
          ),
        );
      case EasyLongPressAction.crossfeed:
        _pickChoice(a, defs.firstWhere((d) => d.index == OutIdx.crossfeed));
      case EasyLongPressAction.recall:
        _recallSheet(a, o.name);
      case EasyLongPressAction.link:
        _linkSheet(outs, a);
      case EasyLongPressAction.refLevel:
        _pickRef(o);
      case EasyLongPressAction.source || EasyLongPressAction.daFilter:
        _pickChoice(
          a,
          defs.firstWhere((d) => d.index == _easyParamIndex(tile.type)),
        );
      case EasyLongPressAction.balance || EasyLongPressAction.lock:
        _paramSheet(
          easyTileTitle(tile, c),
          a,
          defs.where((d) => d.index == _easyParamIndex(tile.type)).toList(),
        );
      case EasyLongPressAction.eq:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => EqPage(ctrl: c, channelAddr: a, title: o.name),
          ),
        );
      case EasyLongPressAction.limit:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ProtectionPage(ctrl: c, out: o),
          ),
        );
      case EasyLongPressAction.outputSettings:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => OutputSettingsPage(ctrl: c, out: o),
          ),
        );
      case EasyLongPressAction.setup:
        _easySetupMenu(tile.param as int);
      case EasyLongPressAction.signalFlow:
        showSignalFlow(context, SignalFlowMode.values[tile.param as int]);
      case EasyLongPressAction.phones:
        _phonesSheet();
    }
  }

  String _easySetupName(int n) {
    final name = c.names[0x20 + n];
    return name == null || name.trim().isEmpty
        ? trf('Setup {n}', {'n': n})
        : name;
  }

  Future<void> _easySetupMenu(int n) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_easySetupName(n), style: ts(18, weight: 600)),
            ListTile(
              title: Text(tr('Laden')),
              onTap: c.offline ? null : () => Navigator.pop(ctx, 'load'),
            ),
            ListTile(
              title: Text(tr('Aktuelle Einstellungen hier speichern')),
              onTap: c.offline ? null : () => Navigator.pop(ctx, 'save'),
            ),
            ListTile(
              title: Text(tr('Umbenennen')),
              onTap: c.offline ? null : () => Navigator.pop(ctx, 'rename'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || c.offline) return;
    switch (action) {
      case 'load':
        if (c.valueOr(Adi2Addr.device, DevIdx.loadVolumeWithSetup, 0) != 0 &&
            !await _easySetupConfirm(
              tr('Setup laden?'),
              tr(
                'Die Lautstärke wird mit dem Setup geladen und kann lauter werden.',
              ),
              tr('Laden'),
            )) {
          return;
        }
        if (mounted && !c.offline) c.loadSetup(n);
      case 'save':
        final ok = await _easySetupConfirm(
          trf('{name} überschreiben?', {'name': _easySetupName(n)}),
          tr('Die aktuellen Einstellungen werden im Gerät gespeichert.'),
          tr('Speichern'),
        );
        if (ok && mounted && !c.offline) c.saveSetup(n);
      case 'rename':
        final form = GlobalKey<FormState>();
        var edited = _easySetupName(n).characters.take(nameLength).toString();
        final name = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('Umbenennen')),
            content: Form(
              key: form,
              child: TextFormField(
                initialValue: edited,
                autofocus: true,
                maxLength: nameLength,
                decoration: InputDecoration(labelText: tr('Name')),
                onChanged: (value) => edited = value,
                validator: (value) =>
                    value == null ||
                        String.fromCharCodes(nameBytes(value).take(nameLength))
                            .trim()
                            .isEmpty
                    ? tr('Bitte einen Namen eingeben.')
                    : null,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('Abbrechen')),
              ),
              FilledButton(
                onPressed: () {
                  if (form.currentState!.validate()) {
                    Navigator.pop(ctx, edited.trim());
                  }
                },
                child: Text(tr('Speichern')),
              ),
            ],
          ),
        );
        if (name != null && mounted && !c.offline) c.renameSetup(n, name);
    }
  }

  Future<bool> _easySetupConfirm(
    String title,
    String message,
    String button,
  ) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Abbrechen')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(button),
            ),
          ],
        ),
      ) ??
      false;
}
