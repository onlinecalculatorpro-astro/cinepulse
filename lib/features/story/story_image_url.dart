import '../../core/models.dart';

const String _API_BASE =
    String.fromEnvironment('API_BASE_URL', defaultValue: ''); // no trailing slash

bool _isHttp(Uri u) => u.hasScheme && (u.scheme == 'http' || u.scheme == 'https');

bool _isJunk(String url) {
  if (url.isEmpty) return true;
  if (url.contains('demo.tagdiv.com')) return true;
  return false;
}

// -------- NEW: allowlist for CORS-safe direct browser fetch --------
bool _isCorsSafe(String url) {
  // Extend this list with CORS-open image hosts
  return url.contains('unsplash.com')
      || url.contains('your-own-safe-domain.com'); // example
}

String _stripChromeSuffix(String raw) {
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
  return u.path.contains('/v1/img') && (apiHost.isEmpty || u.host == apiHost);
}

String _proxy(String absoluteUrl, {String? ref}) {
  if (_API_BASE.isEmpty) return absoluteUrl;
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

String resolveStoryImageUrl(Story story) {
  final String cand = ((story.posterUrl?.trim().isNotEmpty ?? false)
          ? story.posterUrl!.trim()
          : (story.thumbUrl ?? '').trim());

  if (_isJunk(cand)) return '';

  final String cleaned = _stripChromeSuffix(cand);
  final uri = Uri.tryParse(cleaned);
  if (uri == null) return '';

  if (_isOurProxy(uri)) {
    final inner = uri.queryParameters['u'] ?? uri.queryParameters['url'] ?? '';
    if (_isJunk(inner)) return '';
    return cleaned;
  }

  if (_isHttp(uri)) {
    // ----------- CORS-safe direct fetch ---------
    if (_isCorsSafe(cleaned)) return cleaned;
    final ref = (story.url?.isNotEmpty ?? false) ? story.url : null;
    return _proxy(cleaned, ref: ref);
  }

  return _prefixApiBase(cleaned);
}
