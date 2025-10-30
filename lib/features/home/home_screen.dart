// lib/features/home/home_screen.dart
//
// HomeScreen = main "Home" tab.
//
// Responsibilities:
//   • Renders the main feed grid (cards / skeletons / errors)
//   • Shows the global header bar and filter row
//   • Handles inline search, sorting, paging, pull-to-refresh,
//     offline fallback, and realtime updates
//
// -----------------------------------------------------------------------------
// NAV / HEADER BEHAVIOR
// -----------------------------------------------------------------------------
//
// COMPACT (<768px width):
//   - Bottom nav (RootShell) already shows [Home][Discover][Saved][Alerts].
//   - So Home header only shows utility icons:
//        [Search] [Refresh] [Menu]
//   - Tapping [Search] reveals the inline search bar row.
//
// WIDE (≥768px width):
//   - No bottom nav, so header must expose cross-tab CTAs.
//   - Home is considered "current", so we DO NOT show a "Home" pill.
//   - We DO show:
//        [Search] [Saved] [Alerts] [Discover] [Refresh] [Menu]
//   - [Search] still toggles the inline search bar row.
//
// -----------------------------------------------------------------------------
// LAYOUT
// -----------------------------------------------------------------------------
//
// Row 1: Frosted header bar (logo + CTAs)
// Row 2: Filter row
//        - Category chips: All / Entertainment / Sports
//        - Sort pill ("Latest first", "Trending now", etc.)
//        - Offline banner appears ABOVE this row if offline
// Row 3: Inline search bar (visible after tapping [Search])
// Body : TabBarView with a feed per category
//
// The feed supports:
//   - local paging cache
//   - manual refresh (Refresh CTA)
//   - auto-refresh every 2 minutes (only when foreground and not offline)
//   - realtime WebSocket ping triggers (debounced)
//   - offline mode fallback (cached content)
//   - client-side sorting modes
//   - client-side text search
//
// -----------------------------------------------------------------------------
// SORT MODES
// -----------------------------------------------------------------------------
// Latest first     (_SortMode.latest)
// Trending now     (_SortMode.trending)
// Most viewed      (_SortMode.views)
// Editor’s pick    (_SortMode.editorsPick)
//
// Sorting is applied client-side on the in-memory list for the
// currently-selected tab.
//
// -----------------------------------------------------------------------------
// NOTE ABOUT showSearchBar
// -----------------------------------------------------------------------------
// RootShell used to control search visibility. Now HomeScreen controls it
// internally via the [Search] CTA in the header. We keep `showSearchBar`
// as a legacy prop (RootShell always passes false).
// -----------------------------------------------------------------------------

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../../core/api.dart'; // fetchFeed(), kApiBaseUrl
import '../../core/cache.dart'; // FeedDiskCache, FeedCache, SavedStore
import '../../core/models.dart';
import '../../core/utils.dart'; // fadeRoute(), deepLinkForStoryId()
import '../../theme/theme_colors.dart'; // brand + text helpers
import '../../widgets/error_view.dart';
import '../../widgets/offline_banner.dart';
import '../../widgets/search_bar.dart'; // SearchBarInput
import '../../widgets/skeleton_card.dart';
import '../story/story_card.dart';

/* ──────────────────────────────────────────────────────────────────────────
 * Sort mode enum
 * ───────────────────────────────────────────────────────────────────────── */
enum _SortMode {
  latest,
  trending,
  views,
  editorsPick,
}

/* ──────────────────────────────────────────────────────────────────────────
 * HomeScreen widget
 * ───────────────────────────────────────────────────────────────────────── */
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.showSearchBar = false, // legacy; RootShell always sends false now
    this.onMenuPressed,
    this.onHeaderRefresh,
    this.onOpenDiscover,
    this.onOpenSaved,
    this.onOpenAlerts,
  });

  /// Legacy prop from when search was "owned" by RootShell.
  /// We keep it to avoid breaking the call site.
  final bool showSearchBar;

  /// Opens the global right-side drawer ("Menu").
  final VoidCallback? onMenuPressed;

  /// Callback after a manual refresh succeeds.
  final VoidCallback? onHeaderRefresh;

  /// Wide-layout navigation callbacks that jump to other RootShell tabs.
  final VoidCallback? onOpenDiscover;
  final VoidCallback? onOpenSaved;
  final VoidCallback? onOpenAlerts;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // Tabs for this feed layer.
  static const Map<String, String> _tabs = {
    'all': 'All',
    'entertainment': 'Entertainment',
    'sports': 'Sports',
  };

  // refresh + realtime timing
  static const Duration _kAutoRefreshEvery = Duration(minutes: 2);
  static const Duration _kRealtimeDebounce = Duration(milliseconds: 500);

  // controller for tabs ("All" / "Entertainment" / "Sports")
  late final TabController _tab =
      TabController(length: _tabs.length, vsync: this);

  // inline search text controller (Row 3)
  final TextEditingController _search = TextEditingController();

  // feed state per tab key
  final Map<String, _PagedFeed> _feeds = {
    for (final k in _tabs.keys) k: _PagedFeed(tab: k),
  };

  // we keep keys so we can scroll selected chip into view
  final List<GlobalKey> _chipKeys =
      List.generate(_tabs.length, (_) => GlobalKey());

  // network / lifecycle state
  bool _offline = false;
  bool _isForeground = true;

  // sorting
  _SortMode _sortMode = _SortMode.latest;

  // search row visibility
  bool _showHeaderSearch = false;

  // timers / streams
  StreamSubscription? _connSub;
  Timer? _searchDebounce;
  Timer? _autoRefresh;

  // realtime WS
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  Timer? _wsReconnectTimer;
  Timer? _realtimeDebounceTimer;
  int _wsBackoffSecs = 2;

  String get _currentTabKey => _tabs.keys.elementAt(_tab.index);
  _PagedFeed get _currentFeed => _feeds[_currentTabKey]!;

  /* ──────────────────────────────────────────────────────────────────────
   * init / dispose / lifecycle
   * ────────────────────────────────────────────────────────────────────── */
  @override
  void initState() {
    super.initState();

    // Preload all tab feeds (cached data appears instantly if available).
    for (final f in _feeds.values) {
      unawaited(f.load(reset: true));
    }

    _tab.addListener(_onTabChanged);

    WidgetsBinding.instance.addObserver(this);

    // Connectivity watcher.
    _connSub = Connectivity().onConnectivityChanged.listen((event) {
      final hasNetwork = _hasNetworkFrom(event);
      if (!mounted) return;
      final wasOffline = _offline;

      setState(() {
        _offline = !hasNetwork;
      });

      if (hasNetwork) {
        unawaited(_currentFeed.load(reset: false));
        _ensureWebSocket();
      } else {
        _teardownWebSocket();
      }

      // When we come back online, reset WS backoff.
      if (hasNetwork && wasOffline) {
        _wsBackoffSecs = 2;
      }
    });

    // Initial connectivity bootstrap.
    () async {
      final initial = await Connectivity().checkConnectivity();
      final hasNetwork = _hasNetworkFrom(initial);
      if (!mounted) return;
      setState(() {
        _offline = !hasNetwork;
      });
      if (hasNetwork) {
        _ensureWebSocket();
      }
    }();

    // Silent periodic refresh.
    _autoRefresh =
        Timer.periodic(_kAutoRefreshEvery, (_) => _tickAutoRefresh());

    // Debounced local search.
    _search.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _realtimeDebounceTimer?.cancel();
    _autoRefresh?.cancel();

    _wsReconnectTimer?.cancel();
    _wsSub?.cancel();
    _ws?.sink.close(ws_status.normalClosure);
    _ws = null;

    _connSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);

    _search.removeListener(_onSearchChanged);
    _search.dispose();

    _tab.removeListener(_onTabChanged);
    _tab.dispose();

    for (final f in _feeds.values) {
      f.dispose();
    }

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = (state == AppLifecycleState.resumed);

    if (_isForeground && mounted && !_offline) {
      // We just came back to foreground and we're online:
      unawaited(_currentFeed.load(reset: false));
      _ensureWebSocket();
    } else if (!_isForeground) {
      // We're backgrounding:
      _teardownWebSocket();
    }
  }

  /* ──────────────────────────────────────────────────────────────────────
   * Realtime WebSocket handling
   * ────────────────────────────────────────────────────────────────────── */

  String _buildWsUrl() {
    final base = kApiBaseUrl;
    final u = Uri.parse(base);

    final scheme = (u.scheme == 'https') ? 'wss' : 'ws';
    final basePath = (u.path.isEmpty || u.path == '/') ? '' : u.path;
    final fullPath = '$basePath/v1/realtime/ws';

    return Uri(
      scheme: scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: fullPath,
    ).toString();
  }

  void _ensureWebSocket() {
    if (!mounted) return;
    if (_offline || !_isForeground) return;
    if (_ws != null) return; // already connected

    final url = _buildWsUrl();

    try {
      _ws = WebSocketChannel.connect(Uri.parse(url));
      _wsSub = _ws!.stream.listen(
        (data) {
          // Any "content updated" ping should trigger a debounced refresh.
          try {
            final obj = json.decode(data.toString());
            if (obj is Map && obj['type'] == 'ping') {
              // ignore keep-alive pings
              return;
            }
          } catch (_) {}
          _scheduleRealtimeRefresh();
        },
        onDone: _onWsClosed,
        onError: (_) => _onWsClosed(),
        cancelOnError: true,
      );
      _wsBackoffSecs = 2; // reset backoff on success
    } catch (_) {
      _onWsClosed();
    }
  }

  void _onWsClosed() {
    _wsSub?.cancel();
    _wsSub = null;
    _ws = null;

    if (!mounted) return;
    if (_offline || !_isForeground) return;

    // Try to reconnect with exponential backoff.
    _wsReconnectTimer?.cancel();
    _wsReconnectTimer =
        Timer(Duration(seconds: _wsBackoffSecs), _ensureWebSocket);
    _wsBackoffSecs = (_wsBackoffSecs * 2).clamp(2, 60);
  }

  void _teardownWebSocket() {
    _wsReconnectTimer?.cancel();
    _wsReconnectTimer = null;

    _wsSub?.cancel();
    _wsSub = null;

    _ws?.sink.close(ws_status.normalClosure);
    _ws = null;
  }

  void _scheduleRealtimeRefresh() {
    _realtimeDebounceTimer?.cancel();
    _realtimeDebounceTimer = Timer(_kRealtimeDebounce, () {
      if (!mounted) return;
      if (_offline) return;
      if (_search.text.isNotEmpty) return; // don't clobber search view
      unawaited(_currentFeed.load(reset: false));
    });
  }

  /* ──────────────────────────────────────────────────────────────────────
   * Internal helpers
   * ────────────────────────────────────────────────────────────────────── */

  bool _hasNetworkFrom(dynamic event) {
    if (event is ConnectivityResult) {
      return event != ConnectivityResult.none;
    }
    if (event is List<ConnectivityResult>) {
      return event.any((r) => r != ConnectivityResult.none);
    }
    return true;
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() {});
    });
  }

  void _ensureChipVisible(int tabIndex) {
    if (!mounted) return;
    if (tabIndex < 0 || tabIndex >= _chipKeys.length) return;

    // We wait one frame so layout is finalized.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _chipKeys[tabIndex].currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      );
    });
  }

  void _onTabChanged() {
    if (!mounted) return;
    setState(() {});
    _ensureChipVisible(_tab.index);
  }

  Future<void> _refreshManually() async {
    final key = _currentTabKey;
    await _feeds[key]!.load(reset: true);
    widget.onHeaderRefresh?.call();
  }

  void _onTabTap(int i) {
    if (i < 0 || i >= _tab.length) return;
    _tab.animateTo(i);
    unawaited(_feeds[_tabs.keys.elementAt(i)]!.load(reset: false));
    _ensureChipVisible(i);
  }

  void _tickAutoRefresh() {
    if (!mounted) return;
    if (_offline) return;
    if (!_isForeground) return;
    if (_search.text.isNotEmpty) return; // don't auto-refresh while searching
    unawaited(_currentFeed.load(reset: false));
  }

  String _sortModeLabel(_SortMode mode) {
    switch (mode) {
      case _SortMode.latest:
        return 'Latest first';
      case _SortMode.trending:
        return 'Trending now';
      case _SortMode.views:
        return 'Most viewed';
      case _SortMode.editorsPick:
        return 'Editor’s pick';
    }
  }

  Future<void> _showSortSheet(BuildContext sheetContext) async {
    final picked = await showModalBottomSheet<_SortMode>(
      context: sheetContext,
      showDragHandle: true,
      backgroundColor: Theme.of(sheetContext).colorScheme.surface,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final cs = theme.colorScheme;

        Widget option({
          required _SortMode mode,
          required IconData icon,
          required String title,
          required String subtitle,
        }) {
          final selected = (_sortMode == mode);
          final iconColor = selected ? cs.primary : primaryTextColor(ctx);

          return ListTile(
            leading: Icon(icon, color: iconColor),
            title: Text(
              title,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: primaryTextColor(ctx),
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(
                fontSize: 13,
                color: secondaryTextColor(ctx),
              ),
            ),
            trailing:
                selected ? Icon(Icons.check_rounded, color: cs.primary) : null,
            onTap: () => Navigator.pop(ctx, mode),
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              option(
                mode: _SortMode.latest,
                icon: Icons.access_time_rounded,
                title: 'Latest first',
                subtitle: 'Newest published stories first',
              ),
              option(
                mode: _SortMode.trending,
                icon: Icons.local_fire_department_rounded,
                title: 'Trending now',
                subtitle: 'What’s getting attention',
              ),
              option(
                mode: _SortMode.views,
                icon: Icons.visibility_rounded,
                title: 'Most viewed',
                subtitle: 'Top stories by views',
              ),
              option(
                mode: _SortMode.editorsPick,
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

    if (!mounted) return;
    if (picked != null && picked != _sortMode) {
      setState(() {
        _sortMode = picked;
      });
    }
  }

  // Toggle inline search row (Row 3) when header Search is tapped.
  void _toggleHeaderSearch() {
    setState(() {
      _showHeaderSearch = !_showHeaderSearch;

      // If hiding the row, also clear the text and dismiss keyboard.
      if (!_showHeaderSearch) {
        _search.clear();
        FocusScope.of(context).unfocus();
      }
    });
  }

  /* ──────────────────────────────────────────────────────────────────────
   * build()
   * ────────────────────────────────────────────────────────────────────── */
  @override
  Widget build(BuildContext context) {
    try {
      return _buildScaffold(context);
    } catch (err, stack) {
      debugPrint('HomeScreen build ERROR: $err\n$stack');
      return _HomeCrashedView(
        error: err.toString(),
        stack: stack.toString(),
      );
    }
  }

  Widget _buildScaffold(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0b0f17) : theme.colorScheme.surface;

    // Responsive breakpoint
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= 768;

    // Should Row 3 currently be visible?
    final showSearchRow = widget.showSearchBar || _showHeaderSearch;

    return Scaffold(
      backgroundColor: bgColor,

      /* ───────── Header (Row 1) ───────── */
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
                border: Border(
                  bottom: BorderSide(
                    color: outlineHairline(context),
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  const _BrandLogo(),
                  const Spacer(),

                  if (isWide) ...[
                    // DESKTOP / WIDE (≥768px):
                    // [Search] [Saved] [Alerts] [Discover] [Refresh] [Menu]
                    _HeaderIconButton(
                      tooltip: 'Search',
                      icon: Icons.search_rounded,
                      onTap: _toggleHeaderSearch,
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
                      onTap: _refreshManually,
                    ),
                    const SizedBox(width: 8),
                    _HeaderIconButton(
                      tooltip: 'Menu',
                      icon: Icons.menu_rounded,
                      onTap: widget.onMenuPressed,
                    ),
                  ] else ...[
                    // COMPACT (<768px):
                    // [Search] [Refresh] [Menu]
                    _HeaderIconButton(
                      tooltip: 'Search',
                      icon: Icons.search_rounded,
                      onTap: _toggleHeaderSearch,
                    ),
                    const SizedBox(width: 8),
                    _HeaderIconButton(
                      tooltip: 'Refresh',
                      icon: Icons.refresh_rounded,
                      onTap: _refreshManually,
                    ),
                    const SizedBox(width: 8),
                    _HeaderIconButton(
                      tooltip: 'Menu',
                      icon: Icons.menu_rounded,
                      onTap: widget.onMenuPressed,
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
        children: [
          // Offline banner (sits ABOVE filters row)
          if (_offline)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: OfflineBanner(),
            ),

          // Row 2: category chips + sort pill
          _FiltersRow(
            activeIndex: _tab.index,
            sortLabel: _sortModeLabel(_sortMode),
            sortMode: _sortMode,
            isDark: isDark,
            theme: theme,
            chipKeys: _chipKeys,
            onSelect: _onTabTap,
            onSortTap: (ctx) => _showSortSheet(ctx),
          ),

          // Row 3: inline search bar (only when visible)
          if (showSearchRow)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: SearchBarInput(
                controller: _search,
                onExitSearch: () {
                  // Called when the little "X" is tapped.
                  setState(() {
                    _search.clear();
                    FocusScope.of(context).unfocus();
                    _showHeaderSearch = false;
                  });
                },
              ),
            ),

          // Feed content (TabBarView)
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: _tabs.keys.map((tabKey) {
                final feed = _feeds[tabKey]!;
                return _FeedList(
                  key: PageStorageKey('feed-$tabKey'),
                  feed: feed,
                  searchText: _search,
                  offline: _offline,
                  sortMode: _sortMode,
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

/* ──────────────────────────────────────────────────────────────────────────
 * Filters row under header (Row 2)
 *  - Horizontal chips for All / Entertainment / Sports
 *  - Sort pill on the right
 * ───────────────────────────────────────────────────────────────────────── */
class _FiltersRow extends StatelessWidget {
  const _FiltersRow({
    required this.activeIndex,
    required this.sortLabel,
    required this.sortMode,
    required this.isDark,
    required this.theme,
    required this.chipKeys,
    required this.onSelect,
    required this.onSortTap,
  });

  final int activeIndex;
  final String sortLabel;
  final _SortMode sortMode;
  final bool isDark;
  final ThemeData theme;
  final List<GlobalKey> chipKeys;
  final ValueChanged<int> onSelect;
  final void Function(BuildContext ctx) onSortTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final acc = cs.primary;

    Widget tabChip(int index, String label, Key itemKey) {
      final selected = (activeIndex == index);

      final bgColor = selected ? acc : Colors.transparent;
      final textColor = selected ? Colors.white : acc;
      final borderClr = selected ? acc : acc.withOpacity(0.35);
      final fontWeight = selected ? FontWeight.w600 : FontWeight.w500;

      return InkWell(
        key: itemKey,
        borderRadius: BorderRadius.circular(999),
        onTap: () => onSelect(index),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: borderClr, width: 1),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: acc.withOpacity(0.35),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ]
                : const <BoxShadow>[],
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              height: 1.2,
              fontWeight: fontWeight,
              color: textColor,
            ),
          ),
        ),
      );
    }

    IconData iconForSort(_SortMode mode) {
      switch (mode) {
        case _SortMode.latest:
          return Icons.access_time_rounded;
        case _SortMode.trending:
          return Icons.local_fire_department_rounded;
        case _SortMode.views:
          return Icons.visibility_rounded;
        case _SortMode.editorsPick:
          return Icons.star_rounded;
      }
    }

    Widget sortButton() {
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => onSortTap(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              width: 1,
              color: acc.withOpacity(0.35),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                iconForSort(sortMode),
                size: 16,
                color: acc,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  sortLabel,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.2,
                    fontWeight: FontWeight.w500,
                    color: acc,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.arrow_drop_down_rounded,
                size: 18,
                color: acc,
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
            color: outlineHairline(context),
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Horizontal scroll row of chips.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  tabChip(0, 'All', chipKeys[0]),
                  const SizedBox(width: 8),
                  tabChip(1, 'Entertainment', chipKeys[1]),
                  const SizedBox(width: 8),
                  tabChip(2, 'Sports', chipKeys[2]),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Sort pill.
          sortButton(),
        ],
      ),
    );
  }
}

/* ──────────────────────────────────────────────────────────────────────────
 * Feed list / grid per tab
 *   - Shows SkeletonCard grid while first load
 *   - Shows ErrorView if we got an error and have no data
 *   - Shows cards grid with client-side sort + search
 *   - Handles "saved" badge overlay in the corner of saved stories
 * ───────────────────────────────────────────────────────────────────────── */
class _FeedList extends StatefulWidget {
  const _FeedList({
    super.key,
    required this.feed,
    required this.searchText,
    required this.offline,
    required this.sortMode,
  });

  final _PagedFeed feed;
  final TextEditingController searchText;
  final bool offline;
  final _SortMode sortMode;

  @override
  State<_FeedList> createState() => _FeedListState();
}

class _FeedListState extends State<_FeedList>
    with AutomaticKeepAliveClientMixin<_FeedList> {
  @override
  bool get wantKeepAlive => true;

  // Pick a grid layout depending on width and text scale.
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

    // Constrain max card width so tiles look consistent.
    double maxTileW = width / estCols;
    maxTileW = maxTileW.clamp(320.0, 480.0);

    // Base aspect ratio guesses by column count.
    double baseRatio;
    if (estCols == 1) {
      baseRatio = 0.88;
    } else if (estCols == 2) {
      baseRatio = 0.95;
    } else {
      baseRatio = 1.0;
    }

    // Larger text means taller cards, so lower the ratio.
    final scaleForHeight = textScale.clamp(1.0, 1.4);
    final effectiveRatio = baseRatio / scaleForHeight;

    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxTileW,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: effectiveRatio,
    );
  }

  // Helpers to implement sorting modes.
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
    switch (widget.sortMode) {
      case _SortMode.latest:
        // Already newest-first from _PagedFeed
        return input;
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
        return picks.isNotEmpty ? picks : input;
    }
  }

  // Adds a brand-colored "saved" badge on top of the StoryCard if saved.
  Widget _withSavedBadge({
    required Story story,
    required List<Story> allStories,
    required int index,
  }) {
    final isSaved = SavedStore.instance.isSaved(story.id);
    final cs = Theme.of(context).colorScheme;
    final acc = cs.primary;

    final card = StoryCard(
      story: story,
      allStories: allStories,
      index: index,
    );

    if (!isSaved) return card;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        card,
        Positioned(
          top: 8,
          right: 8,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: acc,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: acc,
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: acc.withOpacity(0.35),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: const Icon(
              Icons.bookmark_rounded,
              size: 14,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final feed = widget.feed;

    return AnimatedBuilder(
      animation: feed,
      builder: (context, _) {
        return AnimatedBuilder(
          animation: SavedStore.instance,
          builder: (context, __) {
            return LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                final textScale = MediaQuery.textScaleFactorOf(context);
                final gridDelegate = _gridDelegateFor(w, textScale);

                // Safe padding math
                const hPad = 12.0;
                const topPad = 8.0;
                final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
                final bottomPad = 28.0 + bottomInset;

                // 1. Initial load → skeleton grid
                if (feed.isInitialLoading) {
                  return GridView.builder(
                    padding: EdgeInsets.fromLTRB(
                      hPad,
                      topPad,
                      hPad,
                      bottomPad,
                    ),
                    physics: const AlwaysScrollableScrollPhysics(),
                    cacheExtent: 1800,
                    gridDelegate: gridDelegate,
                    itemCount: 9,
                    itemBuilder: (_, __) => const SkeletonCard(),
                  );
                }

                // 2. Hard failure w/ no cached data
                if (feed.hasError && feed.items.isEmpty) {
                  return ListView(
                    padding: EdgeInsets.fromLTRB(
                      hPad,
                      24,
                      hPad,
                      bottomPad,
                    ),
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      ErrorView(
                        message:
                            feed.errorMessage ?? 'Something went wrong.',
                        onRetry: () => feed.load(reset: true),
                      ),
                    ],
                  );
                }

                // 3. Apply local search + sort
                final q = widget.searchText.text.trim().toLowerCase();

                final baseList = (q.isEmpty)
                    ? feed.items
                    : feed.items.where((s) {
                        final title = s.title.toLowerCase();
                        final summary = (s.summary ?? '').toLowerCase();
                        return title.contains(q) || summary.contains(q);
                      }).toList();

                final displayList = _applySortMode(baseList);

                if (displayList.isEmpty) {
                  final msg = widget.offline
                      ? "You're offline and no results match your search."
                      : 'No matching items.';
                  return ListView(
                    padding: EdgeInsets.fromLTRB(
                      hPad,
                      24,
                      hPad,
                      bottomPad,
                    ),
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      Center(child: Text(msg)),
                    ],
                  );
                }

                // 4. Normal grid (no "Load more" button in this revision)
                return GridView.builder(
                  padding: EdgeInsets.fromLTRB(
                    hPad,
                    topPad,
                    hPad,
                    bottomPad,
                  ),
                  physics: const AlwaysScrollableScrollPhysics(),
                  cacheExtent: 2000,
                  gridDelegate: gridDelegate,
                  itemCount: displayList.length,
                  itemBuilder: (_, i) {
                    final story = displayList[i];
                    return _withSavedBadge(
                      story: story,
                      allStories: displayList,
                      index: i,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

/* ──────────────────────────────────────────────────────────────────────────
 * Paged feed model:
 *  - Holds items for a given tab (e.g. "all", "entertainment", "sports")
 *  - Knows if it's loading / error
 *  - Loads cached data first (FeedDiskCache), then fetches fresh
 *  - Tracks a "since" cursor for incremental updates
 *  - Keeps newest items first
 * ───────────────────────────────────────────────────────────────────────── */
class _PagedFeed extends ChangeNotifier {
  _PagedFeed({required this.tab});

  final String tab;

  final List<Story> _items = [];
  bool _initialLoading = false;
  bool _loadingMore = false;
  bool _hasError = false;
  String? _errorMessage;
  bool _canLoadMore = false; // future-proofing

  List<Story> get items => List.unmodifiable(_items);
  bool get isInitialLoading => _initialLoading;
  bool get isLoadingMore => _loadingMore;
  bool get hasError => _hasError;
  String? get errorMessage => _errorMessage;
  bool get canLoadMore => _canLoadMore;

  // "Effective timestamp" (normalizedAt > publishedAt > releaseDate)
  DateTime? _eff(Story s) =>
      s.normalizedAt ?? s.publishedAt ?? s.releaseDate;

  DateTime? _sinceCursor;

  Future<void> load({required bool reset}) async {
    if (reset) {
      _initialLoading = true;
      _loadingMore = false;
      _hasError = false;
      _errorMessage = null;
      _sinceCursor = null;
      _items.clear();

      // Try disk cache to show *something* instantly.
      final cached = await FeedDiskCache.load(tab);
      if (cached.isNotEmpty) {
        _items.addAll(cached);
        _sortNewestFirst(_items);

        for (final s in cached) {
          FeedCache.put(s);
        }

        _initialLoading = false;
        notifyListeners();
      } else {
        // Still notify so UI flips to skeleton state.
        notifyListeners();
      }
    }

    try {
      final fresh = await fetchFeed(
        tab: tab,
        since: _sinceCursor,
        limit: 40,
      );

      // Merge by ID.
      final byId = {for (final s in _items) s.id: s};
      for (final s in fresh) {
        byId[s.id] = s;
        FeedCache.put(s);
      }

      _items
        ..clear()
        ..addAll(byId.values);

      _sortNewestFirst(_items);

      // Update cursor to newest timestamp in list.
      final allDates = _items.map(_eff).whereType<DateTime>();
      _sinceCursor = allDates.isEmpty
          ? null
          : allDates.reduce(
              (a, b) => a.isAfter(b) ? a : b,
            );

      _hasError = false;
      _errorMessage = null;

      if (reset) {
        unawaited(FeedDiskCache.save(tab, _items));
      }
    } catch (e) {
      _hasError = true;
      _errorMessage = '$e';
    } finally {
      _initialLoading = false;
      _loadingMore = false;
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    if (_loadingMore || !_canLoadMore) return;
    _loadingMore = true;
    notifyListeners();
    await load(reset: false);
  }

  void _sortNewestFirst(List<Story> list) {
    list.sort((a, b) {
      final da = _eff(a);
      final db = _eff(b);

      // Fall back to ID sort (desc) if timestamps tie / missing.
      if (da == null && db == null) {
        return b.id.compareTo(a.id);
      }
      if (da == null) return 1;
      if (db == null) return -1;

      final cmp = db.compareTo(da); // newer first
      if (cmp != 0) return cmp;

      return b.id.compareTo(a.id);
    });
  }
}

/* ──────────────────────────────────────────────────────────────────────────
 * HeaderIconButton
 * Square-ish pill buttons in the header bar ("Search", "Menu", etc.)
 * ───────────────────────────────────────────────────────────────────────── */
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final acc = cs.primary;

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
            border: Border.all(
              color: acc.withOpacity(0.30),
              width: 1,
            ),
          ),
          child: Icon(
            icon,
            size: 16,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
      ),
    );
  }
}

/* ──────────────────────────────────────────────────────────────────────────
 * Brand logo blob in header (square with 🎬 + text "CinePulse")
 * ───────────────────────────────────────────────────────────────────────── */
class _BrandLogo extends StatelessWidget {
  const _BrandLogo();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final acc = cs.primary;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: acc,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: acc.withOpacity(0.35),
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
            color: primaryTextColor(context),
          ),
        ),
      ],
    );
  }
}

/* ──────────────────────────────────────────────────────────────────────────
 * Crash fallback UI for dev / debugging.
 * ───────────────────────────────────────────────────────────────────────── */
class _HomeCrashedView extends StatelessWidget {
  const _HomeCrashedView({
    required this.error,
    required this.stack,
  });

  final String error;
  final String stack;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      width: double.infinity,
      height: double.infinity,
      padding: const EdgeInsets.all(16),
      child: SafeArea(
        child: SingleChildScrollView(
          child: DefaultTextStyle(
            style: const TextStyle(
              fontSize: 14,
              color: Colors.redAccent,
              fontFamily: 'monospace',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'HomeScreen crashed while building.\n'
                  'Screenshot this and send it 👇\n',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.redAccent,
                  ),
                ),
                const Text('Error:'),
                Text(error),
                const SizedBox(height: 12),
                const Text('Stack:'),
                Text(stack),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
