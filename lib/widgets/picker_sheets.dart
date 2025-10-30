// lib/widgets/picker_sheets.dart
//
// Reusable bottom sheets used by RootShell:
//  • ThemePickerSheet       -> returns ThemeMode
//  • CategoryPickerSheet    -> returns Set<String> of category KEYS
//  • ContentTypePickerSheet -> returns String ('all'|'read'|'video'|'audio')
//
// Neutral styling; no hardcoded reds.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// ───────────────────────────────────────────────────────────────────────────
/// CATEGORY REGISTRY — SINGLE SOURCE OF TRUTH
/// Edit this list ONLY to add/remove/rename categories.
/// Order here is the display order in toolbars and pickers.
/// Keep the first item as the "All" catch-all.
/// ───────────────────────────────────────────────────────────────────────────
class CategoryDef {
  final String key;         // e.g. 'sports'
  final String label;       // e.g. 'Sports'
  final IconData icon;      // UI icon for sheets
  final String description; // one-line hint in picker
  const CategoryDef({
    required this.key,
    required this.label,
    required this.icon,
    required this.description,
  });
}

const List<CategoryDef> kCategoryDefs = <CategoryDef>[
  CategoryDef(
    key: 'all',
    label: 'All',
    icon: Icons.apps_rounded,
    description: 'Everything we have (Entertainment)',
  ),
  CategoryDef(
    key: 'entertainment',
    label: 'Entertainment',
    icon: Icons.local_movies_rounded,
    description: 'Movies, OTT, on-air drama, box office',
  ),
  CategoryDef(
    key: 'sports',
    label: 'Sports',
    icon: Icons.sports_cricket_rounded,
    description: 'Match talk, highlights (coming soon)',
  ),
  CategoryDef(
    key: 'travel',
    label: 'Travel',
    icon: Icons.flight_takeoff_rounded,
    description: 'Trips, destinations, culture clips (coming soon)',
  ),
  CategoryDef(
    key: 'fashion',
    label: 'Fashion',
    icon: Icons.checkroom_rounded,
    description: 'Looks, red carpet, style drops (coming soon)',
  ),
];

/// Helpers other files can import (no duplication anywhere).
String get kAllCategoryKey => kCategoryDefs.first.key;
List<String> get kCategoryKeysOrdered =>
    List.unmodifiable(kCategoryDefs.map((d) => d.key));
List<String> get kCategoryLabelsOrdered =>
    List.unmodifiable(kCategoryDefs.map((d) => d.label));
String categoryLabelFor(String key) =>
    kCategoryDefs.firstWhere(
      (d) => d.key == key,
      orElse: () => kCategoryDefs.first,
    ).label;
CategoryDef categoryDefFor(String key) =>
    kCategoryDefs.firstWhere(
      (d) => d.key == key,
      orElse: () => kCategoryDefs.first,
    );

/// THEME ─────────────────────────────────────────────────────────────────────
class ThemePickerSheet extends StatelessWidget {
  const ThemePickerSheet({super.key, required this.current});
  final ThemeMode current;

  @override
  Widget build(BuildContext context) {
    final options = <ThemeMode, ({String label, IconData icon})>{
      ThemeMode.system: (label: 'System', icon: Icons.auto_awesome),
      ThemeMode.light: (label: 'Light', icon: Icons.light_mode_outlined),
      ThemeMode.dark: (label: 'Dark', icon: Icons.dark_mode_outlined),
    };

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Theme',
              style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text('Affects Home and story cards.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            for (final entry in options.entries)
              RadioListTile<ThemeMode>(
                value: entry.key,
                groupValue: current,
                onChanged: (val) => Navigator.pop(context, val),
                title: Row(
                  children: [
                    Icon(entry.value.icon, size: 18),
                    const SizedBox(width: 8),
                    Text(entry.value.label),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// CATEGORIES ────────────────────────────────────────────────────────────────
/// Returns a Set<String> of KEYS selected by the user.
/// Consumes kCategoryDefs so registry stays single-source.
class CategoryPickerSheet extends StatefulWidget {
  const CategoryPickerSheet({super.key, required this.initial});
  final Set<String> initial;

  @override
  State<CategoryPickerSheet> createState() => _CategoryPickerSheetState();
}

class _CategoryPickerSheetState extends State<CategoryPickerSheet> {
  late Set<String> _local;

  @override
  void initState() {
    super.initState();
    _local = widget.initial.isEmpty ? {kAllCategoryKey} : Set<String>.of(widget.initial);
  }

  void _toggle(String key) {
    if (key == kAllCategoryKey) {
      _local..clear()..add(kAllCategoryKey);
    } else {
      if (_local.contains(key)) {
        _local.remove(key);
      } else {
        _local..remove(kAllCategoryKey)..add(key);
      }
      if (_local.isEmpty) _local.add(kAllCategoryKey);
    }
    setState(() {});
  }

  bool _checked(String key) => _local.contains(key);

  Widget _catRow(CategoryDef def) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = _checked(def.key);

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _toggle(def.key),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: active,
              onChanged: (_) => _toggle(def.key),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            ),
            const SizedBox(width: 8),
            Icon(def.icon, size: 20,
                color: active ? scheme.primary : scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(def.label,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  Text(def.description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Categories',
              style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text('Pick what you want in your feed. We mostly cover Entertainment right now.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),

            // Render all categories in the registry (in order)
            for (final def in kCategoryDefs) _catRow(def),

            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.check_rounded),
                label: const Text('Apply'),
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.primary,
                  foregroundColor: scheme.onPrimary,
                  textStyle: const TextStyle(fontWeight: FontWeight.w600),
                ),
                onPressed: () => Navigator.pop(context, _local),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// CONTENT TYPE ──────────────────────────────────────────────────────────────
/// Returns one of: 'all' | 'read' | 'video' | 'audio'
class ContentTypePickerSheet extends StatefulWidget {
  const ContentTypePickerSheet({super.key, required this.current});
  final String current;

  @override
  State<ContentTypePickerSheet> createState() => _ContentTypePickerSheetState();
}

class _ContentTypePickerSheetState extends State<ContentTypePickerSheet> {
  late String _local;

  @override
  void initState() {
    super.initState();
    _local = widget.current;
  }

  void _pick(String v) => setState(() => _local = v);

  Widget _tile({required String value, required String title, required String desc}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = (_local == value);

    return RadioListTile<String>(
      value: value,
      groupValue: _local,
      onChanged: (val) => _pick(val ?? value),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
          Text(desc, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Content type',
              style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text('Choose what format you prefer first.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),

            _tile(value: 'all',   title: 'All',   desc: 'Everything'),
            _tile(value: 'read',  title: 'Read',  desc: 'Text / captions'),
            _tile(value: 'video', title: 'Video', desc: 'Clips, trailers, interviews'),
            _tile(value: 'audio', title: 'Audio', desc: 'Pod bites (coming soon)'),

            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.check_rounded),
                label: const Text('Apply'),
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.primary,
                  foregroundColor: scheme.onPrimary,
                  textStyle: const TextStyle(fontWeight: FontWeight.w600),
                ),
                onPressed: () => Navigator.pop(context, _local),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
