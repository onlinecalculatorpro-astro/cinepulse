// lib/core/cache.dart
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// In-memory cache so other screens can render full cards quickly.
class FeedCache {
  static final Map<String, Story> _byId = {};
  static void put(Story s) => _byId[s.id] = s;
  static Story? get(String id) => _byId[id];
  static Iterable<Story> get values => _byId.values;

  /// Optional helper: bulk insert.
  static void putAll(Iterable<Story> items) {
    for (final s in items) {
      _byId[s.id] = s;
    }
  }

  /// Optional helper: clear (e.g., on logout).
  static void clear() => _byId.clear();
}

/// Lightweight disk cache for last feed per tab (offline-first start).
class FeedDiskCache {
  static String _key(String tab) => 'feed_cache_$tab';

  static Future<void> save(String tab, List<Story> items, {int maxItems = 50}) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode(items.take(maxItems).map((e) => e.toJson()).toList());
    await prefs.setString(_key(tab), payload);
  }

  static Future<List<Story>> load(String tab) async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_key(tab));
    if (s == null) return const [];
    try {
      final raw = jsonDecode(s) as List<dynamic>;
      return raw
          .map((e) => Story.fromJson((e as Map).cast<String, dynamic>()))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// Optional: nuke a tab’s cache (useful for debugging or hard refresh).
  static Future<void> clear(String tab) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(tab));
  }
}

/* ============================ SAVED (PERSIST) ============================ */

enum SavedSort { recent, title }

class SavedStore extends ChangeNotifier {
  SavedStore._();
  static final SavedStore instance = SavedStore._();

  static const _prefsKey = 'saved_ids';
  static const _metaKey = 'saved_meta_v1'; // id -> saved_at (ms)

  SharedPreferences? _prefs;
  final Set<String> _ids = <String>{};
  Map<String, int> _savedAt = <String, int>{};

  bool _ready = false;
  bool get isReady => _ready;
  Set<String> get ids => Set.unmodifiable(_ids);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final list = _prefs!.getStringList(_prefsKey) ?? const <String>[];
    _ids
      ..clear()
      ..addAll(list);
    try {
      final m = _prefs!.getString(_metaKey);
      if (m != null) {
        _savedAt = (jsonDecode(m) as Map).map(
          (k, v) => MapEntry(k.toString(), int.tryParse(v.toString()) ?? 0),
        );
      }
    } catch (_) {
      _savedAt = {};
    }
    _ready = true;
    notifyListeners();
  }

  bool isSaved(String id) => _ids.contains(id);

  void toggle(String id) {
    if (!_ids.remove(id)) {
      _ids.add(id);
      _savedAt[id] = DateTime.now().millisecondsSinceEpoch;
      _haptic();
    } else {
      _savedAt.remove(id);
      _haptic();
    }
    _persist();
    notifyListeners();
  }

  List<String> orderedIds(SavedSort sort) {
    final list = _ids.toList(growable: false);
    switch (sort) {
      case SavedSort.title:
        list.sort((a, b) {
          final sa = FeedCache.get(a)?.title ?? a;
          final sb = FeedCache.get(b)?.title ?? b;
          return sa.toLowerCase().compareTo(sb.toLowerCase());
        });
        break;
      case SavedSort.recent:
      default:
        list.sort((a, b) => (_savedAt[b] ?? 0).compareTo(_savedAt[a] ?? 0));
    }
    return list;
  }

  Future<void> clearAll() async {
    _ids.clear();
    _savedAt.clear();
    _persist();
    notifyListeners();
  }

  String exportLinks() {
    final lines = orderedIds(SavedSort.recent).map((id) {
      final s = FeedCache.get(id);
      if (s == null) return id;
      final url = storyVideoUrl(s)?.toString();
      return url ?? s.title;
    });
    return lines.join('\n');
  }

  void _persist() {
    final p = _prefs;
    if (p == null) return;
    p.setStringList(_prefsKey, _ids.toList(growable: false));
    p.setString(_metaKey, jsonEncode(_savedAt));
  }
}

void _haptic() {
  if (!kIsWeb) {
    HapticFeedback.selectionClick();
  }
}

/* ========================= RECENT SEARCH QUERIES ========================= */

/// MRU store for recent search queries used by the SearchBar.
/// - Case-insensitive de-duplication
/// - Most-recent-first ordering
/// - Capped length to avoid bloat
class RecentQueriesStore extends ChangeNotifier {
  RecentQueriesStore._();
  static final RecentQueriesStore instance = RecentQueriesStore._();

  static const _prefsKey = 'recent_queries_v1';
  static const int _maxItems = 12;

  SharedPreferences? _prefs;
  List<String> _mru = const [];

  Future<void> _ensureReady() async {
    _prefs ??= await SharedPreferences.getInstance();
    if (_mru.isEmpty) {
      _mru = _prefs!.getStringList(_prefsKey) ?? const <String>[];
    }
  }

  /// Returns a copy of the MRU list (most recent first).
  Future<List<String>> list() async {
    await _ensureReady();
    return List<String>.from(_mru);
    }

  /// Adds a query to the front (most recent), deduping case-insensitively.
  Future<void> add(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    await _ensureReady();

    // Remove any existing occurrence (case-insensitive).
    final lower = q.toLowerCase();
    _mru = _mru.where((e) => e.toLowerCase() != lower).toList(growable: true);

    // Insert at front, cap size.
    _mru.insert(0, q);
    if (_mru.length > _maxItems) {
      _mru = _mru.take(_maxItems).toList(growable: false);
    }

    await _prefs!.setStringList(_prefsKey, _mru);
    notifyListeners();
  }

  /// Removes a specific query (case-insensitive).
  Future<void> remove(String query) async {
    await _ensureReady();
    final lower = query.trim().toLowerCase();
    _mru = _mru.where((e) => e.toLowerCase() != lower).toList(growable: false);
    await _prefs!.setStringList(_prefsKey, _mru);
    notifyListeners();
  }

  /// Clears all recent queries.
  Future<void> clear() async {
    await _ensureReady();
    _mru = const [];
    await _prefs!.remove(_prefsKey);
    notifyListeners();
  }
}
