// lib/core/models.dart
import 'package:flutter/foundation.dart';

/// Domain model representing a single feed item/story.
///
/// The backend may return snake_case keys (e.g. `published_at`, `thumb_url`)
/// or camelCase. This model accepts both to stay resilient.
///
/// New fields for theatre/OTT workflows:
/// - releaseDate, ratingCert, runtimeMinutes
/// - ottPlatform (e.g., "netflix", "prime", "hotstar")
/// - languages, genres
/// - isTheatrical / isUpcoming (explicit or derived)
@immutable
class Story {
  final String id;              // e.g. "youtube:GgMWu_oqJ6c"
  final String kind;            // "trailer" | "ott" | "release" | ...
  final String title;
  final String? summary;

  final DateTime? publishedAt;  // RFC3339 string → DateTime UTC
  final DateTime? releaseDate;  // theatrical/OTT release date, if known

  final String? source;         // e.g. "youtube"
  final String? ottPlatform;    // e.g. "netflix", "prime", "hotstar"
  final String? ratingCert;     // e.g. "U", "U/A", "A" (India)

  final int? runtimeMinutes;    // duration if known
  final List<String> languages; // ISO-ish names (e.g., ["hi","en"])
  final List<String> genres;    // e.g., ["Action","Drama"]

  final String? thumbUrl;       // small image (card/list)
  final String? posterUrl;      // larger poster (detail)

  // Flags may come from server; we also derive sensible defaults in getters.
  final bool? isTheatricalFlag;
  final bool? isUpcomingFlag;

  const Story({
    required this.id,
    required this.kind,
    required this.title,
    this.summary,
    this.publishedAt,
    this.releaseDate,
    this.source,
    this.ottPlatform,
    this.ratingCert,
    this.runtimeMinutes,
    this.languages = const [],
    this.genres = const [],
    this.thumbUrl,
    this.posterUrl,
    this.isTheatricalFlag,
    this.isUpcomingFlag,
  });

  /// Robust DateTime parse that tolerates a few formats.
  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v.toUtc();
    if (v is int) {
      // Epoch seconds/millis—best effort
      final isMillis = v > 2000000000; // ~2033 in seconds; larger implies millis
      final ms = isMillis ? v : v * 1000;
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    }
    if (v is String && v.trim().isNotEmpty) {
      try {
        return DateTime.parse(v).toUtc();
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static int? _parseInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) {
      final t = v.trim();
      if (t.isEmpty) return null;
      final n = int.tryParse(t);
      return n;
    }
    return null;
  }

  static List<String> _parseStringList(dynamic v) {
    if (v == null) return const <String>[];
    if (v is List) {
      return v
          .where((e) => e != null)
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    }
    // Allow comma/pipe-separated strings
    if (v is String && v.trim().isNotEmpty) {
      final sep = v.contains('|') ? '|' : ',';
      return v
          .split(sep)
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    }
    return const <String>[];
  }

  /// Accepts both snake_case and camelCase keys.
  factory Story.fromJson(Map<String, dynamic> j) {
    String _readS(String a, [String? b]) =>
        (j[a] ?? (b != null ? j[b] : null))?.toString() ?? '';

    String? _readSOpt(String a, [String? b]) {
      final v = j[a] ?? (b != null ? j[b] : null);
      return v == null ? null : v.toString();
    }

    dynamic _read(dynamic a, [String? b]) => j[a] ?? (b != null ? j[b] : null);

    final published = _read('published_at', 'publishedAt');
    final released  = _read('release_date', 'releaseDate');

    final thumb     = _read('thumb_url', 'thumbUrl');
    final poster    = _read('poster_url', 'posterUrl');

    final langs     = _read('languages', 'language') ?? _read('langs');
    final gens      = _read('genres', 'genre');

    final theatrical = _read('is_theatrical', 'isTheatrical');
    final upcoming   = _read('is_upcoming', 'isUpcoming');

    return Story(
      id: _readS('id'),
      kind: _readS('kind'),
      title: _readS('title'),
      summary: _readSOpt('summary'),
      publishedAt: _parseDate(published),
      releaseDate: _parseDate(released),

      source: _readSOpt('source'),
      ottPlatform: _readSOpt('ott_platform', 'ottPlatform'),
      ratingCert: _readSOpt('rating_cert', 'ratingCert'),

      runtimeMinutes: _parseInt(_read('runtime_minutes', 'runtimeMinutes')),
      languages: _parseStringList(langs),
      genres: _parseStringList(gens),

      thumbUrl: _readSOpt('thumb_url', 'thumbUrl'),
      posterUrl: _readSOpt('poster_url', 'posterUrl'),

      isTheatricalFlag: theatrical is bool ? theatrical : null,
      isUpcomingFlag: upcoming is bool ? upcoming : null,
    );
  }

  /// JSON in the shape the API expects (snake_case).
  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'title': title,
        if (summary != null) 'summary': summary,
        if (publishedAt != null)
          'published_at': publishedAt!.toUtc().toIso8601String(),
        if (releaseDate != null)
          'release_date': releaseDate!.toUtc().toIso8601String(),
        if (source != null) 'source': source,
        if (ottPlatform != null) 'ott_platform': ottPlatform,
        if (ratingCert != null) 'rating_cert': ratingCert,
        if (runtimeMinutes != null) 'runtime_minutes': runtimeMinutes,
        if (languages.isNotEmpty) 'languages': languages,
        if (genres.isNotEmpty) 'genres': genres,
        if (thumbUrl != null) 'thumb_url': thumbUrl,
        if (posterUrl != null) 'poster_url': posterUrl,
        if (isTheatricalFlag != null) 'is_theatrical': isTheatricalFlag,
        if (isUpcomingFlag != null) 'is_upcoming': isUpcomingFlag,
      };

  /// Convenience: YouTube video id if this is a YouTube story.
  String? get youtubeVideoId {
    if (source == 'youtube') {
      final p = id.split(':');
      if (p.length >= 2 && p.first == 'youtube' && p.last.isNotEmpty) {
        return p.last;
      }
    }
    return null;
  }

  /// Derived: treat as theatrical if explicit flag or kind looks like a release.
  bool get isTheatrical {
    if (isTheatricalFlag != null) return isTheatricalFlag!;
    return kind.toLowerCase() == 'release';
  }

  /// Derived: upcoming if explicit flag or releaseDate is in the future.
  bool get isUpcoming {
    if (isUpcomingFlag != null) return isUpcomingFlag!;
    final rd = releaseDate;
    if (rd == null) return false;
    final now = DateTime.now().toUtc();
    return rd.isAfter(now);
  }

  /// Compact “meta line” helpers the UI can use (optional).
  String get primaryMeta {
    // Prefer OTT platform for OTT items, else rating+runtime, else source.
    if ((ottPlatform ?? '').isNotEmpty) return (ottPlatform!);
    if (ratingCert != null && runtimeMinutes != null) {
      return '$ratingCert • ${runtimeMinutes}m';
    }
    return (source ?? '').isNotEmpty ? source! : kind;
  }

  String dateLabel({bool preferRelease = true}) {
    final d = preferRelease ? (releaseDate ?? publishedAt) : (publishedAt ?? releaseDate);
    if (d == null) return '';
    // Simple ISO-like short label; format human-friendly on the UI if needed.
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final da = d.day.toString().padLeft(2, '0');
    return '$y-$m-$da';
  }
}

/// Builds a playable URL when we know how to from the story metadata.
///
/// Currently supports YouTube items (source == "youtube") where the `id` is
/// "youtube:<videoId>".
Uri? storyVideoUrl(Story s) {
  final vid = s.youtubeVideoId;
  if (vid != null) {
    return Uri.parse('https://www.youtube.com/watch?v=$vid');
  }
  return null;
}
