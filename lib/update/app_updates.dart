import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_info.dart';
import '../store_build.dart';
import '../app_settings.dart';
import 'update_check.dart';

class AppUpdates extends ChangeNotifier {
  AppUpdates._();

  @visibleForTesting
  AppUpdates.forTesting();
  static final instance = AppUpdates._();
  UpdateCheck? checker;
  UpdateResult? _visibleResult;
  UpdateResult? get result => _visibleResult;
  Future<void>? _initializing;
  Future<UpdateCheck>? _hostChecker;
  Future<void> Function(bool)? _hostEnabledChanged;

  /// A combined desktop host supplies its existing version/asset selection and
  /// persistence. The surface must not start the standalone app's updater.
  void useHostChecker(
    Future<UpdateCheck> checker, {
    required Future<void> Function(bool) onEnabledChanged,
  }) {
    _hostChecker = checker;
    _hostEnabledChanged = onEnabledChanged;
  }

  bool get automaticEnabled => _hostChecker == null
      ? AppSettings.instance.updateCheck
      : checker?.enabled ?? false;

  Future<void> setAutomaticEnabled(bool enabled) async {
    if (_hostChecker != null) {
      if (checker == null) await initialize();
      checker!.enabled = enabled;
      await _hostEnabledChanged!(enabled);
      notifyListeners();
      if (enabled) await checker!.check();
    } else {
      await AppSettings.instance.setUpdateCheck(enabled);
      settingsChanged();
    }
  }

  void hostResultChanged() {
    final value = checker?.result;
    if (value?.status != UpdateStatus.error ||
        checker?.resultWasAutomatic != true) {
      _visibleResult = value;
    }
    notifyListeners();
  }

  Future<void> initialize() async {
    if (isPlayStoreBuild) return;
    await (_initializing ??= _initialize());
  }

  Future<void> _initialize() async {
    final settings = AppSettings.instance;
    await settings.load();
    if (isPlayStoreBuild) return;
    if (_hostChecker != null) {
      checker = await _hostChecker;
      hostResultChanged();
      return;
    }
    checker = UpdateCheck(
      installedVersion: appVersion,
      platform: Platform.isAndroid
          ? UpdatePlatform.android
          : Platform.isLinux
          ? UpdatePlatform.linux
          : UpdatePlatform.other,
      enabled: settings.updateCheck,
      lastCheck: settings.lastUpdateCheck,
      skippedVersion: settings.skippedUpdateVersion,
      onState: () => settings.saveUpdateState(
        checker!.lastCheck,
        checker!.skippedVersion,
        version: checker!.result?.status == UpdateStatus.error
            ? settings.availableUpdateVersion
            : checker!.result?.version,
        url: checker!.result?.status == UpdateStatus.error
            ? settings.availableUpdateUrl
            : checker!.result?.url?.toString(),
      ),
      onResult: (value) {
        if (value.status != UpdateStatus.error ||
            !checker!.resultWasAutomatic) {
          _visibleResult = value;
          notifyListeners();
        }
      },
    );
    final cachedVersion = settings.availableUpdateVersion;
    final cachedUrl = Uri.tryParse(settings.availableUpdateUrl ?? '');
    if (cachedVersion != null &&
        isNewerVersion(appVersion, cachedVersion) &&
        cachedUrl?.scheme == 'https' &&
        cachedUrl!.host.isNotEmpty) {
      checker!.result = UpdateResult(
        UpdateStatus.available,
        version: cachedVersion,
        url: cachedUrl,
      );
      checker!.resultWasAutomatic = true;
      _visibleResult = checker!.result;
    }
    checker!.start();
    notifyListeners();
  }

  Future<UpdateResult> checkNow() async {
    if (isPlayStoreBuild) return const UpdateResult(UpdateStatus.skipped);
    if (checker == null) await initialize();
    final value = await checker!.check(manual: true);
    return value;
  }

  void settingsChanged() {
    if (isPlayStoreBuild) return;
    checker?.enabled = AppSettings.instance.updateCheck;
    if (checker?.enabled ?? false) checker?.check();
  }
}
