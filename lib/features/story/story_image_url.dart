// lib/features/story/story_image_url.dart
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
  final newPath = u.path.replaceFirst(RegExp(r':\d+$'), '');
  return (newPath == u.path) ? raw : u.replace(path: newPath).toString();
}

String _rootDomain(String host) {
  final parts = host.split('.');
  if (parts.length < 2) return host;
  return '${parts[parts.length - 2]}.${parts.last}';
}

final String _ourRoot =
    _rootDomain(Uri.tryParse(_API_BASE)?.host ?? ''); // e.g. nutshellnewsapp.com

bool _isOurDomainHost(String host) {
  if (_ourRoot.isEmpty) return false;
  final h = host.toLowerCase();
  return h == _ourRoot || h.endsWith('.$_ourRoot');
}

bool _looksLikeImageUri(Uri u) {
  final t = u.toString().toLowerCase();
  // common image endings or query-hinted images
  return RegExp(r'\.(jpg|jpeg|png|webp|gif|avif)(?:$|\?)').hasMatch(t) ||
      t.contains('/vi/') ||
      t.contains('/thumb') ||
      t.contains('/images/');
}

String _prefixApiBase(String rel) {
  if (_API_BASE.isEmpty) return rel;
  return rel.startsWith('/') ? '$_API_BASE$rel' : '$_API_BASE/$rel';
}

bool _isOurProxy(Uri u) {
  final apiHost = Uri.tryParse(_API_BASE)?.host ?? '';
  return u.path.contains('/v1/img') && (apiHost.isEmpty || u.host == apiHost);
}

// small direct-allowlist (CORS-open CDNs)
bool _isCorsSafeDirect(String url) {
  final u = Uri.tryParse(url);
  if (u == null) return false;
  final h = u.host.toLowerCase();
  const allow = <String>[
    'i.ytimg.com',
    'ytimg.com',
    'yt3.ggpht.com',
    'img.youtube.com',
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
  // Gather possible sources
  final cands = <String>[
    (story.posterUrl ?? '').trim(),
    (story.thumbUrl ?? '').trim(),
  ].where((s) => s.isNotEmpty).toList();

  // 1) sanitize + filter to only real image URLs
  for (final raw in cands) {
    if (_isJunk(raw)) continue;
    final cleaned = _stripChromeSuffix(raw);
    final u = Uri.tryParse(cleaned);
    if (u == null || !_isHttp(u)) continue;

    // ✅ accept already-proxied URLs from our API even if they don't look like images
    if (_isOurProxy(u)) {
      final inner = u.queryParameters['u'] ?? u.queryParameters['url'] ?? '';
      if (_isJunk(inner)) continue;
      return cleaned;
    }

    // drop article links on our own hosts
    if (_isOurDomainHost(u.host)) continue;

    // must look like an image otherwise
    if (!_looksLikeImageUri(u)) continue;

    // route through proxy (or direct for tiny allowlist)
    if (_isCorsSafeDirect(cleaned)) return cleaned;
    final ref = (story.url?.isNotEmpty ?? false) ? story.url : null;
    return _proxy(cleaned, ref: ref);
  }

  // 2) if any candidate is relative, serve via API base
  for (final raw in cands) {
    if (_isJunk(raw)) continue;
    final cleaned = _stripChromeSuffix(raw);
    final u = Uri.tryParse(cleaned);
    if (u != null && !u.hasScheme) return _prefixApiBase(cleaned);
  }

  // nothing usable
  return '';
}
