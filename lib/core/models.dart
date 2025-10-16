// lib/core/models.dart
import 'package:flutter/foundation.dart';

/// Domain model representing a single feed item/story.
///
/// The backend returns snake_case keys (e.g. `published_at`, `thumb_url`).
/// This model accepts both snake_case and camelCase to be resilient to any
/// older/local data you might have lying around.
@immutable
class Story {
  final String id; // e.g. "youtube:GgMWu_oqJ6c"
  final String kind; // "trailer" | "ott" | "release" | ...
  final String title;
  final String? summary;
  final DateTime? publishedAt; // parsed from RFC3339 string
  final String? source; // e.g. "youtube"
  final String? thumbUrl;

  const Story({
    required this.id,
    required this.kind,
    required this.title,
    this.summary,
    this.publishedAt,
    this.source,
    this.thumbUrl,
  });

  /// Robust DateTime parse that tolerates a few formats.
  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is int) {
      // Epoch seconds/millis—best effort
      final isMillis = v > 2000000000; // ~2033 in seconds; anything larger is millis
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

  /// Accepts both snake_case and camelCase keys.
  factory Story.fromJson(Map<String, dynamic> j) {
    String _readS(String a, [String? b]) =>
        (j[a] ?? (b != null ? j[b] : null))?.toString() ?? '';

    String? _readSOpt(String a, [String? b]) {
      final v = j[a] ?? (b != null ? j[b] : null);
      return v == null ? null : v.toString();
    }

    final published =
        j.containsKey('published_at') ? j['published_at'] : j['publishedAt'];
    final thumb =
        j.containsKey('thumb_url') ? j['thumb_url'] : j['thumbUrl'];

    return Story(
      id: _readS('id'),
      kind: _readS('kind'),
      title: _readS('title'),
      summary: _readSOpt('summary'),
      publishedAt: _parseDate(published),
      source: _readSOpt('source'),
      thumbUrl: _readSOpt('thumb_url', 'thumbUrl'),
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
        if (source != null) 'source': source,
        if (thumbUrl != null) 'thumb_url': thumbUrl,
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
