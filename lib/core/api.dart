// lib/core/api.dart
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
/// HTTP + helpers
/// ------------------------------------

const _timeout = Duration(seconds: 12);

Never _fail(http.Response r) {
  throw Exception('API ${r.request?.url.path} failed '
      '(${r.statusCode}): ${r.body}');
}

List<Story> _decodeFeed(String body) {
  final map = json.decode(body) as Map<String, dynamic>;
  final raw = (map['items'] as List).cast<dynamic>();
  return raw
      .map((e) => Story.fromJson(e as Map<String, dynamic>))
      .toList(growable: false);
}

Map<String, String> _headers() => {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'X-CinePulse-Client': 'app/1.0',
    };

/// Normalize Flutter tab keys to server-understood categories (if needed).
/// We still pass the same keys by default, but this offers a single place
/// to remap without touching callers if the backend expects other strings.
String _normalizeTab(String tab) {
  switch (tab) {
    case 'all':
    case 'trailers':
    case 'ott':
      return tab;
    case 'intheatres':
      // alias: theatres/in_theatres/in-theatres etc.
      return 'intheatres';
    case 'comingsoon':
      // alias: upcoming/coming_soon etc.
      return 'comingsoon';
    default:
      return 'all';
  }
}

/// ------------------------------------
/// Endpoints
/// ------------------------------------

/// Fetch the feed (optionally filtered by tab/since) from the API.
Future<List<Story>> fetchFeed({
  String tab = 'all',
  DateTime? since,
  int limit = 20,
}) async {
  final norm = _normalizeTab(tab);
  final uri = Uri.parse('$kApiBaseUrl/v1/feed').replace(queryParameters: {
    'tab': norm,
    'limit': '$limit',
    if (since != null) 'since': since.toUtc().toIso8601String(),
  });

  try {
    final r = await http.get(uri, headers: _headers()).timeout(_timeout);
    if (r.statusCode != 200) _fail(r);
    // Keep decoding on the UI isolate—payloads are small.
    return _decodeFeed(r.body);
  } on TimeoutException {
    throw Exception('Network timeout. Please try again.');
  } on FormatException {
    throw Exception('Malformed response from server.');
  }
}

/// Full-text search across the in-memory feed window held by the API.
Future<List<Story>> searchStories(String query, {int limit = 10}) async {
  final uri = Uri.parse('$kApiBaseUrl/v1/search')
      .replace(queryParameters: {'q': query, 'limit': '$limit'});
  try {
    final r = await http.get(uri, headers: _headers()).timeout(_timeout);
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

/// Fetch one story by ID (useful for detail pages / deep links).
Future<Story> fetchStory(String storyId) async {
  final uri = Uri.parse('$kApiBaseUrl/v1/story/$storyId');
  try {
    final r = await http.get(uri, headers: _headers()).timeout(_timeout);
    if (r.statusCode != 200) _fail(r);
    final map = json.decode(r.body) as Map<String, dynamic>;
    return Story.fromJson(map);
  } on TimeoutException {
    throw Exception('Network timeout. Please try again.');
  } on FormatException {
    throw Exception('Malformed response from server.');
  }
}

/// Optional: quick health check (useful when showing an offline banner).
Future<int> fetchApproxFeedLength() async {
  final uri = Uri.parse('$kApiBaseUrl/health');
  try {
    final r = await http.get(uri, headers: _headers()).timeout(_timeout);
    if (r.statusCode != 200) _fail(r);
    final map = json.decode(r.body) as Map<String, dynamic>;
    return (map['feed_len'] as num?)?.toInt() ?? 0;
  } on TimeoutException {
    throw Exception('Network timeout. Please try again.');
  } on FormatException {
    throw Exception('Malformed response from server.');
  }
}
