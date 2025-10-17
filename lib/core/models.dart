// lib/core/models.dart
import 'package:flutter/foundation.dart';

/// Domain model representing a single feed item/story.
///
/// Accepts both snake_case and camelCase from server payloads.
/// Extra resilience:
/// - Tolerant date/int parsing
/// - Immutable list fields
/// - Fallback ID generation if server omits id
/// - Derived helpers for UI (meta, flags, images, comparators)
@immutable
class Story {
  final String id;              // e.g. "youtube:GgMWu_oqJ6c" (never empty)
  final String kind;            // "trailer" | "ott" | "release" | "news" | ...
  final String title;
  final String? summary;

  final DateTime? publishedAt;  // RFC3339 → DateTime UTC
  final DateTime? releaseDate;  // theatrical/OTT release date, if known

  final String? source;         // e.g. "youtube"
  final String? ottPlatform;    // e.g. "netflix", "prime", "hotstar"
  final String? ratingCert;     // e.g. "U", "U/A", "A" (India)

  final int? runtimeMinutes;    // duration if known
  final List<String> languages; // ISO-ish names (e.g., ["hi","en"]) (immutable)
  final List<String> genres;    // e.g., ["Action","Drama"] (immutable)

  final String? thumbUrl;       // small image (card/list)
  final String? posterUrl;      // larger poster (detail)

  // Flags as sent by server; we also provide derived getters.
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
    List<String> languages = const [],
    List<String> genres = const [],
    this.thumbUrl,
    this.posterUrl,
    this.isTheatricalFlag,
    this.isUpcomingFlag,
  })  : languages = _immutable(languages),
        genres = _immutable(genres);

  // ---------- Parsing helpers ----------

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v.toUtc();
    if (v is int) {
      // Epoch seconds/millis heuristic
      final isMillis = v > 2000000000; // ~2033 in seconds; larger ⇒ millis
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
      return int.tryParse(t);
    }
    return null;
  }

  static List<String> _parseStringList(dynamic v) {
    if (v == null) return const <String>[];
    if (v is List) {
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
    // Attempt common alternates first
    final youtubeId = (j['youtube_id'] ?? j['video_id'])?.toString();
    if ((j['source']?.toString().toLowerCase() ?? '') == 'youtube' &&
        youtubeId != null &&
        youtubeId.isNotEmpty) {
      return 'youtube:$youtubeId';
    }

    final title = (j['title'] ?? '').toString();
    final ts = (publishedAt ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    // Deterministic-ish fallback (not globally unique but stable enough for UI)
    return 'gen:${title.hashCode}@$ts';
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

    final langs     = _read('languages', 'language') ?? _read('langs');
    final gens      = _read('genres', 'genre');

    final theatrical = _read('is_theatrical', 'isTheatrical');
    final upcoming   = _read('is_upcoming', 'isUpcoming');

    final parsedPublished = _parseDate(published);
    final idRaw = _readS('id');
    final idEffective = idRaw.isNotEmpty ? idRaw : _fallbackId(j, parsedPublished);

    final kindRaw = _readS('kind');
    final kindEffective = kindRaw.isNotEmpty ? kindRaw : 'news';

    return Story(
      id: idEffective,
      kind: kindEffective,
      title: _readS('title'),
      summary: _readSOpt('summary'),
      publishedAt: parsedPublished,
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

  // ---------- Derived helpers ----------

  /// YouTube video id if this is a YouTube story ("youtube:<videoId>").
  String? get youtubeVideoId {
    if ((source ?? '').toLowerCase() == 'youtube') {
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

  /// Whether this is an OTT item (kind or presence of an OTT platform).
  bool get isOtt =>
      kind.toLowerCase() == 'ott' ||
      ((ottPlatform ?? '').trim().isNotEmpty);

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

  /// Compact “meta line” helpers the UI can use.
  String get primaryMeta {
    // Prefer OTT platform (title-cased) else rating+runtime, else source or kind.
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

  // ---------- Lightweight enum view (keeps JSON kind as String) ----------

  StoryKind get kindEnum => StoryKindX.parse(kind);

  // ---------- Mutability helpers ----------

  Story copyWith({
    String? id,
    String? kind,
    String? title,
    String? summary,
    DateTime? publishedAt,
    DateTime? releaseDate,
    String? source,
    String? ottPlatform,
    String? ratingCert,
    int? runtimeMinutes,
    List<String>? languages,
    List<String>? genres,
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
      source: source ?? this.source,
      ottPlatform: ottPlatform ?? this.ottPlatform,
      ratingCert: ratingCert ?? this.ratingCert,
      runtimeMinutes: runtimeMinutes ?? this.runtimeMinutes,
      languages: languages ?? this.languages,
      genres: genres ?? this.genres,
      thumbUrl: thumbUrl ?? this.thumbUrl,
      posterUrl: posterUrl ?? this.posterUrl,
      isTheatricalFlag: isTheatricalFlag ?? this.isTheatricalFlag,
      isUpcomingFlag: isUpcomingFlag ?? this.isUpcomingFlag,
    );
  }

  // Equality: treat same id as same story (common for feeds)
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Story && runtimeType == other.runtimeType && other.id == id;

  @override
  int get hashCode => id.hashCode;

  // ---------- Private helpers ----------

  static String _titleCase(String s) {
    if (s.isEmpty) return s;
    final parts = s.split(RegExp(r'[\s_\-]+'));
    return parts
        .map((p) => p.isEmpty
            ? p
            : '${p[0].toUpperCase()}${p.substring(1).toLowerCase()}')
        .join(' ');
  }
}

/// Enum-style view for `Story.kind` without changing wire format.
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

  String get wire =>
      switch (this) { StoryKind.trailer => 'trailer', StoryKind.ott => 'ott', StoryKind.release => 'release', StoryKind.news => 'news', StoryKind.unknown => 'unknown' };
}

/// Builds a playable URL when we know how to from the story metadata.
/// Currently supports YouTube items (source == "youtube") where the `id` is
/// "youtube:<videoId>".
Uri? storyVideoUrl(Story s) {
  final vid = s.youtubeVideoId;
  if (vid != null) {
    return Uri.parse('https://www.youtube.com/watch?v=$vid');
  }
  return null;
}
