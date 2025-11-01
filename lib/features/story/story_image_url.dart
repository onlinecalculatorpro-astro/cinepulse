// lib/features/story/story_image_url.dart
//
// Safe hero/thumb image resolver.
// Policy:
//   • Prefer posterUrl, then thumbUrl.
//   • Drop junk/demo hosts.
//   • Any absolute http/https URL → proxy via API /v1/img?u=<encoded> (CORS-safe).
//   • Relative paths → prefix API_BASE_URL.
//   • If API_BASE_URL is missing, gracefully fall back to the original URL.
//   • Strip Chrome’s trailing “:1” suffix from paths.
//
// Usage:
//   final imgUrl = resolveStoryImageUrl(story);
//   if (imgUrl.isNotEmpty) CachedNetworkImage(imageUrl: imgUrl, ...);

import '../../core/models.dart';

const String _API_BASE =
    String.fromEnvironment('API_BASE_URL', defaultValue: ''); // no trailing slash

// ---------- helpers ----------
bool _isHttp(Uri u) => u.hasScheme && (u.scheme == 'http' || u.scheme == 'https');

bool _isJunk(String url) {
  // Block obvious demo/placeholder hosts etc.
  if (url.contains('demo.tagdiv.com')) return true;
  return false;
}

String _proxy(String absoluteUrl) {
  if (_API_BASE.isEmpty) return absoluteUrl; // graceful fallback if not defined
  final enc = Uri.encodeComponent(absoluteUrl);
  return '$_API_BASE/v1/img?u=$enc';
}

String _prefixApiBase(String rel) {
  if (_API_BASE.isEmpty) return rel;
  return rel.startsWith('/') ? '$_API_BASE$rel' : '$_API_BASE/$rel';
}

String _stripChromeSuffix(String raw) {
  // Chrome sometimes appends :<digits> to the *path* (e.g., …/img.jpg:1).
  final u = Uri.tryParse(raw);
  if (u == null) return raw;
  final path = u.path.replaceFirst(RegExp(r':\d+$'), '');
  return (path == u.path) ? raw : u.replace(path: path).toString();
}

bool _isOurProxy(Uri u) {
  final apiHost = Uri.tryParse(_API_BASE)?.host ?? '';
  return u.path.contains('/v1/img') && (apiHost.isEmpty || u.host == apiHost);
}

// ---------- main ----------
String resolveStoryImageUrl(Story story) {
  // 1) pick candidate
  final String cand = ((story.posterUrl?.trim().isNotEmpty ?? false)
          ? story.posterUrl!.trim()
          : (story.thumbUrl ?? '').trim())
      .trim();

  if (cand.isEmpty || _isJunk(cand)) return '';

  // 2) sanitize Chrome :1 suffix early
  final String cleaned = _stripChromeSuffix(cand);
  final uri = Uri.tryParse(cleaned);
  if (uri == null) return '';

  // 3) already our proxy? keep it (but still reject junk inner param)
  if (_isOurProxy(uri)) {
    final inner = uri.queryParameters['u'] ?? uri.queryParameters['url'] ?? '';
    if (inner.isNotEmpty && _isJunk(inner)) return '';
    return cleaned;
  }

  // 4) absolute external URL → go through API proxy (CORS-safe)
  if (_isHttp(uri)) {
    return _proxy(cleaned);
  }

  // 5) relative path → serve via API base directly
  return _prefixApiBase(cleaned);
}
