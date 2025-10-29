// lib/features/alerts/alerts_screen.dart
//
// ALERTS TAB (restyled to match HomeScreen & SavedScreen)
//
// High-level:
// ----------
// • Frosted CinePulse header bar identical to SavedScreen/HomeScreen
//   - Left: CinePulse brand
//   - Right: nav icon pills (Home / Discover / Saved) on wide layouts
//   - Far right: Menu pill (always)
//   - All pills use the same square capsule style as SavedScreen
//
// • Row under header matches the dark "toolbar strip" used in Home (_FiltersRow)
//   and Saved (_SavedToolbarRow):
//   - Left: red-accent pill "Mark all read"
//          * disabled if there are no unread alerts
//   - Right: refresh pill (square icon button like in header)
//   - Same background color band and 1px divider as in other tabs
//
// • Next line: subtle "X new alerts" text in onSurfaceVariant
//
// • Body: EXACT SAME GRID GEOMETRY AS HOME/SAVED
//   (SliverGridDelegateWithMaxCrossAxisExtent with the same breakpoints,
//    same aspect ratio math)
//
// • Pull-to-refresh: still supported via RefreshIndicator
//
// • Loading state: uses SkeletonCard grid (unified with Home)
// • Empty state: friendly bell message in a scrollable ListView (so you
//   can still pull-to-refresh)
// • Error state: scrollable ListView with error text (refresh still works)
//
// Data model:
// -----------
// We persist `_lastSeenUtc` in SharedPreferences under `alerts_last_seen`.
// `_alerts` holds "stories published after lastSeenUtc".
// `_markAllRead()` sets lastSeenUtc = now() and clears `_alerts`.
//
// Navigation callbacks supplied by RootShell:
// ------------------------------------------
// onOpenHome     → switch to Home tab
// onOpenDiscover → switch to Discover tab
// onOpenSaved    → switch to Saved tab
// onOpenMenu     → open drawer
//
// RootShell should now build AlertsScreen like:
//
// AlertsScreen(
//   onOpenHome: _openHome,
//   onOpenDiscover: _openDiscover,
//   onOpenSaved: _openSaved,
//   onOpenMenu: _openEndDrawer,
// );
//

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../widgets/skeleton_card.dart';
import '../story/story_card.dart';

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({
    super.key,
    this.onOpenHome,
    this.onOpenDiscover,
    this.onOpenSaved,
    this.onOpenMenu,
  });

  /// Switch to Home tab.
  final VoidCallback? onOpenHome;

  /// Switch to Discover tab.
  final VoidCallback? onOpenDiscover;

  /// Switch to Saved tab.
  final VoidCallback? onOpenSaved;

  /// Open right-side drawer / menu.
  final VoidCallback? onOpenMenu;

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  static const _kPrefKey = 'alerts_last_seen';
  static const _accent = Color(0xFFdc2626);

  // When user last "marked all read" (UTC).
  DateTime _lastSeenUtc =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true); // first run

  // Stories that are new since _lastSeenUtc.
  List<Story> _alerts = [];

  bool _loading = true;
  String? _error;

  bool get _hasAlerts => _alerts.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _loadLastSeen();
    await _load();
  }

  Future<void> _loadLastSeen() async {
    final sp = await SharedPreferences.getInstance();
    final s = sp.getString(_kPrefKey);
    if (s != null) {
      final parsed = DateTime.tryParse(s);
      if (parsed != null) {
        _lastSeenUtc = parsed.toUtc();
      }
    }
  }

  Future<void> _saveLastSeen(DateTime t) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kPrefKey, t.toUtc().toIso8601String());
  }

  /// Fetch latest feed, filter anything newer than _lastSeenUtc.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Grab newest window from "all" feed (server returns newest-first-ish).
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

  /* ───────────────────────── Grid geometry helper ─────────────────────────
   *
   * EXACT SAME sizing logic we use on Home (_FeedListState._gridDelegateFor)
   * and the Saved tab, so StoryCard tiles look 100% consistent across screens.
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

  /* ───────────────────────── Count line helper ───────────────────────── */

  String _countLabel() {
    if (_loading) return 'Checking…';
    if (_error != null) return 'Couldn’t refresh';
    final total = _alerts.length;
    if (total == 0) return 'No new alerts';
    if (total == 1) return '1 new alert';
    return '$total new alerts';
  }

  /* ───────────────────────── UI build ───────────────────────── */

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor =
        isDark ? const Color(0xFF0b0f17) : theme.colorScheme.surface;

    // same breakpoint we use in Home/Saved to decide whether to show
    // the row of nav icons in the header:
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= 768;

    return Scaffold(
      backgroundColor: bgColor,

      /* ───────── Frosted CinePulse header bar (same as Home/Saved) ───────── */
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

                  // On wide / desktop, show quick nav to other tabs.
                  if (isWide) ...[
                    _HeaderIconButton(
                      tooltip: 'Home',
                      icon: Icons.home_rounded,
                      onTap: widget.onOpenHome,
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
                      tooltip: 'Saved',
                      icon: Icons.bookmark_rounded,
                      onTap: widget.onOpenSaved,
                    ),
                    const SizedBox(width: 8),
                  ],

                  _HeaderIconButton(
                    tooltip: 'Menu',
                    icon: Icons.menu_rounded,
                    onTap: widget.onOpenMenu,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),

      /* ───────── Body column (toolbar strip + count + grid w/ pull-to-refresh) ───────── */
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // toolbar strip under header
          _AlertsToolbarRow(
            hasAlerts: _hasAlerts,
            loading: _loading,
            onMarkAllRead: _markAllRead,
            onRefresh: _load,
          ),

          // "3 new alerts" line
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              _countLabel(),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),

          const SizedBox(height: 4),

          // main grid / states wrapped in pull-to-refresh
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

                  // 1) Loading → SkeletonCard grid
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

                  // 2) Error → scrollable list with error text (pull to retry still works)
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

                  // 3) Empty / caught up → friendly bell message
                  if (!_hasAlerts) {
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
                    itemCount: _alerts.length,
                    itemBuilder: (_, i) {
                      final story = _alerts[i];
                      return StoryCard(
                        story: story,
                        allStories: _alerts,
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

/* ───────────────────────── Toolbar row (under header) ─────────────────────────
 *
 * Matches style of HomeScreen._FiltersRow / SavedScreen._SavedToolbarRow.
 *
 * Layout:
 * [ Mark all read ]           [refresh-icon]
 *
 * The left side is a red-accent pill ("Mark all read"), disabled if
 * there are no alerts. The right side is a square icon pill that calls refresh.
 */

class _AlertsToolbarRow extends StatelessWidget {
  const _AlertsToolbarRow({
    required this.hasAlerts,
    required this.loading,
    required this.onMarkAllRead,
    required this.onRefresh,
  });

  final bool hasAlerts;
  final bool loading;
  final VoidCallback onMarkAllRead;
  final VoidCallback onRefresh;

  static const _accent = Color(0xFFdc2626);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    Widget markAllReadPill() {
      final enabled = hasAlerts && !loading;

      final borderColor = enabled
          ? _accent.withOpacity(0.4)
          : _accent.withOpacity(0.15);
      final textColor =
          enabled ? _accent : _accent.withOpacity(0.4);

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

    Widget refreshButton() {
      return _HeaderIconButton(
        tooltip: 'Refresh',
        icon: Icons.refresh_rounded,
        onTap: onRefresh,
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
          // left side "Mark all read" pill
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  markAllReadPill(),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // right side refresh button
          refreshButton(),
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

/* ───────────────────────── Shared header widgets ─────────────────────────
 *
 * These are copied from SavedScreen (which mirrors HomeScreen),
 * so Alerts header matches the same visual language everywhere.
 */

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
