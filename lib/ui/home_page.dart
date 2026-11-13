import 'dart:math' as math;
import 'dart:async';

import '../app_info.dart';
import '../update/app_updates.dart';
import '../update/open_update.dart';

import '../analyzer/analyzer_controller.dart';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../device/adi2_controller.dart';
import '../device/volume_options.dart';
import '../device/supported_models.dart';
import '../protocol/adi2_codec.dart';
import '../protocol/adi2_params.dart';
import '../app_settings.dart';
import 'app_settings_page.dart';
import 'host_connect_page.dart';
import 'backup_page.dart';
import 'setups_page.dart';
import 'device_setup_section.dart';
import 'loopback_section.dart';
import 'eq_page.dart';
import 'outputs_page.dart';
import 'param_tile.dart';
import 'player_bar.dart';
import '../media/now_playing.dart';
import 'theme.dart';
import '../analyzer/header_content.dart';
import 'analyzer_panel.dart';
import 'responsive_layout.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.ctrl,
    required this.np,
    this.updatesReady = true,
  });
  final Adi2Controller ctrl;
  final NowPlaying np;
  final bool updatesReady;

  @override
  State<HomePage> createState() => _HomePageState();
}

/// Titelzeile. Der Offline-Hinweis steht darin mittig zur Displaybreite und
/// rückt nur nach links, wenn er sonst die Bedienelemente berühren würde.
class HomeHeaderRow extends StatelessWidget {
  const HomeHeaderRow({
    super.key,
    required this.title,
    required this.actions,
    this.badge,
  });
  final Widget title, actions;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final badge = this.badge;
    if (badge == null) {
      return Row(
        children: [
          Expanded(child: title),
          actions,
        ],
      );
    }
    final height = math.max(
      56.0,
      MediaQuery.textScalerOf(context).scale(44) + 12,
    );
    return SizedBox(
      height: height,
      child: CustomMultiChildLayout(
        delegate: _HeaderLayout(),
        children: [
          LayoutId(id: _HeaderSlot.title, child: title),
          LayoutId(
            id: _HeaderSlot.badge,
            child: FittedBox(fit: BoxFit.scaleDown, child: badge),
          ),
          LayoutId(id: _HeaderSlot.actions, child: actions),
        ],
      ),
    );
  }
}

enum _HeaderSlot { title, badge, actions }

class _HeaderLayout extends MultiChildLayoutDelegate {
  // Die Zeile sitzt links 20, rechts 12 eingerückt: Displaymitte = Mitte - 4.
  static const _displayCentreOffset = -4.0, _gap = 6.0;

  @override
  void performLayout(Size size) {
    final loose = BoxConstraints.loose(size);
    final actions = layoutChild(_HeaderSlot.actions, loose);
    final actionsX = size.width - actions.width;
    final badge = layoutChild(
      _HeaderSlot.badge,
      BoxConstraints(
        maxWidth: math.max(0.0, actionsX - _gap),
        maxHeight: size.height,
      ),
    );
    final centred = size.width / 2 + _displayCentreOffset - badge.width / 2;
    final badgeX = math.max(
      0.0,
      math.min(centred, actionsX - _gap - badge.width),
    );
    final title = layoutChild(
      _HeaderSlot.title,
      BoxConstraints(
        maxWidth: math.max(0.0, badgeX - _gap),
        maxHeight: size.height,
      ),
    );
    double middle(double h) => (size.height - h) / 2;
    positionChild(_HeaderSlot.title, Offset(0, middle(title.height)));
    positionChild(_HeaderSlot.badge, Offset(badgeX, middle(badge.height)));
    positionChild(
      _HeaderSlot.actions,
      Offset(actionsX, middle(actions.height)),
    );
  }

  @override
  bool shouldRelayout(_HeaderLayout oldDelegate) => false;
}

/// OFFLINE steht mittig in der Titelzeile. HOST sitzt dagegen als Knopf-
/// ähnliches Feld in der Knopfreihe, damit der Gerätename Platz behält.
Widget? connectionBadge(Adi2Controller controller) =>
    controller.offline && !controller.viaHost ? const _OfflineBadge() : null;

/// Langdruck auf „HOST“: Host anzeigen, Kopplung entfernen, Hosts verwalten.
Future<void> showHostMenu(BuildContext context, Adi2Controller c) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.computer),
              title: Text(tr('Verbunden über Host')),
              subtitle: Text(c.hostName ?? ''),
            ),
            ListTile(
              key: const ValueKey('host-menu-forget'),
              leading: const Icon(Icons.link_off),
              title: Text(tr('Kopplung entfernen')),
              subtitle: Text(
                tr('Trennt die Verbindung. Danach muss neu gekoppelt werden.'),
              ),
              onTap: () async {
                final id = c.hostId;
                final ok = await showDialog<bool>(
                  context: sheet,
                  builder: (d) => AlertDialog(
                    title: Text(tr('Kopplung entfernen?')),
                    content: Text(
                      trf(
                        'Die Kopplung mit {name} wird gelöscht. Zum erneuten '
                        'Verbinden im Host „Smartphone koppeln…“ öffnen.',
                        {'name': c.hostName ?? 'Host'},
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(d, false),
                        child: Text(tr('Abbrechen')),
                      ),
                      TextButton(
                        key: const ValueKey('host-menu-forget-confirm'),
                        onPressed: () => Navigator.pop(d, true),
                        child: Text(tr('Entfernen')),
                      ),
                    ],
                  ),
                );
                if (ok != true || !sheet.mounted) return;
                Navigator.pop(sheet);
                if (id != null) {
                  try {
                    await c.forgetHost(id);
                  } catch (_) {}
                }
                if (c.viaHost) c.disconnect();
              },
            ),
            ListTile(
              key: const ValueKey('host-menu-pause'),
              leading: const Icon(Icons.pause_circle_outline),
              title: Text(tr('Verbindung pausieren')),
              subtitle: Text(
                tr(
                  'Trennt und verbindet nicht mehr automatisch, bis du sie fortsetzt.',
                ),
              ),
              onTap: () {
                Navigator.pop(sheet);
                unawaited(c.pauseHost());
              },
            ),
            ListTile(
              key: const ValueKey('host-menu-manage'),
              leading: const Icon(Icons.settings_ethernet),
              title: Text(tr('Hosts verwalten…')),
              onTap: () {
                Navigator.pop(sheet);
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => HostConnectPage(ctrl: c),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );

class HostBadge extends StatelessWidget {
  const HostBadge({super.key});

  /// Breite des Knopfs „Eigene Ansicht“: Beschriftung plus Innenabstand
  /// 2 × 8 und Rahmen 2 × 1, wie beim FilterChip daneben.
  static double easyChipWidth(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(
        text: tr('Eigene\nAnsicht'),
        style: ts(11, weight: 600).copyWith(height: 1.0),
      ),
      textAlign: TextAlign.center,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 2,
    )..layout();
    return painter.width + 18;
  }

  // Gleiche Größe und Form wie der Knopf „Eigene Ansicht“ daneben.
  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('host-badge'),
    // Sichtbare Höhe des Knopfs „Eigene Ansicht“ einschließlich Rahmen
    // (dessen 44 sind Tippfläche).
    height: 34,
    width: easyChipWidth(context),
    padding: const EdgeInsets.symmetric(horizontal: 4),
    decoration: BoxDecoration(
      color: Palette.green,
      borderRadius: BorderRadius.circular(8),
    ),
    alignment: Alignment.center,
    child: Text(
      'HOST',
      maxLines: 1,
      style: ts(11, weight: 600, color: Colors.white).copyWith(height: 1.0),
    ),
  );
}

class _OfflineBadge extends StatelessWidget {
  const _OfflineBadge();

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('offline-badge'),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: Palette.red,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      tr('OFFLINE'),
      style: ts(12, weight: 700, color: Colors.white, spacing: 0.8),
    ),
  );
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  /// Eine Aufnahme für alle Ansichten: Beim Drehen des Tablets wechselt die
  /// Anzeige, die laufende USB-Aufnahme darf dabei nicht neu starten.
  final _analyzer = AnalyzerController();
  Timer? _updateDialogTimer;
  final Set<String> _announcedUpdates = {};

  void _maybeShowUpdate() {
    final service = AppUpdates.instance;
    final result = service.result;
    if (!mounted ||
        !widget.updatesReady ||
        !AppSettings.instance.updateCheck ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        ModalRoute.of(context)?.isCurrent != true ||
        result == null ||
        !service.checker!.resultWasAutomatic ||
        !service.checker!.shouldNotify(result) ||
        !_announcedUpdates.add(result.version!)) {
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Update verfügbar')),
        content: Text(
          trf('Version {version} ist verfügbar (installiert: {installed}).', {
            'version': result.version,
            'installed': appVersion,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await service.checker!.skip(result.version!);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: Text(tr('Später')),
          ),
          TextButton(
            onPressed: () async {
              final opened = await openUpdate(result.url!);
              if (!dialogContext.mounted) return;
              Navigator.pop(dialogContext);
              if (!opened && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      tr('Download-Link konnte nicht geöffnet werden'),
                    ),
                  ),
                );
              }
            },
            child: Text(tr('Laden', context: 'update')),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updateDialogTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _maybeShowUpdate(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      AppUpdates.instance.checker?.check();
    }
    // Am Gerät kann sich im Hintergrund alles geändert haben.
    if (state == AppLifecycleState.resumed && widget.ctrl.isConnected) {
      widget.ctrl.requestAll();
    }
  }

  @override
  void dispose() {
    _updateDialogTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _analyzer.dispose();
    super.dispose();
  }

  int? _tab;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.ctrl,
        AppSettings.instance,
        widget.np,
      ]),
      builder: (context, _) {
        final c = widget.ctrl;
        if (!c.hasDeviceDisplay || c.variant == null) {
          _tab = null;
          return ConnectPage(ctrl: c, np: widget.np);
        }
        final v = c.variant!;
        final settings = AppSettings.instance;
        final easy = settings.easyMode;
        final landscape = isTabletLandscape(context);
        final layout = settings.easyLayout(v);
        final availableOutputs = outputsFor(v);
        var headerOutput = c.selectedOutput;
        if (!availableOutputs.any((o) => o.address == headerOutput) ||
            (!v.isDac &&
                c.valueOr(Adi2Addr.device, 8, 0) == 0 &&
                headerOutput == Adi2Addr.ph12)) {
          headerOutput = v.isDac
              ? Adi2Addr.ph12
              : availableOutputs.last.address;
        }
        final headerLayout = layout.pageFor(headerOutput!);
        final playerVisible =
            c.viaHost ||
            widget.np.supported &&
                ((!widget.np.access && !widget.np.promptDismissed) ||
                    widget.np.access && widget.np.info?.hasContent == true);
        final header = easy
            ? headerLayout.headerContent
            : settings.headerContent;
        final showStatus = easy ? headerLayout.showStatus : settings.showStatus;
        final hasMainHeader =
            header == HeaderContent.analyzer ||
            header == HeaderContent.status ||
            (header == HeaderContent.player && (showStatus || playerVisible));
        final outputsIndex = v.hasInput ? 1 : 0;
        final tabs = <(String, IconData, Widget)>[
          if (v.hasInput) (tr('Eingang'), Icons.input, InputPage(ctrl: c)),
          (
            tr('Ausgänge'),
            Icons.volume_up,
            OutputsPage(
              ctrl: c,
              easyLayout: easy ? layout : null,
              useFreedSpace: landscape || !hasMainHeader,
              onOutputSelected: () => setState(() {}),
            ),
          ),
          (tr('Gerät'), Icons.settings, DevicePage(ctrl: c)),
          (tr('Setups'), Icons.layers_outlined, SetupsPage(ctrl: c)),
          (tr('Status'), Icons.info_outline, StatusPage(ctrl: c)),
        ];
        final idx = (_tab ?? outputsIndex).clamp(0, tabs.length - 1);
        final srIdx = c.value(Adi2Addr.device, DevIdx.sampleRate);
        const srNames = [
          '44,1',
          '48',
          '88,2',
          '96',
          '176,4',
          '192',
          '352,8',
          '384',
          '705,6',
          '768',
        ];
        final rate = (srIdx != null && srIdx >= 0 && srIdx < srNames.length)
            ? '${srNames[srIdx]} kHz'
            : null;
        // Abtastrate immer in der Kopfzeile: Die Analyzer-Infozeile ist
        // zugeklappt und zeigt sie nicht mehr dauerhaft.
        final connectionRate = rate == null ? '' : ', $rate';
        final outputHeader = <Widget>[
          if (header == HeaderContent.analyzer)
            AnalyzerPanel(
              controller: _analyzer,
              deviceController: c,
              np: widget.np,
            )
          else if (header == HeaderContent.player)
            PlayerBar(
              deviceController: c,
              np: widget.np,
              collapseWhenEmpty: !showStatus,
              fallback: showStatus
                  ? _DigitalMini(
                      key: const ValueKey('digital-mini'),
                      ctrl: c,
                      onTap: () => setState(() => _tab = tabs.length - 1),
                    )
                  : null,
            )
          else if (header == HeaderContent.status)
            _DigitalMini(
              key: const ValueKey('digital-mini'),
              ctrl: c,
              onTap: () => setState(() => _tab = tabs.length - 1),
            ),
        ];
        final mainContent = Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
              child: HomeHeaderRow(
                badge: connectionBadge(c),
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: SizedBox(
                            // A fitted Host title must retain the USB title's
                            // line height so the analyzer and channels stay put.
                            height:
                                isTablet(context) &&
                                    header == HeaderContent.analyzer
                                ? MediaQuery.textScalerOf(context).scale(28)
                                : null,
                            child: c.offline || c.viaHost
                                ? FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      c.deviceLabel,
                                      maxLines: 1,
                                      style: ts(22, weight: 600),
                                    ),
                                  )
                                : Text(
                                    c.deviceLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: ts(22, weight: 600),
                                  ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Container(
                          key: const ValueKey('connection-status-dot'),
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: c.offline
                                ? Palette.red
                                : c.state == ConnState.connected &&
                                      c.variant != null
                                ? Palette.green
                                : Palette.muted,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            c.offline
                                ? tr('Kein Gerät verbunden')
                                : c.hostReconnecting
                                ? tr('Verbinde neu …')
                                : c.viaHost
                                ? trf('Verbunden über Host{rate}', {
                                    'rate': connectionRate,
                                  })
                                : trf('Verbunden über USB{rate}', {
                                    'rate': connectionRate,
                                  }),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ts(
                              13,
                              weight: 500,
                              color: c.offline ? Palette.red : Palette.muted,
                              narrow: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                actions: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (c.viaHost)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: GestureDetector(
                          key: const ValueKey('host-badge-menu'),
                          onLongPress: () => showHostMenu(context, c),
                          onTap: () => ScaffoldMessenger.of(context)
                            ..hideCurrentSnackBar()
                            ..showSnackBar(
                              SnackBar(
                                content: Text(
                                  tr('Gedrückt halten öffnet das Host-Menü.'),
                                ),
                                duration: const Duration(seconds: 2),
                              ),
                            ),
                          child: Opacity(
                            opacity: c.hostReconnecting ? 0.5 : 1,
                            child: const HostBadge(),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: SizedBox(
                        height: 44,
                        child: FilterChip(
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          key: const ValueKey('easy-switch'),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          labelPadding: EdgeInsets.zero,
                          label: Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                tr('Eigene\nAnsicht'),
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                style: const TextStyle(height: 1.0),
                              ),
                            ],
                          ),
                          selected: easy,
                          showCheckmark: false,
                          selectedColor: Palette.amber,
                          labelStyle: ts(
                            11,
                            weight: 600,
                            color: easy ? Palette.bg : Palette.text,
                          ),
                          onSelected: (on) {
                            c.stopAllVolumeRamps();
                            settings.setEasyMode(on);
                          },
                        ),
                      ),
                    ),
                    _RoundIcon(
                      icon: Icons.settings_outlined,
                      tooltip: tr('App'),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              AppSettingsPage(ctrl: c, np: widget.np),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    c.offline
                        ? Material(
                            color: Palette.surf,
                            shape: const StadiumBorder(),
                            child: InkWell(
                              customBorder: const StadiumBorder(),
                              onTap: c.leaveOffline,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 12,
                                ),
                                child: Text(
                                  tr('Beenden'),
                                  style: ts(13, weight: 600),
                                ),
                              ),
                            ),
                          )
                        : _RoundIcon(
                            icon: Icons.refresh,
                            tooltip: tr('Neu einlesen'),
                            onTap: c.requestAll,
                          ),
                  ],
                ),
              ),
            ),
            if (idx == outputsIndex && !landscape) ...outputHeader,
            Expanded(
              child: IgnorePointer(
                ignoring: c.hostReconnecting,
                child: Opacity(
                  opacity: c.hostReconnecting ? 0.65 : 1,
                  child: landscape && idx == outputsIndex
                      ? Row(
                          key: const ValueKey('tablet-output-columns'),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: Column(
                                children: [
                                  if (easy) ...outputHeader,
                                  Expanded(child: tabs[idx].$3),
                                ],
                              ),
                            ),
                            const VerticalDivider(width: 1),
                            Expanded(
                              child: _extraContent(
                                c,
                                headerOutput,
                                availableOutputs,
                              ),
                            ),
                          ],
                        )
                      : tabs[idx].$3,
                ),
              ),
            ),
          ],
        );
        return Scaffold(
          body: SafeArea(
            bottom: landscape,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (landscape)
                  SizedBox(
                    width: tabletNavigationRailWidth,
                    // Kategorien gleichmäßig über die Höhe verteilen statt
                    // eng untereinander.
                    child: LayoutBuilder(
                      builder: (context, box) {
                        // Größere Beschriftungen brauchen ihren Anteil an der Höhe;
                        // die Zwischenräume werden entsprechend kleiner.
                        final itemHeight =
                            72.0 * MediaQuery.textScalerOf(context).scale(1);
                        final gap =
                            ((box.maxHeight - tabs.length * itemHeight) /
                                    (tabs.length * 2))
                                .clamp(4.0, 40.0);
                        return NavigationRail(
                          scrollable: true,
                          minWidth: tabletNavigationRailWidth,
                          selectedIndex: idx,
                          groupAlignment: 0,
                          labelType: NavigationRailLabelType.all,
                          onDestinationSelected: (i) =>
                              setState(() => _tab = i),
                          destinations: [
                            for (final t in tabs)
                              NavigationRailDestination(
                                padding: EdgeInsets.symmetric(vertical: gap),
                                icon: Icon(t.$2),
                                label: Text(t.$1),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                Expanded(
                  child: !landscape
                      ? TabletContent(child: mainContent)
                      : mainContent,
                ),
              ],
            ),
          ),
          bottomNavigationBar: landscape
              ? null
              : NavigationBar(
                  selectedIndex: idx,
                  onDestinationSelected: (i) => setState(() => _tab = i),
                  destinations: [
                    for (final t in tabs)
                      NavigationDestination(icon: Icon(t.$2), label: t.$1),
                  ],
                ),
        );
      },
    );
  }

  Widget _extraContent(
    Adi2Controller ctrl,
    int output,
    List<OutputInfo> outputs,
  ) {
    final selected = AppSettings.instance.tabletExtraContent;
    final title = outputs.firstWhere((o) => o.address == output).name;
    return Column(
      key: const ValueKey('tablet-extra-area'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('Zusatzbereich'),
                style: ts(14, weight: 600, color: Palette.muted),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (final item in [
                    (TabletExtraContent.eq, tr('EQ'), Icons.tune),
                    (
                      TabletExtraContent.analyzer,
                      tr('Analyzer'),
                      Icons.graphic_eq,
                    ),
                    (
                      TabletExtraContent.status,
                      tr('Status'),
                      Icons.info_outline,
                    ),
                    (TabletExtraContent.player, tr('Player'), Icons.music_note),
                  ])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Semantics(
                          selected: selected == item.$1,
                          child: OutlinedButton(
                            key: ValueKey('tablet-extra-${item.$1.name}'),
                            style: OutlinedButton.styleFrom(
                              backgroundColor: selected == item.$1
                                  ? Palette.surf2
                                  : Palette.bg,
                              side: BorderSide(
                                color: selected == item.$1
                                    ? Palette.amber
                                    : Palette.line,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                                vertical: 8,
                              ),
                            ),
                            onPressed: () => AppSettings.instance
                                .setTabletExtraContent(item.$1),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(item.$3, size: 20),
                                const SizedBox(height: 4),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(item.$2),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: switch (selected) {
            TabletExtraContent.eq => EqPage(
              key: ValueKey(output),
              ctrl: ctrl,
              channelAddr: output,
              title: title,
              embedded: true,
            ),
            TabletExtraContent.analyzer => AnalyzerPanel(
              controller: _analyzer,
              deviceController: ctrl,
              expanded: true,
              np: widget.np,
            ),
            TabletExtraContent.status => StatusPage(ctrl: ctrl),
            TabletExtraContent.player => ListView(
              children: [
                PlayerBar(
                  deviceController: ctrl,
                  np: widget.np,
                  fallback: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      tr('Kein Player aktiv'),
                      style: ts(16, color: Palette.muted),
                    ),
                  ),
                ),
              ],
            ),
          },
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class ConnectPage extends StatelessWidget {
  const ConnectPage({super.key, required this.ctrl, this.np});
  final Adi2Controller ctrl;
  final NowPlaying? np;

  @override
  Widget build(BuildContext context) {
    final c = ctrl;
    final families = <DeviceFamily, List<SupportedModel>>{};
    for (final model in supportedModels) {
      families.putIfAbsent(model.family, () => []).add(model);
    }
    final msg = switch (c.state) {
      ConnState.idle => tr('Nicht verbunden'),
      ConnState.searching => tr('Suche ADI-2 …'),
      ConnState.connecting => trf('Verbinde mit {name} …', {
        'name':
            c.device?.name ??
            (c.pendingHostName == null
                ? 'ADI-2'
                : trf('Host {name}', {'name': c.pendingHostName!})),
      }),
      ConnState.waitingForDevice => trf('Warte auf Antwort von {name} …', {
        'name': c.device?.name,
      }),
      ConnState.connected => tr('Verbunden'),
      ConnState.reconnecting => tr('Verbinde neu …'),
      ConnState.offline => tr('Offline'),
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Remote for ADI-2')),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AppSettingsPage(ctrl: c, np: np),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: c.refreshDevices,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            children: [
              Panel(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Kein ADI-2 verbunden'),
                      style: ts(20, weight: 600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      tr(
                        'Per USB verbinden und MIDI Control am Gerät auf ON stellen.',
                      ),
                      style: ts(14, color: Palette.muted, height: 1.4),
                    ),
                    const SizedBox(height: 6),
                    Text(msg, style: ts(13, color: Palette.muted)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(0, 40),
                            iconSize: 18,
                            textStyle: ts(13, weight: 600),
                          ),
                          onPressed: c.refreshDevices,
                          icon: const Icon(Icons.refresh),
                          label: Text(tr('Erneut suchen')),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(0, 40),
                            iconSize: 18,
                            textStyle: ts(13, weight: 600),
                          ),
                          onPressed: () => showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            useSafeArea: true,
                            showDragHandle: true,
                            builder: (_) => const _ConnectionHelp(),
                          ),
                          icon: const Icon(Icons.info_outline),
                          label: Text(tr('Verbindungshilfe')),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (c.hostAvailable && c.hostPaused)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: FilledButton.icon(
                    key: const ValueKey('host-resume'),
                    onPressed: () => unawaited(c.resumeHost()),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(tr('Host-Verbindung fortsetzen')),
                  ),
                ),
              if (c.hostAvailable)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => HostConnectPage(ctrl: c),
                      ),
                    ),
                    icon: const Icon(Icons.wifi),
                    label: Text(tr('Über Host verbinden')),
                  ),
                ),
              if (c.state == ConnState.connecting ||
                  c.state == ConnState.waitingForDevice)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (c.noMidiAnswer) ...[
                const SizedBox(height: 16),
                _MidiHint(
                  isDac: c.device?.name.toLowerCase().contains('dac') ?? false,
                ),
              ],
              if (c.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    c.error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Panel(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('Offline einstellen'), style: ts(18, weight: 600)),
                    const SizedBox(height: 6),
                    Text(
                      tr(
                        'Modell wählen und Einstellungen ohne angeschlossenes Gerät vorbereiten.',
                      ),
                      style: ts(14, color: Palette.muted, height: 1.4),
                    ),
                    const SizedBox(height: 10),
                    for (final models in families.values)
                      for (var i = 0; i < models.length; i += 2)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              for (var column = 0; column < 2; column++) ...[
                                if (column > 0) const SizedBox(width: 8),
                                Expanded(
                                  child: i + column < models.length
                                      ? _OfflineModelTile(
                                          model: models[i + column],
                                          ctrl: c,
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ],
                            ],
                          ),
                        ),
                    const SizedBox(height: 6),
                    Text(
                      tr(
                        'Offline festgelegte Einstellungen kannst du später mit angeschlossenem Gerät übertragen: Setups → Weiteres → Offline-Einstellungen übertragen.',
                      ),
                      style: ts(13, color: Palette.muted, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tr('MIDI-Geräte'),
                style: ts(14, weight: 600, color: Palette.muted),
              ),
              const SizedBox(height: 6),
              Panel(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Material(
                  color: Colors.transparent,
                  child: Column(
                    children: [
                      if (c.devices.isEmpty)
                        ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          title: Text(tr('Keine gefunden')),
                        ),
                      for (final d in c.devices)
                        ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          leading: const Icon(Icons.piano),
                          title: Text(d.name),
                          subtitle: Text(d.type.name),
                          trailing: c.device?.id == d.id
                              ? const Icon(Icons.link)
                              : const Icon(Icons.chevron_right),
                          onTap: () => c.connect(d),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfflineModelTile extends StatelessWidget {
  const _OfflineModelTile({required this.model, required this.ctrl});

  final SupportedModel model;
  final Adi2Controller ctrl;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      key: ValueKey('offline-${model.name}'),
      style: OutlinedButton.styleFrom(
        backgroundColor: Palette.bg,
        foregroundColor: Palette.text,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        side: const BorderSide(color: Palette.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: () => ctrl.startOffline(model.variant, label: model.name),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          tr(model.name),
          maxLines: 1,
          textAlign: TextAlign.center,
          style: ts(14, weight: 500),
        ),
      ),
    );
  }
}

class _ConnectionHelp extends StatelessWidget {
  const _ConnectionHelp();

  @override
  Widget build(BuildContext context) {
    final steps = [
      (
        tr('ADI-2 mit einem USB-Kabel direkt ans Handy anschließen.'),
        tr(
          'Das Handy steuert den ADI-2 dabei wie ein Computer (bei Android heißt das „OTG“). Passt das Kabel nicht direkt, hilft ein kleiner USB-C-Adapter (OTG-Adapter). iPhone mit Lightning: Lightning-auf-USB-Kamera-Adapter. Findet die App nichts: Kabel neu einstecken und prüfen, ob OTG in den Handy-Einstellungen eingeschaltet ist.',
        ),
      ),
      (
        tr('MIDI Control am Gerät auf ON stellen.'),
        tr(
          'DAC: SETUP → Options → Remap Keys / Diag → MIDI Control → ON.\nPro / ADI-2/4: SETUP → Options → Device Mode / DSD → MIDI Control → ON.',
        ),
      ),
      (tr('App-Berechtigung / USB-Dialog bestätigen.'), null),
      (tr('„Erneut suchen“ antippen.'), null),
    ];
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('Verbindungshilfe'), style: ts(20, weight: 600)),
            const SizedBox(height: 12),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text(
                        '${i + 1}.',
                        style: ts(14, weight: 600, color: Palette.amber),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(steps[i].$1, style: ts(14, weight: 500)),
                          if (steps[i].$2 != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              steps[i].$2!,
                              style: ts(12, color: Palette.muted, height: 1.4),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr('Schließen')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class InputPage extends StatelessWidget {
  const InputPage({super.key, required this.ctrl});
  final Adi2Controller ctrl;

  @override
  Widget build(BuildContext context) {
    final v = ctrl.variant!;
    return AdaptivePageList(
      children: [
        ListTile(
          title: Text(tr('Equalizer (Eingang)')),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                ctrl.valueOr(1, 2, 0) != 0 ? tr('an') : tr('aus'),
                style: ts(15, weight: 500, color: Palette.amber),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  EqPage(ctrl: ctrl, channelAddr: 0, title: tr('Eingang')),
            ),
          ),
        ),
        const Divider(),
        for (final d in inputParams(v))
          ParamTile(
            ctrl: ctrl,
            address: Adi2Addr.input,
            def: d,
            formatOverride: (v == Adi2Variant.pro4ex && d.index == 1)
                ? (raw) => tr(exInputRef[(raw + 6).clamp(0, 10)])
                : null,
          ),
      ],
    );
  }
}

class DevicePage extends StatefulWidget {
  const DevicePage({super.key, required this.ctrl});
  final Adi2Controller ctrl;

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  Adi2Controller get ctrl => widget.ctrl;

  @override
  void initState() {
    super.initState();
    ctrl.refreshCcMode();
  }

  @override
  void didUpdateWidget(covariant DevicePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ctrl != ctrl) ctrl.refreshCcMode();
  }

  @override
  Widget build(BuildContext context) {
    final v = ctrl.variant!;
    return AdaptivePageList(
      children: [
        ListTile(
          leading: const Icon(Icons.save_outlined),
          title: Text(tr('Backup sichern / laden')),
          subtitle: Text(tr('Alle Einstellungen und EQ-Presets')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => BackupPage(ctrl: ctrl)),
          ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: LoopbackSection(ctrl: ctrl),
        ),
        for (final d in deviceParams(v, ess: ctrl.hasEss))
          if (d.index != DevIdx.sampleRate &&
              d.index != DevIdx.loadVolumeWithSetup)
            ParamTile(ctrl: ctrl, address: Adi2Addr.device, def: d),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: DeviceSetupSection(ctrl: ctrl),
        ),
      ],
    );
  }
}

class StatusPage extends StatelessWidget {
  const StatusPage({super.key, required this.ctrl});
  final Adi2Controller ctrl;

  @override
  Widget build(BuildContext context) {
    final s = ctrl.status;
    if (s == null) return Center(child: Text(tr('Warte auf Status …')));
    final v = ctrl.variant!;
    final sr = deviceParams(v)
        .firstWhere((d) => d.index == DevIdx.sampleRate)
        .format(ctrl.valueOr(Adi2Addr.device, DevIdx.sampleRate, 1));
    final mode = ctrl.value(Adi2Addr.device, 6);
    final warnings = <String>[
      if (s.overCurrentPhones1) tr('Überstrom Phones 1'),
      if (s.overCurrentPhones2) tr('Überstrom Phones 2'),
      if (s.dcErrorPhones1) tr('DC-Fehler Phones 1'),
      if (s.dcErrorPhones2) tr('DC-Fehler Phones 2'),
      if (s.dcDetectLine) tr('DC erkannt Line'),
      if (s.dcDetectPhones) tr('DC erkannt Phones'),
      if (s.powerFail) tr('Stromversorgung'),
    ];
    return AdaptivePageList(
      splitAt: warnings.length + 2,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        for (final w in warnings)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Panel(
              child: ListTile(
                leading: const Icon(Icons.warning, color: Palette.red),
                title: Text(w, style: ts(15, weight: 600, color: Palette.red)),
              ),
            ),
          ),
        _StatusSection(
          title: tr('Gerät'),
          rows: [
            (
              ctrl.deviceLabel,
              RegExp(r'\((\d+)\)').firstMatch(ctrl.device?.name ?? '') == null
                  ? ''
                  : trf('SN {sn}', {
                      'sn': RegExp(r'\((\d+)\)')
                          .firstMatch(ctrl.device!.name)!
                          .group(1),
                    }),
            ),
            if (ctrl.adConverter case final converter?)
              (tr('AD-Wandler'), converter),
            if (ctrl.daConverter case final converter?)
              (tr('DA-Wandler'), converter),
            (
              tr('Basic Mode'),
              // DAC: immer "DAC". Pro/2-4: aktueller Modus aus Statusbyte 15
              // (Reihenfolge wie Device-Parameter 6).
              v.isDac
                  ? 'DAC'
                  : (const [
                          'Auto',
                          'AD/DA',
                          'USB',
                          'Preamp',
                          'Dig Thru',
                          'DAC',
                        ].elementAtOrNull(s.deviceMode) ??
                        (mode == null
                            ? '–'
                            : deviceParams(v)
                                  .firstWhere((d) => d.index == 6)
                                  .format(mode))),
            ),
            (tr('Clock'), tr(s.clockSourceName)),
            (tr('Sample Rate'), sr),
          ],
        ),
        _DigitalInputs(ctrl: ctrl, sr: sr),
        ListenableBuilder(
          listenable: AppSettings.instance,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr('Output State'),
                    style: ts(14, weight: 600, color: Palette.muted),
                  ),
                ),
                for (final u in [false, true])
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: ChoiceChip(
                      label: Text(u ? 'dBu' : 'dBFS'),
                      selected: AppSettings.instance.statusInDbu == u,
                      onSelected: (_) => AppSettings.instance.setStatusInDbu(u),
                      selectedColor: Palette.surf2,
                      backgroundColor: Palette.bg,
                      side: BorderSide(
                        color: AppSettings.instance.statusInDbu == u
                            ? Palette.amber
                            : Palette.line,
                      ),
                      labelStyle: ts(13, weight: 600),
                      showCheckmark: false,
                    ),
                  ),
              ],
            ),
          ),
        ),
        for (final o in outputsFor(v))
          ListenableBuilder(
            listenable: AppSettings.instance,
            builder: (context, _) => _OutputStatus(ctrl: ctrl, out: o),
          ),
      ],
    );
  }
}

class _StatusSection extends StatelessWidget {
  const _StatusSection({
    required this.title,
    required this.rows,
    this.chips,
    this.footer,
  });
  final String title;
  final List<(String, String)> rows;
  final List<Widget>? chips;
  final Widget? footer;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Panel(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: ts(16, weight: 600))),
              ...?chips,
            ],
          ),
          const SizedBox(height: 6),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Text(r.$1, style: ts(14, color: Palette.muted)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          r.$2,
                          maxLines: 1,
                          style: ts(14, weight: 500),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (footer != null) ...[const SizedBox(height: 8), footer!],
        ],
      ),
    ),
  );
}

/// Zustand eines Ausgangs wie in der State Overview des Originals:
/// Quelle, Ref-Level, Lautstärke in dB und dBu, aktive Effekte.
class _OutputStatus extends StatelessWidget {
  const _OutputStatus({required this.ctrl, required this.out});
  final Adi2Controller ctrl;
  final OutputInfo out;

  @override
  Widget build(BuildContext context) {
    final v = ctrl.variant!;
    final a = out.address;
    final defs = outputParams(v, phones: out.phones, ess: ctrl.hasEss);
    String fmt(int idx) {
      final raw = ctrl.value(a, idx);
      if (raw == null) return '–';
      return defs.firstWhere((d) => d.index == idx).format(raw);
    }

    final vol = ctrl.value(a, OutIdx.volume);
    final ref = ctrl.currentRefDbu(a);
    final muted = ctrl.valueOr(a, OutIdx.mute, 0) != 0 || ctrl.autoMuted(a);
    final dsp = <String>[
      if (ctrl.valueOr(a + 1, 2, 0) != 0) tr('EQ'),
      if (ctrl.valueOr(a + 1, 20, 0) != 0 &&
          (ctrl.valueOr(a + 1, 21, 0) != 0 || ctrl.valueOr(a + 1, 24, 0) != 0))
        tr('Bass/Treble'),
      if (ctrl.valueOr(a, OutIdx.loudness, 0) != 0) tr('Loudness'),
      if (ctrl.valueOr(a, OutIdx.crossfeed, 0) != 0)
        trf('Crossfeed {n}', {'n': ctrl.valueOr(a, OutIdx.crossfeed, 0)}),
    ];
    String vol2(int raw) =>
        '${raw < 0 ? '−' : (raw > 0 ? '+' : '')}${(raw.abs() / 10).toStringAsFixed(1).replaceAll('.', ',')}';
    Widget chip(String t, Color col) => Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: col),
      ),
      child: Text(t, style: ts(12, weight: 600, color: col)),
    );
    return _StatusSection(
      title: out.name,
      footer: dsp.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('DSP-Funktionen'), style: ts(14, color: Palette.muted)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final d in dsp)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Palette.surf2,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Palette.amber),
                        ),
                        child: Text(d, style: ts(13, weight: 600)),
                      ),
                  ],
                ),
              ],
            ),
      chips: [
        if (muted) chip(tr('Mute'), Palette.red),
        if (ctrl.valueOr(a, OutIdx.lockVolume, 0) != 0)
          chip(tr('Lock'), Palette.amber),
        if (ctrl.valueOr(a, OutIdx.dim, 0) != 0) chip(tr('Dim'), Palette.amber),
      ],
      rows: [
        if (ctrl.value(a, OutIdx.source) != null)
          (tr('Quelle'), fmt(OutIdx.source)),
        if (v.isDac && a == Adi2Addr.line && ref != null)
          (tr('Ref Level'), 'RCA ${_dbuS(ref)}   XLR ${_dbuS(ref + 6)}')
        else if (refTable(v, a).length < 2 && ref != null)
          (
            tr('Ref Level'),
            trf('{wert} dBu (fest)', {'wert': ref.toStringAsFixed(0)}),
          )
        else if (ctrl.value(a, OutIdx.refLevel) != null)
          (tr('Ref Level'), fmt(OutIdx.refLevel)),
        if (vol != null)
          (
            tr('Lautstärke'),
            AppSettings.instance.statusInDbu && ref != null
                ? (v.isDac && a == Adi2Addr.line
                      ? 'RCA ${vol2((vol + ref * 10).round())}   '
                            'XLR ${vol2((vol + ref * 10 + 60).round())} dBu'
                      : '${vol2((vol + ref * 10).round())} dBu')
                : '${vol2(vol)} dBFS',
          ),
        if (dsp.isEmpty) (tr('DSP-Funktionen'), '–'),
      ],
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, this.onTap, this.tooltip});
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final w = Container(
      width: 44,
      height: 44,
      decoration: const BoxDecoration(
        color: Palette.surf,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 22, color: Palette.text),
    );
    if (onTap == null) return w;
    return Tooltip(
      message: tooltip ?? '',
      child: GestureDetector(onTap: onTap, child: w),
    );
  }
}

/// Hinweis, wenn der ADI-2 per USB da ist, aber nicht über MIDI antwortet.
class _MidiHint extends StatelessWidget {
  const _MidiHint({required this.isDac});
  final bool isDac;

  @override
  Widget build(BuildContext context) {
    final path = isDac
        ? 'SETUP → Options → Remap Keys / Diag → MIDI Control → ON'
        : 'SETUP → Options → Device Mode / DSD → MIDI Control → ON';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          Palette.amber.withValues(alpha: 0.10),
          Palette.surf,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Palette.amber),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Palette.amber),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr('Der ADI-2 antwortet nicht über MIDI'),
                  style: ts(16, weight: 600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            tr(
              'Das Gerät ist per USB verbunden, aber die Fernsteuerung ist ausgeschaltet. Am ADI-2 einstellen:',
            ),
            style: ts(14, color: Palette.muted, height: 1.4),
          ),
          const SizedBox(height: 8),
          Text(path, style: ts(15, weight: 600, color: Palette.amber)),
          const SizedBox(height: 8),
          Text(
            tr(
              'Danach verbindet sich die App automatisch. Hilft das nicht: USB-Kabel kurz ab- und wieder anstecken.',
            ),
            style: ts(13, color: Palette.muted, height: 1.4),
          ),
        ],
      ),
    );
  }
}

String _dbuS(double v) =>
    '${v > 0 ? '+' : (v < 0 ? '−' : '')}${v.abs().toStringAsFixed(0)} dBu';

/// Digital Input State wie in der State Overview des Geräts:
/// Eingang | Sync | SR | Zustand | Bit.
class _DigitalInputs extends StatelessWidget {
  const _DigitalInputs({required this.ctrl, required this.sr});
  final Adi2Controller ctrl;
  final String sr;

  @override
  Widget build(BuildContext context) {
    final s = ctrl.status!;
    final v = ctrl.variant!;
    String sync(bool lock, bool syn) => syn ? 'Sync' : (lock ? 'Lock' : '– –');
    final rows = <List<String>>[
      if (!v.isDac)
        [
          'AES',
          sync(s.aesLock, s.aesSync),
          s.aesLock ? s.aesRate : '–',
          !s.aesLock
              ? '–'
              : (s.dsdAes ? 'DSD' : (s.professionalAes ? 'pro' : 'cons')),
          !s.aesLock ? '–' : (s.bits24Aes ? '24' : '16'),
        ],
      // Das Gerät meldet nur den gewählten SPDIF-Eingang (Bit "SPDIF source");
      // der andere erscheint ohne Daten.
      for (final optical in [true, false])
        s.spdifOptical == optical
            ? [
                optical ? 'SPDIF optical' : 'SPDIF coax',
                sync(s.spdifLock, s.spdifSync),
                s.spdifLock ? s.spdifRate : '–',
                !s.spdifLock
                    ? '–'
                    : (s.dsdSpdif
                          ? 'DSD'
                          : (s.professionalSpdif ? 'pro' : 'cons')),
                !s.spdifLock ? '–' : (s.bits24Spdif ? '24' : '16'),
              ]
            : [optical ? 'SPDIF optical' : 'SPDIF coax', '– –', '–', '–', '–'],
      ['USB', ctrl.offline ? '–' : 'conn', sr, s.dsdUsb ? 'DSD' : '2/2', ''],
    ];
    final warn = <String>[
      if (s.nonAudioSpdif) tr('SPDIF: kein Audiosignal (Non-Audio)'),
      if (s.emphasisSpdif) tr('SPDIF: Emphasis'),
      if (!v.isDac && s.nonAudioAes) tr('AES: kein Audiosignal (Non-Audio)'),
      if (!v.isDac && s.emphasisAes) tr('AES: Emphasis'),
    ];
    Widget cell(String t, {bool head = false, TextAlign al = TextAlign.left}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            t,
            textAlign: al,
            style: head
                ? ts(12, weight: 600, color: Palette.muted, narrow: true)
                : ts(14, weight: 500),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Panel(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('Digitale Eingänge'), style: ts(16, weight: 600)),
            const SizedBox(height: 6),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(1.9),
                1: FlexColumnWidth(1.1),
                2: FlexColumnWidth(1.1),
                3: FlexColumnWidth(1),
                4: FlexColumnWidth(0.6),
              },
              children: [
                TableRow(
                  children: [
                    cell(tr('Eingang'), head: true),
                    cell('Sync', head: true),
                    cell('SR', head: true),
                    cell(tr('Zustand'), head: true),
                    cell('Bit', head: true),
                  ],
                ),
                for (final r in rows)
                  TableRow(children: [for (final c in r) cell(c)]),
              ],
            ),
            for (final w in warn)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(w, style: ts(13, color: Palette.amber)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Kompakte Anzeige der Digitaleingänge an Stelle der Player-Leiste,
/// aufgebaut wie die Tabelle der Statusseite.
class _DigitalMini extends StatelessWidget {
  const _DigitalMini({super.key, required this.ctrl, required this.onTap});
  final Adi2Controller ctrl;
  final VoidCallback onTap;

  /// Eine Zeile: Eingang | Sync | SR | Zustand | Bit.
  Widget _row(List<String> r, {bool head = false, bool active = false}) {
    Text t(String x, {TextAlign al = TextAlign.left}) => Text(
      x,
      textAlign: al,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: head
          ? ts(11, weight: 600, color: Palette.muted, narrow: true)
          : ts(
              13,
              weight: active ? 600 : 500,
              color: active ? Palette.text : Palette.muted,
              narrow: true,
            ),
    );
    return Row(
      children: [
        Expanded(flex: 4, child: t(r[0])),
        Expanded(flex: 3, child: t(r[1])),
        Expanded(flex: 3, child: t(r[2])),
        Expanded(flex: 3, child: t(r[3])),
        Expanded(flex: 2, child: t(r[4])),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ctrl.status;
    final v = ctrl.variant;
    String sync(bool lock, bool syn) => syn ? 'Sync' : (lock ? 'Lock' : '– –');
    String state(bool dsd, bool pro) => dsd ? 'DSD' : (pro ? 'pro' : 'cons');
    final srIdx = ctrl.value(Adi2Addr.device, DevIdx.sampleRate);
    final usbSr = v == null || srIdx == null
        ? '–'
        : deviceParams(v)
              .firstWhere((d) => d.index == DevIdx.sampleRate)
              .format(srIdx);
    final rows = <List<String>>[
      if (s != null && v != null) ...[
        if (!v.isDac)
          [
            'AES',
            sync(s.aesLock, s.aesSync),
            s.aesLock ? s.aesRate : '–',
            s.aesLock ? state(s.dsdAes, s.professionalAes) : '–',
            s.aesLock ? (s.bits24Aes ? '24' : '16') : '–',
          ],
        for (final optical in [true, false])
          if (s.spdifOptical == optical)
            [
              optical ? 'SPDIF optical' : 'SPDIF coax',
              sync(s.spdifLock, s.spdifSync),
              s.spdifLock ? s.spdifRate : '–',
              s.spdifLock ? state(s.dsdSpdif, s.professionalSpdif) : '–',
              s.spdifLock ? (s.bits24Spdif ? '24' : '16') : '–',
            ]
          else
            [optical ? 'SPDIF optical' : 'SPDIF coax', '– –', '–', '–', '–'],
        [
          'USB',
          ctrl.offline ? '–' : 'conn',
          usbSr,
          s.dsdUsb ? 'DSD' : '2/2',
          '',
        ],
      ],
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Material(
        color: Palette.surf,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: SizedBox(
            height: isTablet(context) ? null : headerSlotHeight(context) - 8,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                        tr('Kein Gerät verbunden'),
                        style: ts(14, color: Palette.muted),
                      ),
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _row([
                          tr('Eingang'),
                          'Sync',
                          'SR',
                          tr('Zustand'),
                          'Bit',
                        ], head: true),
                        for (final r in rows) ...[
                          if (isTablet(context)) const SizedBox(height: 4),
                          _row(r, active: r[1] != '– –' && r[1] != '–'),
                        ],
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
