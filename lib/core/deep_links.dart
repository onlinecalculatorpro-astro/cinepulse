// lib/core/deep_links.dart
import 'package:flutter/foundation.dart';

String _resolveShareSite() {
  // flutter build web --dart-define=SHARE_SITE=https://app.nutshellnewsapp.com
  const fromDefine = String.fromEnvironment('SHARE_SITE');
  if (fromDefine.isNotEmpty) return fromDefine;

  // On web, default to current origin; else production.
  if (kIsWeb) return Uri.base.origin;
  return 'https://app.nutshellnewsapp.com';
}

// Optional: override the path segment used for story deep links.
// Example: --dart-define=SHARE_PATH=#/s
String _resolveSharePath() {
  const fromDefine = String.fromEnvironment('SHARE_PATH');
  if (fromDefine.isNotEmpty) return fromDefine;
  return '#/s';
}

/// Public: the site you share (no trailing slash)
final String kShareSite = _resolveShareSite();

/// Public: the path fragment for story links (defaults to "#/s")
final String kSharePath = _resolveSharePath();

/// Base URL like "https://app.nutshellnewsapp.com/#/s"
String get kShareBaseUrl {
  final base = '$kShareSite/$kSharePath';
  return base.replaceAll('//#/', '/#/'); // normalize accidental double slash
}

/// Build: "https://app.nutshellnewsapp.com/#/s/<encoded-id>"
String buildShareUrl(String storyId) {
  final encoded = Uri.encodeComponent(storyId);
  final full = '$kShareSite/$kSharePath/$encoded';
  return full.replaceAll('//#/', '/#/');
}
