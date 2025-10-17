// lib/core/cache.dart
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// ==============================
/// In-memory cache (by Story.id)
/// ==============================
class FeedCache {
  static final Map<String, Story> _byId = <String, Story>{};

  static void put(Story s) => _byId[s.id] = s;

  /// Optional helper: bulk insert.
  static void putAll(Iterable<Story> items) {
    for (final s in items) {
      _byId[s.id] = s;
    }
  }

  static Story? get(String id) => _byId[id];

  static bool contains(String id) => _byId.containsKey(id);

  static Iterable<Story> get values =>
      List<Story>.unmodifiable(_byId.values);

  static int get size => _byId.length;

  /// Optional helper: clear (e.g., on logout).
  static void clear() => _byId.clear();
}

/// ===========================================
/// Lightweight disk cache (per-tab, offline)
/// Shape (v2):
/// { "v": 2, "ts": 1700000000000, "items": [Story...] }
/// Back-compat: also reads legacy raw List<Story>
/// ===========================================
class FeedDiskCache {
  static const int _schemaVersion = 2;

  static String _key(String tab) => 'feed_cache_$tab';
  static String _keyV(String tab) => 'feed_cache_${tab}_v$_schemaVersion';

  /// Save up to [maxItems] (newest-first recommended by caller).
  static Future<void> save(
    String tab,
    List<Story> items, {
    int maxItems = 50,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      'v': _schemaVersion,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'items': items.take(maxItems).map((e) => e.toJson()).toList(),
    };
    final s = jsonEncode(payload);

    // Write both the versioned key and (for back-compat) the old one once.
    await prefs.setString(_keyV(tab), s);
    await prefs.setString(_key(tab), s);
  }

  static Future<List<Story>> load(String tab) async {
    final prefs = await SharedPreferences.getInstance();

    // Prefer versioned
    String? s = prefs.getString(_keyV(tab)) ?? prefs.getString(_key(tab));
    if (s == null) return const <Story>[];

    try {
      final dynamic parsed = jsonDecode(s);

      // v2+ object payload
      if (parsed is Map<String, dynamic>) {
        final items = (parsed['items'] as List?) ?? const <dynamic>[];
        return List<Story>.unmodifiable(items.map((e) {
          return Story.fromJson((e as Map).cast<String, dynamic>());
        }));
      }

      // Legacy: list of Story JSONs directly
      if (parsed is List) {
        return List<Story>.unmodifiable(parsed.map((e) {
          return Story.fromJson((e as Map).cast<String, dynamic>());
        }));
      }

      return const <Story>[];
    } catch (_) {
      // Corrupt cache: clear to avoid repeated failures.
      await clear(tab);
      return const <Story>[];
    }
  }

  /// Optional: nuke a tab’s cache (useful for debugging or hard refresh).
  static Future<void> clear(String tab) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(tab));
    await prefs.remove(_keyV(tab));
  }

  /// Optional: clear caches for a set of tabs.
  static Future<void> clearAll(Iterable<String> tabs) async {
    final prefs = await SharedPreferences.getInstance();
    for (final tab in tabs) {
      await prefs.remove(_key(tab));
      await prefs.remove(_keyV(tab));
    }
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
  Set<String> get ids => Set<String>.unmodifiable(_ids);

  Future<void> init() async {
    if (_ready) return;
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
      _savedAt = <String, int>{};
    }
    _ready = true;
    notifyListeners();
  }

  bool isSaved(String id) => _ids.contains(id);

  /// Toggle save/unsave; also records saved-at millis.
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

  /// Explicit setter (useful for bulk ops).
  void setSaved(String id, bool saved) {
    if (saved && !_ids.contains(id)) {
      _ids.add(id);
      _savedAt[id] = DateTime.now().millisecondsSinceEpoch;
    } else if (!saved && _ids.remove(id)) {
      _savedAt.remove(id);
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

  /// Export a newline-separated list of links (when available) or titles.
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
  List<String> _mru = const <String>[];

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

  /// Simple prefix suggestions (case-insensitive).
  Future<List<String>> suggest(String prefix) async {
    await _ensureReady();
    final p = prefix.trim().toLowerCase();
    if (p.isEmpty) return List<String>.from(_mru);
    return _mru.where((e) => e.toLowerCase().startsWith(p)).toList();
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

  /// Moves an existing query to the front (if present).
  Future<void> touch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    await _ensureReady();

    final lower = q.toLowerCase();
    final exists = _mru.any((e) => e.toLowerCase() == lower);
    if (!exists) return;

    _mru = _mru.where((e) => e.toLowerCase() != lower).toList(growable: true);
    _mru.insert(0, q);
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
    _mru = const <String>[];
    await _prefs!.remove(_prefsKey);
    notifyListeners();
  }
}
