// lib/features/story/story_image_url.dart
//
// Choose a safe hero image URL for a Story.
// Policy (to avoid browser CORS):
//   • Prefer posterUrl, fall back to thumbUrl.
//   • Reject junk/demo domains.
//   • For any absolute http/https URL, return API /v1/img?u=<encoded>.
//   • For relative paths, prefix API_BASE_URL directly.
//   • If API_BASE_URL is missing, fall back to the original URL.
//
// Usage:
//   final imgUrl = resolveStoryImageUrl(story);
//   if (imgUrl.isNotEmpty) ... CachedNetworkImage(imageUrl: imgUrl, ...);

import '../../core/models.dart';

// Set in CI with:
//   --dart-define=API_BASE_URL=https://api.nutshellnewsapp.com
// (no trailing slash; your workflow trims it)
const String _API_BASE = String.fromEnvironment('API_BASE_URL', defaultValue: '');

bool _isHttp(Uri u) => u.hasScheme && (u.scheme == 'http' || u.scheme == 'https');

bool _isJunk(String url) {
  // Block obvious demo/placeholder hosts etc.
  if (url.contains('demo.tagdiv.com')) return true;
  return false;
}

String _proxy(String absoluteUrl) {
  if (_API_BASE.isEmpty) return absoluteUrl; // graceful fallback
  final enc = Uri.encodeComponent(absoluteUrl);
  return '$_API_BASE/v1/img?u=$enc';
}

String resolveStoryImageUrl(Story story) {
  // 1) pick candidate
  final cand = (story.posterUrl?.isNotEmpty == true)
      ? story.posterUrl!
      : (story.thumbUrl ?? '');
  if (cand.isEmpty || _isJunk(cand)) return '';

  final uri = Uri.tryParse(cand);
  if (uri == null) return '';

  // 2) If this is already our own proxy (/v1/img?u=...), keep it
  final isAlreadyProxy = uri.path.toLowerCase().contains('/v1/img');
  if (isAlreadyProxy) {
    // Also reject proxied junk if present in inner param
    final inner = uri.queryParameters['u'] ?? uri.queryParameters['url'] ?? '';
    if (inner.isNotEmpty && _isJunk(inner)) return '';
    return _API_BASE.isNotEmpty ? cand : (inner.isNotEmpty ? inner : cand);
  }

  // 3) Absolute external URL → always go through API proxy to avoid CORS
  if (_isHttp(uri)) {
    return _proxy(cand);
  }

  // 4) Relative path → serve from API base directly
  if (_API_BASE.isNotEmpty) {
    return cand.startsWith('/') ? '$_API_BASE$cand' : '$_API_BASE/$cand';
  }

  // 5) Last resort
  return cand;
}
