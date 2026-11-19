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
  Future<void> initialize() async {
    if (isPlayStoreBuild) return;
    await (_initializing ??= _initialize());
  }

  Future<void> _initialize() async {
    final settings = AppSettings.instance;
    await settings.load();
    if (isPlayStoreBuild) return;
    checker = UpdateCheck(
      installedVersion: appVersion,
      platform: Platform.isAndroid
          ? UpdatePlatform.android
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
