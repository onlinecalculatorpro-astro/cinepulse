// lib/core/deep_links.dart
import 'package:flutter/foundation.dart';

/// Site where the SPA is hosted (no hash fragment here).
String _resolveShareSite() {
  // Recommended override (optional):
  //   --dart-define=SHARE_SITE=https://app.nutshellnewsapp.com
  const fromDefine = String.fromEnvironment('SHARE_SITE');
  if (fromDefine.isNotEmpty) return fromDefine;

  // On web, default to current origin (works for custom domains).
  if (kIsWeb) return Uri.base.origin;

  // Mobile fallback:
  return 'https://app.nutshellnewsapp.com';
}

/// Public: single source of truth for app site (no "#/s" here).
final String kShareSite = _resolveShareSite();

/// Build canonical deep link:  https://<site>/#/s/<encoded-id>
String buildShareUrl(String storyId) {
  final site = kShareSite.endsWith('/')
      ? kShareSite.substring(0, kShareSite.length - 1)
      : kShareSite;
  final encodedId = Uri.encodeComponent(storyId);
  return '$site/#/s/$encodedId';
}
