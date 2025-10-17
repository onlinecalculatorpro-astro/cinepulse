// lib/core/api.dart
//
// CinePulse HTTP client & endpoints
// - Preserves existing public API (fetchFeed/searchStories/fetchStory/...)
// - Adds a persistent http.Client, retries with backoff, and clearer errors.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

/// ------------------------------------
/// Base URLs (auto-detected for dev)
/// ------------------------------------

String _autoApiBase() {
  // Prefer a --dart-define passed at run time.
  const fromDefine = String.fromEnvironment('API_BASE_URL');
  if (fromDefine.isNotEmpty) return fromDefine;

  // Helpful default for GitHub Codespaces (replace current port with 8000).
  if (kIsWeb) {
    final host = Uri.base.host; // e.g. supreme-...-5173.app.github.dev
    if (host.endsWith('.app.github.dev')) {
      final guessed = host.replaceFirst(
        RegExp(r'-\d+\.app\.github\.dev$'),
        '-8000.app.github.dev',
      );
      return 'https://$guessed';
    }
  }

  // Local dev (Docker on your machine)
  return 'http://localhost:8000';
}

String _autoDeepBase() {
  // Prefer a --dart-define as the source of truth.
  const fromDefine = String.fromEnvironment('DEEP_LINK_BASE');
  if (fromDefine.isNotEmpty) return fromDefine;

  // If we're running the Flutter web dev server, share links to the same host.
  if (kIsWeb) {
    // origin keeps scheme+host+port, we append the hash route.
    return '${Uri.base.origin}/#/s';
  }

  // Fallback placeholder; update in .env/defines for release builds.
  return 'https://cinepulse.example/#/s';
}

/// Public constants you can import elsewhere.
final String kApiBaseUrl = _autoApiBase();
final String kDeepLinkBase = _autoDeepBase();

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

  /// Common headers. (Some headers like User-Agent are blocked on web.)
  Map<String, String> _headers() => const {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'X-CinePulse-Client': 'app/1.0',
      };

  /// Small retry/backoff helper for transient failures.
  Future<http.Response> _withRetry(
    Future<http.Response> Function() op, {
    int attempts = 2,
    Duration backoff = const Duration(milliseconds: 350),
  }) async {
    Object? lastErr;
    for (var i = 0; i <= attempts; i++) {
      try {
        final r = await op().timeout(_timeout);
        if (_isRetriableStatus(r.statusCode)) {
          // Allow one more try for 502/503/504.
          if (i < attempts) {
            await Future<void>.delayed(backoff * (i + 1));
            continue;
          }
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
    // Shouldn't reach here; just throw the last error.
    throw lastErr ?? Exception('Unknown network error');
  }

  bool _isRetriableStatus(int code) =>
      code == 502 || code == 503 || code == 504;

  Never _fail(http.Response r) {
    final path = r.request?.url.path ?? '';
    String body = r.body;
    // Truncate very long bodies to avoid flooding logs.
    if (body.length > 400) body = '${body.substring(0, 400)}…';
    throw Exception('API $path failed (${r.statusCode}): $body');
  }

  List<Story> _decodeFeed(String body) {
    final map = json.decode(body) as Map<String, dynamic>;
    final raw = (map['items'] as List).cast<dynamic>();
    return raw
        .map((e) => Story.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Normalize Flutter tab keys to server-understood categories (if needed).
  String _normalizeTab(String tab) {
    switch (tab) {
      case 'all':
      case 'trailers':
      case 'ott':
        return tab;
      case 'intheatres':
        return 'intheatres';
      case 'comingsoon':
        return 'comingsoon';
      default:
        return 'all';
    }
  }

  Uri _build(String path, [Map<String, String>? q]) =>
      _base.replace(
        path: [
          // Ensure we don't duplicate slashes; keep existing base path.
          if (_base.path.isNotEmpty && _base.path != '/') _base.path,
          path.startsWith('/') ? path.substring(1) : path,
        ].join('/'),
        queryParameters: q,
      );

  // -------- Endpoints (instance) --------

  Future<List<Story>> fetchFeed({
    String tab = 'all',
    DateTime? since,
    int limit = 20,
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

/// Global client (preserves your top-level function API).
final ApiClient _api = ApiClient(baseUrl: kApiBaseUrl);

/// ------------------------------------
/// Top-level functions (back-compat)
/// ------------------------------------

Future<List<Story>> fetchFeed({
  String tab = 'all',
  DateTime? since,
  int limit = 20,
}) =>
    _api.fetchFeed(tab: tab, since: since, limit: limit);

Future<List<Story>> searchStories(String query, {int limit = 10}) =>
    _api.searchStories(query, limit: limit);

Future<Story> fetchStory(String storyId) => _api.fetchStory(storyId);

Future<int> fetchApproxFeedLength() => _api.fetchApproxFeedLength();
