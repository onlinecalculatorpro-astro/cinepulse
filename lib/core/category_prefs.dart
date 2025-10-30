// lib/core/category_prefs.dart
//
// Single source of truth for categories + user selection.
// - Define categories once (CategoryRegistry).
// - Picker, toolbar, headers, etc. read from here.
// - Selection is normalized (keeps 'all' semantics) and persisted.

import 'dart:async' show scheduleMicrotask;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kCatPrefsKey = 'cp.categories';

/// A single category definition (key + UI metadata).
class CategoryDef {
  final String key;
  final String label;
  final IconData icon;
  final String desc;
  const CategoryDef({
    required this.key,
    required this.label,
    required this.icon,
    required this.desc,
  });
}

/// Central registry for all categories (order controls display order).
class CategoryRegistry {
  static const List<CategoryDef> ordered = [
    CategoryDef(
      key: 'all',
      label: 'All',
      icon: Icons.apps_rounded,
      desc: 'Everything we have (Entertainment)',
    ),
    CategoryDef(
      key: 'entertainment',
      label: 'Entertainment',
      icon: Icons.local_movies_rounded,
      desc: 'Movies, OTT, on-air drama, box office',
    ),
    CategoryDef(
      key: 'sports',
      label: 'Sports',
      icon: Icons.sports_cricket_rounded,
      desc: 'Match talk, highlights (coming soon)',
    ),
    CategoryDef(
      key: 'travel',
      label: 'Travel',
      icon: Icons.flight_takeoff_rounded,
      desc: 'Trips, destinations, culture clips (coming soon)',
    ),
    CategoryDef(
      key: 'fashion',
      label: 'Fashion',
      icon: Icons.checkroom_rounded,
      desc: 'Looks, red carpet, style drops (coming soon)',
    ),
  ];

  static List<String> get keysOrdered =>
      List.unmodifiable(ordered.map((d) => d.key));

  static bool isKnown(String key) =>
      ordered.any((d) => d.key == key);

  static CategoryDef of(String key) =>
      ordered.firstWhere((d) => d.key == key, orElse: () => ordered.first);

  static String labelOf(String key) => of(key).label;
  static IconData iconOf(String key) => of(key).icon;
  static String descOf(String key) => of(key).desc;
}

/// Convenience exports for callers that only need read helpers.
const String kAllCategoryKey = 'all';
List<String> get kCategoryKeysOrdered => CategoryRegistry.keysOrdered;
String categoryLabelFor(String key) => CategoryRegistry.labelOf(key);
IconData categoryIconFor(String key) => CategoryRegistry.iconOf(key);
String categoryDescFor(String key) => CategoryRegistry.descOf(key);

/// Holds user's selected categories; persists to SharedPreferences.
class CategoryPrefs extends ChangeNotifier {
  CategoryPrefs._internal();
  static final CategoryPrefs instance = CategoryPrefs._internal();

  final Set<String> _selected = {kAllCategoryKey};
  Set<String> get selected => Set.unmodifiable(_selected);

  /// Load persisted selection (call once during app bootstrap).
  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    final saved = sp.getStringList(_kCatPrefsKey);
    if (saved == null || saved.isEmpty) return;

    _selected
      ..clear()
      ..addAll(saved.where(CategoryRegistry.isKnown));
    _normalize();
    notifyListeners();
  }

  bool isSelected(String key) => _selected.contains(key);

  /// Replace selection wholesale (e.g., from picker).
  void applySelection(Set<String> incoming) {
    _selected
      ..clear()
      ..addAll(incoming.where(CategoryRegistry.isKnown));
    _normalize();
    // Persist without blocking UI frame.
    scheduleMicrotask(_save);
    notifyListeners();
  }

  /// Keys for toolbar chips, always starting with 'all'.
  /// Example: {'sports','travel'} → ['all','sports','travel'].
  List<String> displayKeys() {
    if (_selected.length == 1 && _selected.contains(kAllCategoryKey)) {
      return const [kAllCategoryKey];
    }
    final out = <String>[kAllCategoryKey];
    for (final key in CategoryRegistry.keysOrdered) {
      if (key == kAllCategoryKey) continue;
      if (_selected.contains(key)) out.add(key);
    }
    return out.isNotEmpty ? out : const [kAllCategoryKey];
  }

  /// Labels matching [displayKeys()].
  List<String> displayLabels() =>
      displayKeys().map(CategoryRegistry.labelOf).toList();

  /// Drawer/header summary:
  /// - Only 'all'  → 'All'
  /// - One pick    → '<Label>'
  /// - Many picks  → '<First> +N'
  String summary() {
    if (_selected.contains(kAllCategoryKey)) return 'All';
    final ordered = <String>[];
    for (final key in CategoryRegistry.keysOrdered) {
      if (key == kAllCategoryKey) continue;
      if (_selected.contains(key)) ordered.add(key);
    }
    if (ordered.isEmpty) return 'All';
    if (ordered.length == 1) return CategoryRegistry.labelOf(ordered.first);
    return '${CategoryRegistry.labelOf(ordered.first)} +${ordered.length - 1}';
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Internals
  // ──────────────────────────────────────────────────────────────────────────

  void _normalize() {
    // If 'all' is mixed with others → keep only 'all'.
    if (_selected.contains(kAllCategoryKey) && _selected.length > 1) {
      _selected
        ..clear()
        ..add(kAllCategoryKey);
    }
    // Never allow empty.
    if (_selected.isEmpty) _selected.add(kAllCategoryKey);
  }

  Future<void> _save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_kCatPrefsKey, _selected.toList());
  }
}
