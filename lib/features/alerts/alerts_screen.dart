// lib/features/alerts/alerts_screen.dart
//
// ALERTS TAB (theme-driven)
// ----------------------------------------------------------------------
// WIDE (≥768px):    [Home] [Search] [Saved] [Discover] [Refresh] [Menu]
// COMPACT (<768px): [Search] [Refresh] [Menu]
// Search toggles an inline row scoped to Alerts.
// Row 2 = chips + “Mark all read”; Row 2.5 = count; Body = grid.
// Colors come from Theme + theme_colors helpers (no hard-coded reds).
// ----------------------------------------------------------------------

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../widgets/search_bar.dart';
import '../../widgets/skeleton_card.dart';
import '../story/story_card.dart';
import '../../theme/theme_colors.dart'; // primaryTextColor, neutralPillBg, outlineHairline

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({
    super.key,
    this.onOpenHome,
    this.onOpenDiscover,
    this.onOpenSaved,
    this.onOpenMenu,
  });

  final VoidCallback? onOpenHome;
  final VoidCallback? onOpenDiscover;
  final VoidCallback? onOpenSaved;
  final VoidCallback? onOpenMenu;

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  static const _kPrefKey = 'alerts_last_seen';

  DateTime _lastSeenUtc =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true); // first run
  List<Story> _alerts = [];

  bool _loading = true;
  String? _error;

  bool get _hasAlerts => _alerts.isNotEmpty;

  // Category chips (0=All,1=Entertainment,2=Sports)
  int _activeCatIndex = 0;

  // Inline search row state
  bool _showSearchRow = false;
  final _searchCtl = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _searchCtl.addListener(_onSearchChanged);
    _bootstrap();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtl.removeListener(_onSearchChanged);
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _loadLastSeen();
    await _load();
  }

  Future<void> _loadLastSeen() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kPrefKey);
    if (raw != null) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) _lastSeenUtc = parsed.toUtc();
    }
  }

  Future<void> _saveLastSeen(DateTime t) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kPrefKey, t.toUtc().toIso8601String());
  }

  /// Fetch latest and keep only “new since lastSeen”.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final list = await fetchFeed(tab: 'all', since: null, limit: 80);

      final fresh = list.where((s) {
        final dt = s.publishedAt;
        return dt != null && dt.isAfter(_lastSeenUtc);
      }).toList();

      fresh.sort((a, b) {
        final pa = a.publishedAt;
        final pb = b.publishedAt;
        if (pa == null) return 1;
        if (pb == null) return -1;
        return pb.compareTo(pa);
      });

      setState(() => _alerts = fresh);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _markAllRead() async {
    final now = DateTime.now().toUtc();
    await _saveLastSeen(now);
    if (!mounted) return;
    setState(() {
      _lastSeenUtc = now;
      _alerts.clear();
    });
  }

  void _toggleSearchRow() {
    setState(() {
      _showSearchRow = !_showSearchRow;
      if (!_showSearchRow) _searchCtl.clear();
    });
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() {});
    });
  }

  void _setCategory(int i) => setState(() => _activeCatIndex = i);

  /* ───────── Grid sizing (matches Home/Saved) ───────── */

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

  /* ───────── Labels / local filter ───────── */

  String _countLabel() {
    if (_loading) return 'Checking…';
    if (_error != null) return 'Couldn’t refresh';
    final total = _alerts.length;
    if (total == 0) return 'No new alerts';
    if (total == 1) return '1 new alert';
    return '$total new alerts';
  }

  List<Story> _filteredAlerts() {
    final q = _searchCtl.text.trim().toLowerCase();
    if (q.isEmpty) return _alerts;
    return _alerts.where((s) {
      final title = s.title.toLowerCase();
      final summ = (s.summary ?? '').toLowerCase();
      return title.contains(q) || summ.contains(q);
    }).toList();
  }

  /* ───────── UI ───────── */

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= 768;

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
                    cs.surface.withOpacity(0.96),
                    cs.surface.withOpacity(0.94),
                  ],
                ),
                border: Border(
                  bottom: BorderSide(color: outlineHairline(context), width: 1),
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
                      tooltip: 'Discover',
                      icon: kIsWeb ? Icons.explore_outlined : Icons.manage_search_rounded,
                      onTap: widget.onOpenDiscover,
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

      /* ── Body ── */
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 2: chips + "Mark all read"
          _AlertsToolbarRow(
            activeIndex: _activeCatIndex,
            onCategoryTap: _setCategory,
            hasAlerts: _hasAlerts,
            loading: _loading,
            onMarkAllRead: _markAllRead,
          ),

          // Row 2.5: count
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              _countLabel(),
              style: theme.textTheme.labelMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),

          // Row 3: inline search (if toggled)
          if (_showSearchRow)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SearchBarInput(
                controller: _searchCtl,
                onExitSearch: () {
                  setState(() {
                    _searchCtl.clear();
                    _showSearchRow = false;
                  });
                  FocusScope.of(context).unfocus();
                },
              ),
            ),

          // Body: refreshable grid
          Expanded(
            child: RefreshIndicator.adaptive(
              onRefresh: _load,
              color: cs.primary,
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  final w = constraints.maxWidth;
                  final textScale = MediaQuery.textScaleFactorOf(ctx);
                  final gridDelegate = _gridDelegateFor(w, textScale);

                  const horizontalPad = 12.0;
                  const topPad = 8.0;
                  final bottomSafe = MediaQuery.viewPaddingOf(ctx).bottom;
                  final bottomPad = 28.0 + bottomSafe;

                  final visibleAlerts = _filteredAlerts();

                  if (_loading) {
                    return GridView.builder(
                      padding: EdgeInsets.fromLTRB(horizontalPad, topPad, horizontalPad, bottomPad),
                      physics: const AlwaysScrollableScrollPhysics(),
                      cacheExtent: 1800,
                      gridDelegate: gridDelegate,
                      itemCount: 9,
                      itemBuilder: (_, __) => const SkeletonCard(),
                    );
                  }

                  if (_error != null) {
                    return ListView(
                      padding: EdgeInsets.fromLTRB(horizontalPad, 24, horizontalPad, bottomPad),
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

                  if (visibleAlerts.isEmpty) {
                    return ListView(
                      padding: EdgeInsets.fromLTRB(horizontalPad, 24, horizontalPad, bottomPad),
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [ _EmptyAlerts() ],
                    );
                  }

                  return GridView.builder(
                    padding: EdgeInsets.fromLTRB(horizontalPad, topPad, horizontalPad, bottomPad),
                    physics: const AlwaysScrollableScrollPhysics(),
                    cacheExtent: 2000,
                    gridDelegate: gridDelegate,
                    itemCount: visibleAlerts.length,
                    itemBuilder: (_, i) => StoryCard(
                      story: visibleAlerts[i],
                      allStories: visibleAlerts,
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

/* ───────── Row 2: chips + “Mark all read” ───────── */

class _AlertsToolbarRow extends StatelessWidget {
  const _AlertsToolbarRow({
    required this.activeIndex,
    required this.onCategoryTap,
    required this.hasAlerts,
    required this.loading,
    required this.onMarkAllRead,
  });

  final int activeIndex;
  final ValueChanged<int> onCategoryTap;

  final bool hasAlerts;
  final bool loading;
  final VoidCallback onMarkAllRead;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    Widget inactiveChip(String label, VoidCallback onTap) {
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: cs.primary.withOpacity(0.45), width: 1),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              height: 1.2,
              color: cs.primary,
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
            color: cs.primary,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: cs.primary, width: 1),
            boxShadow: [
              BoxShadow(
                color: cs.primary.withOpacity(0.35),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.2,
              color: cs.onPrimary,
            ),
          ),
        ),
      );
    }

    Widget chip(int idx, String label) =>
        (idx == activeIndex) ? activeChip(label, idx) : inactiveChip(label, () => onCategoryTap(idx));

    Widget markAllReadPill() {
      final enabled = hasAlerts && !loading;
      final borderColor = cs.primary.withOpacity(enabled ? 0.45 : 0.20);
      final textColor  = enabled ? cs.primary : cs.primary.withOpacity(0.45);

      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: enabled ? onMarkAllRead : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(width: 1, color: borderColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.done_all_rounded, size: 16, color: textColor),
              const SizedBox(width: 6),
              Text(
                'Mark all read',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.2,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(width: 1, color: outlineHairline(context)),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // LEFT: chips
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

          // RIGHT: "Mark all read"
          markAllReadPill(),
        ],
      ),
    );
  }
}

/* ───────── Empty state ───────── */

class _EmptyAlerts extends StatelessWidget {
  const _EmptyAlerts();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.notifications_none_rounded, size: 48, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text("You're all caught up", style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(
              'New trailers, clips, and drops will show here.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/* ───────── Header CTA + brand ───────── */

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
            border: Border.all(color: outlineHairline(context), width: 1),
          ),
          child: Icon(icon, size: 16, color: cs.onSurface),
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
