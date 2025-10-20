// lib/core/models.dart
import 'dart:collection'; // for UnmodifiableListView (when callers pass it)
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

/// Domain model representing a single feed item/story.
///
/// - Accepts snake_case and camelCase from the server
/// - Safe parsing for dates/ints/bools
/// - Immutable list fields
/// - Fallback ID if backend omits one
/// - Handy derived helpers for UI (meta, flags, images)
@immutable
class Story {
  final String id;              // e.g. "youtube:GgMWu_oqJ6c" (never empty)
  final String kind;            // "trailer" | "ott" | "release" | "news" | ...
  final String title;
  final String? summary;

  final DateTime? publishedAt;  // RFC3339 → DateTime UTC
  final DateTime? releaseDate;  // theatrical/OTT release date
  final DateTime? normalizedAt; // server ingest time (optional)

  final String? source;         // e.g. "youtube"
  final String? url;            // canonical/watch URL
  final String? sourceDomain;   // e.g. "youtube.com" / "variety.com"
  final String? ottPlatform;    // e.g. "Netflix", "Prime Video"
  final String? ratingCert;     // e.g. "U", "U/A", "A"

  final int? runtimeMinutes;    // duration if known
  final List<String> languages; // immutable
  final List<String> genres;    // immutable
  final List<String> tags;      // immutable

  final String? thumbUrl;       // small image (card/list)
  final String? posterUrl;      // larger image (detail)

  // Raw flags from API (derived getters below)
  final bool? isTheatricalFlag;
  final bool? isUpcomingFlag;

  // NOTE: not `const` (we normalize lists at runtime)
  Story({
    required this.id,
    required this.kind,
    required this.title,
    this.summary,
    this.publishedAt,
    this.releaseDate,
    this.normalizedAt,
    this.source,
    this.url,
    this.sourceDomain,
    this.ottPlatform,
    this.ratingCert,
    this.runtimeMinutes,
    List<String>? languages,
    List<String>? genres,
    List<String>? tags,
    this.thumbUrl,
    this.posterUrl,
    this.isTheatricalFlag,
    this.isUpcomingFlag,
  })  : languages = _immutable(languages ?? const <String>[]),
        genres = _immutable(genres ?? const <String>[]),
        tags = _immutable(tags ?? const <String>[]);

  /* ----------------------------- parsing helpers ----------------------------- */

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v.toUtc();
    if (v is int) {
      final isMillis = v > 2000000000; // seconds→~2033; bigger likely millis
      final ms = isMillis ? v : v * 1000;
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    }
    if (v is String) {
      final s = v.trim();
      if (s.isEmpty) return null;
      try {
        // Allow trailing Z or explicit offsets.
        return DateTime.parse(s.endsWith('Z') ? s : s).toUtc();
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
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static bool? _parseBool(dynamic v) {
    if (v == null) return null;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      if (s.isEmpty) return null;
      return s == 'true' || s == '1' || s == 'yes';
    }
    return null;
  }

  static List<String> _parseStringList(dynamic v) {
    if (v == null) return const <String>[];
    if (v is Iterable) {
      return List<String>.unmodifiable(
        v.where((e) => e != null)
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty),
      );
    }
    if (v is String && v.trim().isNotEmpty) {
      final sep = v.contains('|') ? '|' : ',';
      return List<String>.unmodifiable(
        v.split(sep).map((e) => e.trim()).where((e) => e.isNotEmpty),
      );
    }
    return const <String>[];
  }

  static List<String> _immutable(List<String> v) =>
      v is UnmodifiableListView<String> ? v : List<String>.unmodifiable(v);

  static String _fallbackId(Map<String, dynamic> j, DateTime? publishedAt) {
    // If source is YouTube, try to synthesize "youtube:<id>"
    final src = (j['source'] ?? j['sourceName'] ?? '').toString().toLowerCase();
    final youtubeId = (j['youtube_id'] ?? j['video_id'])?.toString();
    if (src == 'youtube' && youtubeId != null && youtubeId.isNotEmpty) {
      return 'youtube:$youtubeId';
    }
    // Otherwise a stable-ish generated id
    final title = (j['title'] ?? '').toString();
    final ts = (publishedAt ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    return 'gen:${title.hashCode}@$ts';
  }

  static String? _domainFromUrl(String? u) {
    if (u == null || u.trim().isEmpty) return null;
    try {
      final uri = Uri.parse(u);
      var host = uri.host;
      if (host.startsWith('www.')) host = host.substring(4);
      return host.isEmpty ? null : host;
    } catch (_) {
      return null;
    }
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

    final publishedRaw  = _read('published_at', 'publishedAt');
    final releaseRaw    = _read('release_date', 'releaseDate');
    final normalizedRaw = _read('normalized_at', 'normalizedAt');

    final langsRaw  = _read('languages', 'language') ?? _read('langs');
    final genresRaw = _read('genres', 'genre');
    final tagsRaw   = _read('tags', 'tag');

    final theatrical = _read('is_theatrical', 'isTheatrical');
    final upcoming   = _read('is_upcoming', 'isUpcoming');

    final published = _parseDate(publishedRaw);
    final idRaw = _readS('id');
    final idEffective = idRaw.isNotEmpty ? idRaw : _fallbackId(j, published);

    final kindRaw = _readS('kind');
    final kindEffective = kindRaw.isNotEmpty ? kindRaw : 'news';

    final url = _readSOpt('url');
    final sourceDomainRaw = _readSOpt('source_domain', 'sourceDomain');
    final sourceDomain = sourceDomainRaw ?? _domainFromUrl(url);

    return Story(
      id: idEffective,
      kind: kindEffective,
      title: _readS('title'),
      summary: _readSOpt('summary'),

      publishedAt: published,
      releaseDate: _parseDate(releaseRaw),
      normalizedAt: _parseDate(normalizedRaw),

      source: _readSOpt('source'),
      url: url,
      sourceDomain: sourceDomain,
      ottPlatform: _readSOpt('ott_platform', 'ottPlatform'),
      ratingCert: _readSOpt('rating_cert', 'ratingCert'),

      runtimeMinutes: _parseInt(_read('runtime_minutes', 'runtimeMinutes')),
      languages: _parseStringList(langsRaw),
      genres: _parseStringList(genresRaw),
      tags: _parseStringList(tagsRaw),

      thumbUrl: _readSOpt('thumb_url', 'thumbUrl'),
      posterUrl: _readSOpt('poster_url', 'posterUrl'),

      isTheatricalFlag: _parseBool(theatrical),
      isUpcomingFlag: _parseBool(upcoming),
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
        if (normalizedAt != null)
          'normalized_at': normalizedAt!.toUtc().toIso8601String(),
        if (source != null) 'source': source,
        if (url != null) 'url': url,
        if (sourceDomain != null) 'source_domain': sourceDomain,
        if (ottPlatform != null) 'ott_platform': ottPlatform,
        if (ratingCert != null) 'rating_cert': ratingCert,
        if (runtimeMinutes != null) 'runtime_minutes': runtimeMinutes,
        if (languages.isNotEmpty) 'languages': languages,
        if (genres.isNotEmpty) 'genres': genres,
        if (tags.isNotEmpty) 'tags': tags,
        if (thumbUrl != null) 'thumb_url': thumbUrl,
        if (posterUrl != null) 'poster_url': posterUrl,
        if (isTheatricalFlag != null) 'is_theatrical': isTheatricalFlag,
        if (isUpcomingFlag != null) 'is_upcoming': isUpcomingFlag,
      };

  /* ------------------------------ derived helpers ------------------------------ */

  /// YouTube video id if this represents a YouTube video.
  /// - Prefer "youtube:<videoId>" in `id`
  /// - Else try to parse from `url` when it points to YouTube
  String? get youtubeVideoId {
    // From ID prefix
    if ((source ?? '').toLowerCase() == 'youtube') {
      final p = id.split(':');
      if (p.length >= 2 && p.first == 'youtube' && p.last.isNotEmpty) {
        return p.last;
      }
    }
    // From URL
    final u = url;
    if (u == null || u.isEmpty) return null;
    try {
      final uri = Uri.parse(u);
      final host = uri.host.toLowerCase();
      if (host.contains('youtube.com')) {
        final v = uri.queryParameters['v']; // watch?v=VIDEOID
        if (v != null && v.isNotEmpty) return v;
      } else if (host.contains('youtu.be')) {
        final seg = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
        if (seg.isNotEmpty) return seg;
      }
    } catch (_) {}
    return null;
  }

  /// Theatrical if explicit flag or kind looks like a release.
  bool get isTheatrical =>
      isTheatricalFlag ?? (kind.toLowerCase() == 'release');

  /// Upcoming if explicit flag or future release date.
  bool get isUpcoming {
    if (isUpcomingFlag != null) return isUpcomingFlag!;
    final rd = releaseDate;
    if (rd == null) return false;
    return rd.toUtc().isAfter(DateTime.now().toUtc());
  }

  /// Whether this is an OTT item (kind or presence of an OTT platform).
  bool get isOtt =>
      kind.toLowerCase() == 'ott' || ((ottPlatform ?? '').trim().isNotEmpty);

  /// Preferred card image (thumb → poster).
  String? get imageUrl => thumbUrl ?? posterUrl;

  /// Release date if present, else publishedAt.
  DateTime? get releasedOrPublished => releaseDate ?? publishedAt;

  /// Comparator: newest first (releaseDate preferred, then publishedAt).
  static int compareByRecency(Story a, Story b) {
    final da = a.releasedOrPublished;
    final db = b.releasedOrPublished;
    if (da == null && db == null) return 0;
    if (da == null) return 1; // nulls last
    if (db == null) return -1;
    return db.compareTo(da); // newest first
  }

  /// Human label for kind (title-cased), e.g., "News", "Trailer".
  String get kindLabel => _titleCase(kind);

  /// Hide origin host entirely (UI will not show a site).
  String get originHost => '';

  /// Localized pretty timestamp; falls back: published → release → normalized.
  /// Example: "20 Oct 2025, 1:59 PM"
  String get publishedAtLocalPretty {
    final d = publishedAt ?? releaseDate ?? normalizedAt;
    if (d == null) return '';
    final local = d.toLocal();
    return DateFormat('d MMM yyyy, h:mm a').format(local);
  }

  /// One-liner for meta row: "News • 20 Oct 2025, 1:59 PM"
  String get metaLine {
    final parts = <String>[kindLabel];
    final when = publishedAtLocalPretty;
    if (when.isNotEmpty) parts.add(when);
    return parts.join(' • ');
  }

  /// Compact “meta” that can still be used elsewhere if needed.
  String get primaryMeta {
    if ((ottPlatform ?? '').isNotEmpty) return _titleCase(ottPlatform!);
    if (ratingCert != null && runtimeMinutes != null) {
      return '$ratingCert • ${runtimeMinutes}m';
    }
    final s = source ?? '';
    return s.isNotEmpty ? _titleCase(s) : _titleCase(kind);
  }

  String dateLabel({bool preferRelease = true}) {
    final d = preferRelease ? (releaseDate ?? publishedAt) : (publishedAt ?? releaseDate);
    if (d == null) return '';
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final da = d.day.toString().padLeft(2, '0');
    return '$y-$m-$da';
  }

  /* -------------------------- enum facade for kind --------------------------- */

  StoryKind get kindEnum => StoryKindX.parse(kind);

  /* ------------------------------ copy & equality ----------------------------- */

  Story copyWith({
    String? id,
    String? kind,
    String? title,
    String? summary,
    DateTime? publishedAt,
    DateTime? releaseDate,
    DateTime? normalizedAt,
    String? source,
    String? url,
    String? sourceDomain,
    String? ottPlatform,
    String? ratingCert,
    int? runtimeMinutes,
    List<String>? languages,
    List<String>? genres,
    List<String>? tags,
    String? thumbUrl,
    String? posterUrl,
    bool? isTheatricalFlag,
    bool? isUpcomingFlag,
  }) {
    return Story(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      summary: summary ?? this.summary,
      publishedAt: publishedAt ?? this.publishedAt,
      releaseDate: releaseDate ?? this.releaseDate,
      normalizedAt: normalizedAt ?? this.normalizedAt,
      source: source ?? this.source,
      url: url ?? this.url,
      sourceDomain: sourceDomain ?? this.sourceDomain,
      ottPlatform: ottPlatform ?? this.ottPlatform,
      ratingCert: ratingCert ?? this.ratingCert,
      runtimeMinutes: runtimeMinutes ?? this.runtimeMinutes,
      languages: languages ?? this.languages,
      genres: genres ?? this.genres,
      tags: tags ?? this.tags,
      thumbUrl: thumbUrl ?? this.thumbUrl,
      posterUrl: posterUrl ?? this.posterUrl,
      isTheatricalFlag: isTheatricalFlag ?? this.isTheatricalFlag,
      isUpcomingFlag: isUpcomingFlag ?? this.isUpcomingFlag,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Story && runtimeType == other.runtimeType && other.id == id;

  @override
  int get hashCode => id.hashCode;

  /* -------------------------------- utilities -------------------------------- */

  static String _titleCase(String s) {
    if (s.isEmpty) return s;
    final parts = s.split(RegExp(r'[\s_\-]+'));
    return parts
        .map((p) => p.isEmpty ? p : '${p[0].toUpperCase()}${p.substring(1).toLowerCase()}')
        .join(' ');
  }
}

/// Enum-style view for `Story.kind` without changing the wire format.
enum StoryKind { trailer, ott, release, news, unknown }

extension StoryKindX on StoryKind {
  static StoryKind parse(String? s) {
    switch ((s ?? '').toLowerCase()) {
      case 'trailer':
        return StoryKind.trailer;
      case 'ott':
        return StoryKind.ott;
      case 'release':
        return StoryKind.release;
      case 'news':
        return StoryKind.news;
      default:
        return StoryKind.unknown;
    }
  }

  String get wire => switch (this) {
        StoryKind.trailer => 'trailer',
        StoryKind.ott => 'ott',
        StoryKind.release => 'release',
        StoryKind.news => 'news',
        StoryKind.unknown => 'unknown',
      };
}

/// Builds a playable URL when we can, currently for YouTube items.
Uri? storyVideoUrl(Story s) {
  final vid = s.youtubeVideoId;
  return vid == null ? null : Uri.parse('https://www.youtube.com/watch?v=$vid');
}
