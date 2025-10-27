// lib/root_shell.dart
//
// RootShell = main scaffold with:
//  - IndexedStack pages (Home / Discover / Saved / Alerts)
//  - Right-side endDrawer (AppDrawer)
//  - Bottom nav on MOBILE ONLY
//
// IMPORTANT VISUAL BEHAVIOR TO MATCH APPROVED DESIGN:
//  - On phone widths, we still show the bottom nav (Home / Search / Saved / Alerts).
//  - On wider layouts (tablet / desktop / large web), we HIDE the bottom nav
//    completely so it feels like a proper web app, not a blown-up phone.
//    (In other words: no bottom nav bar at >=768px.)
//  - Content is centered and clamped to ~1300px max width on big screens,
//    same as the HTML mock's max-page-width.
//
// Drawer rules (unchanged):
//  - Drawer lives on the right (endDrawer).
//  - Drawer shows language chips, theme row, categories row, etc.
//  - Tapping "Theme" or "Categories" in the drawer opens a bottom sheet
//    (Theme picker = radio System/Light/Dark,
//     Category picker = checkbox list with Apply).
//
// CategoryPrefs is the singleton source of truth for category filters.
// HomeScreen is still responsible for rendering feed UI based on
// CategoryPrefs.instance.selected (not wired in this file yet, just conceptually).

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, ChangeNotifier;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app/app_settings.dart';
import 'core/api.dart' show fetchStory; // deep-link fallback
import 'core/cache.dart';
import 'core/models.dart';
import 'core/utils.dart'; // fadeRoute()
import 'features/home/home_screen.dart';
import 'features/saved/saved_screen.dart';
import 'features/story/story_details.dart';
import 'features/alerts/alerts_screen.dart';
import 'widgets/app_drawer.dart';

/* ────────────────────────────────────────────────────────────────────────────
 * CATEGORY PREFS
 *
 * Global singleton for the currently selected verticals.
 *
 * Rules:
 *  - "all" means everything.
 *  - If "all" is in the set, ignore any other categories (collapse to {'all'}).
 *  - User can choose multiple (Entertainment + Sports, etc.).
 *  - We never allow an empty set; fallback to {'all'}.
 *
 * This is in-memory only right now. Wire SharedPreferences later if needed.
 * ────────────────────────────────────────────────────────────────────────────*/
class CategoryPrefs extends ChangeNotifier {
  CategoryPrefs._internal();
  static final CategoryPrefs instance = CategoryPrefs._internal();

  static const String keyAll = 'all';
  static const String keyEntertainment = 'entertainment';
  static const String keySports = 'sports';
  static const String keyTravel = 'travel';
  static const String keyFashion = 'fashion';

  final Set<String> _selected = {keyAll}; // default

  Set<String> get selected => Set.unmodifiable(_selected);

  bool isSelected(String k) => _selected.contains(k);

  /// Replace the current selection, normalize it, and notify.
  void applySelection(Set<String> incoming) {
    _selected
      ..clear()
      ..addAll(incoming);
    _sanitize();
    notifyListeners();
  }

  /// Drawer summary pill, ex: "All", "Entertainment", "Entertainment +2"
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

  void _sanitize() {
    // If "all" plus others => collapse to just "all".
    if (_selected.contains(keyAll) && _selected.length > 1) {
      _selected
        ..clear()
        ..add(keyAll);
      return;
    }
    // Can't be empty.
    if (_selected.isEmpty) {
      _selected.add(keyAll);
    }
  }
}

/* ────────────────────────────────────────────────────────────────────────────
 * ROOT SHELL
 *
 * Hosts:
 *  - IndexedStack of tabs (Home / Discover / Saved / Alerts)
 *  - Right-side drawer
 *  - Bottom nav (but ONLY on narrow/mobile, hidden on desktop width ≥768px)
 *  - Deep link handling (/s/<id> opens StoryDetails)
 *  - Opens Theme & Category pickers as bottom sheets
 * ────────────────────────────────────────────────────────────────────────────*/
class RootShell extends StatefulWidget {
  const RootShell({super.key});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  // lets us open/close the endDrawer
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // Body page index in the IndexedStack:
  // 0 = Home, 1 = Discover placeholder, 2 = Saved, 3 = Alerts
  int _pageIndex = 0;

  // Which bottom nav item is highlighted:
  // 0 = Home, 1 = Search, 2 = Saved, 3 = Alerts
  int _navIndex = 0;

  // If true, HomeScreen shows the inline search bar under the header
  // (that's how we represent tapping "Search" in bottom nav).
  bool _showSearchBar = false;

  // Deep-link state for /s/<id>
  String? _pendingDeepLinkId;
  bool _deepLinkHandled = false;

  @override
  void initState() {
    super.initState();
    _captureInitialDeepLink();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _tryOpenPendingDeepLink(),
    );
  }

  /// Parse initial URL fragment/path for /s/<id> so we can open StoryDetails.
  void _captureInitialDeepLink() {
    final frag = Uri.base.fragment; // hash part on web, "" on mobile
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

    // 1. Try FeedCache for up to ~4s while feeds warm up.
    while (mounted && DateTime.now().difference(started) < maxWait) {
      final Story? cached = FeedCache.get(_pendingDeepLinkId!);
      if (cached != null) {
        await _openDetails(cached);
        return;
      }
      await Future<void>.delayed(tick);
    }

    // 2. Fallback: fetch story directly.
    try {
      final s = await fetchStory(_pendingDeepLinkId!);
      if (!mounted) return;
      FeedCache.put(s);
      await _openDetails(s);
      return;
    } catch (_) {
      // If we can't load the story, we just stay on Home.
    }
  }

  Future<void> _openDetails(Story s) async {
    _deepLinkHandled = true;

    // Make sure Home tab is selected underneath the pushed details screen,
    // so when user backs out they land on Home.
    if (_pageIndex != 0) setState(() => _pageIndex = 0);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    Navigator.of(context).push(
      fadeRoute(StoryDetailsScreen(story: s)),
    );
  }

  /* ───────────────────────── header icon callbacks ────────────────────── */

  // Called by HomeScreen header Discover / Search icon.
  // This should take us to the Discover placeholder page and hide the inline
  // search bar.
  void _openDiscover() {
    setState(() {
      _pageIndex = 1;     // show Discover placeholder
      _navIndex = (_navIndex == 1) ? 0 : _navIndex;
      _showSearchBar = false;
    });
  }

  // Called by HomeScreen header menu icon.
  // Opens the endDrawer we define below.
  void _openEndDrawer() {
    _scaffoldKey.currentState?.openEndDrawer();
  }

  /* ───────────────────────── bottom nav taps ──────────────────────────── */

  // Bottom nav items:
  // - Tapping "Home" => show Home normally.
  // - Tapping "Search" => show Home but force inline search bar visible.
  // - Tapping "Saved" => go to Saved tab.
  // - Tapping "Alerts" => go to Alerts tab.
  void _onDestinationSelected(int i) {
    if (i == 1) {
      // "Search"
      setState(() {
        _pageIndex = 0; // still Home
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

  /* ───────────────────────── theme picker sheet ───────────────────────── */

  Future<void> _openThemePicker(BuildContext drawerContext) async {
    final current = AppSettings.instance.themeMode;

    // Close drawer first so sheet animates from the bottom.
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

  /* ───────────────────── category picker sheet (bottom sheet) ─────────── */

  Future<void> _openCategoryPicker(BuildContext drawerContext) async {
    // Close drawer before opening sheet.
    Navigator.pop(drawerContext);

    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _CategoryPicker(
        initial: CategoryPrefs.instance.selected,
      ),
    );

    // "Apply" returns a Set<String>.
    if (picked != null && picked.isNotEmpty) {
      CategoryPrefs.instance.applySelection(picked);
      if (mounted) setState(() {});
    }
  }

  /* ───────────────────────── responsive helpers ───────────────────────── */

  // Compact = phone-ish layout.
  // We'll use 768px as our cutoff because the approved mock hides
  // the bottom nav on wider/desktop views.
  bool _isCompact(BuildContext context) =>
      MediaQuery.of(context).size.width < 768;

  @override
  Widget build(BuildContext context) {
    final compact = _isCompact(context);

    // Bottom nav ONLY on compact screens.
    // Even if we're on web (kIsWeb == true), on a wide browser window
    // we should *not* show the bottom nav. This matches the approved
    // "desktop web" look, where bottom nav disappears.
    final showBottomNav = compact;

    return WillPopScope(
      // Back button on Android:
      // If we have routes stacked (like StoryDetails), pop that first.
      onWillPop: () async {
        final canPop = Navigator.of(context).canPop();
        if (canPop) Navigator.of(context).maybePop();
        return !canPop;
      },
      child: Scaffold(
        key: _scaffoldKey,

        // Right-side drawer (endDrawer).
        // We explicitly disable drag-to-open so horizontal back-swipe on
        // Android/iOS doesn't accidentally open it.
        drawer: null,
        drawerEnableOpenDragGesture: false,
        endDrawerEnableOpenDragGesture: false,
        endDrawer: Builder(
          // Builder gives us a context inside the drawer so we can call
          // Navigator.pop(drawerCtx) when needed (Theme/Category sheets).
          builder: (drawerCtx) {
            return AppDrawer(
              onClose: () => Navigator.of(drawerCtx).pop(),
              onFiltersChanged: () => setState(() {}),
              onThemeTap: () => _openThemePicker(drawerCtx),
              onCategoryTap: () => _openCategoryPicker(drawerCtx),
              appShareUrl: 'https://cinepulse.netlify.app',
              privacyUrl: 'https://example.com/privacy', // TODO real
              termsUrl: 'https://example.com/terms',     // TODO real
            );
          },
        ),

        // Main content body.
        // We wrap IndexedStack with _ResponsiveWidth so that on desktop/tablet
        // the content column is centered and clamped to ~1300px max width,
        // matching the mock's max-page-width.
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

        // Bottom nav bar (Home / Search / Saved / Alerts)
        // Shows only on compact. Hidden entirely on wide screens.
        bottomNavigationBar: showBottomNav
            ? SafeArea(
                top: false,
                child: NavigationBarTheme(
                  data: NavigationBarThemeData(
                    height: 70,
                    labelTextStyle:
                        MaterialStateProperty.resolveWith((states) {
                      return TextStyle(
                        fontSize: 12,
                        fontWeight: states.contains(MaterialState.selected)
                            ? FontWeight.w700
                            : FontWeight.w500,
                        letterSpacing: 0.1,
                      );
                    }),
                  ),
                  child: NavigationBar(
                    selectedIndex: _navIndex,
                    labelBehavior:
                        NavigationDestinationLabelBehavior.alwaysShow,
                    onDestinationSelected: _onDestinationSelected,
                    destinations: const [
                      NavigationDestination(
                        icon: Text('🏠',
                            style: TextStyle(fontSize: 20, height: 1)),
                        selectedIcon: Text('🏠',
                            style: TextStyle(fontSize: 22, height: 1)),
                        label: 'Home',
                      ),
                      NavigationDestination(
                        icon: Text('🔍',
                            style: TextStyle(fontSize: 20, height: 1)),
                        selectedIcon: Text('🔍',
                            style: TextStyle(fontSize: 22, height: 1)),
                        label: 'Search',
                      ),
                      NavigationDestination(
                        icon: Text('🔖',
                            style: TextStyle(fontSize: 20, height: 1)),
                        selectedIcon: Text('🔖',
                            style: TextStyle(fontSize: 22, height: 1)),
                        label: 'Saved',
                      ),
                      NavigationDestination(
                        icon: Text('🔔',
                            style: TextStyle(fontSize: 20, height: 1)),
                        selectedIcon: Text('🔔',
                            style: TextStyle(fontSize: 22, height: 1)),
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

/* ───────────────────────────── THEME PICKER SHEET ───────────────────────── */

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.current});
  final ThemeMode current;

  @override
  Widget build(BuildContext context) {
    // Record-style map so we get entry.value.label / entry.value.icon
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

/* ────────────────────────── CATEGORY PICKER SHEET ─────────────────────────
 * Called from drawer -> Categories.
 * User can pick All / Entertainment / Sports / Travel / Fashion.
 * "Apply" returns a Set<String> back to RootShell.
 * ───────────────────────────────────────────────────────────────────────────*/
class _CategoryPicker extends StatefulWidget {
  const _CategoryPicker({required this.initial});
  final Set<String> initial; // CategoryPrefs.instance.selected

  @override
  State<_CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<_CategoryPicker> {
  late Set<String> _local; // working copy in the sheet

  @override
  void initState() {
    super.initState();
    _local = Set<String>.of(widget.initial);
  }

  void _toggle(String key) {
    final all = CategoryPrefs.keyAll;

    if (key == all) {
      // tapping "All": reset to only All
      _local
        ..clear()
        ..add(all);
    } else {
      // toggle this specific category
      if (_local.contains(key)) {
        _local.remove(key);
      } else {
        _local.add(key);
      }
      // remove "All" if any specific categories exist
      _local.remove(all);
      // never allow empty -> fallback to All
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
              'Categories',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Choose what you want in your feed. You can pick more than one.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            // All
            row(
              catKey: CategoryPrefs.keyAll,
              icon: Icons.apps_rounded,
              title: 'All',
              desc: 'Everything',
            ),

            // Entertainment
            row(
              catKey: CategoryPrefs.keyEntertainment,
              icon: Icons.local_movies_rounded,
              title: 'Entertainment',
              desc: 'Movies, OTT, celebrity updates',
            ),

            // Sports
            row(
              catKey: CategoryPrefs.keySports,
              icon: Icons.sports_cricket_rounded,
              title: 'Sports',
              desc: 'Cricket, match talk, highlights',
            ),

            // Travel
            row(
              catKey: CategoryPrefs.keyTravel,
              icon: Icons.flight_takeoff_rounded,
              title: 'Travel',
              desc: 'Trips, destinations, culture clips',
            ),

            // Fashion
            row(
              catKey: CategoryPrefs.keyFashion,
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

/* ─────────────────────────── DISCOVER PLACEHOLDER ───────────────────────── */

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

/* ───────────────────────────── RESPONSIVE WIDTH ────────────────────────────
 * Centers app content on desktop/tablet and clamps to ~1300px max width.
 * On phones (<768px) we just return child directly for full-bleed.
 *
 * This mirrors the HTML mock's layout:
 *   max-page-width: 1300px;
 *   side padding handled inside HomeScreen (16px).
 * ───────────────────────────────────────────────────────────────────────────*/
class _ResponsiveWidth extends StatelessWidget {
  const _ResponsiveWidth({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;

      // Phone / narrow (<768px): use full width, no additional centering.
      if (w < 768) return child;

      // Tablet / desktop: clamp to 1300px just like the mock.
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
