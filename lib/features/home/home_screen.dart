// lib/features/home/home_screen.dart
//
// HomeScreen = main "Home" tab.
// Updates in this rewrite:
//  • Search row opens/closes smoothly (AnimatedSize) and autofocuses
//  • Uses shared SearchBarInput with `[🔍][text][✕]`
//  • Grid only rebuilds on search text changes via ValueListenableBuilder
//  • Minor perf polish for realtime/refresh checks
//  • Inline search row is locally themed (no red) on mobile & desktop
//  • Flutter 3.35: AnimatedSize no longer uses `vsync`

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../../core/api.dart';            // fetchFeed(), kApiBaseUrl
import '../../core/cache.dart';          // FeedDiskCache, FeedCache, SavedStore
import '../../core/models.dart';
import '../../theme/theme_colors.dart';  // brand + text helpers
import '../../widgets/app_toolbar.dart'; // shared toolbar row
import '../../widgets/error_view.dart';
import '../../widgets/offline_banner.dart';
import '../../widgets/search_bar.dart';  // SearchBarInput
import '../../widgets/skeleton_card.dart';
import '../story/story_card.dart';

/* ──────────────────────────────────────────────────────────────────────────
 * Sort mode enum
 * ───────────────────────────────────────────────────────────────────────── */
enum _SortMode { latest, trending, views, editorsPick }

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

  final bool showSearchBar;
  final VoidCallback? onMenuPressed;
  final VoidCallback? onHeaderRefresh;
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
  }

  @override
  void dispose() {
    _realtimeDebounceTimer?.cancel();
    _autoRefresh?.cancel();

    _wsReconnectTimer?.cancel();
    _wsSub?.cancel();
    _ws?.sink.close(ws_status.normalClosure);
    _ws = null;

    _connSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);

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
      unawaited(_currentFeed.load(reset: false));
      _ensureWebSocket();
    } else if (!_isForeground) {
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
    if (_ws != null) return;

    final url = _buildWsUrl();

    try {
      _ws = WebSocketChannel.connect(Uri.parse(url));
      _wsSub = _ws!.stream.listen(
        (data) {
          try {
            final obj = json.decode(data.toString());
            if (obj is Map && obj['type'] == 'ping') return; // keep-alive
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

  void _ensureChipVisible(int tabIndex) {
    if (!mounted) return;
    if (tabIndex < 0 || tabIndex >= _chipKeys.length) return;

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
    setState(() {}); // update AppToolbar active chip
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

  IconData _iconForSort(_SortMode mode) {
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
              style: TextStyle(fontSize: 13, color: secondaryTextColor(ctx)),
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
    final cs = theme.colorScheme;

    final bgColor = theme.scaffoldBackgroundColor;

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
                  const _BrandLogo(),
                  const Spacer(),

                  if (isWide) ...[
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

          // Row 2: shared AppToolbar (chips + sort pill)
          AppToolbar(
            tabs: _tabs.values.toList(growable: false),
            activeIndex: _tab.index,
            onSelect: _onTabTap,
            chipKeys: _chipKeys,
            sortLabel: _sortModeLabel(_sortMode),
            sortIcon: _iconForSort(_sortMode),
            onSortTap: () => _showSortSheet(context),
          ),

          // Row 3: inline search bar (smooth show/hide + autofocus)
          AnimatedSize(
            // NOTE: Flutter 3.35 — no `vsync` param
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: showSearchRow
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    // Local theme override so the search doesn't inherit any red.
                    child: Theme(
                      data: Theme.of(context).copyWith(
                        inputDecorationTheme: InputDecorationTheme(
                          filled: true,
                          fillColor: neutralPillBg(context),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          hintStyle: TextStyle(color: faintTextColor(context)),
                          prefixIconColor: secondaryTextColor(context),
                          suffixIconColor: secondaryTextColor(context),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: outlineHairline(context),
                              width: 1,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: outlineHairline(context),
                              width: 1.2,
                            ),
                          ),
                        ),
                        textSelectionTheme: TextSelectionThemeData(
                          cursorColor: secondaryTextColor(context),
                          selectionColor:
                              Theme.of(context).colorScheme.primary.withOpacity(0.15),
                          selectionHandleColor: secondaryTextColor(context),
                        ),
                      ),
                      child: SearchBarInput(
                        controller: _search,
                        autofocus: true,
                        onExitSearch: () {
                          setState(() {
                            _search.clear();
                            _showHeaderSearch = false;
                          });
                          FocusScope.of(context).unfocus();
                        },
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          // Feed content (TabBarView)
          Expanded(
            // Rebuild only the grid area when search text changes.
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _search,
              builder: (context, _, __) {
                return TabBarView(
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
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/* ──────────────────────────────────────────────────────────────────────────
 * Feed list / grid per tab
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
        return input; // newest-first already
      case _SortMode.trending:
        final list = [...input];
        list.sort((a, b) => _trendingScore(b).compareTo(_trendingScore(a)));
        return list;
      case _SortMode.views:
        final list = [...input];
        list.sort((a, b) => _viewsCount(b).compareTo(_viewsCount(a)));
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
              border: Border.all(color: acc, width: 1),
              boxShadow: [
                BoxShadow(
                  color: acc.withOpacity(0.35),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Icon(Icons.bookmark_rounded, size: 14, color: cs.onPrimary),
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
                    padding: EdgeInsets.fromLTRB(hPad, topPad, hPad, bottomPad),
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
                    padding: EdgeInsets.fromLTRB(hPad, 24, hPad, bottomPad),
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      ErrorView(
                        message: feed.errorMessage ?? 'Something went wrong.',
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
                    padding: EdgeInsets.fromLTRB(hPad, 24, hPad, bottomPad),
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [Center(child: Text(msg))],
                  );
                }

                // 4. Normal grid (no "Load more" button in this revision)
                return GridView.builder(
                  padding: EdgeInsets.fromLTRB(hPad, topPad, hPad, bottomPad),
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
 * Paged feed model
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
  DateTime? _eff(Story s) => s.normalizedAt ?? s.publishedAt ?? s.releaseDate;

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
        notifyListeners();
      }
    }

    try {
      final fresh = await fetchFeed(tab: tab, since: _sinceCursor, limit: 40);

      // Merge by ID.
      final byId = {for (final s in _items) s.id: s};
      for (final s in fresh) {
        byId[s.id] = s;
        FeedCache.put(s);
      }

      _items..clear()..addAll(byId.values);
      _sortNewestFirst(_items);

      // Update cursor to newest timestamp in list.
      final allDates = _items.map(_eff).whereType<DateTime>();
      _sinceCursor = allDates.isEmpty
          ? null
          : allDates.reduce((a, b) => a.isAfter(b) ? a : b);

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
      if (da == null && db == null) return b.id.compareTo(a.id);
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
          child: Icon(
            icon,
            size: 16,
            color: primaryTextColor(context),
          ),
        ),
      ),
    );
  }
}

/* ──────────────────────────────────────────────────────────────────────────
 * Brand logo blob in header
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
          child: Center(
            child: Text(
              '🎬',
              style: TextStyle(fontSize: 16, height: 1, color: cs.onPrimary),
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      color: scheme.background,
      width: double.infinity,
      height: double.infinity,
      padding: const EdgeInsets.all(16),
      child: SafeArea(
        child: SingleChildScrollView(
          child: DefaultTextStyle(
            style: TextStyle(
              fontSize: 14,
              color: freshnessColor(context), // brand freshness red
              fontFamily: 'monospace',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'HomeScreen crashed while building.\n'
                  'Screenshot this and send it 👇\n',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: freshnessColor(context),
                  ),
                ),
                Text('Error:', style: TextStyle(color: primaryTextColor(context))),
                Text(error, style: TextStyle(color: primaryTextColor(context))),
                const SizedBox(height: 12),
                Text('Stack:', style: TextStyle(color: primaryTextColor(context))),
                Text(stack, style: TextStyle(color: primaryTextColor(context))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
