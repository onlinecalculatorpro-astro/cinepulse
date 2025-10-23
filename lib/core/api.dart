// lib/core/api.dart
//
// CinePulse HTTP client & endpoints
// - Keeps public API: fetchFeed / searchStories / fetchStory / fetchApproxFeedLength
// - Persistent http.Client with tiny retry/backoff for flaky 50x/timeouts
// - Sensible BASE URL resolution (dart-define > explicit prod > local dev)
// - Safer path joining + clearer, truncated error messages

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

/// ------------------------------------
/// Base URLs (prod by default; dev auto-detect)
/// ------------------------------------

String _resolveApiBase() {
  // 1) Strongest: passed via --dart-define=API_BASE_URL=https://...
  const fromDefine = String.fromEnvironment('API_BASE_URL');
  if (fromDefine.isNotEmpty) return fromDefine;

  // 2) Default to your live API domain.
  //    For local/dev we override below when not in release mode.
  const prod = 'https://api.onlinecalculatorpro.org';

  // 3) Local/dev heuristics (only when not release).
  if (!kReleaseMode) {
    if (kIsWeb) {
      // Helpful default for Codespaces: swap port → 8000
      final host = Uri.base.host; // e.g. foo-5173.app.github.dev
      if (host.endsWith('.app.github.dev')) {
        final guessed = host.replaceFirst(RegExp(r'-\d+\.app\.github\.dev$'), '-8000.app.github.dev');
        return 'https://$guessed';
      }
    }
    return 'http://localhost:8000';
  }

  return prod;
}

String _resolveDeepBase() {
  // 1) --dart-define=DEEP_LINK_BASE=https://.../#/s
  const fromDefine = String.fromEnvironment('DEEP_LINK_BASE');
  if (fromDefine.isNotEmpty) return fromDefine;

  // 2) For Flutter web dev server, share links to same origin.
  if (kIsWeb) return '${Uri.base.origin}/#/s';

  // 3) Fallback placeholder; override via --dart-define for releases if needed.
  return 'https://cinepulse.example/#/s';
}

/// Public constants you can import elsewhere.
final String kApiBaseUrl = _resolveApiBase();
final String kDeepLinkBase = _resolveDeepBase();

/// Build a CinePulse deep link to open a story inside the app.
Uri deepLinkForStoryId(String storyId) {
  final encoded = Uri.encodeComponent(storyId);
  return Uri.parse('$kDeepLinkBase/$encoded');
}

/// ------------------------------------
/// Low-level client with retry/backoff
/// ------------------------------------

const _timeout = Duration(seconds: 12);

class ApiClient {
  ApiClient({required String baseUrl}) : _base = Uri.parse(baseUrl);

  final Uri _base;
  final http.Client _client = http.Client();

  Map<String, String> _headers() => const {
        'Accept': 'application/json',
        'Accept-Encoding': 'gzip',
        'Content-Type': 'application/json',
        'X-CinePulse-Client': 'app/1.0',
      };

  bool _isRetriableStatus(int code) => code == 502 || code == 503 || code == 504;

  Future<http.Response> _withRetry(
    Future<http.Response> Function() op, {
    int attempts = 2, // total tries = attempts + 1
    Duration backoff = const Duration(milliseconds: 350),
  }) async {
    Object? lastErr;
    for (var i = 0; i <= attempts; i++) {
      try {
        final r = await op().timeout(_timeout);
        if (_isRetriableStatus(r.statusCode) && i < attempts) {
          await Future<void>.delayed(backoff * (i + 1));
          continue;
        }
        return r;
      } on TimeoutException catch (e) {
        lastErr = e;
        if (i < attempts) {
          await Future<void>.delayed(backoff * (i + 1));
          continue;
        }
        rethrow;
      } on http.ClientException catch (e) {
        lastErr = e;
        if (i < attempts) {
          await Future<void>.delayed(backoff * (i + 1));
          continue;
        }
        rethrow;
      } catch (e) {
        lastErr = e;
        rethrow;
      }
    }
    throw lastErr ?? Exception('Unknown network error');
  }

  Never _fail(http.Response r) {
    final path = r.request?.url.path ?? '';
    var body = r.body;
    if (body.length > 400) body = '${body.substring(0, 400)}…';

    // Friendlier messages for a few common cases.
    if (r.statusCode == 429) {
      throw Exception('API $path rate limited (429). Please try again shortly.');
    }
    if (r.statusCode >= 500) {
      throw Exception('API $path failed (${r.statusCode}). Please try again.');
    }
    throw Exception('API $path failed (${r.statusCode}): $body');
  }

  List<Story> _decodeFeed(String body) {
    final map = json.decode(body) as Map<String, dynamic>;
    final raw = (map['items'] as List).cast<dynamic>();
    return raw
        .map((e) => Story.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Normalize Flutter tab keys to server-understood categories (noop today).
  String _normalizeTab(String tab) {
    switch (tab) {
      case 'all':
      case 'trailers':
      case 'ott':
      case 'intheatres':
      case 'comingsoon':
        return tab;
      default:
        return 'all';
    }
  }

  /// Safe path join that respects an existing base path.
  Uri _build(String path, [Map<String, String>? q]) {
    final pieces = <String>[
      if (_base.path.isNotEmpty && _base.path != '/') _base.path,
      path.startsWith('/') ? path.substring(1) : path,
    ].where((s) => s.isNotEmpty).join('/');

    return _base.replace(path: '/$pieces', queryParameters: q);
  }

  // -------- Endpoints (instance) --------

  Future<List<Story>> fetchFeed({
    String tab = 'all',
    DateTime? since,
    int limit = 30, // show a healthy page by default
  }) async {
    final norm = _normalizeTab(tab);
    final uri = _build('/v1/feed', {
      'tab': norm,
      'limit': '$limit',
      if (since != null) 'since': since.toUtc().toIso8601String(),
    });

    try {
      final r = await _withRetry(() => _client.get(uri, headers: _headers()));
      if (r.statusCode != 200) _fail(r);
      return _decodeFeed(r.body);
    } on TimeoutException {
      throw Exception('Network timeout. Please try again.');
    } on FormatException {
      throw Exception('Malformed response from server.');
    }
  }

  Future<List<Story>> searchStories(String query, {int limit = 10}) async {
    final uri = _build('/v1/search', {'q': query, 'limit': '$limit'});
    try {
      final r = await _withRetry(() => _client.get(uri, headers: _headers()));
      if (r.statusCode != 200) _fail(r);
      final map = json.decode(r.body) as Map<String, dynamic>;
      final raw = (map['items'] as List).cast<dynamic>();
      return raw
          .map((e) => Story.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
    } on TimeoutException {
      throw Exception('Search timed out. Please try again.');
    } on FormatException {
      throw Exception('Malformed response from server.');
    }
  }

  Future<Story> fetchStory(String storyId) async {
    final uri = _build('/v1/story/$storyId');
    try {
      final r = await _withRetry(() => _client.get(uri, headers: _headers()));
      if (r.statusCode != 200) _fail(r);
      final map = json.decode(r.body) as Map<String, dynamic>;
      return Story.fromJson(map);
    } on TimeoutException {
      throw Exception('Network timeout. Please try again.');
    } on FormatException {
      throw Exception('Malformed response from server.');
    }
  }

  Future<int> fetchApproxFeedLength() async {
    final uri = _build('/health');
    try {
      final r = await _withRetry(() => _client.get(uri, headers: _headers()));
      if (r.statusCode != 200) _fail(r);
      final map = json.decode(r.body) as Map<String, dynamic>;
      return (map['feed_len'] as num?)?.toInt() ?? 0;
    } on TimeoutException {
      throw Exception('Network timeout. Please try again.');
    } on FormatException {
      throw Exception('Malformed response from server.');
    }
  }

  void dispose() => _client.close();
}

/// Global client (keeps your top-level function API intact).
final ApiClient _api = ApiClient(baseUrl: kApiBaseUrl);

/// ------------------------------------
/// Top-level functions (back-compat)
/// ------------------------------------

Future<List<Story>> fetchFeed({
  String tab = 'all',
  DateTime? since,
  int limit = 30,
}) =>
    _api.fetchFeed(tab: tab, since: since, limit: limit);

Future<List<Story>> searchStories(String query, {int limit = 10}) =>
    _api.searchStories(query, limit: limit);

Future<Story> fetchStory(String storyId) => _api.fetchStory(storyId);

Future<int> fetchApproxFeedLength() => _api.fetchApproxFeedLength();
