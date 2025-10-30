// lib/features/discover/discover_screen.dart
//
// DISCOVER TAB
// ----------------------------------------------------------------------
// Header (same responsive CTA model as other tabs):
// WIDE (≥768px):    [Home] [Search] [Saved] [Alerts] [Refresh] [Menu]
// COMPACT (<768px): [Search] [Refresh] [Menu]
// - No "Discover" CTA here because we’re already on Discover.
//
// Row 2  : AppToolbar (chips + Sort pill; theme-safe)
// Row 2.5: Count line ("24 results")
// Row 3  : Inline SearchBarInput (toggled by header Search)
// Body   : RefreshIndicator + responsive grid of StoryCard
// Notes  : Chips map to API tabs: all / entertainment / sports.
//          Sort applied client-side. Search filters locally.
// ----------------------------------------------------------------------

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../theme/theme_colors.dart';   // primaryTextColor, neutralPillBg, outlineHairline
import '../../widgets/app_toolbar.dart';  // shared toolbar (chips + trailing sort)
import '../../widgets/search_bar.dart';
import '../../widgets/skeleton_card.dart';
import '../story/story_card.dart';

/* Sort modes mirror Home/Saved */
enum _SortMode { latest, trending, views, editorsPick }

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

class _DiscoverScreenState extends State<DiscoverScreen> {
  // Category chips → backend tab keys
  static const List<String> _tabKeys = ['all', 'entertainment', 'sports'];
  static const List<String> _tabLabels = ['All', 'Entertainment', 'Sports'];

  // State
  int _activeCatIndex = 0;
  _SortMode _sort = _SortMode.trending; // Discover defaults to "Trending"
  bool _showSearchRow = false;
  final TextEditingController _query = TextEditingController();
  Timer? _debounce;

  bool _loading = true;
  String? _error;
  List<Story> _results = [];

  // Optional: keep keys so active chip can be scrolled into view
  final List<GlobalKey> _chipKeys =
      List.generate(_tabLabels.length, (_) => GlobalKey());

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

      // Newest-first baseline order (matches Home)
      final sorted = [...list]..sort((a, b) {
          final da = a.normalizedAt ?? a.publishedAt ?? a.releaseDate;
          final db = b.normalizedAt ?? b.publishedAt ?? b.releaseDate;
          if (da == null && db == null) return b.id.compareTo(a.id);
          if (da == null) return 1;
          if (db == null) return -1;
          final cmp = db.compareTo(da);
          return (cmp != 0) ? cmp : b.id.compareTo(a.id);
        });

      setState(() => _results = sorted);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /* ───────────────────────── Interactions ───────────────────────── */

  void _onQueryChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() {});
    });
  }

  void _toggleSearchRow() {
    setState(() {
      _showSearchRow = !_showSearchRow;
      if (!_showSearchRow) _query.clear();
    });
  }

  void _setCategory(int i) {
    if (i == _activeCatIndex) return;
    setState(() => _activeCatIndex = i);
    // Optional scroll-to-visible for the tapped chip
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _chipKeys[i].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        );
      }
    });
    _load();
  }

  Future<void> _showSortSheet() async {
    final picked = await showModalBottomSheet<_SortMode>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;

        Widget tile({
          required _SortMode value,
          required IconData icon,
          required String title,
          required String subtitle,
        }) {
          final selected = (_sort == value);
          return ListTile(
            leading: Icon(icon, color: selected ? cs.primary : cs.onSurface),
            title: Text(
              title,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: cs.onSurface,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
            trailing: selected ? Icon(Icons.check_rounded, color: cs.primary) : null,
            onTap: () => Navigator.pop(ctx, value),
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              tile(
                value: _SortMode.latest,
                icon: Icons.access_time_rounded,
                title: 'Latest first',
                subtitle: 'Newest published stories first',
              ),
              tile(
                value: _SortMode.trending,
                icon: Icons.local_fire_department_rounded,
                title: 'Trending now',
                subtitle: 'What’s getting attention',
              ),
              tile(
                value: _SortMode.views,
                icon: Icons.visibility_rounded,
                title: 'Most viewed',
                subtitle: 'Top stories by views',
              ),
              tile(
                value: _SortMode.editorsPick,
                icon: Icons.star_rounded,
                title: 'Editor’s pick',
                subtitle: 'Hand-picked highlights',
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );

    if (picked != null && picked != _sort) {
      setState(() => _sort = picked);
    }
  }

  /* ───────────────────────── Sorting / Filter ───────────────────────── */

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

  List<Story> _applySort(List<Story> input) {
    switch (_sort) {
      case _SortMode.latest:
        return input; // already newest-first
      case _SortMode.trending:
        final list = [...input]..sort((a, b) => _trendingScore(b).compareTo(_trendingScore(a)));
        return list;
      case _SortMode.views:
        final list = [...input]..sort((a, b) => _viewsCount(b).compareTo(_viewsCount(a)));
        return list;
      case _SortMode.editorsPick:
        final picks = input.where(_isEditorsPick).toList();
        return picks.isNotEmpty ? picks : input;
    }
  }

  List<Story> _visibleResults() {
    final q = _query.text.trim().toLowerCase();
    final base = q.isEmpty
        ? _results
        : _results.where((s) {
            final title = s.title.toLowerCase();
            final summ = (s.summary ?? '').toLowerCase();
            return title.contains(q) || summ.contains(q);
          }).toList();
    return _applySort(base);
  }

  String _sortLabel(_SortMode m) => switch (m) {
        _SortMode.latest => 'Latest',
        _SortMode.trending => 'Trending',
        _SortMode.views => 'Most viewed',
        _SortMode.editorsPick => 'Editor’s pick',
      };

  IconData _sortIcon(_SortMode m) => switch (m) {
        _SortMode.latest => Icons.access_time_rounded,
        _SortMode.trending => Icons.local_fire_department_rounded,
        _SortMode.views => Icons.visibility_rounded,
        _SortMode.editorsPick => Icons.star_rounded,
      };

  String _countLabel(int n) {
    if (_loading) return 'Finding the latest…';
    if (_error != null) return 'Couldn’t refresh';
    if (n == 0) return 'No results';
    if (n == 1) return '1 result';
    return '$n results';
  }

  /* ───────────────────────── Grid helper ───────────────────────── */

  SliverGridDelegate _gridDelegateFor(double width, double textScale) {
    int estCols;
    if (width < 520) estCols = 1;
    else if (width < 900) estCols = 2;
    else if (width < 1400) estCols = 3;
    else estCols = 4;

    double maxTileW = (width / estCols).clamp(320.0, 480.0);
    final baseRatio = (estCols == 1) ? 0.88 : (estCols == 2 ? 0.95 : 1.00);
    final scaleForHeight = textScale.clamp(1.0, 1.4);
    final effectiveRatio = baseRatio / scaleForHeight;

    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxTileW,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: effectiveRatio,
    );
  }

  /* ───────────────────────── UI BUILD ───────────────────────── */

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= 768;

    final visible = _visibleResults();

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,

      /* ── Row 1: Frosted header ── */
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
                  colors: [
                    cs.surface.withOpacity(0.95),
                    cs.surface.withOpacity(0.90),
                  ],
                ),
                border: Border(
                  bottom: BorderSide(
                    color: outlineHairline(context),
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  const _ModernBrandLogo(),
                  const Spacer(),

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
                  ] else ...[
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

      /* ── Body ── */
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 2: ✅ shared AppToolbar (chips + sort pill; theme-safe)
          AppToolbar(
            tabs: _tabLabels,
            activeIndex: _activeCatIndex,
            onSelect: _setCategory,
            chipKeys: _chipKeys,
            sortLabel: _sortLabel(_sort),
            sortIcon: _sortIcon(_sort),
            onSortTap: _showSortSheet,
          ),

          // Row 2.5: count
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              _countLabel(visible.length),
              style: theme.textTheme.labelMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),

          // Row 3: inline search
          if (_showSearchRow)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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

          // Grid / states
          Expanded(
            child: RefreshIndicator.adaptive(
              onRefresh: _load,
              color: cs.primary,
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  final w = constraints.maxWidth;
                  final textScale = MediaQuery.textScaleFactorOf(ctx);
                  final gridDelegate = _gridDelegateFor(w, textScale);

                  const hPad = 12.0;
                  const topPad = 8.0;
                  final bottomSafe = MediaQuery.viewPaddingOf(ctx).bottom;
                  final bottomPad = 28.0 + bottomSafe;

                  if (_loading) {
                    return GridView.builder(
                      padding: EdgeInsets.fromLTRB(hPad, topPad, hPad, bottomPad),
                      physics: const AlwaysScrollableScrollPhysics(),
                      cacheExtent: 1800,
                      gridDelegate: gridDelegate,
                      itemCount: 9,
                      itemBuilder: (_, __) => const SkeletonCard(),
                    );
                  }

                  if (_error != null) {
                    return ListView(
                      padding: EdgeInsets.fromLTRB(hPad, 24, hPad, bottomPad),
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        Center(
                          child: Text(
                            _error!,
                            style: TextStyle(color: cs.onSurface),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    );
                  }

                  if (visible.isEmpty) {
                    return ListView(
                      padding: EdgeInsets.fromLTRB(hPad, 24, hPad, bottomPad),
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [_EmptyDiscover()],
                    );
                  }

                  return GridView.builder(
                    padding: EdgeInsets.fromLTRB(hPad, topPad, hPad, bottomPad),
                    physics: const AlwaysScrollableScrollPhysics(),
                    cacheExtent: 2000,
                    gridDelegate: gridDelegate,
                    itemCount: visible.length,
                    itemBuilder: (_, i) => StoryCard(
                      story: visible[i],
                      allStories: visible,
                      index: i,
                    ),
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

/* ───────── Empty state ───────── */

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
            Icon(Icons.search_off_rounded, size: 48, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('Nothing to discover yet',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(
              'New trailers, clips, and drops will land here.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/* ───────── Shared header bits (match other tabs) ───────── */

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
            color: neutralPillBg(context),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: cs.primary.withOpacity(0.30), width: 1),
          ),
          child: Icon(icon, size: 16, color: primaryTextColor(context)),
        ),
      ),
    );
  }
}

class _ModernBrandLogo extends StatelessWidget {
  const _ModernBrandLogo();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: cs.primary,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: cs.primary.withOpacity(0.35),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Center(
            child: Text('🎬', style: TextStyle(fontSize: 16, height: 1, color: cs.onPrimary)),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'CinePulse',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: primaryTextColor(context),
          ),
        ),
      ],
    );
  }
}
