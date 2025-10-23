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

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.showSearchBar = false, // show only when Search tab active
    this.onMenuPressed,         // opens drawer (from RootShell)
    this.onHeaderRefresh,       // optional external hook
    this.onOpenDiscover,        // header "Discover" button -> Search tab
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
  static const Map<String, String> _tabs = {
    'all': 'All',
    'trailers': 'Trailers',
    'ott': 'OTT',
    'intheatres': 'In Theatres',
    'comingsoon': 'Coming Soon',
  };

  // Silent background refresh cadence (fallback if WS not available).
  static const Duration _kAutoRefreshEvery = Duration(minutes: 2);

  // Debounce for rapid WS event bursts -> a single fetch.
  static const Duration _kRealtimeDebounce = Duration(milliseconds: 500);

  late final TabController _tab = TabController(length: _tabs.length, vsync: this);

  final TextEditingController _search = TextEditingController();
  final GlobalKey<RefreshIndicatorState> _refreshKey = GlobalKey<RefreshIndicatorState>();

  final Map<String, _PagedFeed> _feeds = {for (final k in _tabs.keys) k: _PagedFeed(tab: k)};

  bool _offline = false;
  bool _isForeground = true;

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

    // First load for all tabs (cached-first).
    for (final f in _feeds.values) {
      unawaited(f.load(reset: true));
    }

    // Observe app lifecycle for resume refresh.
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
        _ensureWebSocket(); // connect (or reconnect) when online
      } else {
        // Offline: drop the socket to avoid loop.
        _teardownWebSocket();
      }

      // If we just came back from offline, reset backoff for quick reconnects.
      if (hasNetwork && wasOffline) {
        _wsBackoffSecs = 2;
      }
    });

    // Initial connectivity state.
    () async {
      final initial = await Connectivity().checkConnectivity();
      final hasNetwork = _hasNetworkFrom(initial);
      if (!mounted) return;
      setState(() => _offline = !hasNetwork);
      if (hasNetwork) _ensureWebSocket();
    }();

    // Auto refresh tick (silent).
    _autoRefresh = Timer.periodic(_kAutoRefreshEvery, (_) => _tickAutoRefresh());

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

    for (final f in _feeds.values) {
      f.dispose();
    }
    _tab.dispose();
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
    // Build ws/wss from your REST base, e.g. https://api.example.com -> wss://api.example.com/v1/realtime/ws
    final base = kApiBaseUrl; // provided by core/api.dart
    final u = Uri.parse(base);
    final scheme = (u.scheme == 'https') ? 'wss' : 'ws';

    // If your API has a base path (e.g. /api), preserve it.
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
          } catch (_) {
            // If not JSON, ignore—server always sends JSON though.
          }
          _scheduleRealtimeRefresh();
        },
        onDone: _onWsClosed,
        onError: (_) => _onWsClosed(),
        cancelOnError: true,
      );
      // Connected → reset backoff
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

    // Exponential backoff reconnect (cap at 60s)
    _wsReconnectTimer?.cancel();
    _wsReconnectTimer = Timer(Duration(seconds: _wsBackoffSecs), _ensureWebSocket);
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
    // Debounce bursts of messages into a single gentle delta fetch.
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

  // Manual pull-to-refresh: full reset + optional external hook.
  Future<void> _refresh() async {
    final key = _currentTabKey;
    await _feeds[key]!.load(reset: true);
    widget.onHeaderRefresh?.call();
  }

  // Background silent refresh tick (fallback if WS is blocked by proxies).
  void _tickAutoRefresh() {
    if (!mounted) return;
    if (_offline) return;
    if (!_isForeground) return;
    if (_search.text.isNotEmpty) return; // don’t disturb while searching
    unawaited(_currentFeed.load(reset: false));
  }

  /* ------------------------------- UI -------------------------------------- */

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0a0e1a) : theme.colorScheme.surface,
      body: RefreshIndicator.adaptive(
        key: _refreshKey,
        onRefresh: _refresh,
        color: const Color(0xFFdc2626),
        child: CustomScrollView(
          slivers: [
            // Glassy app bar
            SliverAppBar(
              floating: true,
              pinned: true,
              elevation: 0,
              backgroundColor: isDark
                  ? const Color(0xFF0f172a).withOpacity(0.95)
                  : theme.colorScheme.surface.withOpacity(0.95),
              surfaceTintColor: Colors.transparent,
              toolbarHeight: 70,
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
                        bottom: BorderSide(color: Color(0x0Fffffff), width: 1),
                      ),
                    ),
                  ),
                ),
              ),
              leading: IconButton(
                icon: const Icon(Icons.menu_rounded),
                onPressed: widget.onMenuPressed,
                tooltip: 'Menu',
              ),
              title: const _ModernBrandLogo(), // 🎬
              actions: [
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: () {
                    _refreshKey.currentState?.show();
                    unawaited(_refresh());
                  },
                ),
                IconButton(
                  tooltip: 'Discover',
                  icon: Icon(kIsWeb ? Icons.explore_outlined : Icons.manage_search_rounded),
                  onPressed: widget.onOpenDiscover,
                ),
                const SizedBox(width: 4),
              ],
            ),

            // Search bar only on the Search tab
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

            // Tabs (sticky)
            SliverPersistentHeader(
              pinned: true,
              delegate: _ModernTabsDelegate(
                child: Builder(
                  builder: (context) {
                    return Container(
                      color: isDark ? const Color(0xFF0a0e1a) : theme.colorScheme.surface,
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF1e293b).withOpacity(0.4)
                              : theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.05),
                            width: 1,
                          ),
                        ),
                        child: TabBar(
                          controller: _tab,
                          isScrollable: true,
                          tabAlignment: TabAlignment.start,
                          labelPadding: const EdgeInsets.symmetric(horizontal: 16),
                          dividerColor: Colors.transparent,
                          indicatorSize: TabBarIndicatorSize.tab,
                          indicator: BoxDecoration(
                            color: const Color(0xFFdc2626),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFFdc2626).withOpacity(0.3),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          labelColor: Colors.white,
                          labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                          unselectedLabelColor:
                              isDark ? const Color(0xFF94a3b8) : theme.colorScheme.onSurfaceVariant,
                          unselectedLabelStyle:
                              const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                          tabs: _tabs.values.map((t) => Tab(text: t)).toList(),
                          onTap: (_) {
                            setState(() {});
                            // When switching tabs, fetch recent deltas quickly.
                            unawaited(_currentFeed.load(reset: false));
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),

            // “Trending Now” header — compact
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                child: SizedBox(
                  height: 36,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: const [
                        Padding(
                          padding: EdgeInsets.only(bottom: 1),
                          child: Text('🔥', style: TextStyle(fontSize: 18, height: 1)),
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Trending Now',
                          style: TextStyle(
                            fontSize: 20,
                            height: 1.05,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Main tabbed feed list — auto-responsive grid (slightly taller cards)
            SliverFillRemaining(
              child: TabBarView(
                controller: _tab,
                children: _tabs.keys.map((key) {
                  final feed = _feeds[key]!;
                  return _FeedList(
                    key: PageStorageKey('feed-$key'),
                    feed: feed,
                    searchText: _search,
                    offline: _offline,
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

// Tabs Delegate
class _ModernTabsDelegate extends SliverPersistentHeaderDelegate {
  _ModernTabsDelegate({required this.child});
  final Widget child;

  @override
  double get minExtent => 64;
  @override
  double get maxExtent => 64;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => child;

  @override
  bool shouldRebuild(_ModernTabsDelegate oldDelegate) => false;
}

// Responsive Feed List (auto columns + *slightly taller* tiles)
class _FeedList extends StatefulWidget {
  const _FeedList({
    super.key,
    required this.feed,
    required this.searchText,
    required this.offline,
  });

  final _PagedFeed feed;
  final TextEditingController searchText;
  final bool offline;

  @override
  State<_FeedList> createState() => _FeedListState();
}

class _FeedListState extends State<_FeedList>
    with AutomaticKeepAliveClientMixin<_FeedList> {
  @override
  bool get wantKeepAlive => true;

  SliverGridDelegate _gridDelegateFor(double width, double textScale) {
    // Determine columns via max cross-axis extent (auto responsive).
    double maxTileW;
    if (width < 520) {
      maxTileW = width;         // 1 col
    } else if (width < 900) {
      maxTileW = width / 2;     // 2 cols
    } else if (width < 1400) {
      maxTileW = width / 3;     // 3 cols
    } else {
      maxTileW = width / 4;     // 4 cols
    }
    maxTileW = maxTileW.clamp(320.0, 480.0);

    // Make cards a bit taller than before:
    // childAspectRatio = width / height, so LOWER = TALLER.
    double ratio;
    if (maxTileW <= 340) {
      ratio = 0.56; // taller on narrow phones
    } else if (maxTileW <= 380) {
      ratio = 0.64;
    } else if (maxTileW <= 420) {
      ratio = 0.72;
    } else {
      ratio = 0.80;
    }
    // Respect large text accessibility (taller with bigger text).
    ratio /= textScale.clamp(1.0, 1.8);

    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxTileW,
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      childAspectRatio: ratio,
    );
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

            final horizontalPad = 16.0;
            final topPad = 0.0;
            final bottomSafe = MediaQuery.viewPaddingOf(context).bottom;
            final bottomPad = 28.0 + bottomSafe;

            if (feed.isInitialLoading) {
              return GridView.builder(
                padding: EdgeInsets.fromLTRB(horizontalPad, 8, horizontalPad, bottomPad),
                physics: const AlwaysScrollableScrollPhysics(),
                cacheExtent: 1800, // slightly higher since cards are taller
                gridDelegate: gridDelegate,
                itemCount: 9,
                itemBuilder: (_, __) => const SkeletonCard(),
              );
            }

            if (feed.hasError && feed.items.isEmpty) {
              return ListView(
                padding: EdgeInsets.fromLTRB(horizontalPad, 24, horizontalPad, bottomPad),
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
            final filtered = (q.isEmpty)
                ? feed.items
                : feed.items
                    .where((s) =>
                        s.title.toLowerCase().contains(q) ||
                        (s.summary ?? '').toLowerCase().contains(q))
                    .toList();

            if (filtered.isEmpty) {
              final msg = widget.offline
                  ? "You're offline and no results match your search."
                  : "No matching items.";
              return ListView(
                padding: EdgeInsets.fromLTRB(horizontalPad, 24, horizontalPad, bottomPad),
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  Center(child: Text(msg)),
                ],
              );
            }

            const showLoadMore = false;

            return GridView.builder(
              padding: EdgeInsets.fromLTRB(horizontalPad, topPad, horizontalPad, bottomPad),
              physics: const AlwaysScrollableScrollPhysics(),
              cacheExtent: 2000,
              gridDelegate: gridDelegate,
              itemCount: filtered.length + (showLoadMore ? 1 : 0),
              itemBuilder: (_, i) {
                if (showLoadMore && i == filtered.length) {
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
                return StoryCard(story: filtered[i]);
              },
            );
          },
        );
      },
    );
  }
}

// Paging/feed model (unchanged)
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

      final dates = _items.map((e) => e.publishedAt).whereType<DateTime>();
      _sinceCursor = dates.isEmpty ? null : dates.reduce((a, b) => a.isBefore(b) ? a : b);

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
      final pa = a.publishedAt;
      final pb = b.publishedAt;
      if (pa == null && pb == null) return 0;
      if (pa == null) return 1;
      if (pb == null) return -1;
      return pb.compareTo(pa);
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
            child: Text('🎬', style: TextStyle(fontSize: 20, height: 1)),
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
