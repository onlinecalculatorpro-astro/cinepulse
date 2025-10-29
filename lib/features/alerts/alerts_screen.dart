// lib/features/alerts/alerts_screen.dart
//
// ALERTS TAB
// ----------------------------------------------------------------------
// Header rules (global CTA model):
//
// WIDE (≥768px):
//   [Home] [Search] [Saved] [Discover] [Refresh] [Menu]
//   - We do NOT show "Alerts" in the header because we're already on Alerts.
//
// COMPACT (<768px):
//   [Search] [Refresh] [Menu]
//   - We skip Home / Saved / Discover in compact mode because bottom nav
//     already exposes Home / Discover / Saved / Alerts.
//
// Search CTA behavior:
//   - Tapping Search in the header toggles a dedicated inline search row
//     (Row 3 below the chips + count line), scoped to Alerts only.
//   - Closing that row clears the query.
//
// Layout structure:
//
//   Row 1 (header): CinePulse brand + CTAs above
//
//   Row 2: _AlertsToolbarRow
//          LEFT  = category chips [All / Entertainment / Sports]
//          RIGHT = "Mark all read" pill
//
//   Row 2.5: count line, e.g. "3 new alerts"
//
//   Row 3 (conditional): inline SearchBarInput (only if header Search toggled)
//          - Filters the visible alerts list locally
//
//   Body: pull-to-refresh + grid of unread alerts
//
// Other behavior:
//   • "Mark all read" advances lastSeen, clears current list.
//   • Refresh icon is in header, not in Row 2.
//   • Grid sizing math matches Home and Saved so StoryCard tiles line up.
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
import '../../theme/theme_colors.dart';

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
  static const _accent = Color(0xFFdc2626);

  // Last time user "marked all read" (UTC).
  DateTime _lastSeenUtc =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true); // first run

  // Stories published after _lastSeenUtc.
  List<Story> _alerts = [];

  bool _loading = true;
  String? _error;

  bool get _hasAlerts => _alerts.isNotEmpty;

  // Category chip state (0=All,1=Entertainment,2=Sports).
  int _activeCatIndex = 0;

  // Inline search row toggle + controller.
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
      if (parsed != null) {
        _lastSeenUtc = parsed.toUtc();
      }
    }
  }

  Future<void> _saveLastSeen(DateTime t) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kPrefKey, t.toUtc().toIso8601String());
  }

  /// Fetch latest feed and keep only "new since lastSeen".
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

      // newest first
      fresh.sort((a, b) {
        final pa = a.publishedAt;
        final pb = b.publishedAt;
        if (pa == null) return 1;
        if (pb == null) return -1;
        return pb.compareTo(pa);
      });

      setState(() {
        _alerts = fresh;
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
      if (!_showSearchRow) {
        _searchCtl.clear();
      }
    });
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() {});
    });
  }

  void _setCategory(int i) {
    setState(() {
      _activeCatIndex = i;
    });
    // (future: actually filter by category here)
  }

  /* ───────────────────────── Grid sizing helper ─────────────────────────
   * SAME math as Home and Saved tabs so StoryCard tiles line up.
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

  /* ───────────────────────── Label helpers ───────────────────────── */

  String _countLabel() {
    if (_loading) return 'Checking…';
    if (_error != null) return 'Couldn’t refresh';
    final total = _alerts.length;
    if (total == 0) return 'No new alerts';
    if (total == 1) return '1 new alert';
    return '$total new alerts';
  }

  // apply local search filter
  List<Story> _filteredAlerts() {
    final q = _searchCtl.text.trim().toLowerCase();
    if (q.isEmpty) return _alerts;
    return _alerts.where((s) {
      final title = s.title.toLowerCase();
      final summ = (s.summary ?? '').toLowerCase();
      return title.contains(q) || summ.contains(q);
    }).toList();
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

      /* ───────── Row 1: Frosted CinePulse header ───────── */
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
                  // [Home] [Search] [Saved] [Discover] [Refresh] [Menu]
                  // (No "Alerts" CTA because we're already here.)
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
                      icon: kIsWeb
                          ? Icons.explore_outlined
                          : Icons.manage_search_rounded,
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

      /* ───────── Body ───────── */
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 2: category chips + "Mark all read"
          _AlertsToolbarRow(
            activeIndex: _activeCatIndex,
            onCategoryTap: _setCategory,
            hasAlerts: _hasAlerts,
            loading: _loading,
            onMarkAllRead: _markAllRead,
          ),

          // Row 2.5: count line ("3 new alerts")
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              _countLabel(),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),

          // Row 3: inline search bar (if toggled)
          if (_showSearchRow)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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

          // Body: refreshable grid / states
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

                  final visibleAlerts = _filteredAlerts();

                  // 1) Loading -> skeleton grid
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

                  // 2) Error -> simple scrollable error view
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

                  // 3) Empty / all caught up
                  if (visibleAlerts.isEmpty) {
                    return ListView(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPad,
                        24,
                        horizontalPad,
                        bottomPad,
                      ),
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        _EmptyAlerts(),
                      ],
                    );
                  }

                  // 4) Normal grid of unread alerts
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
                    itemCount: visibleAlerts.length,
                    itemBuilder: (_, i) {
                      final story = visibleAlerts[i];
                      return StoryCard(
                        story: story,
                        allStories: visibleAlerts,
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
 * _AlertsToolbarRow
 * LEFT  : category chips (All / Entertainment / Sports)
 * RIGHT : "Mark all read" pill
 *
 * The pill:
 *   - Red outline style
 *   - Disabled when there are no alerts or we're loading
 */
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

    Widget activeChip(String label, VoidCallback onTap) {
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
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
          child: const Text(
            'placeholder', // replaced per-chip below via chip()
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.2,
              color: Colors.white,
            ),
          ),
        ),
      );
    }

    Widget chip(int idx, String label) {
      if (idx == activeIndex) {
        return InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => onCategoryTap(idx),
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
      } else {
        return inactiveChip(label, () => onCategoryTap(idx));
      }
    }

    Widget markAllReadPill() {
      final enabled = hasAlerts && !loading;

      final borderColor =
          enabled ? _accent.withOpacity(0.4) : _accent.withOpacity(0.15);
      final textColor = enabled ? _accent : _accent.withOpacity(0.4);

      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: enabled ? onMarkAllRead : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              width: 1,
              color: borderColor,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.done_all_rounded,
                size: 16,
                color: textColor,
              ),
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
          // LEFT: chip row, horizontally scrollable if needed
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

          // RIGHT: "Mark all read" pill
          markAllReadPill(),
        ],
      ),
    );
  }
}

/* ───────────────────────── Empty state ───────────────────────── */

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
            Icon(
              Icons.notifications_none_rounded,
              size: 48,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              "You're all caught up",
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'New trailers, clips, and drops will show here.',
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

/* ───────────────────────── Header CTA button + brand ───────────────────────── */

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

    // icon color now adapts using theme_colors.dart
    final Color fg = primaryTextColor(context);

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
        Text(
          'CinePulse',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: primaryTextColor(context), // was hardcoded white
          ),
        ),
      ],
    );
  }
}
