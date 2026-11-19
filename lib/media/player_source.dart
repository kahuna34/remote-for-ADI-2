import 'package:flutter/material.dart';

import '../device/adi2_controller.dart';
import '../host/host_client.dart';
import 'now_playing.dart';

bool _preferLocal(NowPlaying? np, HostClient? host) =>
    np?.supported == true &&
    np?.access == true &&
    np?.info?.hasContent == true &&
    np?.info?.playing == true &&
    host?.playerInfo?.playing != true;

bool _hostReady(HostClient? host) =>
    host?.playerAvailable == true && (host!.connected || host.reconnecting);

/// Also used by HomePage to decide whether an otherwise empty header exists.
bool playerIsVisible(NowPlaying? np, Adi2Controller? device) {
  final host = device?.viaHost == true ? device!.host : null;
  return _hostReady(host) ||
      (host != null && !host.playerAvailable && !_preferLocal(np, host)) ||
      np?.supported == true &&
          ((np?.access == false && np?.promptDismissed == false) ||
              np?.access == true && np?.info?.hasContent == true);
}

/// One visible consumer of the shared host subscription, or the local player.
class PlayerSource extends ChangeNotifier {
  PlayerSource({this.np, this.deviceController}) {
    np?.addListener(_changed);
    deviceController?.addListener(_changed);
    deviceController?.host.addListener(_changed);
  }

  final NowPlaying? np;
  final Adi2Controller? deviceController;
  bool _active = false;
  HostClient? _subscribed;
  HostClient? get host =>
      deviceController?.viaHost == true ? deviceController!.host : null;
  bool get usesHost => _hostReady(host) && !_preferLocal(np, host);
  bool get controlsEnabled =>
      !usesHost || (host!.connected && !host!.reconnecting);
  bool get needsHostUpdate =>
      host != null && !host!.playerAvailable && !_preferLocal(np, host);
  NowPlayingInfo? get info => usesHost ? host!.playerInfo : np?.info;
  bool get available =>
      usesHost || (np?.supported == true && np?.access == true);
  bool get showPrompt =>
      !usesHost &&
      np?.supported == true &&
      np?.access == false &&
      np?.promptDismissed == false;
  bool get visible => playerIsVisible(np, deviceController);

  void setActive(bool active) {
    _active = active;
    _syncSubscription();
  }

  void _syncSubscription() {
    // Keep observing the host while local music wins, so a host starting
    // playback can take precedence without changing routes.
    final next = _active && _hostReady(host) ? host : null;
    if (_subscribed != next) {
      _subscribed?.unsubscribePlayer(this);
      _subscribed = next;
    }
    // Idempotent; also restores the owner after a session reconnect.
    _subscribed?.subscribePlayer(this);
  }

  void _changed() {
    _syncSubscription();
    notifyListeners();
  }

  Future<void> command(String command) async {
    if (!controlsEnabled) return;
    if (usesHost) {
      host!.playerCommand(command);
    } else {
      await np?.command(command);
    }
  }

  Future<void> openPlayer() async {
    if (!usesHost) await np?.openPlayer();
  }

  @override
  void dispose() {
    np?.removeListener(_changed);
    deviceController?.removeListener(_changed);
    deviceController?.host.removeListener(_changed);
    _subscribed?.unsubscribePlayer(this);
    super.dispose();
  }
}

/// Holds an owner only while this surface is on the current, visible route.
class PlayerSourceView extends StatefulWidget {
  const PlayerSourceView({
    super.key,
    this.np,
    this.deviceController,
    this.active = true,
    required this.builder,
  });
  final NowPlaying? np;
  final Adi2Controller? deviceController;
  final bool active;
  final Widget Function(BuildContext, PlayerSource) builder;
  @override
  State<PlayerSourceView> createState() => _PlayerSourceViewState();
}

class _PlayerSourceViewState extends State<PlayerSourceView>
    with WidgetsBindingObserver {
  late PlayerSource source;
  bool foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _create();
  }

  void _create() {
    source = PlayerSource(
      np: widget.np,
      deviceController: widget.deviceController,
    );
  }

  @override
  void didUpdateWidget(PlayerSourceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.np != widget.np ||
        oldWidget.deviceController != widget.deviceController) {
      source.dispose();
      _create();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) source.setActive(false);
    setState(() => foreground = state == AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) {
    source.setActive(
      widget.active &&
          foreground &&
          TickerMode.valuesOf(context).enabled &&
          ModalRoute.isCurrentOf(context) != false,
    );
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) => IgnorePointer(
        ignoring: !source.controlsEnabled,
        child: Opacity(
          opacity: source.controlsEnabled ? 1 : 0.65,
          child: widget.builder(context, source),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    source.dispose();
    super.dispose();
  }
}
