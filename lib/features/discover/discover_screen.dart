// lib/features/discover/discover_screen.dart
//
// DISCOVER TAB
// ----------------------------------------------------------------------
// Header rules (same responsive CTA model as other tabs):
//
// WIDE (≥768px):
//   [Home] [Search] [Saved] [Alerts] [Refresh] [Menu]
//   - We DO NOT show a "Discover" CTA here because we're already
//     on Discover.
//
// COMPACT (<768px):
//   [Search] [Refresh] [Menu]
//   - We skip Home / Saved / Alerts in compact header because
//     the bottom nav on mobile already exposes Home / Discover / Saved / Alerts.
//
// Search CTA behavior:
//   - Tapping Search in the header toggles a dedicated inline
//     SearchBarInput row (Row 3).
//   - Closing that row clears the query.
//
// Sort behavior:
//   - Row 2 has a "Sort" pill on the right with modes:
//       Latest, Trending, Most viewed, Editor’s pick
//     (these match HomeScreen sort options).
//
// Body layout below header:
//
//   Row 2: _DiscoverToolbarRow
//          LEFT: category chips [ All / Entertainment / Sports ]
//          RIGHT: sort pill [ Trending ▼ ] etc.
//
//   Row 2.5: Count line, e.g. "24 results"
//
//   Row 3 (conditional): SearchBarInput if header Search is toggled
//          - Filters locally in this tab
//
//   Body: RefreshIndicator + responsive grid of StoryCard
//         (skeleton loading, error, empty, normal states)
//         Grid math matches Home / Saved / Alerts.
//
// Notes:
//   - Switching category chips refetches from the API with that tab
//     key ("all", "entertainment", "sports").
//   - Sort is applied client-side to the fetched results.
//   - Local search (Row 3) filters client-side.
//   - "Refresh" in header just re-runs _load() for the active category.
// ----------------------------------------------------------------------

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../widgets/search_bar.dart';
import '../../widgets/skeleton_card.dart';
import '../story/story_card.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({
    super.key,
    this.onOpenHome,
    this.onOpenSaved,
    this.onOpenAlerts,
    this.onOpenMenu,
  });

  final VoidCallback? onOpenHome;
  final VoidCallback? onOpenSaved;
  final VoidCallback? onOpenAlerts;
  final VoidCallback? onOpenMenu;

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

/* Sort modes mirror HomeScreen */
enum _SortMode {
  latest,
  trending,
  views,
  editorsPick,
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  static const _accent = Color(0xFFdc2626);

  // Category chips map directly to backend "tab" parameter.
  // 0="all", 1="entertainment", 2="sports"
  static const List<String> _tabKeys = [
    'all',
    'entertainment',
    'sports',
  ];

  // which category chip is active (0=All / 1=Entertainment / 2=Sports)
  int _activeCatIndex = 0;

  // which sort mode is active
  _SortMode _sort = _SortMode.trending; // Discover leans "Trending" by default

  // header search toggle + controller
  bool _showSearchRow = false;
  final TextEditingController _query = TextEditingController();
  Timer? _debounce;

  // network state
  bool _loading = true;
  String? _error;
  List<Story> _results = [];

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQueryChanged);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.removeListener(_onQueryChanged);
    _query.dispose();
    super.dispose();
  }

  /* ───────────────────────── Network load ───────────────────────── */

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final tabKey = _tabKeys[_activeCatIndex];
      final list = await fetchFeed(tab: tabKey, since: null, limit: 80);

      // Sort newest-first initially (like _PagedFeed._sortNewestFirst)
      final sorted = [...list];
      sorted.sort((a, b) {
        DateTime? effA =
            a.normalizedAt ?? a.publishedAt ?? a.releaseDate;
        DateTime? effB =
            b.normalizedAt ?? b.publishedAt ?? b.releaseDate;

        if (effA == null && effB == null) {
          return b.id.compareTo(a.id);
        }
        if (effA == null) return 1;
        if (effB == null) return -1;
        final cmp = effB.compareTo(effA); // newest first
        if (cmp != 0) return cmp;
        return b.id.compareTo(a.id);
      });

      setState(() {
        _results = sorted;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  /* ───────────────────────── Interaction handlers ───────────────────────── */

  void _onQueryChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() {});
    });
  }

  void _toggleSearchRow() {
    setState(() {
      _showSearchRow = !_showSearchRow;
      if (!_showSearchRow) {
        _query.clear();
      }
    });
  }

  void _setCategory(int i) {
    setState(() {
      _activeCatIndex = i;
    });
    _load();
  }

  void _setSort(_SortMode m) {
    setState(() {
      _sort = m;
    });
  }

  /* ───────────────────────── Grid sizing helper ─────────────────────────
   * SAME math as Home / Saved / Alerts so StoryCard tiles align visually.
   */
  SliverGridDelegate _gridDelegateFor(double width, double textScale) {
    int estCols;
    if (width < 520) {
      estCols = 1;
    } else if (width < 900) {
      estCols = 2;
    } else if (width < 1400) {
      estCols = 3;
    } else {
      estCols = 4;
    }

    double maxTileW = width / estCols;
    maxTileW = maxTileW.clamp(320.0, 480.0);

    double baseRatio;
    if (estCols == 1) {
      baseRatio = 0.88;
    } else if (estCols == 2) {
      baseRatio = 0.95;
    } else {
      baseRatio = 1.00;
    }

    final scaleForHeight = textScale.clamp(1.0, 1.4);
    final effectiveRatio = baseRatio / scaleForHeight;

    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxTileW,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: effectiveRatio,
    );
  }

  /* ───────────────────────── Sorting helpers ───────────────────────── */

  double _trendingScore(Story s) {
    try {
      final dyn = (s as dynamic);
      final v = dyn.trendingScore ?? dyn.score ?? dyn.rank ?? 0.0;
      if (v is num) return v.toDouble();
    } catch (_) {}
    final dt = s.normalizedAt ?? s.publishedAt ?? s.releaseDate;
    return dt?.millisecondsSinceEpoch.toDouble() ?? 0.0;
  }

  int _viewsCount(Story s) {
    try {
      final dyn = (s as dynamic);
      final v = dyn.viewCount ?? dyn.views ?? dyn.impressions ?? 0;
      if (v is num) return v.toInt();
    } catch (_) {}
    return 0;
  }

  bool _isEditorsPick(Story s) {
    try {
      final dyn = (s as dynamic);
      final v = dyn.isEditorsPick ?? dyn.editorsPick ?? dyn.editorChoice;
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) return v.toLowerCase() == 'true';
    } catch (_) {}
    return false;
  }

  List<Story> _applySortMode(List<Story> input) {
    switch (_sort) {
      case _SortMode.latest:
        return input; // list is already newest-first from _load()
      case _SortMode.trending:
        final list = [...input];
        list.sort(
          (a, b) => _trendingScore(b).compareTo(_trendingScore(a)),
        );
        return list;
      case _SortMode.views:
        final list = [...input];
        list.sort(
          (a, b) => _viewsCount(b).compareTo(_viewsCount(a)),
        );
        return list;
      case _SortMode.editorsPick:
        final picks = input.where(_isEditorsPick).toList();
        if (picks.isNotEmpty) return picks;
        return input;
    }
  }

  // Apply local search filter, then sort mode.
  List<Story> _filteredResults() {
    final q = _query.text.trim().toLowerCase();
    final base = q.isEmpty
        ? _results
        : _results.where((s) {
            final title = s.title.toLowerCase();
            final summ = (s.summary ?? '').toLowerCase();
            return title.contains(q) || summ.contains(q);
          }).toList();

    return _applySortMode(base);
  }

  /* ───────────────────────── Label helpers ───────────────────────── */

  String _countLabel() {
    if (_loading) return 'Finding the latest…';
    if (_error != null) return 'Couldn’t refresh';
    final total = _results.length;
    if (total == 0) return 'No results';
    if (total == 1) return '1 result';
    return '$total results';
  }

  /* ───────────────────────── UI BUILD ───────────────────────── */

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor =
        isDark ? const Color(0xFF0b0f17) : theme.colorScheme.surface;

    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= 768;

    return Scaffold(
      backgroundColor: bgColor,

      /* ───────── Row 1: Frosted header bar ───────── */
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(64),
        child: ClipRRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              height: 64,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isDark
                      ? [
                          const Color(0xFF1e2537).withOpacity(0.9),
                          const Color(0xFF0b0f17).withOpacity(0.95),
                        ]
                      : [
                          theme.colorScheme.surface.withOpacity(0.95),
                          theme.colorScheme.surface.withOpacity(0.9),
                        ],
                ),
                border: const Border(
                  bottom: BorderSide(
                    color: Color(0x0FFFFFFF),
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  const _ModernBrandLogo(),
                  const Spacer(),

                  // WIDE (≥768px):
                  // [Home] [Search] [Saved] [Alerts] [Refresh] [Menu]
                  if (isWide) ...[
                    _HeaderIconButton(
                      tooltip: 'Home',
                      icon: Icons.home_rounded,
                      onTap: widget.onOpenHome,
                    ),
                    const SizedBox(width: 8),

                    _HeaderIconButton(
                      tooltip: 'Search',
                      icon: Icons.search_rounded,
                      onTap: _toggleSearchRow,
                    ),
                    const SizedBox(width: 8),

                    _HeaderIconButton(
                      tooltip: 'Saved',
                      icon: Icons.bookmark_rounded,
                      onTap: widget.onOpenSaved,
                    ),
                    const SizedBox(width: 8),

                    _HeaderIconButton(
                      tooltip: 'Alerts',
                      icon: Icons.notifications_rounded,
                      onTap: widget.onOpenAlerts,
                    ),
                    const SizedBox(width: 8),

                    _HeaderIconButton(
                      tooltip: 'Refresh',
                      icon: Icons.refresh_rounded,
                      onTap: _load,
                    ),
                    const SizedBox(width: 8),

                    _HeaderIconButton(
                      tooltip: 'Menu',
                      icon: Icons.menu_rounded,
                      onTap: widget.onOpenMenu,
                    ),
                  ],

                  // COMPACT (<768px):
                  // [Search] [Refresh] [Menu]
                  if (!isWide) ...[
                    _HeaderIconButton(
                      tooltip: 'Search',
                      icon: Icons.search_rounded,
                      onTap: _toggleSearchRow,
                    ),
                    const SizedBox(width: 8),

                    _HeaderIconButton(
                      tooltip: 'Refresh',
                      icon: Icons.refresh_rounded,
                      onTap: _load,
                    ),
                    const SizedBox(width: 8),

                    _HeaderIconButton(
                      tooltip: 'Menu',
                      icon: Icons.menu_rounded,
                      onTap: widget.onOpenMenu,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),

      /* ───────── Body content ───────── */
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 2: chips + sort pill
          _DiscoverToolbarRow(
            activeIndex: _activeCatIndex,
            onCategoryTap: _setCategory,
            sortMode: _sort,
            onSortPicked: _setSort,
          ),

          // Row 2.5: count label ("24 results")
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              _countLabel(),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),

          // Row 3: inline search (only if header Search is toggled)
          if (_showSearchRow)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SearchBarInput(
                controller: _query,
                onExitSearch: () {
                  setState(() {
                    _query.clear();
                    _showSearchRow = false;
                  });
                  FocusScope.of(context).unfocus();
                },
              ),
            ),

          // Main grid / loading / error / empty
          Expanded(
            child: RefreshIndicator.adaptive(
              onRefresh: _load,
              color: _accent,
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  final w = constraints.maxWidth;
                  final textScale = MediaQuery.textScaleFactorOf(ctx);
                  final gridDelegate = _gridDelegateFor(w, textScale);

                  const horizontalPad = 12.0;
                  const topPad = 8.0;
                  final bottomSafe = MediaQuery.viewPaddingOf(ctx).bottom;
                  final bottomPad = 28.0 + bottomSafe;

                  final visible = _filteredResults();

                  // 1) Loading → skeleton grid
                  if (_loading) {
                    return GridView.builder(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPad,
                        topPad,
                        horizontalPad,
                        bottomPad,
                      ),
                      physics: const AlwaysScrollableScrollPhysics(),
                      cacheExtent: 1800,
                      gridDelegate: gridDelegate,
                      itemCount: 9,
                      itemBuilder: (_, __) => const SkeletonCard(),
                    );
                  }

                  // 2) Error → scrollable error text
                  if (_error != null) {
                    return ListView(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPad,
                        24,
                        horizontalPad,
                        bottomPad,
                      ),
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        Center(
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: theme.colorScheme.onSurface,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    );
                  }

                  // 3) Empty state
                  if (visible.isEmpty) {
                    return ListView(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPad,
                        24,
                        horizontalPad,
                        bottomPad,
                      ),
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        _EmptyDiscover(),
                      ],
                    );
                  }

                  // 4) Normal grid
                  return GridView.builder(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPad,
                      topPad,
                      horizontalPad,
                      bottomPad,
                    ),
                    physics: const AlwaysScrollableScrollPhysics(),
                    cacheExtent: 2000,
                    gridDelegate: gridDelegate,
                    itemCount: visible.length,
                    itemBuilder: (_, i) {
                      final story = visible[i];
                      return StoryCard(
                        story: story,
                        allStories: visible,
                        index: i,
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/* ───────────────────────── Row 2 under header ─────────────────────────
 *
 * _DiscoverToolbarRow:
 *   LEFT  : category chips [All / Entertainment / Sports]
 *   RIGHT : sort pill ([Trending ▼], [Latest ▼], etc.)
 *
 * Sort pill uses PopupMenuButton<_SortMode> similar to Saved tab's sort.
 */
class _DiscoverToolbarRow extends StatelessWidget {
  const _DiscoverToolbarRow({
    required this.activeIndex,
    required this.onCategoryTap,
    required this.sortMode,
    required this.onSortPicked,
  });

  final int activeIndex;
  final ValueChanged<int> onCategoryTap;

  final _SortMode sortMode;
  final ValueChanged<_SortMode> onSortPicked;

  static const _accent = Color(0xFFdc2626);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    Widget inactiveChip(String label, VoidCallback onTap) {
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: _accent.withOpacity(0.4),
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              height: 1.2,
              color: _accent,
            ),
          ),
        ),
      );
    }

    Widget activeChip(String label, int index) {
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => onCategoryTap(index),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _accent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _accent, width: 1),
            boxShadow: [
              BoxShadow(
                color: _accent.withOpacity(0.4),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.2,
              color: Colors.white,
            ),
          ),
        ),
      );
    }

    Widget chip(int index, String label) {
      final sel = (activeIndex == index);
      return sel
          ? activeChip(label, index)
          : inactiveChip(label, () => onCategoryTap(index));
    }

    // Right side pill: reflects current sort mode and opens popup menu.
    Widget sortPill() {
      IconData iconData;
      String label;

      switch (sortMode) {
        case _SortMode.latest:
          iconData = Icons.access_time_rounded;
          label = 'Latest';
          break;
        case _SortMode.trending:
          iconData = Icons.local_fire_department_rounded;
          label = 'Trending';
          break;
        case _SortMode.views:
          iconData = Icons.visibility_rounded;
          label = 'Most viewed';
          break;
        case _SortMode.editorsPick:
          iconData = Icons.star_rounded;
          label = 'Editor’s pick';
          break;
      }

      return PopupMenuButton<_SortMode>(
        tooltip: 'Sort',
        onSelected: onSortPicked,
        itemBuilder: (_) => [
          PopupMenuItem(
            value: _SortMode.latest,
            child: Row(
              children: const [
                Icon(Icons.access_time_rounded, size: 18),
                SizedBox(width: 8),
                Text('Latest first'),
              ],
            ),
          ),
          PopupMenuItem(
            value: _SortMode.trending,
            child: Row(
              children: const [
                Icon(Icons.local_fire_department_rounded, size: 18),
                SizedBox(width: 8),
                Text('Trending now'),
              ],
            ),
          ),
          PopupMenuItem(
            value: _SortMode.views,
            child: Row(
              children: const [
                Icon(Icons.visibility_rounded, size: 18),
                SizedBox(width: 8),
                Text('Most viewed'),
              ],
            ),
          ),
          PopupMenuItem(
            value: _SortMode.editorsPick,
            child: Row(
              children: const [
                Icon(Icons.star_rounded, size: 18),
                SizedBox(width: 8),
                Text('Editor’s pick'),
              ],
            ),
          ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              width: 1,
              color: _accent.withOpacity(0.4),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                iconData,
                size: 16,
                color: _accent,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.2,
                  color: _accent,
                ),
              ),
              const SizedBox(width: 2),
              const Icon(
                Icons.arrow_drop_down_rounded,
                size: 18,
                color: _accent,
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0b0f17) : theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            width: 1,
            color: isDark
                ? Colors.white.withOpacity(0.06)
                : Colors.black.withOpacity(0.06),
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // LEFT: category chips
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  chip(0, 'All'),
                  const SizedBox(width: 8),
                  chip(1, 'Entertainment'),
                  const SizedBox(width: 8),
                  chip(2, 'Sports'),
                ],
              ),
            ),
          ),

          const SizedBox(width: 12),

          // RIGHT: sort pill
          sortPill(),
        ],
      ),
    );
  }
}

/* ───────────────────────── Empty state ───────────────────────── */

class _EmptyDiscover extends StatelessWidget {
  const _EmptyDiscover();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 48,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'Nothing to discover yet',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'New trailers, clips, and drops will land here.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/* ───────────────────────── Shared header widgets ───────────────────────── */

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;

  static const _accent = Color(0xFFdc2626);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color bg = isDark
        ? const Color(0xFF0f172a).withOpacity(0.7)
        : Colors.black.withOpacity(0.06);
    final Color fg = isDark ? Colors.white : Colors.black87;

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _accent.withOpacity(0.3),
              width: 1,
            ),
          ),
          child: Icon(
            icon,
            size: 16,
            color: fg,
          ),
        ),
      ),
    );
  }
}

class _ModernBrandLogo extends StatelessWidget {
  const _ModernBrandLogo();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: const Color(0xFFdc2626),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFdc2626).withOpacity(0.4),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: const Center(
            child: Text(
              '🎬',
              style: TextStyle(
                fontSize: 16,
                height: 1,
                color: Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        const Text(
          'CinePulse',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}
