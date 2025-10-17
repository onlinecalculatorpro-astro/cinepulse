// lib/features/home/home_screen.dart
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/api.dart';
import '../../core/cache.dart';
import '../../core/models.dart';
import '../../widgets/error_view.dart';
import '../../widgets/offline_banner.dart';
import '../../widgets/skeleton_card.dart';
import 'widgets/search_bar.dart';
import '../../features/story/story_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  // ✅ Tabs: All · Trailers · OTT · In Theatres · Coming Soon
  static const Map<String, String> _tabs = {
    'all': 'All',
    'trailers': 'Trailers',
    'ott': 'OTT',
    'intheatres': 'In Theatres',
    'comingsoon': 'Coming Soon',
  };

  late final TabController _tab =
      TabController(length: _tabs.length, vsync: this);

  final TextEditingController _search = TextEditingController();
  final GlobalKey<RefreshIndicatorState> _refreshKey =
      GlobalKey<RefreshIndicatorState>();

  final Map<String, _PagedFeed> _feeds = {
    for (final k in _tabs.keys) k: _PagedFeed(tab: k),
  };

  bool _offline = false;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();

    // Kick off initial loads (with disk cache for fast-first paint).
    for (final f in _feeds.values) {
      f.load(reset: true);
    }

    // Online/offline banner wiring.
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNetwork = results.any((r) => r != ConnectivityResult.none);
      if (mounted) setState(() => _offline = !hasNetwork);
    });
    () async {
      final results = await Connectivity().checkConnectivity();
      final hasNetwork = results.any((r) => r != ConnectivityResult.none);
      if (mounted) setState(() => _offline = !hasNetwork);
    }();

    _search.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _connSub?.cancel();
    _search.dispose();
    for (final f in _feeds.values) {
      f.dispose();
    }
    _tab.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() {}); // local filter only
    });
  }

  Future<void> _refresh() async {
    final key = _tabs.keys.elementAt(_tab.index);
    await _feeds[key]!.load(reset: true);
  }

  // Long-press the refresh icon to force-refresh all tabs.
  Future<void> _refreshAll() async {
    for (final f in _feeds.values) {
      await f.load(reset: true);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All tabs refreshed')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isPhone = MediaQuery.of(context).size.width < 600;

    return RefreshIndicator.adaptive(
      key: _refreshKey,
      onRefresh: _refresh,
      // ✅ Allow pull-to-refresh from anywhere on the page (nice on mobile)
      triggerMode: RefreshIndicatorTriggerMode.anywhere,
      child: NestedScrollView(
        headerSliverBuilder: (_, __) => [
          // Brand + search in a sliver app bar
          SliverAppBar(
            pinned: true,
            centerTitle: false,
            toolbarHeight: isPhone ? 56 : 64,
            expandedHeight: isPhone ? 112 : 140,
            leading: Builder(
              builder: (ctx) => IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () => Scaffold.of(ctx).openDrawer(),
              ),
            ),
            title: const _BrandInline(),
            flexibleSpace: const _HeaderGradient(),
            bottom: PreferredSize(
              preferredSize: Size.fromHeight(isPhone ? 60 : 70),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                // ✅ Search + Refresh icon row
                child: Row(
                  children: [
                    Expanded(child: SearchBarInput(controller: _search)),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: 'Refresh',
                      child: IconButton.filledTonal(
                        onPressed: () {
                          _refreshKey.currentState?.show(); // show spinner
                          _refresh();
                        },
                        onLongPress: _refreshAll, // optional power-user shortcut
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          if (_offline)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: OfflineBanner(),
              ),
            ),

          // Sticky tabs bar
          SliverPersistentHeader(
            pinned: true,
            delegate: _TabsHeaderDelegate(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: TabBar(
                    controller: _tab,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 18),
                    dividerColor: Colors.transparent,
                    indicatorSize: TabBarIndicatorSize.tab,
                    splashBorderRadius: BorderRadius.circular(28),
                    indicator: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    labelColor: scheme.onPrimary,
                    unselectedLabelColor: scheme.onSurfaceVariant,
                    tabs: _tabs.values.map((t) => Tab(text: t)).toList(),
                    onTap: (_) => setState(() {}),
                  ),
                ),
              ),
            ),
          ),
        ],
        // The tab views scroll smoothly with NestedScrollView
        body: TabBarView(
          controller: _tab,
          children: _tabs.keys.map((key) {
            final feed = _feeds[key]!;
            return _FeedList(
              key: PageStorageKey('feed-$key'), // ✅ keep scroll per tab
              feed: feed,
              searchText: _search,
              offline: _offline,
            );
          }).toList(),
        ),
      ),
    );
  }
}

/* ===================== Header helpers ===================== */

class _HeaderGradient extends StatelessWidget {
  const _HeaderGradient();

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            s.primaryContainer.withOpacity(0.95),
            s.surface.withOpacity(0.75),
          ],
        ),
      ),
    );
  }
}

class _BrandInline extends StatelessWidget {
  const _BrandInline();

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/Logo.png',
          height: 24, // width will scale to keep aspect
          errorBuilder: (_, __, ___) =>
              Icon(Icons.movie_creation_outlined, color: onSurface),
        ),
        const SizedBox(width: 8),
        Text(
          'CinePulse',
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w800,
            fontSize: 18,
            color: onSurface,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}

/* ===================== Tabs header ===================== */

class _TabsHeaderDelegate extends SliverPersistentHeaderDelegate {
  _TabsHeaderDelegate({required this.child});
  final Widget child;

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
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: child,
    );
  }

  @override
  bool shouldRebuild(_TabsHeaderDelegate oldDelegate) => false;
}

/* ===================== Feed list (keep-alive) ===================== */

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
  bool get wantKeepAlive => true; // ✅ preserve state across tab switches

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final feed = widget.feed;

    return AnimatedBuilder(
      animation: feed,
      builder: (context, _) {
        if (feed.isInitialLoading) {
          return ListView.builder(
            padding: const EdgeInsets.only(top: 8, bottom: 24),
            physics: const AlwaysScrollableScrollPhysics(),
            cacheExtent: 1200,
            itemCount: 6,
            itemBuilder: (_, __) => const SkeletonCard(),
          );
        }
        if (feed.hasError && feed.items.isEmpty) {
          return ErrorView(
            message: feed.errorMessage ?? 'Something went wrong.',
            onRetry: () => feed.load(reset: true),
          );
        }

        // Local search filter
        final q = widget.searchText.text.trim().toLowerCase();
        final filtered = (q.isEmpty)
            ? feed.items
            : feed.items
                .where((s) =>
                    s.title.toLowerCase().contains(q) ||
                    (s.summary ?? '').toLowerCase().contains(q))
                .toList();

        if (filtered.isEmpty) {
          return ListView(
            padding: const EdgeInsets.only(top: 32),
            physics: const AlwaysScrollableScrollPhysics(), // ✅ still pull-to-refresh
            children: [
              Center(
                child: Text(
                  widget.offline
                      ? 'You’re offline and no results match your search.'
                      : 'No matching items.',
                ),
              ),
            ],
          );
        }

        // Paging toggle (kept false until API supports before/after)
        const showLoadMore = false;

        return ListView.builder(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          physics: const AlwaysScrollableScrollPhysics(),
          cacheExtent: 1400, // ✅ smoother scrolling
          itemCount: filtered.length + (showLoadMore ? 1 : 0),
          itemBuilder: (_, i) {
            if (showLoadMore && i == filtered.length) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Center(
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
                ),
              );
            }
            return StoryCard(story: filtered[i]);
          },
        );
      },
    );
  }
}

/* ===================== Paging model ===================== */

class _PagedFeed extends ChangeNotifier {
  _PagedFeed({required this.tab});
  final String tab;

  final List<Story> _items = [];
  bool _initialLoading = false;
  bool _loadingMore = false;
  bool _hasError = false;
  String? _errorMessage;
  bool _canLoadMore = false; // disabled until API supports paging

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

      // Fast paint from disk
      final cached = await FeedDiskCache.load(tab);
      if (cached.isNotEmpty) {
        _items.addAll(cached);
        // Ensure newest-first even from cache.
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

      // Merge by id to avoid duplicates
      final byId = {for (final s in _items) s.id: s};
      for (final s in list) {
        byId[s.id] = s;
        FeedCache.put(s);
      }
      _items
        ..clear()
        ..addAll(byId.values);

      // 🔽 Keep UI newest → oldest.
      _sortNewestFirst(_items);

      // Keep the oldest timestamp as cursor (for future paging support)
      final dates = _items.map((e) => e.publishedAt).whereType<DateTime>();
      _sinceCursor =
          dates.isEmpty ? null : dates.reduce((a, b) => a.isBefore(b) ? a : b);

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

  // ---- Helpers ----
  void _sortNewestFirst(List<Story> list) {
    list.sort((a, b) {
      final pa = a.publishedAt;
      final pb = b.publishedAt;
      if (pa == null && pb == null) return 0;
      if (pa == null) return 1; // nulls last
      if (pb == null) return -1;
      return pb.compareTo(pa); // newest first
    });
  }
}
