import 'package:url_launcher/url_launcher.dart';

import '../store_build.dart';

Future<bool> openUpdate(Uri url) async {
  if (isPlayStoreBuild) return false;
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
