// lib/features/story/story_image_url.dart
//
// Always prefer proxy for external images (server fetch avoids CORS).
// Allow a tiny direct-allowed list (e.g., YouTube thumbs).

import '../../core/models.dart';

const String _API_BASE =
    String.fromEnvironment('API_BASE_URL', defaultValue: ''); // no trailing slash

bool _isHttp(Uri u) => u.hasScheme && (u.scheme == 'http' || u.scheme == 'https');

bool _isJunk(String url) {
  if (url.isEmpty) return true;
  final s = url.trim().toLowerCase();
  if (s == 'about:blank' || s.startsWith('data:') || s.startsWith('blob:')) return true;
  if (s.contains('demo.tagdiv.com')) return true;
  return false;
}

String _stripChromeSuffix(String raw) {
  final u = Uri.tryParse(raw);
  if (u == null) return raw;
  final p = u.path.replaceFirst(RegExp(r':\d+$'), '');
  return (p == u.path) ? raw : u.replace(path: p).toString();
}

String _prefixApiBase(String rel) {
  if (_API_BASE.isEmpty) return rel;
  return rel.startsWith('/') ? '$_API_BASE$rel' : '$_API_BASE/$rel';
}

bool _isOurProxy(Uri u) {
  final apiHost = Uri.tryParse(_API_BASE)?.host ?? '';
  return u.path.contains('/v1/img') && (apiHost.isEmpty || u.host == apiHost);
}

// Tiny CORS-open allowlist (kept narrow on purpose)
bool _isCorsSafeDirect(String url) {
  final u = Uri.tryParse(url);
  if (u == null || u.host.isEmpty) return false;
  final h = u.host.toLowerCase();
  const allow = <String>[
    'i.ytimg.com', 'ytimg.com', 'yt3.ggpht.com', 'img.youtube.com',
  ];
  return allow.any((sfx) => h == sfx || h.endsWith('.$sfx'));
}

String _proxy(String absoluteUrl, {String? ref}) {
  if (_API_BASE.isEmpty) return absoluteUrl; // graceful fallback
  final qp = <String, String>{'u': absoluteUrl};
  if (ref != null && ref.isNotEmpty) {
    final r = Uri.tryParse(ref);
    if (r != null && (r.scheme == 'http' || r.scheme == 'https') && r.host.isNotEmpty) {
      qp['ref'] = r.toString();
    }
  }
  return Uri.parse('$_API_BASE/v1/img').replace(queryParameters: qp).toString();
}

String resolveStoryImageUrl(Story story) {
  final String cand = ((story.posterUrl?.trim().isNotEmpty ?? false)
      ? story.posterUrl!.trim()
      : (story.thumbUrl ?? '').trim());

  if (_isJunk(cand)) return '';

  final String cleaned = _stripChromeSuffix(cand);
  final uri = Uri.tryParse(cleaned);
  if (uri == null) return '';

  // Keep existing proxy URLs (but reject if inner is junk)
  if (_isOurProxy(uri)) {
    final inner = uri.queryParameters['u'] ?? uri.queryParameters['url'] ?? '';
    if (_isJunk(inner)) return '';
    return cleaned;
  }

  if (_isHttp(uri)) {
    // Only a tiny allowlist goes direct; everything else via proxy (with article URL as referer)
    if (_isCorsSafeDirect(cleaned)) return cleaned;
    final ref = (story.url?.isNotEmpty ?? false) ? story.url : null;
    return _proxy(cleaned, ref: ref);
  }

  // Relative asset under our API
  return _prefixApiBase(cleaned);
}
