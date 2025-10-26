// lib/core/api.dart
//
// CinePulse HTTP client & endpoints
//
// Responsibilities:
// - Resolve which backend base URL to talk to (prod by default).
// - Provide typed helpers to call the CinePulse API.
// - Handle retry/backoff, decode responses, and pagination.
// - Build deep links for story pages.
// - Build CORS-safe thumbnail URLs using the backend /v1/img proxy.
//
// Production changes:
// - kApiBaseUrl is now the single source of truth for ALL network access
//   including thumbnails (proxyImageUrl()).
// - proxyImageUrl() ALWAYS points to API_BASE_URL/v1/img?u=..., never the
//   Netlify origin.
// - We send X-CinePulse-Client and nginx is configured to allow it in CORS.
// - We keep cursor pagination and ApiPage model.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

/// ------------------------------------------------------------
/// Resolve base URLs
/// ------------------------------------------------------------

String _resolveApiBase() {
  // Highest priority: explicit build-time override
  //   flutter build web --dart-define=API_BASE_URL=https://api.onlinecalculatorpro.org
  const fromDefine = String.fromEnvironment('API_BASE_URL');
  if (fromDefine.isNotEmpty) return fromDefine;

  // Dev override for LAN box:
  //   --dart-define=DEV_SERVER=http://192.168.1.50:8000
  const devServer = String.fromEnvironment('DEV_SERVER');
  if (devServer.isNotEmpty) {
    return devServer.startsWith('http') ? devServer : 'http://$devServer';
  }

  // Local emulator fallback (opt-in):
  //   --dart-define=USE_LOCAL_DEV=true
  // We assume Android emulator (10.0.2.2 -> host machine).
  const useLocal = String.fromEnvironment('USE_LOCAL_DEV');
  if (useLocal.toLowerCase() == 'true' || useLocal == '1') {
    return 'http://10.0.2.2:8000';
  }

  // Default: production API
  return 'https://api.onlinecalculatorpro.org';
}

String _resolveDeepBase() {
  // Optional override:
  //   --dart-define=DEEP_LINK_BASE=https://cinepulse.app/#/s
  const fromDefine = String.fromEnvironment('DEEP_LINK_BASE');
  if (fromDefine.isNotEmpty) return fromDefine;

  // On web builds, default deep link base to current origin.
  if (kIsWeb) return '${Uri.base.origin}/#/s';

  // Mobile fallback:
  return 'https://cinepulse.netlify.app/#/s';
}

/// Public bases used everywhere else.
final String kApiBaseUrl = _resolveApiBase();
final String kDeepLinkBase = _resolveDeepBase();

/// A small flavor string you can show in debug banners / settings pages.
String get currentApiFlavor {
  if (kApiBaseUrl.contains('10.0.2.2')) return 'local-dev';
  if (kApiBaseUrl.contains('192.168.')) return 'lan-dev';
  if (kApiBaseUrl.contains('staging')) return 'staging';
  return 'prod';
}

/// Build a CinePulse deep link to open a story inside the app UI.
Uri deepLinkForStoryId(String storyId) {
  final encoded = Uri.encodeComponent(storyId);
  return Uri.parse('$kDeepLinkBase/$encoded');
}

/// ------------------------------------------------------------
/// Image proxy helper
///
/// Web browsers block <img src="https://i.ytimg.com/..."> if the remote
/// host doesn't send CORS headers. We solve this by routing all images
/// through our API's /v1/img proxy, which DOES send CORS. This MUST use
/// the API domain, not the Netlify origin, otherwise you get 404 + CORS
/// errors like we saw in DevTools.
///
/// Usage in widgets:
///   Image.network(proxyImageUrl(story.thumbUrl))
/// ------------------------------------------------------------
String proxyImageUrl(String rawImageUrl) {
  if (rawImageUrl.isEmpty) return '';
  final encoded = Uri.encodeQueryComponent(rawImageUrl);
  return '$kApiBaseUrl/v1/img?u=$encoded';
}

/// ------------------------------------------------------------
/// ApiPage: feed results + opaque cursor
/// ------------------------------------------------------------
class ApiPage {
  final List<Story> items;
  final String? nextCursor;

  const ApiPage({
    required this.items,
    required this.nextCursor,
  });
}

/// ------------------------------------------------------------
/// Low-level HTTP client with retry
/// ------------------------------------------------------------
const _timeout = Duration(seconds: 12);

class ApiClient {
  ApiClient({required String baseUrl}) : _base = Uri.parse(baseUrl);

  final Uri _base;
  final http.Client _client = http.Client();

  /// Request headers for every API call.
  /// NOTE: nginx is configured to allow X-CinePulse-Client
  /// in Access-Control-Allow-Headers.
  Map<String, String> _headers() => const {
        'Accept': 'application/json',
        'Accept-Encoding': 'gzip',
        'Content-Type': 'application/json',
        'X-CinePulse-Client': 'app/1.0',
      };

  bool _isRetriableStatus(int code) =>
      code == 502 || code == 503 || code == 504;

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
          // soft backoff then retry
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
    if (body.length > 400) {
      body = '${body.substring(0, 400)}…';
    }

    if (r.statusCode == 429) {
      throw Exception(
        'API $path rate limited (429). Please try again shortly.',
      );
    }
    if (r.statusCode >= 500) {
      throw Exception(
        'API $path failed (${r.statusCode}). Please try again.',
      );
    }
    throw Exception('API $path failed (${r.statusCode}): $body');
  }

  ApiPage _decodeFeedPage(String body) {
    final map = json.decode(body) as Map<String, dynamic>;

    final rawItems = (map['items'] as List).cast<dynamic>();
    final items = rawItems
        .map((e) => Story.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);

    final cursor = map['next_cursor'];
    final nextCursor =
        (cursor is String && cursor.isNotEmpty) ? cursor : null;

    return ApiPage(items: items, nextCursor: nextCursor);
  }

  /// Normalize Flutter tab keys to server categories.
  /// If something weird hits us, fall back to "all".
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

  /// Build a URL against kApiBaseUrl, with optional query params.
  /// This preserves the upstream path (/v1/feed, /v1/story/..., etc.).
  Uri _build(String path, [Map<String, String>? q]) {
    final pieces = <String>[
      if (_base.path.isNotEmpty && _base.path != '/') _base.path,
      path.startsWith('/') ? path.substring(1) : path,
    ].where((s) => s.isNotEmpty).join('/');

    return _base.replace(path: '/$pieces', queryParameters: q);
  }

  // ------------------------------------------------------------
  // Public API calls
  // ------------------------------------------------------------

  /// Fetch 1 page of the feed with cursor pagination.
  ///
  /// - `tab` = "all", "trailers", ...
  /// - `since` = optional DateTime to only include newer stories.
  /// - `cursor` = opaque string from previous page's next_cursor.
  /// - `limit` = page size.
  ///
  /// Returns ApiPage(items, nextCursor).
  Future<ApiPage> fetchFeedPage({
    String tab = 'all',
    DateTime? since,
    String? cursor,
    int limit = 30,
  }) async {
    final normTab = _normalizeTab(tab);

    final params = <String, String>{
      'tab': normTab,
      'limit': '$limit',
    };

    if (since != null) {
      // Send RFC3339 UTC
      params['since'] = since.toUtc().toIso8601String();
    }

    if (cursor != null && cursor.isNotEmpty) {
      params['cursor'] = cursor;
    }

    final uri = _build('/v1/feed', params);

    try {
      final r = await _withRetry(() => _client.get(uri, headers: _headers()));
      if (r.statusCode != 200) _fail(r);
      return _decodeFeedPage(r.body);
    } on TimeoutException {
      throw Exception('Network timeout. Please try again.');
    } on FormatException {
      throw Exception('Malformed response from server.');
    }
  }

  /// Convenience shim for older code that just wants "List<Story>".
  Future<List<Story>> fetchFeed({
    String tab = 'all',
    DateTime? since,
    int limit = 30,
  }) async {
    final page =
        await fetchFeedPage(tab: tab, since: since, limit: limit);
    return page.items;
  }

  /// Full-text search.
  Future<List<Story>> searchStories(
    String query, {
    int limit = 10,
  }) async {
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

  /// Fetch a single story by ID.
  /// We URL-encode storyId so characters like ":" or "/" don't break the path.
  Future<Story> fetchStory(String storyId) async {
    final safeId = Uri.encodeComponent(storyId);
    final uri = _build('/v1/story/$safeId');

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

  /// Ask the API /health endpoint for feed_len, etc.
  /// We use this for diagnostics, maybe "is backend alive" banners.
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

/// Singleton client shared everywhere.
final ApiClient _api = ApiClient(baseUrl: kApiBaseUrl);

/// ------------------------------------------------------------
/// Top-level helpers (back-compat for existing widgets)
/// ------------------------------------------------------------

Future<List<Story>> fetchFeed({
  String tab = 'all',
  DateTime? since,
  int limit = 30,
}) =>
    _api.fetchFeed(tab: tab, since: since, limit: limit);

Future<ApiPage> fetchFeedPage({
  String tab = 'all',
  DateTime? since,
  String? cursor,
  int limit = 30,
}) =>
    _api.fetchFeedPage(
      tab: tab,
      since: since,
      cursor: cursor,
      limit: limit,
    );

Future<List<Story>> searchStories(
  String query, {
  int limit = 10,
}) =>
    _api.searchStories(query, limit: limit);

Future<Story> fetchStory(String storyId) => _api.fetchStory(storyId);

Future<int> fetchApproxFeedLength() => _api.fetchApproxFeedLength();
