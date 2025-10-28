// lib/features/home/home_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
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

/* ──────────────────────────────────────────────────────────────────────────
   Sort mode enum
   ───────────────────────────────────────────────────────────────────────── */
enum _SortMode {
  latest,
  trending,
  views,
  editorsPick,
}

/* ──────────────────────────────────────────────────────────────────────────
   HomeScreen
   ───────────────────────────────────────────────────────────────────────── */
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.showSearchBar = false,
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
  // Tabs we expose in UI
  static const Map<String, String> _tabs = {
    'all': 'All',
    'entertainment': 'Entertainment',
    'sports': 'Sports',
  };

  static const Duration _kAutoRefreshEvery = Duration(minutes: 2);
  static const Duration _kRealtimeDebounce = Duration(milliseconds: 500);

  late final TabController _tab =
      TabController(length: _tabs.length, vsync: this);

  final TextEditingController _search = TextEditingController();

  final Map<String, _PagedFeed> _feeds = {
    for (final k in _tabs.keys) k: _PagedFeed(tab: k)
  };

  // keys for each category chip ("All", "Entertainment", "Sports")
  final List<GlobalKey> _chipKeys =
      List.generate(_tabs.length, (_) => GlobalKey());

  bool _offline = false;
  bool _isForeground = true;

  _SortMode _sortMode = _SortMode.latest;

  // timers / subs
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

  @override
  void initState() {
    super.initState();

    // warm feeds
    for (final f in _feeds.values) {
      unawaited(f.load(reset: true));
    }

    _tab.addListener(_onTabChanged);
    WidgetsBinding.instance.addObserver(this);

    // connectivity watcher
    _connSub = Connectivity().onConnectivityChanged.listen((event) {
      final hasNetwork = _hasNetworkFrom(event);
      if (!mounted) return;
      final wasOffline = _offline;
      setState(() => _offline = !hasNetwork);

      if (hasNetwork) {
        unawaited(_currentFeed.load(reset: false));
        _ensureWebSocket();
      } else {
        _teardownWebSocket();
      }

      if (hasNetwork && wasOffline) _wsBackoffSecs = 2;
    });

    // initial connectivity
    () async {
      final initial = await Connectivity().checkConnectivity();
      final hasNetwork = _hasNetworkFrom(initial);
      if (!mounted) return;
      setState(() => _offline = !hasNetwork);
      if (hasNetwork) _ensureWebSocket();
    }();

    // silent periodic refresh
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

  /* ────────────────────────────────────────────────────────────────────────
     Realtime WS
     ─────────────────────────────────────────────────────────────────────── */
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
            if (obj is Map && obj['type'] == 'ping') return;
          } catch (_) {}
          _scheduleRealtimeRefresh();
        },
        onDone: _onWsClosed,
        onError: (_) => _onWsClosed(),
        cancelOnError: true,
      );
      _wsBackoffSecs = 2;
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
      if (_search.text.isNotEmpty) return;
      unawaited(_currentFeed.load(reset: false));
    });
  }

  /* ────────────────────────────────────────────────────────────────────────
     Helpers
     ─────────────────────────────────────────────────────────────────────── */
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

  void _ensureChipVisible(int tabIndex) {
    if (!mounted) return;
    if (tabIndex < 0 || tabIndex >= _chipKeys.length) return;

    // wait until layout is done so the chip actually has a context/size
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
    if (mounted) {
      setState(() {});
      _ensureChipVisible(_tab.index);
    }
  }

  Future<void> _refreshManually() async {
    final key = _currentTabKey;
    await _feeds[key]!.load(reset: true);
    widget.onHeaderRefresh?.call();
  }

  void _onTabTap(int i) {
    if (i >= 0 && i < _tab.length) {
      _tab.animateTo(i);
      unawaited(_feeds[_tabs.keys.elementAt(i)]!.load(reset: false));
      _ensureChipVisible(i);
    }
  }

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

  /* ────────────────────────────────────────────────────────────────────────
     UI BUILD
     ─────────────────────────────────────────────────────────────────────── */
  @override
  Widget build(BuildContext context) {
    try {
      return _buildSimpleLayout(context);
    } catch (err, stack) {
      debugPrint('HomeScreen simple build ERROR: $err\n$stack');
      return _HomeCrashedView(
        error: err.toString(),
        stack: stack.toString(),
      );
    }
  }

  Widget _buildSimpleLayout(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0b0f17) : theme.colorScheme.surface;

    // breakpoint for mobile vs wide layout
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= 768;

    return Scaffold(
      backgroundColor: bgColor,
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

                  // Saved + Alerts should only appear on wide layouts.
                  if (isWide) ...[
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
                  ],

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
                ],
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          // inline Search (like Search tab mode)
          if (widget.showSearchBar)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: SearchBarInput(
                controller: _search,
                onExitSearch: () {
                  _search.clear();
                  FocusScope.of(context).unfocus();
                },
              ),
            ),

          // offline banner
          if (_offline)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: OfflineBanner(),
            ),

          // category + sort row (NOT sticky for now)
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

          // Tab pages -> Expanded so it fills remaining height
          Expanded(
            child: TabBarView(
              controller: _tab,
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
    );
  }
}

/* ──────────────────────────────────────────────────────────────────────────
   Filters row (used in simple layout instead of SliverPersistentHeader)
   ───────────────────────────────────────────────────────────────────────── */
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

  static const accent = Color(0xFFdc2626);

  @override
  Widget build(BuildContext context) {
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
              color: accent.withOpacity(0.4),
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              height: 1.2,
              color: accent,
            ),
          ),
        ),
      );
    }

    Widget tabChip(int index, String label, Key itemKey) {
      final sel = (activeIndex == index);
      if (sel) {
        return InkWell(
          key: itemKey,
          borderRadius: BorderRadius.circular(999),
          onTap: () => onSelect(index),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: accent, width: 1),
              boxShadow: [
                BoxShadow(
                  color: accent.withOpacity(0.4),
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
      return Container(
        key: itemKey,
        child: inactiveChip(label, () => onSelect(index)),
      );
    }

    Widget sortButton() {
      IconData sortIcon;
      switch (sortMode) {
        case _SortMode.latest:
          sortIcon = Icons.access_time_rounded;
          break;
        case _SortMode.trending:
          sortIcon = Icons.local_fire_department_rounded;
          break;
        case _SortMode.views:
          sortIcon = Icons.visibility_rounded;
          break;
        case _SortMode.editorsPick:
          sortIcon = Icons.star_rounded;
          break;
      }

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
              color: accent.withOpacity(0.4),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                sortIcon,
                size: 16,
                color: accent,
              ),
              const SizedBox(width: 6),
              Text(
                sortLabel,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.2,
                  color: accent,
                ),
              ),
              const SizedBox(width: 2),
              const Icon(
                Icons.arrow_drop_down_rounded,
                size: 18,
                color: accent,
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
          // scrollable chips
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
          // sort pill
          sortButton(),
        ],
      ),
    );
  }
}

/* ──────────────────────────────────────────────────────────────────────────
   Feed list (unchanged logic)
   ───────────────────────────────────────────────────────────────────────── */
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
            const topPad = 8.0;
            final bottomSafe = MediaQuery.viewPaddingOf(context).bottom;
            final bottomPad = 28.0 + bottomSafe;

            if (feed.isInitialLoading) {
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

            if (feed.hasError && feed.items.isEmpty) {
              return ListView(
                padding: EdgeInsets.fromLTRB(
                  horizontalPad,
                  24,
                  horizontalPad,
                  bottomPad,
                ),
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  ErrorView(
                    message: feed.errorMessage ?? 'Something went wrong.',
                    onRetry: () => feed.load(reset: true),
                  ),
                ],
              );
            }

            final q = widget.searchText.text.trim().toLowerCase();
            final baseList = (q.isEmpty)
                ? feed.items
                : feed.items
                    .where((s) =>
                        s.title.toLowerCase().contains(q) ||
                        (s.summary ?? '').toLowerCase().contains(q))
                    .toList();

            final displayList = _applySortMode(baseList);

            if (displayList.isEmpty) {
              final msg = widget.offline
                  ? "You're offline and no results match your search."
                  : "No matching items.";
              return ListView(
                padding: EdgeInsets.fromLTRB(
                  horizontalPad,
                  24,
                  horizontalPad,
                  bottomPad,
                ),
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  Center(child: Text(msg)),
                ],
              );
            }

            const showLoadMore = false;

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

/* ──────────────────────────────────────────────────────────────────────────
   Feed paging model
   ───────────────────────────────────────────────────────────────────────── */
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

      final byId = {for (final s in _items) s.id: s};
      for (final s in list) {
        byId[s.id] = s;
        FeedCache.put(s);
      }
      _items
        ..clear()
        ..addAll(byId.values);

      _sortNewestFirst(_items);

      final dates = _items.map(_eff).whereType<DateTime>();
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
      if (da == null) return 1;
      if (db == null) return -1;
      final cmp = db.compareTo(da); // newest first
      if (cmp != 0) return cmp;
      return b.id.compareTo(a.id);
    });
  }
}

/* ──────────────────────────────────────────────────────────────────────────
   Header icon button
   ───────────────────────────────────────────────────────────────────────── */
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
    final bg = isDark
        ? const Color(0xFF0f172a).withOpacity(0.7)
        : Colors.black.withOpacity(0.06);
    final borderColor = const Color(0xFFdc2626).withOpacity(0.3);
    final iconColor = isDark ? Colors.white : Colors.black87;

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
              color: borderColor,
              width: 1,
            ),
          ),
          child: Icon(
            icon,
            size: 16,
            color: iconColor,
          ),
        ),
      ),
    );
  }
}

/* ──────────────────────────────────────────────────────────────────────────
   Brand logo in header
   ───────────────────────────────────────────────────────────────────────── */
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
            color: Colors.white, // note: white on light bg = low contrast,
                                 // but we’ll keep for now, same as design
          ),
        ),
      ],
    );
  }
}


/* ──────────────────────────────────────────────────────────────────────────
   CRASH VIEW
   ───────────────────────────────────────────────────────────────────────── */
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
