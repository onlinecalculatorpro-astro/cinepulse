import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../features/story/story_card.dart';

/// Simple alerts screen:
/// - Shows items published after your last visit (lastSeen).
/// - “Mark all read” sets lastSeen = now and clears current alerts.
/// - Pull to refresh reloads.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

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
      if (parsed != null) _lastSeenUtc = parsed.toUtc();
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
      // Pull a reasonable window and filter locally.
      final list = await fetchFeed(tab: 'all', since: null, limit: 80);

      final fresh = list.where((s) {
        final dt = s.publishedAt;
        return dt != null && dt.isAfter(_lastSeenUtc);
      }).toList();

      // Sort newest first
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
    if (mounted) {
      setState(() {
        _lastSeenUtc = now;
        _alerts.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator.adaptive(
      onRefresh: _load,
      child: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            title: Text(
              'Alerts',
              style: GoogleFonts.inter(fontWeight: FontWeight.w700),
            ),
            actions: [
              IconButton(
                tooltip: 'Mark all read',
                icon: const Icon(Icons.done_all_rounded),
                onPressed: _hasAlerts ? _markAllRead : null,
              ),
            ],
          ),

          // Error state
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

          // Loading skeletons
          if (_loading)
            SliverList.separated(
              itemBuilder: (_, __) => const _SkeletonLine(),
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemCount: 6,
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

          // List of alerts (reusing StoryCard for consistency)
          if (_hasAlerts)
            SliverList.builder(
              itemCount: _alerts.length,
              itemBuilder: (_, i) => StoryCard(story: _alerts[i]),
            ),
        ],
      ),
    );
  }
}

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
