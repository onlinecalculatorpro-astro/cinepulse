// lib/core/category_prefs.dart
//
// CategoryPrefs = selected category state + toolbar helpers.
// IMPORTANT: This imports the single source of truth from
//            lib/widgets/picker_sheets.dart (kCategoryDefs, etc.)
//            so you ONLY edit categories in one place.

import 'package:flutter/foundation.dart';
import '../widgets/picker_sheets.dart'
    show
        kAllCategoryKey,
        kCategoryKeysOrdered,
        categoryLabelFor;

/// Holds the user's selected categories and exposes
/// helpers for headers/toolbars.
class CategoryPrefs extends ChangeNotifier {
  CategoryPrefs._internal();
  static final CategoryPrefs instance = CategoryPrefs._internal();

  /// Current selection (keys). Default = {'all'}.
  final Set<String> _selected = {kAllCategoryKey};

  /// Read-only view of the selection.
  Set<String> get selected => Set.unmodifiable(_selected);

  bool isSelected(String key) => _selected.contains(key);

  /// Replace selection wholesale (e.g., from the picker sheet).
  void applySelection(Set<String> incoming) {
    _selected
      ..clear()
      ..addAll(incoming);
    _normalize();
    notifyListeners();
  }

  /// Ensure valid state: if 'all' + others → only 'all';
  /// if empty → 'all'.
  void _normalize() {
    if (_selected.contains(kAllCategoryKey) && _selected.length > 1) {
      _selected
        ..clear()
        ..add(kAllCategoryKey);
      return;
    }
    if (_selected.isEmpty) {
      _selected.add(kAllCategoryKey);
    }
  }

  /// Keys to show in the toolbar, always starting with 'all'.
  /// Example: selection={'sports','travel'} → ['all','sports','travel'].
  List<String> displayKeys() {
    // Only 'all'?
    if (_selected.length == 1 && _selected.contains(kAllCategoryKey)) {
      return const [kAllCategoryKey];
    }

    // 'all' plus selected (in registry order).
    final out = <String>[kAllCategoryKey];
    for (final key in kCategoryKeysOrdered) {
      if (key == kAllCategoryKey) continue;
      if (_selected.contains(key)) out.add(key);
    }
    // Fallback safeguard
    if (out.length == 1) return const [kAllCategoryKey];
    return out;
    }

  /// Human-facing labels matching [displayKeys()].
  List<String> displayLabels() =>
      displayKeys().map(categoryLabelFor).toList();

  /// Short drawer header summary.
  /// - Only 'all'  → 'All'
  /// - One pick    → '<Label>'
  /// - Many picks  → '<First> +N'
  String summary() {
    if (_selected.contains(kAllCategoryKey)) return 'All';

    // Preserve registry order for stable, predictable summaries.
    final ordered = <String>[];
    for (final key in kCategoryKeysOrdered) {
      if (key == kAllCategoryKey) continue;
      if (_selected.contains(key)) ordered.add(key);
    }

    if (ordered.isEmpty) return 'All';
    if (ordered.length == 1) return categoryLabelFor(ordered.first);
    return '${categoryLabelFor(ordered.first)} +${ordered.length - 1}';
  }
}
