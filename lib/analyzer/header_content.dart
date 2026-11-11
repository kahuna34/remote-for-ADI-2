/// One header choice shared by app settings and custom layouts.
enum HeaderContent { player, status, analyzer, none }

HeaderContent headerContentFromLegacy(
  bool player,
  bool status,
  bool analyzer,
) => analyzer
    ? HeaderContent.analyzer
    : player
    ? HeaderContent.player
    : status
    ? HeaderContent.status
    : HeaderContent.none;
