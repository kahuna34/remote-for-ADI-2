import 'package:url_launcher/url_launcher.dart';

Future<bool> openUpdate(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
