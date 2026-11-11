part of 'eq_page.dart';

class _EqFullscreen extends StatefulWidget {
  const _EqFullscreen({
    required this.source,
    required this.automatic,
    required this.onClosing,
  });

  final ValueListenable<EqPlot> source;
  final bool automatic;
  final VoidCallback onClosing;

  @override
  State<_EqFullscreen> createState() => _EqFullscreenState();
}

class _EqFullscreenState extends State<_EqFullscreen>
    with WidgetsBindingObserver {
  late int _selected;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.source.value.selected;
    WidgetsBinding.instance.addObserver(this);
    EqDisplayMode.enterFullscreen(this, automatic: widget.automatic);
  }

  @override
  void didChangeMetrics() {
    if (!widget.automatic) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closing) return;
      final size = MediaQuery.sizeOf(context);
      if (size.height > size.width &&
          ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    EqDisplayMode.leaveFullscreen(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop || _closing) return;
      _closing = true;
      widget.onClosing();
    },
    child: Scaffold(
      body: SafeArea(
        child: ValueListenableBuilder<EqPlot>(
          valueListenable: widget.source,
          builder: (context, source, _) {
            final band = eqBands[_selected];
            final address = band.isBassTreble ? source.btAddr : source.eqAddr;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, box) => SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SizedBox(
                              width: math.max(480, box.maxWidth),
                              child: EqBandChips(
                                compact: true,
                                selected: _selected,
                                onSelect: (band) {
                                  setState(() => _selected = band);
                                  source.onSelect(band);
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: tr('Vollbild schließen'),
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.fullscreen_exit),
                      ),
                    ],
                  ),
                ),
                LayoutBuilder(
                  builder: (context, box) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: math.max(700, box.maxWidth),
                      child: Row(
                        children: [
                          Expanded(
                            child: EqBandControls(
                              compact: true,
                              band: _selected,
                              address: address,
                              read: source.read,
                              write: (address, index, raw) {
                                source.write(address, index, raw);
                                setState(() {});
                              },
                            ),
                          ),
                          SizedBox(
                            width: 268,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: band.types.length > 1
                                  ? EqTypeTiles(
                                      compact: true,
                                      band: _selected,
                                      value:
                                          source.read(address, band.typeIdx!) ??
                                          0,
                                      onChanged: (type) {
                                        source.write(
                                          address,
                                          band.typeIdx!,
                                          type,
                                        );
                                        setState(() {});
                                      },
                                    )
                                  : Container(
                                      alignment: Alignment.center,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Palette.bg,
                                        border: Border.all(color: Palette.line),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        tr(switch (band.kindFor(null)) {
                                          FilterKind.lowShelf => 'Low-Shelf',
                                          FilterKind.highShelf => 'High-Shelf',
                                          _ => band.typeName(null),
                                        }),
                                        style: ts(12, color: Palette.muted),
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: EqPlot(
                    fullscreen: true,
                    glide: source.glide,
                    read: source.read,
                    write: (address, index, raw) {
                      source.write(address, index, raw);
                      setState(() {});
                    },
                    eqAddr: source.eqAddr,
                    btAddr: source.btAddr,
                    selected: _selected,
                    enabled: source.enabled,
                    includeBassTreble: source.includeBassTreble,
                    onSelect: (band) {
                      setState(() => _selected = band);
                      source.onSelect(band);
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
