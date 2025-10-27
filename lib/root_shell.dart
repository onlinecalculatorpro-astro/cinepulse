// lib/root_shell.dart
//
// RootShell = main scaffold with bottom nav + right-side settings drawer.
//
// This version does 3 things:
// 1. Keeps Theme picker bottom sheet (radio select), launched from drawer.
// 2. Adds Categories picker bottom sheet (multi-select), launched from drawer.
//    - It behaves just like Theme: drawer closes, bottom sheet slides up.
//    - The selection is stored in AppSettings, same place you already keep
//      themeMode. No separate category_prefs.dart, no extra singleton.
//    - AppSettings must expose:
//        Set<String> get selectedCategories
//        Future<void> setSelectedCategories(Set<String> next)
//      We assume it persists internally the same way themeMode does.
//    - Category rules:
//        • "all" means "show everything"
//        • If "all" is chosen, ignore others
//        • If user picks any specific category, drop "all"
//        • Never allow empty: fall back to {"all"}
// 3. AppDrawer must now accept onCategoryTap (like onThemeTap) and NOT render
//    inline chips. Drawer will just call onCategoryTap().
//
// Deep link handling / bottom nav behavior / responsive width are unchanged.

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
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

class RootShell extends StatefulWidget {
  const RootShell({super.key});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  // Used to control the Scaffold so we can open/close the endDrawer.
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // Which big page is showing in the body stack.
  // 0 = Home, 1 = Discover placeholder, 2 = Saved, 3 = Alerts.
  int _pageIndex = 0;

  // Which bottom nav item is highlighted.
  // 0 = Home, 1 = Search, 2 = Saved, 3 = Alerts.
  int _navIndex = 0;

  // Whether HomeScreen should render its inline search bar.
  bool _showSearchBar = false;

  // Deep-link boot flow.
  String? _pendingDeepLinkId;
  bool _deepLinkHandled = false;

  @override
  void initState() {
    super.initState();
    _captureInitialDeepLink();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _tryOpenPendingDeepLink());
  }

  /// Look for /#/s/<id> or /s/<id> to support direct story links.
  void _captureInitialDeepLink() {
    final frag = Uri.base.fragment; // hash-part on web ("" on mobile)
    final path = (frag.isNotEmpty ? frag : Uri.base.path).trim();
    final match = RegExp(r'(^|/)+s/([^/?#]+)').firstMatch(path);
    if (match != null) {
      _pendingDeepLinkId = match.group(2);
    }
  }

  Future<void> _tryOpenPendingDeepLink() async {
    if (_deepLinkHandled || _pendingDeepLinkId == null) return;

    const maxWait = Duration(seconds: 4);
    const tick = Duration(milliseconds: 200);
    final started = DateTime.now();

    // 1. Try to find story in FeedCache for ~4s while feeds warm up.
    while (mounted && DateTime.now().difference(started) < maxWait) {
      final Story? s = FeedCache.get(_pendingDeepLinkId!);
      if (s != null) {
        await _openDetails(s);
        return;
      }
      await Future<void>.delayed(tick);
    }

    // 2. Cold fetch the story if not cached.
    try {
      final s = await fetchStory(_pendingDeepLinkId!);
      if (!mounted) return;
      FeedCache.put(s);
      await _openDetails(s);
    } catch (_) {
      // If fetch fails we just stay on Home quietly.
    }
  }

  Future<void> _openDetails(Story s) async {
    _deepLinkHandled = true;
    // Make sure Home is visible behind details so back pops cleanly.
    if (_pageIndex != 0) setState(() => _pageIndex = 0);
    // Tiny delay so IndexedStack index actually updated before push.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    Navigator.of(context).push(fadeRoute(StoryDetailsScreen(story: s)));
  }

  // Called by HomeScreen header "Discover" action.
  void _openDiscover() {
    setState(() {
      _pageIndex = 1; // Discover placeholder tab
      _navIndex = (_navIndex == 1) ? 0 : _navIndex;
      _showSearchBar = false;
    });
  }

  // Called by HomeScreen header menu icon (burger).
  void _openEndDrawer() {
    _scaffoldKey.currentState?.openEndDrawer();
  }

  // Bottom navigation taps.
  void _onDestinationSelected(int i) {
    // 0=Home, 1=Search, 2=Saved, 3=Alerts
    if (i == 1) {
      // Search is special: don't navigate to new page,
      // just show Home with the inline search bar expanded.
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

  /* ───────────────────────────── THEME PICKER ─────────────────────────── */

  Future<void> _openThemePicker(BuildContext drawerContext) async {
    final current = AppSettings.instance.themeMode;

    // Close drawer first so sheet uses full width.
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

  /* ───────────────────────── CATEGORIES PICKER ────────────────────────── */

  Future<void> _openCategoryPicker(BuildContext drawerContext) async {
    // Close drawer before showing sheet.
    Navigator.pop(drawerContext);

    // Snapshot current categories from AppSettings.
    // AppSettings.instance.selectedCategories must be a Set<String>.
    final initialSet = AppSettings.instance.selectedCategories;

    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _CategoryPicker(initial: initialSet),
    );

    if (picked != null) {
      // We got new categories. Persist in AppSettings.
      await AppSettings.instance.setSelectedCategories(picked);
      // Rebuild root so UI reflecting categories (like drawer subtitle, feeds)
      // can update immediately.
      if (mounted) setState(() {});
    }
  }

  bool _isCompact(BuildContext context) =>
      MediaQuery.of(context).size.width < 900;

  @override
  Widget build(BuildContext context) {
    final compact = _isCompact(context);
    // We show bottom nav on phones AND on web. (Desktop-ish native maybe hides.)
    final showBottomNav = kIsWeb || compact;

    return WillPopScope(
      // Android back should close pushed routes first (e.g. StoryDetails).
      onWillPop: () async {
        final canPop = Navigator.of(context).canPop();
        if (canPop) Navigator.of(context).maybePop();
        return !canPop;
      },
      child: Scaffold(
        key: _scaffoldKey,

        // Right-side drawer (endDrawer). Edge swipe disabled so we
        // don't interfere with Android back gesture from left edge.
        drawer: null,
        drawerEnableOpenDragGesture: false,
        endDrawerEnableOpenDragGesture: false,
        endDrawer: Builder(
          // Builder so callbacks can `Navigator.pop(drawerCtx)` safely.
          builder: (drawerCtx) {
            return AppDrawer(
              onClose: () => Navigator.of(drawerCtx).pop(),
              onFiltersChanged: () => setState(() {}), // e.g. language changed
              onThemeTap: () => _openThemePicker(drawerCtx),
              onCategoryTap: () => _openCategoryPicker(drawerCtx),
              appShareUrl: 'https://cinepulse.netlify.app',
              privacyUrl: 'https://example.com/privacy', // TODO real link
              termsUrl: 'https://example.com/terms',     // TODO real link
            );
          },
        ),

        // App body. IndexedStack keeps state (scroll position, etc.) alive.
        body: _ResponsiveWidth(
          child: IndexedStack(
            index: _pageIndex,
            children: [
              HomeScreen(
                showSearchBar: _showSearchBar,
                onMenuPressed: _openEndDrawer,
                onOpenDiscover: _openDiscover,
                onHeaderRefresh: () {},
              ),
              const _DiscoverPlaceholder(),
              const SavedScreen(),
              const AlertsScreen(),
            ],
          ),
        ),

        // Bottom nav (🏠 / 🔍 / 🔖 / 🔔).
        bottomNavigationBar: showBottomNav
            ? SafeArea(
                top: false,
                child: NavigationBarTheme(
                  data: NavigationBarThemeData(
                    height: 70,
                    labelTextStyle: MaterialStateProperty.resolveWith(
                      (states) => TextStyle(
                        fontSize: 12,
                        fontWeight: states.contains(MaterialState.selected)
                            ? FontWeight.w700
                            : FontWeight.w500,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ),
                  child: NavigationBar(
                    selectedIndex: _navIndex,
                    labelBehavior:
                        NavigationDestinationLabelBehavior.alwaysShow,
                    onDestinationSelected: _onDestinationSelected,
                    destinations: const [
                      NavigationDestination(
                        icon: Text(
                          '🏠',
                          style: TextStyle(fontSize: 20, height: 1),
                        ),
                        selectedIcon: Text(
                          '🏠',
                          style: TextStyle(fontSize: 22, height: 1),
                        ),
                        label: 'Home',
                      ),
                      NavigationDestination(
                        icon: Text(
                          '🔍',
                          style: TextStyle(fontSize: 20, height: 1),
                        ),
                        selectedIcon: Text(
                          '🔍',
                          style: TextStyle(fontSize: 22, height: 1),
                        ),
                        label: 'Search',
                      ),
                      NavigationDestination(
                        icon: Text(
                          '🔖',
                          style: TextStyle(fontSize: 20, height: 1),
                        ),
                        selectedIcon: Text(
                          '🔖',
                          style: TextStyle(fontSize: 22, height: 1),
                        ),
                        label: 'Saved',
                      ),
                      NavigationDestination(
                        icon: Text(
                          '🔔',
                          style: TextStyle(fontSize: 20, height: 1),
                        ),
                        selectedIcon: Text(
                          '🔔',
                          style: TextStyle(fontSize: 22, height: 1),
                        ),
                        label: 'Alerts',
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

/* ───────────────────────── THEME PICKER BOTTOM SHEET ───────────────────── */

class _ThemeOption {
  final String label;
  final IconData icon;
  const _ThemeOption(this.label, this.icon);
}

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.current});
  final ThemeMode current;

  @override
  Widget build(BuildContext context) {
    final options = <ThemeMode, _ThemeOption>{
      ThemeMode.system:
          const _ThemeOption('System', Icons.auto_awesome),
      ThemeMode.light:
          const _ThemeOption('Light', Icons.light_mode_outlined),
      ThemeMode.dark:
          const _ThemeOption('Dark', Icons.dark_mode_outlined),
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
            const SizedBox(height: 8),
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

/* ─────────────────────── CATEGORIES PICKER BOTTOM SHEET ───────────────────
 *
 * Shown when the user taps "Categories" in the drawer.
 * Multi-select list with checkboxes.
 *
 * Behavior rules (enforced locally when toggling):
 *  - "all" means show everything.
 *  - if "all" is turned on, wipe others.
 *  - picking any specific category turns "all" off.
 *  - can't end up empty; fallback {"all"}.
 *
 * When user taps "Apply", we pop with the final Set<String>. RootShell then
 * calls AppSettings.instance.setSelectedCategories(newSet).
 * --------------------------------------------------------------------------*/

class _CategoryPicker extends StatefulWidget {
  const _CategoryPicker({required this.initial});

  final Set<String> initial; // comes from AppSettings.instance.selectedCategories

  @override
  State<_CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<_CategoryPicker> {
  // canonical keys
  static const String _kAll = 'all';
  static const String _kEntertainment = 'entertainment';
  static const String _kSports = 'sports';
  static const String _kTravel = 'travel';
  static const String _kFashion = 'fashion';

  late Set<String> _local; // working copy

  @override
  void initState() {
    super.initState();
    // copy current selection
    _local = Set<String>.from(widget.initial);
    // sanitize immediately so sheet always opens valid
    _sanitize();
  }

  // enforce the selection rules spelled out above
  void _sanitize() {
    if (_local.isEmpty) {
      _local = {_kAll};
      return;
    }
    if (_local.contains(_kAll) && _local.length > 1) {
      _local = {_kAll};
      return;
    }
  }

  void _toggle(String key) {
    if (key == _kAll) {
      // tapping "All" just resets to only all
      _local = {_kAll};
    } else {
      if (_local.contains(key)) {
        _local.remove(key);
      } else {
        _local.add(key);
      }
      // remove "all" if we're picking specific categories
      _local.remove(_kAll);
      // don't allow empty final state
      if (_local.isEmpty) {
        _local = {_kAll};
      }
    }
    // make sure we clean up any invalid combos
    _sanitize();
    setState(() {});
  }

  bool _checked(String key) => _local.contains(key);

  Widget _row({
    required String catKey,
    required IconData icon,
    required String title,
    required String desc,
  }) {
    final theme = Theme.of(context);
    final active = _checked(catKey);

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
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Categories',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Pick what shows up in Home. You can choose more than one.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            // "All"
            _row(
              catKey: _kAll,
              icon: Icons.apps_rounded,
              title: 'All',
              desc: 'Everything',
            ),

            // "Entertainment"
            _row(
              catKey: _kEntertainment,
              icon: Icons.local_movies_rounded,
              title: 'Entertainment',
              desc: 'Movies, OTT, celebrity updates',
            ),

            // "Sports"
            _row(
              catKey: _kSports,
              icon: Icons.sports_cricket_rounded,
              title: 'Sports',
              desc: 'Cricket, match talk, highlights',
            ),

            // "Travel"
            _row(
              catKey: _kTravel,
              icon: Icons.flight_takeoff_rounded,
              title: 'Travel',
              desc: 'Trips, destinations, culture clips',
            ),

            // "Fashion"
            _row(
              catKey: _kFashion,
              icon: Icons.checkroom_rounded,
              title: 'Fashion',
              desc: 'Looks, style drops, red carpet',
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
                  Navigator.pop<Set<String>>(context, _local);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ───────────────────────── DISCOVER PLACEHOLDER ───────────────────────── */

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

/* ───────────────────────── RESPONSIVE WIDTH WRAPPER ─────────────────────
 * Centers content on tablets / desktop so pages don’t grow too wide.
 * On phones it just returns the child unchanged.
 * ------------------------------------------------------------------------*/

class _ResponsiveWidth extends StatelessWidget {
  const _ResponsiveWidth({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      if (w <= 720) return child; // phones: full-bleed

      // tablets & web: clamp width for nicer reading
      final maxW = w >= 1400
          ? 1200.0
          : (w >= 1200)
              ? 1080.0
              : 980.0;
      return Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: child,
        ),
      );
    });
  }
}
