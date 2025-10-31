// lib/core/deep_links.dart
//
// Builds canonical share/deep links for Story Details.
// Our web app uses HASH routing: https://app.nutshellnewsapp.com/#/s/<id>

const String kDeepLinkBase =
    String.fromEnvironment('DEEP_LINK_BASE', defaultValue: 'https://app.nutshellnewsapp.com');

/// Build a share URL for a story id (id can contain ':' etc.)
String buildShareUrl(String storyId, {String? base, bool hashRouting = true}) {
  final b = (base ?? kDeepLinkBase).replaceFirst(RegExp(r'/$'), ''); // trim trailing /
  final encId = Uri.encodeComponent(storyId); // ONLY encode the id, not the whole URL
  return hashRouting ? '$b/#/s/$encId' : '$b/s/$encId';
}
