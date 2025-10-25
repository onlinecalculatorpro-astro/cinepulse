// lib/core/api.dart
//
// CinePulse HTTP client & endpoints
//
// What this file does:
// - Figures out which backend URL to talk to (prod by default).
// - Wraps HTTP with retry/backoff and friendly error messages.
// - Exposes high-level helpers like fetchFeed(), fetchStory(), etc.
// - Now supports cursor pagination from /v1/feed.
//
// New in this version:
// - Safe storyId URL-encoding in fetchStory()
// - Cursor-aware fetchFeedPage()
// - ApiPage model { items, nextCursor }
// - Debug-friendly "flavor" string

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

/// ------------------------------------------------------------
/// Base URLs (prod by default; NO implicit localhost unless asked)
/// ------------------------------------------------------------

String _resolveApiBase() {
  // Highest priority: explicit build-time override
  //   --dart-define=API_BASE_URL=https://api.my-prod.com
  const fromDefine = String.fromEnvironment('API_BASE_URL');
  if (fromDefine.isNotEmpty) return fromDefine;

  // Dev override:
  //   --dart-define=DEV_SERVER=http://192.168.1.50:8000
  const devServer = String.fromEnvironment('DEV_SERVER');
  if (devServer.isNotEmpty) {
    return devServer.startsWith('http') ? devServer : 'http://$devServer';
  }

  // Opt-in local mode:
  //   --dart-define=USE_LOCAL_DEV=true
  //
  // We default Android emulator style (10.0.2.2). If you're on iOS sim,
  // just use DEV_SERVER above instead.
  const useLocal = String.fromEnvironment('USE_LOCAL_DEV');
  if (useLocal.toLowerCase() == 'true' || useLocal == '1') {
    return 'http://10.0.2.2:8000';
  }

  // Default: production API
  return 'https://api.onlinecalculatorpro.org';
}

String _resolveDeepBase() {
  // You can override deep link base at build time if needed:
  //   --dart-define=DEEP_LINK_BASE=https://cinepulse.app/#/s
  const fromDefine = String.fromEnvironment('DEEP_LINK_BASE');
  if (fromDefine.isNotEmpty) return fromDefine;

  // Web builds can just reuse their current origin.
  if (kIsWeb) return '${Uri.base.origin}/#/s';

  // Fallback for mobile builds.
  return 'https://cinepulse.netlify.app/#/s';
}

/// Public constants: most of the app should refer to these.
final String kApiBaseUrl = _resolveApiBase();
final String kDeepLinkBase = _resolveDeepBase();

/// Optional helper that's nice in debug UIs.
String get currentApiFlavor {
  if (kApiBaseUrl.contains('10.0.2.2')) return 'local-dev';
  if (kApiBaseUrl.contains('192.168.')) return 'lan-dev';
  if (kApiBaseUrl.contains('staging')) return 'staging';
  return 'prod';
}

/// Build a CinePulse deep link to open a story inside the app.
Uri deepLinkForStoryId(String storyId) {
  final encoded = Uri.encodeComponent(storyId);
  return Uri.parse('$kDeepLinkBase/$encoded');
}

/// ------------------------------------------------------------
/// ApiPage: page of feed results w/ cursor for "load more"
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
/// Low-level API client w/ retry & helpers
/// ------------------------------------------------------------
const _timeout = Duration(seconds: 12);

class ApiClient {
  ApiClient({required String baseUrl}) : _base = Uri.parse(baseUrl);

  final Uri _base;
  final http.Client _client = http.Client();

  Map<String, String> _headers() => const {
        'Accept': 'application/json',
        'Accept-Encoding': 'gzip',
        'Content-Type': 'application/json',
        'X-CinePulse-Client': 'app/1.0', // bump this if you ever need server logic per app version
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
          // brief backoff, then try again
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

  /// Normalize Flutter tab keys to server-understood categories.
  /// (Right now it's basically pass-through with sanity fallback.)
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

  /// Safe path join that won't accidentally drop base path segments.
  Uri _build(String path, [Map<String, String>? q]) {
    final pieces = <String>[
      if (_base.path.isNotEmpty && _base.path != '/') _base.path,
      path.startsWith('/') ? path.substring(1) : path,
    ].where((s) => s.isNotEmpty).join('/');

    return _base.replace(path: '/$pieces', queryParameters: q);
  }

  // ------------------------------------------------------------
  // Public instance methods
  // ------------------------------------------------------------

  /// Get 1 page of feed items (with cursor).
  ///
  /// `cursor` = opaque string from previous page's `next_cursor`.
  /// `since`  = only include items newer than this timestamp (UTC).
  /// `tab`    = category filter ("all", "trailers", ...).
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
      // API accepts RFC3339 with offset or Z.
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

  /// Back-compat helper:
  /// returns just `items` from the first page, ignores cursor.
  /// Your existing UI code that expects `List<Story>` can keep using this.
  Future<List<Story>> fetchFeed({
    String tab = 'all',
    DateTime? since,
    int limit = 30,
  }) async {
    final page =
        await fetchFeedPage(tab: tab, since: since, limit: limit);
    return page.items;
  }

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

  Future<Story> fetchStory(String storyId) async {
    // IMPORTANT: encode storyId so colons / slashes don't break the URL.
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

  Future<int> fetchApproxFeedLength() async {
    // /health returns { feed_len: <int>, ... } from the API container.
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

/// A shared singleton client for convenience.
/// Most code should just call the top-level helpers below.
final ApiClient _api = ApiClient(baseUrl: kApiBaseUrl);

/// ------------------------------------------------------------
/// Top-level functions (back-compat for your existing widgets)
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
