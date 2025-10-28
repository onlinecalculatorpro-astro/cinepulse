// lib/root_shell.dart
//
// RootShell = main scaffold / shell for the whole app.
// It owns:
//  - the tab pages (Home / Discover / Saved / Alerts) via IndexedStack
//  - the global right-side drawer (AppDrawer)
//  - the bottom nav on phones only (<768px width)
//  - deep link handling for /s/<id> → StoryDetailsScreen
//
// Goals in this rewrite:
// 1. Treat CinePulse like one product everywhere (Home, Story, Drawer).
//    - Drawer should describe "what you're seeing right now" (Entertainment · Mixed language).
//    - Drawer should communicate "Early access", safety rules, etc.
//    - Category sheet copy talks like the app ("What to show").
//    - Theme picker sheet copy explicitly says it affects the whole app.
// 2. Make category prefs & theme prefs still flow the same way.
// 3. Keep the phone-vs-desktop responsive behavior exactly the same.
//

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app/app_settings.dart';
import 'core/api.dart' show fetchStory;
import 'core/cache.dart';
import 'core/models.dart';
import 'core/utils.dart'; // fadeRoute()
import 'features/home/home_screen.dart';
import 'features/saved/saved_screen.dart';
import 'features/story/story_details.dart';
import 'features/alerts/alerts_screen.dart';
import 'widgets/app_drawer.dart';

const String _kAppVersion = '0.1.0';

/// User-facing category prefs (which verticals they want to see).
/// We expose:
/// - a stable set of keys
/// - a user-friendly summary() string for UI
/// - a _sanitize() so state never becomes empty / illegal
class CategoryPrefs extends ChangeNotifier {
  CategoryPrefs._internal();
  static final CategoryPrefs instance = CategoryPrefs._internal();

  static const String keyAll = 'all';
  static const String keyEntertainment = 'entertainment';
  static const String keySports = 'sports';
  static const String keyTravel = 'travel';
  static const String keyFashion = 'fashion';

  // default feed is "All" (which effectively means "Entertainment" today
  // in production; Sports/Travel/Fashion are roadmap).
  final Set<String> _selected = {keyAll};

  Set<String> get selected => Set.unmodifiable(_selected);

  bool isSelected(String k) => _selected.contains(k);

  /// Applies a new set from UI, then normalizes and notifies.
  void applySelection(Set<String> incoming) {
    _selected
      ..clear()
      ..addAll(incoming);
    _sanitize();
    notifyListeners();
  }

  /// Returns a short human string for surfaces like:
  /// - Drawer status line
  /// - "What to show" previews
  /// Examples:
  ///   "All"
  ///   "Entertainment"
  ///   "Entertainment +2"
  String summary() {
    if (_selected.contains(keyAll)) return 'All';

    final pretty = _selected.map((k) {
      switch (k) {
        case keyEntertainment:
          return 'Entertainment';
        case keySports:
          return 'Sports';
        case keyTravel:
          return 'Travel';
        case keyFashion:
          return 'Fashion';
        default:
          return k;
      }
    }).toList()
      ..sort();

    if (pretty.isEmpty) return 'All';
    if (pretty.length == 1) return pretty.first;
    return '${pretty.first} +${pretty.length - 1}';
  }

  /// Internal guardrails:
  /// - If "all" and others are both selected, collapse to just "all".
  /// - Never allow empty set.
  void _sanitize() {
    if (_selected.contains(keyAll) && _selected.length > 1) {
      _selected
        ..clear()
        ..add(keyAll);
      return;
    }
    if (_selected.isEmpty) {
      _selected.add(keyAll);
    }
  }
}

/// RootShell is the single top-level Scaffold for the app.
///
/// Tabs:
///   0 = Home
///   1 = Discover (placeholder right now)
///   2 = Saved
///   3 = Alerts
///
/// Bottom nav (phone only):
///   0 = Home
///   1 = Search (this is "Home + inline search bar")
///   2 = Saved
///   3 = Alerts
///
/// On desktop/tablet we hide the bottom nav and rely on header actions.
///
/// It also:
///  - Handles deep link "/s/<id>" → opens StoryDetailsScreen
///  - Owns the right-side drawer and wires callbacks for Theme / Categories
class RootShell extends StatefulWidget {
  const RootShell({super.key});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // Which tab page is visible in the IndexedStack.
  // 0 = Home, 1 = Discover, 2 = Saved, 3 = Alerts
  int _pageIndex = 0;

  // Which item is lit up in the bottom nav.
  // 0 = Home, 1 = Search, 2 = Saved, 3 = Alerts
  int _navIndex = 0;

  // This mirrors tapping the "Search" tab in bottom nav:
  // We don't navigate away; we just ask HomeScreen to reveal its inline search bar.
  bool _showSearchBar = false;

  // Deep link handling (/s/<id>) (mostly for web / app links).
  String? _pendingDeepLinkId;
  bool _deepLinkHandled = false;

  @override
  void initState() {
    super.initState();
    _captureInitialDeepLink();
    // After first frame, try to resolve & open.
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryOpenPendingDeepLink());
  }

  /// Checks the initial URL for a pattern like /s/<id>
  /// and stores that id so we can resolve the story and push details.
  void _captureInitialDeepLink() {
    final frag = Uri.base.fragment; // on web we might have "#/s/abcdef"
    final path = (frag.isNotEmpty ? frag : Uri.base.path).trim();
    final match = RegExp(r'(^|/)+s/([^/?#]+)').firstMatch(path);
    if (match != null) {
      _pendingDeepLinkId = match.group(2);
    }
  }

  /// Try to open deep link story.
  /// 1. First attempt FeedCache for ~4s
  /// 2. Then fallback to fetchStory()
  Future<void> _tryOpenPendingDeepLink() async {
    if (_deepLinkHandled || _pendingDeepLinkId == null) return;

    const maxWait = Duration(seconds: 4);
    const tick = Duration(milliseconds: 200);
    final started = DateTime.now();

    // Try cache briefly (lets the feed warm up on cold launch).
    while (mounted && DateTime.now().difference(started) < maxWait) {
      final Story? cached = FeedCache.get(_pendingDeepLinkId!);
      if (cached != null) {
        await _openDetails(cached);
        return;
      }
      await Future<void>.delayed(tick);
    }

    // Fallback: direct fetch.
    try {
      final s = await fetchStory(_pendingDeepLinkId!);
      if (!mounted) return;
      FeedCache.put(s);
      await _openDetails(s);
      return;
    } catch (_) {
      // ignore if fetch fails
    }
  }

  /// Push StoryDetailsScreen for [s].
  /// Ensures the Home tab is active beneath it first.
  Future<void> _openDetails(Story s) async {
    _deepLinkHandled = true;

    if (_pageIndex != 0) {
      setState(() => _pageIndex = 0);
    }

    // Wait a tick so Scaffold/Navigator are settled.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;

    Navigator.of(context).push(
      fadeRoute(StoryDetailsScreen(story: s)),
    );
  }

  /* ───────────────────── Header icon actions from HomeScreen ───────────────────── */

  // "Discover" header icon → go to Discover tab.
  void _openDiscover() {
    setState(() {
      _pageIndex = 1;
      // If we were highlighting Search in bottom nav, drop back to Home highlight.
      _navIndex = (_navIndex == 1) ? 0 : _navIndex;
      _showSearchBar = false;
    });
  }

  // "Menu" / hamburger / profile icon in header → open right-side drawer.
  void _openEndDrawer() {
    _scaffoldKey.currentState?.openEndDrawer();
  }

  // Header icon → Saved tab.
  void _openSaved() {
    setState(() {
      _pageIndex = 2;
      _navIndex = 2;
      _showSearchBar = false;
    });
  }

  // Header icon → Alerts tab.
  void _openAlerts() {
    setState(() {
      _pageIndex = 3;
      _navIndex = 3;
      _showSearchBar = false;
    });
  }

  /* ───────────────────────────── Bottom nav taps ─────────────────────────────
   *
   * Bottom nav meanings:
   *   0 = Home tab
   *   1 = "Search" → still Home tab, but showSearchBar = true
   *   2 = Saved tab
   *   3 = Alerts tab
   */
  void _onDestinationSelected(int i) {
    if (i == 1) {
      // "Search": highlight Search, stay on Home page, show inline search bar.
      setState(() {
        _pageIndex = 0;
        _navIndex = 1;
        _showSearchBar = true;
      });
      return;
    }

    setState(() {
      _navIndex = i;
      _showSearchBar = false;
      if (i == 0) _pageIndex = 0;
      if (i == 2) _pageIndex = 2;
      if (i == 3) _pageIndex = 3;
    });
  }

  /* ───────────────────────── Theme picker (from drawer) ─────────────────────────
   *
   * When user taps "Theme" in the drawer, we:
   *  - close the drawer
   *  - open a bottom sheet with System / Light / Dark radio list
   *  - apply + refresh
   */
  Future<void> _openThemePicker(BuildContext drawerContext) async {
    final current = AppSettings.instance.themeMode;

    // Close drawer first so the sheet animates cleanly from bottom.
    Navigator.pop(drawerContext);

    final picked = await showModalBottomSheet<ThemeMode>(
      context: context,
      showDragHandle: true,
      builder: (_) => _ThemePicker(current: current),
    );

    if (picked != null) {
      await AppSettings.instance.setThemeMode(picked);
      if (mounted) setState(() {});
    }
  }

  /* ─────────────────────── Category picker (from drawer) ───────────────────────
   *
   * When user taps "What to show" (Categories) in the drawer:
   *  - close drawer
   *  - open a sheet with checkboxes: All / Entertainment / Sports (coming soon) / ...
   *  - applySelection() is called on CategoryPrefs
   */
  Future<void> _openCategoryPicker(BuildContext drawerContext) async {
    // Close drawer so sheet isn't stacked weird.
    Navigator.pop(drawerContext);

    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _CategoryPicker(
        initial: CategoryPrefs.instance.selected,
      ),
    );

    if (picked != null && picked.isNotEmpty) {
      CategoryPrefs.instance.applySelection(picked);
      if (mounted) setState(() {});
    }
  }

  /* ───────────────────────────── Responsive helpers ─────────────────────────────
   *
   * "compact" == phone-ish width. On compact:
   *   - bottom nav bar is visible
   * On >=768px:
   *   - bottom nav bar hidden
   *   - app feels like a desktop web app
   */
  bool _isCompact(BuildContext context) =>
      MediaQuery.of(context).size.width < 768;

  @override
  Widget build(BuildContext context) {
    final compact = _isCompact(context);
    final showBottomNav = compact;

    // Drawer wants to show a status line like:
    // "Entertainment · Mixed language"
    // We get the category summary from CategoryPrefs;
    // language mode is currently managed in the drawer itself,
    // but we can still pass a hint ("Mixed language") if needed.
    final categorySummary = CategoryPrefs.instance.summary();
    final feedStatusLine = '$categorySummary · Mixed language';

    // Drawer also wants a nicer version label:
    // "Version 0.1.0 · Early access"
    final versionLabel = 'Version $_kAppVersion · Early access';

    return WillPopScope(
      onWillPop: () async {
        // Android back button behavior:
        // If the nested Navigator can pop (e.g. StoryDetailsScreen is open),
        // pop that instead of closing the entire app shell.
        final canPop = Navigator.of(context).canPop();
        if (canPop) Navigator.of(context).maybePop();
        return !canPop;
      },
      child: Scaffold(
        key: _scaffoldKey,

        // We explicitly don't use the left drawer.
        drawer: null,
        drawerEnableOpenDragGesture: false,

        // Right-side drawer (what you call Menu).
        endDrawerEnableOpenDragGesture: false,
        endDrawer: Builder(
          builder: (drawerCtx) {
            return AppDrawer(
              // Close "X" in drawer header.
              onClose: () => Navigator.of(drawerCtx).pop(),

              // Tell the shell to rebuild (chips / summary text etc.) if prefs changed.
              onFiltersChanged: () => setState(() {}),

              // "Theme" row in drawer.
              onThemeTap: () => _openThemePicker(drawerCtx),

              // "What to show" row in drawer.
              onCategoryTap: () => _openCategoryPicker(drawerCtx),

              // These URLs feed the "Share CinePulse" / policy rows.
              appShareUrl: 'https://cinepulse.netlify.app',
              privacyUrl: 'https://example.com/privacy', // TODO real link
              termsUrl: 'https://example.com/terms',     // TODO real link

              // New info so the drawer can speak in the same voice as rest of app.
              // 1. Short status under CinePulse brand ("what am I seeing right now")
              // 2. Friendly version string ("Early access")
              feedStatusLine: feedStatusLine,
              versionLabel: versionLabel,
            );
          },
        ),

        // Body: our tab pages, width-clamped on desktop via _ResponsiveWidth.
        body: _ResponsiveWidth(
          child: IndexedStack(
            index: _pageIndex,
            children: [
              _DebugPageWrapper(
                builder: (ctx) => HomeScreen(
                  // Home gets toggles / callbacks so it can
                  //  - show inline search bar (Search tab)
                  //  - open drawer
                  //  - jump to Saved / Alerts / Discover tabs
                  //  - trigger manual refresh
                  showSearchBar: _showSearchBar,
                  onMenuPressed: _openEndDrawer,
                  onOpenDiscover: _openDiscover,
                  onOpenSaved: _openSaved,
                  onOpenAlerts: _openAlerts,
                  onHeaderRefresh: () {},
                ),
              ),
              _DebugPageWrapper(
                builder: (ctx) => const _DiscoverPlaceholder(),
              ),
              _DebugPageWrapper(
                builder: (ctx) => const SavedScreen(),
              ),
              _DebugPageWrapper(
                builder: (ctx) => const AlertsScreen(),
              ),
            ],
          ),
        ),

        // Bottom nav bar (Home / Search / Saved / Alerts)
        // Only visible on compact (phone-ish).
        bottomNavigationBar: showBottomNav
            ? CineBottomNavBar(
                currentIndex: _navIndex,
                onTap: _onDestinationSelected,
              )
            : null,
      ),
    );
  }
}

/* ───────────────────────────── THEME PICKER SHEET ─────────────────────────────
 *
 * This is the bottom sheet opened when user taps "Theme" in the drawer.
 * We clarified text to match brand tone:
 *  - Title "Theme"
 *  - Short helper line "Affects Home and story cards"
 * Then we offer System / Light / Dark.
 */
class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.current});
  final ThemeMode current;

  @override
  Widget build(BuildContext context) {
    final options = <ThemeMode, ({String label, IconData icon})>{
      ThemeMode.system: (label: 'System', icon: Icons.auto_awesome),
      ThemeMode.light: (label: 'Light', icon: Icons.light_mode_outlined),
      ThemeMode.dark: (label: 'Dark', icon: Icons.dark_mode_outlined),
    };

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Theme',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Affects Home and story cards.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            for (final entry in options.entries)
              RadioListTile<ThemeMode>(
                value: entry.key,
                groupValue: current,
                onChanged: (val) => Navigator.pop(context, val),
                title: Row(
                  children: [
                    Icon(entry.value.icon, size: 18),
                    const SizedBox(width: 8),
                    Text(entry.value.label),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/* ─────────────────────────── CATEGORY PICKER SHEET ────────────────────────────
 *
 * This bottom sheet lets the user say "What to show".
 * We changed the language to match the rest of the app:
 *  - Title "What to show"
 *  - Helper text in plain voice
 *  - Each row explains in user terms:
 *     - All: "Everything we have (Entertainment)"
 *     - Entertainment: "Movies, OTT, on-air drama"
 *     - Sports / Travel / Fashion can be marked as "coming soon"
 *
 * We still return a Set<String> so RootShell can call
 * CategoryPrefs.instance.applySelection(...)
 */
class _CategoryPicker extends StatefulWidget {
  const _CategoryPicker({required this.initial});
  final Set<String> initial;

  @override
  State<_CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<_CategoryPicker> {
  late Set<String> _local;

  @override
  void initState() {
    super.initState();
    _local = Set<String>.of(widget.initial);
  }

  void _toggle(String key) {
    final all = CategoryPrefs.keyAll;

    if (key == all) {
      _local
        ..clear()
        ..add(all);
    } else {
      if (_local.contains(key)) {
        _local.remove(key);
      } else {
        _local.add(key);
      }
      // If you start choosing specific verticals, drop "All".
      _local.remove(all);
      // Never allow [].
      if (_local.isEmpty) {
        _local.add(all);
      }
    }
    setState(() {});
  }

  bool _isChecked(String key) => _local.contains(key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget row({
      required String catKey,
      required IconData icon,
      required String title,
      required String desc,
    }) {
      final active = _isChecked(catKey);
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _toggle(catKey),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: active,
                onChanged: (_) => _toggle(catKey),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                icon,
                size: 20,
                color: active
                    ? const Color(0xFFdc2626)
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight:
                            active ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    Text(
                      desc,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'What to show',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Pick what you want in your feed. Right now we mostly cover Entertainment.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            row(
              catKey: CategoryPrefs.keyAll,
              icon: Icons.apps_rounded,
              title: 'All',
              desc: 'Everything we have (Entertainment)',
            ),
            row(
              catKey: CategoryPrefs.keyEntertainment,
              icon: Icons.local_movies_rounded,
              title: 'Entertainment',
              desc: 'Movies, OTT, on-air drama, box office',
            ),
            row(
              catKey: CategoryPrefs.keySports,
              icon: Icons.sports_cricket_rounded,
              title: 'Sports',
              desc: 'Match talk, highlights (coming soon)',
            ),
            row(
              catKey: CategoryPrefs.keyTravel,
              icon: Icons.flight_takeoff_rounded,
              title: 'Travel',
              desc: 'Trips, destinations, culture clips (coming soon)',
            ),
            row(
              catKey: CategoryPrefs.keyFashion,
              icon: Icons.checkroom_rounded,
              title: 'Fashion',
              desc: 'Looks, red carpet, style drops (coming soon)',
            ),

            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.check_rounded),
                label: const Text('Apply'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFdc2626),
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onPressed: () {
                  Navigator.pop(context, _local);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ─────────────────────────── DISCOVER PLACEHOLDER ────────────────────────────
 *
 * Until Discover is implemented, show a friendly placeholder.
 */
class _DiscoverPlaceholder extends StatelessWidget {
  const _DiscoverPlaceholder();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Discover (coming soon)',
        style: GoogleFonts.inter(
          fontWeight: FontWeight.w700,
          fontSize: 22,
        ),
      ),
    );
  }
}

/* ───────────────────────────── RESPONSIVE WIDTH ──────────────────────────────
 *
 * On desktop/tablet, we center content and clamp max width to ~1300px so the
 * feed grid doesn’t stretch into absurdly long rows.
 * On phones (<768px) we just return child directly.
 */
class _ResponsiveWidth extends StatelessWidget {
  const _ResponsiveWidth({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      if (w < 768) return child;

      const maxW = 1300.0;
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxW),
          child: child,
        ),
      );
    });
  }
}

/* ──────────────────────────── CINE BOTTOM NAV BAR ────────────────────────────
 *
 * Phone bottom nav. This matches the app vibe:
 * - Frosted/blurred glass bar
 * - Red accent glow on active item
 * - Icons for Home / Search / Saved / Alerts
 *
 * We didn't change visuals here. Just tightened inline comments
 * so it’s obvious how it maps to _onDestinationSelected().
 */
class CineBottomNavBar extends StatelessWidget {
  const CineBottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;

  static const _accent = Color(0xFFdc2626);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bgGradientColors = isDark
        ? <Color>[
            const Color(0xFF1e2537).withOpacity(0.9),
            const Color(0xFF0b0f17).withOpacity(0.95),
          ]
        : <Color>[
            theme.colorScheme.surface.withOpacity(0.95),
            theme.colorScheme.surface.withOpacity(0.9),
          ];

    final borderColor = isDark
        ? Colors.white.withOpacity(0.06)
        : Colors.black.withOpacity(0.06);

    final items = <_NavItemSpec>[
      _NavItemSpec(
        icon: Icons.home_rounded,
        label: 'Home',
      ),
      _NavItemSpec(
        icon: Icons.search_rounded,
        label: 'Search',
      ),
      _NavItemSpec(
        icon: Icons.bookmark_rounded,
        label: 'Saved',
      ),
      _NavItemSpec(
        icon: Icons.notifications_rounded,
        label: 'Alerts',
      ),
    ];

    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: bgGradientColors,
            ),
            border: Border(
              top: BorderSide(
                color: borderColor,
                width: 1,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.6),
                blurRadius: 30,
                spreadRadius: 0,
                offset: const Offset(0, -20),
              ),
            ],
          ),
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 8,
            bottom: bottomInset == 0 ? 12 : bottomInset,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(items.length, (i) {
              final spec = items[i];
              final selected = i == currentIndex;
              return Expanded(
                child: _NavButton(
                  icon: spec.icon,
                  label: spec.label,
                  selected: selected,
                  onTap: () => onTap(i),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _NavItemSpec {
  const _NavItemSpec({
    required this.icon,
    required this.label,
  });
  final IconData icon;
  final String label;
}

/// Single button in the bottom nav ("Home", "Search", ...)
/// Red glow + red border for selected state.
class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  static const _accent = Color(0xFFdc2626);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final Color inactiveBg = isDark
        ? const Color(0xFF0f172a).withOpacity(0.7)
        : Colors.black.withOpacity(0.06);
    final Color inactiveBorder = _accent.withOpacity(0.3);
    final Color inactiveText = isDark ? Colors.white : Colors.black87;

    final Color activeBg = _accent.withOpacity(0.12);
    final Color activeBorder = _accent;
    final Color activeText = _accent;

    final bg = selected ? activeBg : inactiveBg;
    final borderColor = selected ? activeBorder : inactiveBorder;
    final fg = selected ? activeText : inactiveText;

    final boxShadow = selected
        ? [
            BoxShadow(
              color: _accent.withOpacity(0.4),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ]
        : <BoxShadow>[];

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: borderColor,
                width: 1,
              ),
              boxShadow: boxShadow,
            ),
            child: Icon(
              icon,
              size: 20,
              color: fg,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              height: 1.2,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

/* ────────────────────────── DEBUG WRAPPER / ERROR FALLBACK ───────────────────
 *
 * On some phones (esp. release APK), if a tab build throws during layout,
 * Flutter will just render a blank/white region. That's awful for debugging.
 *
 * _DebugPageWrapper tries to build the real widget, and if that throws
 * it captures the exception + stacktrace and shows them full-screen
 * in a monospace view. You screenshot that and send it, so we can fix.
 */

class _DebugPageWrapper extends StatelessWidget {
  const _DebugPageWrapper({required this.builder});

  final Widget Function(BuildContext) builder;

  @override
  Widget build(BuildContext context) {
    try {
      return builder(context);
    } catch (err, st) {
      return _DebugPageErrorView(error: err, stack: st);
    }
  }
}

class _DebugPageErrorView extends StatelessWidget {
  const _DebugPageErrorView({
    required this.error,
    required this.stack,
  });

  final Object error;
  final StackTrace stack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0b0f17) : Colors.white;
    final fg = isDark ? Colors.white : Colors.black;

    return Container(
      color: bg,
      width: double.infinity,
      height: double.infinity,
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: DefaultTextStyle(
          style: TextStyle(
            color: fg,
            fontSize: 13,
            height: 1.4,
            fontFamily: 'monospace',
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '💥 Build error',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(error.toString()),
              const SizedBox(height: 12),
              Text(stack.toString()),
            ],
          ),
        ),
      ),
    );
  }
}
