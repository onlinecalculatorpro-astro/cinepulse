// lib/widgets/picker_sheets.dart
//
// Reusable bottom sheets used by RootShell:
//  • ThemePickerSheet       -> returns ThemeMode
//  • CategoryPickerSheet    -> returns Set<String>
//  • ContentTypePickerSheet -> returns String ('all'|'read'|'video'|'audio')
//
// Neutral styling; no hardcoded reds.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// THEME ──────────────────────────────────────────────────────────────────────
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
/// Uses the same keys as RootShell.CategoryPrefs: 'all','entertainment','sports','travel','fashion'.
class CategoryPickerSheet extends StatefulWidget {
  const CategoryPickerSheet({super.key, required this.initial});
  final Set<String> initial;

  @override
  State<CategoryPickerSheet> createState() => _CategoryPickerSheetState();
}

class _CategoryPickerSheetState extends State<CategoryPickerSheet> {
  late Set<String> _local;
  static const _kAll = 'all';

  @override
  void initState() {
    super.initState();
    _local = Set<String>.of(widget.initial);
  }

  void _toggle(String key) {
    if (key == _kAll) {
      _local..clear()..add(_kAll);
    } else {
      _local.contains(key) ? _local.remove(key) : _local.add(key);
      _local.remove(_kAll);
      if (_local.isEmpty) _local.add(_kAll);
    }
    setState(() {});
  }

  bool _checked(String key) => _local.contains(key);

  Widget _row({
    required String key,
    required IconData icon,
    required String title,
    required String desc,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = _checked(key);

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _toggle(key),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: active,
              onChanged: (_) => _toggle(key),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            ),
            const SizedBox(width: 8),
            Icon(icon, size: 20, color: active ? scheme.primary : scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  Text(desc,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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

            _row(key: 'all',            icon: Icons.apps_rounded,             title: 'All',            desc: 'Everything we have (Entertainment)'),
            _row(key: 'entertainment',  icon: Icons.local_movies_rounded,     title: 'Entertainment',  desc: 'Movies, OTT, on-air drama, box office'),
            _row(key: 'sports',         icon: Icons.sports_cricket_rounded,   title: 'Sports',         desc: 'Match talk, highlights (coming soon)'),
            _row(key: 'travel',         icon: Icons.flight_takeoff_rounded,   title: 'Travel',         desc: 'Trips, destinations, culture clips (coming soon)'),
            _row(key: 'fashion',        icon: Icons.checkroom_rounded,        title: 'Fashion',        desc: 'Looks, red carpet, style drops (coming soon)'),

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
