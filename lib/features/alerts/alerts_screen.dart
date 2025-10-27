// lib/features/alerts/alerts_screen.dart
//
// Alerts tab
// - Shows only the "new since you last checked" stories.
// - "Mark all read" = remember now() as lastSeen and clear list.
// - Pull to refresh = refetch feed/all and recompute what's new.
//
// Layout changes vs old version:
// - We no longer try to shove StoryCard in a SliverList (that would explode,
//   because StoryCard's internal Column uses Expanded and expects a bounded
//   height).
// - Instead, we render alerts in a responsive SliverGrid with the same
//   StoryCard used on Home. This gives each card a fixed tile size
//   (so Expanded inside StoryCard is happy).
//
// Swipe UX:
// - StoryCard now supports prev/next swipe via StoryPagerScreen.
//   We pass the whole `_alerts` list + index into each StoryCard so that
//   AlertsScreen gets the same swipe experience as Home.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../story/story_card.dart';

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  static const _kPrefKey = 'alerts_last_seen';

  // When user last visited + marked as read (UTC).
  DateTime _lastSeenUtc =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true); // first run

  // Stories that are "new since lastSeenUtc".
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

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Grab a window from the "all" feed.
      // (Server returns newest-first or near-newest. We'll sort anyway.)
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

  // We reuse the same responsive card tiling logic conceptually as Home.
  // The grid delegate we build here must give each StoryCard a *bounded*
  // height (via childAspectRatio), otherwise StoryCard's Expanded will throw.
  SliverGridDelegate _gridDelegateFor(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final textScale = MediaQuery.textScaleFactorOf(context);

    // Choose an approximate "max card width" like Home does,
    // and also pick an aspect ratio bucket for that width.
    double maxTileW;
    if (screenW < 520) {
      maxTileW = screenW; // 1 col on phones
    } else if (screenW < 900) {
      maxTileW = screenW / 2; // 2 cols
    } else if (screenW < 1400) {
      maxTileW = screenW / 3; // 3 cols
    } else {
      maxTileW = screenW / 4; // 4 cols on wide screens
    }
    maxTileW = maxTileW.clamp(320.0, 480.0);

    // childAspectRatio = width / height.
    // Lower ratio => taller tile.
    double ratio;
    if (maxTileW <= 340) {
      ratio = 0.56;
    } else if (maxTileW <= 380) {
      ratio = 0.64;
    } else if (maxTileW <= 420) {
      ratio = 0.72;
    } else {
      ratio = 0.80;
    }

    // Respect user text scaling (bigger text -> need taller tiles).
    ratio /= textScale.clamp(1.0, 1.8);

    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxTileW,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: ratio,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final horizontalPad = 12.0;
    final topPad = 8.0;
    final bottomSafe = MediaQuery.viewPaddingOf(context).bottom;
    final bottomPad = 28.0 + bottomSafe;

    return RefreshIndicator.adaptive(
      onRefresh: _load,
      color: const Color(0xFFdc2626),
      child: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            title: Text(
              'Alerts',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w700,
              ),
            ),
            actions: [
              IconButton(
                tooltip: 'Mark all read',
                icon: const Icon(Icons.done_all_rounded),
                onPressed: _hasAlerts ? _markAllRead : null,
              ),
            ],
          ),

          // Error
          if (_error != null && !_loading)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_error!),
                ),
              ),
            ),

          // Loading skeletons (simple list rows)
          if (_loading)
            SliverList.separated(
              itemCount: 6,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, __) => const _SkeletonLine(),
            ),

          // Empty state
          if (!_loading && !_hasAlerts)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    "You're all caught up!\nNew trailers will appear here.",
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(fontSize: 16),
                  ),
                ),
              ),
            ),

          // Grid of unread alerts
          if (_hasAlerts)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                horizontalPad,
                topPad,
                horizontalPad,
                bottomPad,
              ),
              sliver: SliverGrid(
                gridDelegate: _gridDelegateFor(context),
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final story = _alerts[i];
                    return StoryCard(
                      story: story,
                      allStories: _alerts,
                      index: i,
                    );
                  },
                  childCount: _alerts.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/* --------------------------- skeleton row --------------------------- */

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine();

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Container(
            width: 96,
            height: 54,
            decoration: BoxDecoration(
              color: s.surfaceVariant.withOpacity(0.4),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 14,
                  decoration: BoxDecoration(
                    color: s.surfaceVariant.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 12,
                  width: 140,
                  decoration: BoxDecoration(
                    color: s.surfaceVariant.withOpacity(0.35),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
