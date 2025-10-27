// lib/features/home/home_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../../core/api.dart';
import '../../core/cache.dart';
import '../../core/models.dart';
import '../../widgets/error_view.dart';
import '../../widgets/offline_banner.dart';
import '../../widgets/skeleton_card.dart';
import 'widgets/search_bar.dart';
import '../story/story_card.dart';

/* -------------------------------------------------------------------------- */
/* Sort mode for the feed                                                     */
/* -------------------------------------------------------------------------- */

enum _SortMode {
  latest,        // "Latest first" (default)
  trending,      // "Trending now"
  views,         // "Most viewed"
  editorsPick,   // "Editor’s pick"
}

/* -------------------------------------------------------------------------- */
/* HomeScreen                                                                 */
/* -------------------------------------------------------------------------- */

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.showSearchBar = false, // show only when Search tab active
    this.onMenuPressed, // opens drawer (from RootShell)
    this.onHeaderRefresh, // optional external hook
    this.onOpenDiscover, // header "Discover" button -> Search tab
  });

  final bool showSearchBar;
  final VoidCallback? onMenuPressed;
  final VoidCallback? onHeaderRefresh;
  final VoidCallback? onOpenDiscover;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // 3 logical feeds for the pill row.
  static const Map<String, String> _tabs = {
    'all': 'All',
    'entertainment': 'Entertainment',
    'sports': 'Sports',
  };

  // Silent background refresh cadence (fallback if WS not available).
  static const Duration _kAutoRefreshEvery = Duration(minutes: 2);

  // Debounce for rapid WS event bursts -> a single fetch.
  static const Duration _kRealtimeDebounce = Duration(milliseconds: 500);

  late final TabController _tab =
      TabController(length: _tabs.length, vsync: this);

  final TextEditingController _search = TextEditingController();
  final GlobalKey<RefreshIndicatorState> _refreshKey =
      GlobalKey<RefreshIndicatorState>();

  final Map<String, _PagedFeed> _feeds = {
    for (final k in _tabs.keys) k: _PagedFeed(tab: k)
  };

  bool _offline = false;
  bool _isForeground = true;

  // current "Sorting" mode in the header
  _SortMode _sortMode = _SortMode.latest;

  // Connectivity / timers
  StreamSubscription? _connSub;
  Timer? _searchDebounce;
  Timer? _autoRefresh;

  // Realtime (WebSocket)
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  Timer? _wsReconnectTimer;
  int _wsBackoffSecs = 2; // exponential backoff up to 60s
  Timer? _realtimeDebounceTimer;

  String get _currentTabKey => _tabs.keys.elementAt(_tab.index);
  _PagedFeed get _currentFeed => _feeds[_currentTabKey]!;

  @override
  void initState() {
    super.initState();

    // First load for all feeds (cached-first).
    for (final f in _feeds.values) {
      unawaited(f.load(reset: true));
    }

    _tab.addListener(_onTabChanged);

    WidgetsBinding.instance.addObserver(this);

    // Connectivity changes.
    _connSub = Connectivity().onConnectivityChanged.listen((event) {
      final hasNetwork = _hasNetworkFrom(event);
      if (!mounted) return;
      final wasOffline = _offline;
      setState(() => _offline = !hasNetwork);

      if (hasNetwork) {
        // Back online: gently fetch deltas for current tab and ensure WS is up.
        unawaited(_currentFeed.load(reset: false));
        _ensureWebSocket();
      } else {
        // Offline: drop socket to avoid loop.
        _teardownWebSocket();
      }

      if (hasNetwork && wasOffline) _wsBackoffSecs = 2;
    });

    // Initial connectivity state (async fire-and-forget).
    () async {
      final initial = await Connectivity().checkConnectivity();
      final hasNetwork = _hasNetworkFrom(initial);
      if (!mounted) return;
      setState(() => _offline = !hasNetwork);
      if (hasNetwork) _ensureWebSocket();
    }();

    // Auto refresh tick (silent).
    _autoRefresh =
        Timer.periodic(_kAutoRefreshEvery, (_) => _tickAutoRefresh());

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

  // Lifecycle → refresh + manage realtime when returning to foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = (state == AppLifecycleState.resumed);
    if (_isForeground && mounted && !_offline) {
      // Gentle, incremental fetch (no skeleton flicker).
      unawaited(_currentFeed.load(reset: false));
      _ensureWebSocket(); // make sure WS is alive in foreground
    } else if (!_isForeground) {
      _teardownWebSocket(); // pause socket in background to save battery
    }
  }

  /* --------------------------- Realtime (WebSocket) ------------------------ */

  String _buildWsUrl() {
    // Build ws/wss from your REST base
    final base = kApiBaseUrl;
    final u = Uri.parse(base);
    final scheme = (u.scheme == 'https') ? 'wss' : 'ws';

    // preserve any base path
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
    if (_ws != null) return; // already connected/connecting

    final url = _buildWsUrl();
    try {
      _ws = WebSocketChannel.connect(Uri.parse(url));
      _wsSub = _ws!.stream.listen(
        (data) {
          // Expected: {"id":"...", "kind":"...", "..."} or {"type":"ping"}
          try {
            final obj = json.decode(data.toString());
            if (obj is Map && obj['type'] == 'ping') return;
          } catch (_) {}
          _scheduleRealtimeRefresh();
        },
        onDone: _onWsClosed,
        onError: (_) => _onWsClosed(),
        cancelOnError: true,
      );
      _wsBackoffSecs = 2; // connected → reset backoff
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

    // Exponential backoff reconnect
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
      if (_search.text.isNotEmpty) return; // don't disrupt focused search
      unawaited(_currentFeed.load(reset: false));
    });
  }

  /* ------------------------------ Helpers ---------------------------------- */

  bool _hasNetworkFrom(dynamic event) {
    if (event is ConnectivityResult) return event != ConnectivityResult.none;
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

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  // Manual pull-to-refresh: full reset + optional external hook.
  Future<void> _refresh() async {
    final key = _currentTabKey;
    await _feeds[key]!.load(reset: true);
    widget.onHeaderRefresh?.call();
  }

  // Background silent refresh tick.
  void _tickAutoRefresh() {
    if (!mounted) return;
    if (_offline) return;
    if (!_isForeground) return;
    if (_search.text.isNotEmpty) return;
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
    final choice = await showModalBottomSheet<_SortMode>(
      context: sheetContext,
      showDragHandle: true,
      backgroundColor: Theme.of(sheetContext).colorScheme.surface,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        final textColor = Theme.of(ctx).colorScheme.onSurface;
        final subColor = Theme.of(ctx).colorScheme.onSurfaceVariant;

        Widget tile({
          required _SortMode mode,
          required IconData icon,
          required String title,
          required String subtitle,
        }) {
          final selected = (_sortMode == mode);
          return ListTile(
            leading: Icon(
              icon,
              color: selected
                  ? const Color(0xFFdc2626)
                  : (isDark ? Colors.white : Colors.black87),
            ),
            title: Text(
              title,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: textColor,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(
                fontSize: 13,
                color: subColor,
              ),
            ),
            trailing: selected
                ? const Icon(Icons.check_rounded, color: Color(0xFFdc2626))
                : null,
            onTap: () => Navigator.pop(ctx, mode),
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              tile(
                mode: _SortMode.latest,
                icon: Icons.access_time_rounded,
                title: 'Latest first',
                subtitle: 'Newest published stories first',
              ),
              tile(
                mode: _SortMode.trending,
                icon: Icons.local_fire_department_rounded,
                title: 'Trending now',
                subtitle: 'What’s getting attention',
              ),
              tile(
                mode: _SortMode.views,
                icon: Icons.visibility_rounded,
                title: 'Most viewed',
                subtitle: 'Top stories by views',
              ),
              tile(
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
    if (choice != null && choice != _sortMode) {
      setState(() {
        _sortMode = choice;
      });
    }
  }

  /* ------------------------------- UI -------------------------------------- */

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF0a0e1a) : theme.colorScheme.surface,
      body: RefreshIndicator.adaptive(
        key: _refreshKey,
        onRefresh: _refresh,
        color: const Color(0xFFdc2626),
        child: CustomScrollView(
          slivers: [
            // Sticky glass header bar:
            SliverAppBar(
              floating: true,
              pinned: true,
              elevation: 0,
              backgroundColor: isDark
                  ? const Color(0xFF0f172a).withOpacity(0.95)
                  : theme.colorScheme.surface.withOpacity(0.95),
              surfaceTintColor: Colors.transparent,
              toolbarHeight: 70,
              leading: null,
              automaticallyImplyLeading: false,
              flexibleSpace: ClipRRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: isDark
                            ? [
                                const Color(0xFF0f172a).withOpacity(0.95),
                                const Color(0xFF0f172a).withOpacity(0.8),
                              ]
                            : [
                                theme.colorScheme.surface.withOpacity(0.95),
                                theme.colorScheme.surface.withOpacity(0.8),
                              ],
                      ),
                      border: const Border(
                        bottom: BorderSide(
                          color: Color(0x0Fffffff),
                          width: 1,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              title: const _ModernBrandLogo(),
              actions: [
                IconButton(
                  tooltip: 'Discover',
                  icon: Icon(
                    kIsWeb
                        ? Icons.explore_outlined
                        : Icons.manage_search_rounded,
                  ),
                  onPressed: widget.onOpenDiscover,
                ),
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: () {
                    _refreshKey.currentState?.show();
                    unawaited(_refresh());
                  },
                ),
                IconButton(
                  tooltip: 'Menu',
                  icon: const Icon(Icons.menu_rounded),
                  onPressed: widget.onMenuPressed,
                ),
                const SizedBox(width: 4),
              ],
            ),

            // Search bar (only if Search tab from bottom nav was tapped)
            if (widget.showSearchBar)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: SearchBarInput(
                    controller: _search,
                    onExitSearch: () {
                      _search.clear();
                      FocusScope.of(context).unfocus();
                    },
                  ),
                ),
              ),

            // Offline banner if applicable
            if (_offline)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: OfflineBanner(),
                ),
              ),

            // CATEGORY + SORT BAR (pinned, sticky)
            SliverPersistentHeader(
              pinned: true,
              delegate: _FiltersHeaderDelegate(
                activeIndex: _tab.index,
                sortLabel: _sortModeLabel(_sortMode),
                onSelect: (i) {
                  if (i >= 0 && i < _tab.length) {
                    _tab.animateTo(i);
                    unawaited(
                      _feeds[_tabs.keys.elementAt(i)]!.load(reset: false),
                    );
                  }
                },
                onSortTap: (ctx) => _showSortSheet(ctx),
              ),
            ),

            // FEED GRID
            SliverFillRemaining(
              child: TabBarView(
                controller: _tab,
                // swipe between All / Entertainment / Sports
                children: _tabs.keys.map((key) {
                  final feed = _feeds[key]!;
                  return _FeedList(
                    key: PageStorageKey('feed-$key'),
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
      ),
      floatingActionButton: null,
    );
  }
}

/* -------------------- Sticky horizontal filter header -------------------- */

class _FiltersHeaderDelegate extends SliverPersistentHeaderDelegate {
  _FiltersHeaderDelegate({
    required this.activeIndex,
    required this.onSelect,
    required this.sortLabel,
    required this.onSortTap,
  });

  final int activeIndex;
  final ValueChanged<int> onSelect;

  // The label under the caret on the Sorting button ("Latest first", etc.)
  final String sortLabel;

  // We need BuildContext to open the bottom sheet from parent
  final void Function(BuildContext ctx) onSortTap;

  @override
  double get minExtent => 56;
  @override
  double get maxExtent => 56;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    Color pillBg(bool active) =>
        active ? const Color(0xFFdc2626) : Colors.transparent;

    Color textColor(bool active) {
      if (active) return Colors.white;
      return isDark
          ? const Color(0xFFCBD5E1)
          : theme.colorScheme.onSurfaceVariant;
    }

    Widget tabItem({
      required String label,
      required bool active,
      required VoidCallback onTap,
    }) {
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: pillBg(active),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              height: 1.2,
              color: textColor(active),
            ),
          ),
        ),
      );
    }

    Widget pipe() {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Text(
          '|',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            height: 1.2,
            color: isDark
                ? const Color(0xFF64748B)
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    Widget sortButton() {
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onSortTap(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              width: 1,
              color: isDark
                  ? Colors.white.withOpacity(0.12)
                  : Colors.black.withOpacity(0.12),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.sort_rounded,
                size: 16,
                color: isDark
                    ? const Color(0xFFCBD5E1)
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  sortLabel,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                    color: isDark
                        ? const Color(0xFFCBD5E1)
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.arrow_drop_down_rounded,
                size: 18,
                color: isDark
                    ? const Color(0xFFCBD5E1)
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      );
    }

    // Layout:
    // [ tabs .... ] [ sort button ]
    return Container(
      color: isDark ? const Color(0xFF0a0e1a) : theme.colorScheme.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              width: 1,
              color: isDark
                  ? Colors.white.withOpacity(0.08)
                  : Colors.black.withOpacity(0.08),
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Tabs (scrollable horizontally)
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    tabItem(
                      label: 'All',
                      active: activeIndex == 0,
                      onTap: () => onSelect(0),
                    ),
                    pipe(),
                    tabItem(
                      label: 'Entertainment',
                      active: activeIndex == 1,
                      onTap: () => onSelect(1),
                    ),
                    pipe(),
                    tabItem(
                      label: 'Sports',
                      active: activeIndex == 2,
                      onTap: () => onSelect(2),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(width: 12),

            // Sorting (fixed at end)
            sortButton(),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_FiltersHeaderDelegate oldDelegate) {
    return oldDelegate.activeIndex != activeIndex ||
        oldDelegate.sortLabel != sortLabel;
  }
}

/* ----------------------------- Feed list/grid --------------------------- */

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

  // RESPONSIVE GRID DELEGATE
  //
  // The big change here vs your previous version:
  // We bumped childAspectRatio UP so each grid tile is SHORTER.
  //
  // Before:
  //   ratio ~0.56 for 3-col desktop ⇒ card height ~1.8× width (super tall)
  //
  // Now:
  //   ratio ~0.9..1.1 ⇒ card height ~0.9–1.1× width (much tighter).
  //
  // We still tweak for breakpoints + textScale, but baseline is compact.
  SliverGridDelegate _gridDelegateFor(double width, double textScale) {
    // pick a target column width by breakpoint
    double maxTileW;
    if (width < 520) {
      maxTileW = width; // 1 col
    } else if (width < 900) {
      maxTileW = width / 2; // 2 cols
    } else if (width < 1400) {
      maxTileW = width / 3; // 3 cols
    } else {
      maxTileW = width / 4; // 4 cols
    }
    maxTileW = maxTileW.clamp(320.0, 480.0);

    // Base ratio (width / height). Bigger number = shorter tile.
    //
    // Narrower cards (phones ~320-340 wide) still need a little vertical
    // breathing room for image + text, so we start ~0.9. Wider cards can go
    // even shorter because text wraps less.
    double baseRatio;
    if (maxTileW <= 340) {
      baseRatio = 0.90;
    } else if (maxTileW <= 380) {
      baseRatio = 0.95;
    } else if (maxTileW <= 420) {
      baseRatio = .92; // was 1.00, Lower value makes cards taller
    } else {
      baseRatio = 1.05;
    }

    // If the user bumps system textScale up, we allow the cards
    // to get a bit taller (ratio goes DOWN).
    final effectiveRatio = baseRatio / textScale.clamp(1.0, 1.8);

    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxTileW,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: effectiveRatio,
    );
  }

  // ---------- sort helpers ----------
  double _trendingScore(Story s) {
    try {
      final dyn = (s as dynamic);
      final v = dyn.trendingScore ?? dyn.score ?? dyn.rank ?? 0.0;
      if (v is num) return v.toDouble();
    } catch (_) {}
    // fallback: newer is "hotter"
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
        if (picks.isNotEmpty) return picks;
        return input;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final feed = widget.feed;

    return AnimatedBuilder(
      animation: feed,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final textScale = MediaQuery.textScaleFactorOf(context);
            final gridDelegate = _gridDelegateFor(w, textScale);

            const horizontalPad = 12.0;
            const topPad = 0.0;
            final bottomSafe = MediaQuery.viewPaddingOf(context).bottom;
            final bottomPad = 28.0 + bottomSafe;

            if (feed.isInitialLoading) {
              return GridView.builder(
                padding: EdgeInsets.fromLTRB(
                    horizontalPad, 8, horizontalPad, bottomPad),
                physics: const AlwaysScrollableScrollPhysics(),
                cacheExtent: 1800,
                gridDelegate: gridDelegate,
                itemCount: 9,
                itemBuilder: (_, __) => const SkeletonCard(),
              );
            }

            if (feed.hasError && feed.items.isEmpty) {
              return ListView(
                padding: EdgeInsets.fromLTRB(
                    horizontalPad, 24, horizontalPad, bottomPad),
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  ErrorView(
                    message: feed.errorMessage ?? 'Something went wrong.',
                    onRetry: () => feed.load(reset: true),
                  ),
                ],
              );
            }

            // text filter
            final q = widget.searchText.text.trim().toLowerCase();
            final baseList = (q.isEmpty)
                ? feed.items
                : feed.items
                    .where((s) =>
                        s.title.toLowerCase().contains(q) ||
                        (s.summary ?? '').toLowerCase().contains(q))
                    .toList();

            // apply sort mode
            final displayList = _applySortMode(baseList);

            if (displayList.isEmpty) {
              final msg = widget.offline
                  ? "You're offline and no results match your search."
                  : "No matching items.";
              return ListView(
                padding: EdgeInsets.fromLTRB(
                    horizontalPad, 24, horizontalPad, bottomPad),
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  Center(child: Text(msg)),
                ],
              );
            }

            const showLoadMore = false;

            return GridView.builder(
              padding: EdgeInsets.fromLTRB(
                  horizontalPad, topPad, horizontalPad, bottomPad),
              physics: const AlwaysScrollableScrollPhysics(),
              cacheExtent: 2000,
              gridDelegate: gridDelegate,
              itemCount: displayList.length + (showLoadMore ? 1 : 0),
              itemBuilder: (_, i) {
                if (showLoadMore && i == displayList.length) {
                  return Center(
                    child: feed.isLoadingMore
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: CircularProgressIndicator(),
                          )
                        : OutlinedButton.icon(
                            onPressed: feed.loadMore,
                            icon: const Icon(Icons.expand_more_rounded),
                            label: const Text('Load more'),
                          ),
                  );
                }

                return StoryCard(
                  story: displayList[i],
                  allStories: displayList,
                  index: i,
                );
              },
            );
          },
        );
      },
    );
  }
}

/* ----------------------------- Feed paging model ------------------------ */

class _PagedFeed extends ChangeNotifier {
  _PagedFeed({required this.tab});
  final String tab;

  final List<Story> _items = [];
  bool _initialLoading = false;
  bool _loadingMore = false;
  bool _hasError = false;
  String? _errorMessage;
  bool _canLoadMore = false;

  List<Story> get items => List.unmodifiable(_items);
  bool get isInitialLoading => _initialLoading;
  bool get isLoadingMore => _loadingMore;
  bool get hasError => _hasError;
  String? get errorMessage => _errorMessage;
  bool get canLoadMore => _canLoadMore;

  // Effective timestamp for ordering and cursors.
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

      final cached = await FeedDiskCache.load(tab);
      if (cached.isNotEmpty) {
        _items.addAll(cached);
        _sortNewestFirst(_items);
        for (final s in cached) FeedCache.put(s);
        _initialLoading = false;
        notifyListeners();
      } else {
        notifyListeners();
      }
    }
    try {
      final list = await fetchFeed(tab: tab, since: _sinceCursor, limit: 40);

      // Merge by id (incoming wins), then sort.
      final byId = {for (final s in _items) s.id: s};
      for (final s in list) {
        byId[s.id] = s;
        FeedCache.put(s);
      }
      _items
        ..clear()
        ..addAll(byId.values);

      _sortNewestFirst(_items);

      // Cursor should be the NEWEST effective date we have (for delta fetch).
      final dates = _items
          .map(_eff)
          .whereType<DateTime>();
      _sinceCursor = dates.isEmpty
          ? null
          : dates.reduce((a, b) => a.isAfter(b) ? a : b);

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
      if (da == null && db == null) {
        return b.id.compareTo(a.id);
      }
      if (da == null) return 1; // nulls last
      if (db == null) return -1;
      final cmp = db.compareTo(da); // newest first
      if (cmp != 0) return cmp;
      return b.id.compareTo(a.id); // stable tiebreak
    });
  }
}

/* ----------------------------- Branding ----------------------------- */

class _ModernBrandLogo extends StatelessWidget {
  const _ModernBrandLogo();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFdc2626), Color(0xFFef4444)],
            ),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFdc2626).withOpacity(0.3),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Center(
            child: Text(
              '🎬',
              style: TextStyle(fontSize: 20, height: 1),
            ),
          ),
        ),
        const SizedBox(width: 10),
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [Color(0xFFdc2626), Color(0xFFef4444)],
          ).createShader(bounds),
          child: const Text(
            'CinePulse',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              letterSpacing: -0.5,
            ),
          ),
        ),
      ],
    );
  }
}
