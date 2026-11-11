import 'package:adi2_remote/app_settings.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
  });

  test('automatic updates default to enabled', () {
    expect(AppSettings.instance.updateCheck, true);
    expect(AppSettings.instance.lastUpdateCheck, isNull);
    expect(AppSettings.instance.skippedUpdateVersion, isNull);
  });

  test('update preferences survive reload', () async {
    await AppSettings.instance.setUpdateCheck(false);
    final time = DateTime.utc(2026, 11, 11);
    await AppSettings.instance.saveUpdateState(
      time,
      '1.2.0',
      version: '1.2.0',
      url: 'https://github.com/download',
    );
    await AppSettings.instance.load();
    expect(AppSettings.instance.updateCheck, false);
    expect(AppSettings.instance.lastUpdateCheck, time);
    expect(AppSettings.instance.skippedUpdateVersion, '1.2.0');
    expect(AppSettings.instance.availableUpdateVersion, '1.2.0');
  });
  test('download label has update context and preserves other Load labels', () {
    final language = AppLang.instance.language;
    try {
      AppLang.instance.language = AppLanguage.en;
      expect(tr('Laden', context: 'update'), 'Download');
      expect(tr('Laden'), 'Load');
      AppLang.instance.language = AppLanguage.de;
      expect(tr('Laden', context: 'update'), 'Laden');
    } finally {
      AppLang.instance.language = language;
    }
  });
}
