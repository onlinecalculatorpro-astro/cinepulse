import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// In-memory cache so other screens can render full cards.
class FeedCache {
  static final Map<String, Story> _byId = {};
  static void put(Story s) => _byId[s.id] = s;
  static Story? get(String id) => _byId[id];
  static Iterable<Story> get values => _byId.values;
}

/// Lightweight disk cache for last feed per tab (offline-first start).
class FeedDiskCache {
  static String _key(String tab) => 'feed_cache_$tab';

  static Future<void> save(String tab, List<Story> items,
      {int maxItems = 50}) async {
    final prefs = await SharedPreferences.getInstance();
    final payload =
        jsonEncode(items.take(maxItems).map((e) => e.toJson()).toList());
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
          .toList();
    } catch (_) {
      return const [];
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

  late SharedPreferences _prefs;
  final Set<String> _ids = <String>{};
  Map<String, int> _savedAt = <String, int>{};

  bool _ready = false;
  bool get isReady => _ready;
  Set<String> get ids => Set.unmodifiable(_ids);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final list = _prefs.getStringList(_prefsKey) ?? const <String>[];
    _ids
      ..clear()
      ..addAll(list);
    try {
      final m = _prefs.getString(_metaKey);
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
    _prefs.setStringList(_prefsKey, _ids.toList(growable: false));
    _prefs.setString(_metaKey, jsonEncode(_savedAt));
  }
}

void _haptic() {
  if (!kIsWeb) {
    HapticFeedback.selectionClick();
  }
}
