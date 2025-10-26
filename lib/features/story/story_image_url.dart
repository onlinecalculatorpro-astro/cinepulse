import '../../core/api.dart'; // for API_BASE_URL

/// Return a cleaned, absolute image URL for a story hero/thumb.
/// Falls back to '' if it's trash.
String resolveStoryImageUrl(String? posterUrl, String? thumbUrl) {
  // Prefer posterUrl, else thumbUrl.
  var raw = (posterUrl != null && posterUrl.isNotEmpty)
      ? posterUrl
      : (thumbUrl ?? '');

  if (raw.isEmpty) return '';

  // 1. reject obvious garbage from spammy demo hosts
  if (raw.contains('demo.tagdiv.com')) return '';

  // 2. normalize relative proxy URLs like "/v1/img?u=..." so they hit API, not Netlify
  String fixProxy(String u) {
    // already absolute? leave it.
    if (u.startsWith('http://') || u.startsWith('https://')) {
      return u;
    }

    // "/v1/img?u=..."  OR  "v1/img?u=..."
    if (u.startsWith('/v1/img')) {
      return '$API_BASE_URL$u'; // API_BASE_URL has no trailing slash (CI enforces that)
    }
    if (u.startsWith('v1/img')) {
      return '$API_BASE_URL/$u';
    }

    // any other relative path, just return it untouched (best effort)
    return u;
  }

  raw = fixProxy(raw);

  // 3. if it's still a proxy path, sanity check the inner target
  final uri = Uri.tryParse(raw);
  if (uri != null && uri.path.contains('/v1/img')) {
    final inner = uri.queryParameters['u'] ?? uri.queryParameters['url'] ?? '';
    if (inner.contains('demo.tagdiv.com')) {
      return '';
    }
  }

  return raw;
}
