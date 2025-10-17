// lib/features/story/ott_badge.dart
//
// Small, brand-tinted badges for OTT/video platforms.
// Usage:
//   • In a card/details screen:
//       OttBadge.fromStory(story)
//     or, if you already know the platform string:
//       OttBadge(platform: 'Netflix')
//
// The widget is resilient to messy inputs like
//   "prime video", "Amazon Prime", "disney+ hotstar", "yt", etc.
// Unknown platforms gracefully fallback to a neutral chip.

import 'package:flutter/material.dart';
import '../../core/models.dart';

class OttBadge extends StatelessWidget {
  const OttBadge({
    super.key,
    this.platform,
    this.dense = false,
    this.leading, // optional custom icon to override
  });

  /// Raw platform label (e.g., "Netflix", "Prime Video").
  /// If null/empty, the badge renders nothing.
  final String? platform;

  /// Compact size (smaller padding & text).
  final bool dense;

  /// Optional custom leading icon to override the default brand icon.
  final Widget? leading;

  /// Convenience: derive platform from a Story (source/ottPlatform).
  factory OttBadge.fromStory(Story story, {bool dense = false, Widget? leading}) {
    final key = _inferPlatformKey(story);
    return OttBadge(platform: key?.label, dense: dense, leading: leading);
  }

  @override
  Widget build(BuildContext context) {
    final raw = (platform ?? '').trim();
    if (raw.isEmpty) return const SizedBox.shrink();

    final style = _resolveStyle(raw);
    if (style == null) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;

    // Subtle brand-tinted background that adapts to light/dark.
    final bg = Color.alphaBlend(style.color.withOpacity(0.12), cs.surface);
    final border = style.color.withOpacity(0.55);
    final fg = cs.onSurface;

    final pad = dense ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
                      : const EdgeInsets.symmetric(horizontal: 10, vertical: 6);

    final txtStyle = dense
        ? Theme.of(context).textTheme.labelSmall
        : Theme.of(context).textTheme.labelMedium;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: pad,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            leading ??
                Icon(style.icon, size: dense ? 14 : 16, color: style.color),
            SizedBox(width: dense ? 6 : 8),
            Text(style.label, style: txtStyle?.copyWith(color: fg)),
          ],
        ),
      ),
    );
  }
}

/* ------------------------------------------------------------------------ */
/*                          Style & Resolution logic                        */
/* ------------------------------------------------------------------------ */

class _OttStyle {
  const _OttStyle({
    required this.key,
    required this.label,
    required this.color,
    required this.icon,
    this.aliases = const <String>[],
  });

  final String key;     // normalized key e.g., "netflix"
  final String label;   // human label e.g., "Netflix"
  final Color color;    // brand tint
  final IconData icon;  // material icon approximation
  final List<String> aliases;
}

/// Brand styles + aliases.
/// Colors are approximate brand tints that work on both light & dark UIs.
const _styles = <_OttStyle>[
  _OttStyle(
    key: 'netflix',
    label: 'Netflix',
    color: Color(0xFFE50914),
    icon: Icons.local_movies_rounded,
    aliases: ['nflx', 'net flix'],
  ),
  _OttStyle(
    key: 'prime',
    label: 'Prime Video',
    color: Color(0xFF00A8E1),
    icon: Icons.play_circle_fill_rounded,
    aliases: ['amazon prime', 'primevideo', 'prime video', 'amazon'],
  ),
  _OttStyle(
    key: 'hotstar',
    label: 'Disney+ Hotstar',
    color: Color(0xFF1F80C0),
    icon: Icons.star_rounded,
    aliases: ['disney+ hotstar', 'disney hotstar', 'hotstar'],
  ),
  _OttStyle(
    key: 'youtube',
    label: 'YouTube',
    color: Color(0xFFFF0000),
    icon: Icons.play_arrow_rounded,
    aliases: ['yt', 'you tube'],
  ),
  _OttStyle(
    key: 'jiocinema',
    label: 'JioCinema',
    color: Color(0xFFFB0064),
    icon: Icons.movie_filter_rounded,
    aliases: ['jio cinema', 'jio'],
  ),
  _OttStyle(
    key: 'sonyliv',
    label: 'SonyLIV',
    color: Color(0xFF1A237E),
    icon: Icons.live_tv_rounded,
    aliases: ['sony liv', 'sony'],
  ),
  _OttStyle(
    key: 'zee5',
    label: 'ZEE5',
    color: Color(0xFF00C2A0),
    icon: Icons.blur_circular_rounded,
    aliases: ['zee 5', 'zee'],
  ),
  _OttStyle(
    key: 'apple-tv',
    label: 'Apple TV+',
    color: Color(0xFF111111),
    icon: Icons.tv_rounded,
    aliases: ['appletv', 'apple tv', 'tv+', 'apple tv plus'],
  ),
  _OttStyle(
    key: 'hulu',
    label: 'Hulu',
    color: Color(0xFF1CE783),
    icon: Icons.stream_rounded,
    aliases: [],
  ),
];

_OttStyle? _resolveStyle(String input) {
  final norm = _norm(input);
  // Exact key match.
  for (final s in _styles) {
    if (norm == s.key) return s;
  }
  // Alias match.
  for (final s in _styles) {
    for (final a in s.aliases) {
      if (_norm(a) == norm) return s;
    }
  }
  // Fuzzy contains (e.g., "watch on amazon prime")
  for (final s in _styles) {
    if (norm.contains(s.key)) return s;
    if (s.aliases.any((a) => norm.contains(_norm(a)))) return s;
  }
  return null;
}

String _norm(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

class _PlatformKey {
  const _PlatformKey(this.key, this.label);
  final String key;
  final String label;
}

/// Try to infer the platform from Story fields.
/// Priority: ottPlatform → source (for YouTube trailers) → null.
_PlatformKey? _inferPlatformKey(Story story) {
  final ott = (story.ottPlatform ?? '').trim();
  if (ott.isNotEmpty) {
    final style = _resolveStyle(ott);
    if (style != null) return _PlatformKey(style.key, style.label);
  }
  final src = (story.source ?? '').trim();
  if (src.isNotEmpty) {
    final style = _resolveStyle(src);
    if (style != null) return _PlatformKey(style.key, style.label);
  }
  // Heuristic: If kind says trailer and source missing, assume YouTube.
  if (story.kind.toLowerCase() == 'trailer') {
    final yt = _resolveStyle('youtube');
    return yt == null ? null : _PlatformKey(yt.key, yt.label);
  }
  return null;
}

/* ------------------------------------------------------------------------ */
/*                        Convenience row for multiple                      */
/* ------------------------------------------------------------------------ */

/// Show one or more platforms as a wrap of badges.
/// Provide either [platforms] or [story]. If both are given, [platforms] wins.
/// Unknown entries are skipped.
class OttBadges extends StatelessWidget {
  const OttBadges({
    super.key,
    this.platforms,
    this.story,
    this.dense = false,
    this.spacing = 8,
    this.runSpacing = 8,
  });

  final List<String>? platforms;
  final Story? story;
  final bool dense;
  final double spacing;
  final double runSpacing;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];

    if (platforms != null && platforms!.isNotEmpty) {
      for (final p in platforms!) {
        final style = _resolveStyle(p);
        if (style != null) {
          items.add(OttBadge(platform: style.label, dense: dense));
        }
      }
    } else if (story != null) {
      final k = _inferPlatformKey(story!);
      if (k != null) items.add(OttBadge(platform: k.label, dense: dense));
    }

    if (items.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: spacing, runSpacing: runSpacing, children: items);
  }
}
