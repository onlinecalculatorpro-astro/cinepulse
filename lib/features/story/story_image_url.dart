// lib/features/story/story_image_url.dart
//
// Safe hero/thumb image resolver.
// Policy:
//   • Prefer posterUrl, then thumbUrl.
//   • Drop junk/demo hosts.
//   • Any absolute http/https URL → proxy via API /v1/img?u=<encoded> (CORS-safe).
//   • Relative paths → prefix API_BASE_URL.
//   • If API_BASE_URL is missing, fall back to the original URL.
//   • Strip Chrome’s trailing “:1” suffix from paths.
//   • If URL is already our proxy, leave it (but still reject junk inside).
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
  if (url.isEmpty) return true;
  if (url.contains('demo.tagdiv.com')) return true;
  return false;
}

String _stripChromeSuffix(String raw) {
  // Chrome sometimes appends :<digits> to the *path* (e.g., …/img.jpg:1).
  final u = Uri.tryParse(raw);
  if (u == null) return raw;
  final newPath = u.path.replaceFirst(RegExp(r':\d+$'), '');
  return (newPath == u.path) ? raw : u.replace(path: newPath).toString();
}

String _prefixApiBase(String rel) {
  if (_API_BASE.isEmpty) return rel;
  return rel.startsWith('/') ? '$_API_BASE$rel' : '$_API_BASE/$rel';
}

bool _isOurProxy(Uri u) {
  final apiHost = Uri.tryParse(_API_BASE)?.host ?? '';
  // Accept both absolute and same-host forms; path must contain /v1/img
  return u.path.contains('/v1/img') && (apiHost.isEmpty || u.host == apiHost);
}

String _proxy(String absoluteUrl, {String? ref}) {
  if (_API_BASE.isEmpty) return absoluteUrl; // graceful fallback if not defined
  final qp = <String, String>{'u': absoluteUrl};
  if (ref != null && ref.isNotEmpty) {
    final r = Uri.tryParse(ref);
    if (r != null && (r.scheme == 'http' || r.scheme == 'https') && r.host.isNotEmpty) {
      qp['ref'] = r.toString();
    }
  }
  final uri = Uri.parse('$_API_BASE/v1/img').replace(queryParameters: qp);
  return uri.toString();
}

// ---------- main ----------
String resolveStoryImageUrl(Story story) {
  // 1) pick candidate
  final String cand = ((story.posterUrl?.trim().isNotEmpty ?? false)
          ? story.posterUrl!.trim()
          : (story.thumbUrl ?? '').trim());

  if (_isJunk(cand)) return '';

  // 2) sanitize Chrome :1 suffix early
  final String cleaned = _stripChromeSuffix(cand);
  final uri = Uri.tryParse(cleaned);
  if (uri == null) return '';

  // 3) already our proxy? keep it (but still reject junk inner param)
  if (_isOurProxy(uri)) {
    final inner = uri.queryParameters['u'] ?? uri.queryParameters['url'] ?? '';
    if (_isJunk(inner)) return '';
    return cleaned;
  }

  // 4) absolute external URL → go through API proxy (CORS-safe), with article URL as ref when available
  if (_isHttp(uri)) {
    final ref = (story.url?.isNotEmpty ?? false) ? story.url : null;
    return _proxy(cleaned, ref: ref);
  }

  // 5) relative path → serve via API base directly
  return _prefixApiBase(cleaned);
}
