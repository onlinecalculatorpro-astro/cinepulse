// lib/root_shell.dart
//
// RootShell = main scaffold with bottom nav + right-side settings drawer.
// Updates in this rewrite:
//   • Adds CategoryPrefs singleton (multi-select categories like All / Entertainment / Sports / Travel / Fashion).
//   • Adds _openCategoryPicker() bottom sheet (looks/behaves like Theme sheet, but with checkboxes & Apply).
//   • Passes a new onCategoryTap callback into AppDrawer so tapping "Categories"
//     in the drawer will slide up the category picker instead of inline chips.
//   • Theme picker flow is unchanged (still showModalBottomSheet with radios).
//
// NOTE: you'll also update AppDrawer to accept onCategoryTap and stop rendering
// inline category chips. AppDrawer will just call widget.onCategoryTap().

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
 * Global (in-memory for now) category selection that the rest of the app
 * can read to filter feeds.
 *
 * Rules:
 *  - "all" means "show everything".
 *  - If "all" is selected, all other categories are ignored.
 *  - If the user selects any specific categories, "all" is removed.
 *  - We never allow an empty selection; we fall back to "all".
 *
 * We'll use this in:
 *   - The bottom-sheet picker (_CategoryPicker)
 *   - The drawer summary (via AppDrawer after you wire it)
 *   - In future: HomeScreen can read CategoryPrefs.instance.selected
 *     to filter the feed.
 * ────────────────────────────────────────────────────────────────────────────*/
class CategoryPrefs extends ChangeNotifier {
  CategoryPrefs._internal();
  static final CategoryPrefs instance = CategoryPrefs._internal();

  // canonical keys
  static const String keyAll = 'all';
  static const String keyEntertainment = 'entertainment';
  static const String keySports = 'sports';
  static const String keyTravel = 'travel';
  static const String keyFashion = 'fashion';

  final Set<String> _selected = {keyAll}; // default: All

  Set<String> get selected => Set.unmodifiable(_selected);

  bool isSelected(String k) => _selected.contains(k);

  /// Overwrite selection with [incoming], then sanitize (apply rules).
  void applySelection(Set<String> incoming) {
    _selected
      ..clear()
      ..addAll(incoming);
    _sanitize();
    notifyListeners();
  }

  /// Helper for UI summary chips, e.g. "All", "Entertainment +2"
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
    // if "all" is present with others -> keep only "all"
    if (_selected.contains(keyAll) && _selected.length > 1) {
      _selected
        ..clear()
        ..add(keyAll);
      return;
    }
    // if nothing picked, force "all"
    if (_selected.isEmpty) {
      _selected.add(keyAll);
    }
  }
}

/* ────────────────────────────────────────────────────────────────────────────
 * ROOT SHELL
 * Hosts:
 *   - IndexedStack of pages (Home / Discover / Saved / Alerts)
 *   - Bottom nav
 *   - Right-side drawer (AppDrawer)
 * Also:
 *   - Handles deep links like /#/s/<id> -> opens StoryDetailsScreen
 *   - Hosts bottom sheets: Theme picker & Category picker
 * ────────────────────────────────────────────────────────────────────────────*/

class RootShell extends StatefulWidget {
  const RootShell({super.key});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  // used to open/close the endDrawer
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // Which page sits in the body stack (0=Home, 1=Discover placeholder,
  // 2=Saved, 3=Alerts).
  int _pageIndex = 0;

  // Which bottom-nav item is visually selected
  // 0=Home, 1=Search, 2=Saved, 3=Alerts.
  int _navIndex = 0;

  // When true, HomeScreen should render its inline search bar.
  bool _showSearchBar = false;

  // Deep link state
  String? _pendingDeepLinkId;
  bool _deepLinkHandled = false;

  @override
  void initState() {
    super.initState();
    _captureInitialDeepLink();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _tryOpenPendingDeepLink());
  }

  /// Parse `/#/s/<id>` or `/s/<id>` from current URL (web),
  /// stash story id so we can open detail later.
  void _captureInitialDeepLink() {
    final frag = Uri.base.fragment; // hash on web, "" on mobile
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

    // 1) Try in-memory FeedCache for up to 4s (lets feeds load first).
    while (mounted && DateTime.now().difference(started) < maxWait) {
      final Story? cached = FeedCache.get(_pendingDeepLinkId!);
      if (cached != null) {
        await _openDetails(cached);
        return;
      }
      await Future<void>.delayed(tick);
    }

    // 2) Fetch directly from API if not in cache.
    try {
      final s = await fetchStory(_pendingDeepLinkId!);
      if (!mounted) return;
      FeedCache.put(s);
      await _openDetails(s);
      return;
    } catch (_) {
      // swallow; worst case we just land on Home
    }
  }

  Future<void> _openDetails(Story s) async {
    _deepLinkHandled = true;
    // make sure Home is visible behind details
    if (_pageIndex != 0) setState(() => _pageIndex = 0);
    // tiny delay so stack is in the right state
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    Navigator.of(context).push(fadeRoute(StoryDetailsScreen(story: s)));
  }

  // Called by HomeScreen header Discover/Explore icon
  void _openDiscover() {
    setState(() {
      _pageIndex = 1; // Discover placeholder page
      _navIndex = (_navIndex == 1) ? 0 : _navIndex;
      _showSearchBar = false;
    });
  }

  // Called by HomeScreen header menu icon
  void _openEndDrawer() {
    _scaffoldKey.currentState?.openEndDrawer();
  }

  // Bottom nav tap
  void _onDestinationSelected(int i) {
    // 0=Home, 1=Search, 2=Saved, 3=Alerts
    if (i == 1) {
      // "Search" is special: show Home but reveal search bar
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

      if (i == 0) _pageIndex = 0; // Home
      if (i == 2) _pageIndex = 2; // Saved
      if (i == 3) _pageIndex = 3; // Alerts
    });
  }

  /* ───────────────────────────── THEME PICKER ─────────────────────────── */

  Future<void> _openThemePicker(BuildContext drawerContext) async {
    final current = AppSettings.instance.themeMode;

    // close the drawer before showing the bottom sheet
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

  /* ─────────────────────── CATEGORY PICKER (NEW) ──────────────────────── */

  Future<void> _openCategoryPicker(BuildContext drawerContext) async {
    // Close the drawer first so the sheet shows full-width on mobile.
    Navigator.pop(drawerContext);

    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _CategoryPicker(
        initial: CategoryPrefs.instance.selected,
      ),
    );

    if (result != null && result.isNotEmpty) {
      CategoryPrefs.instance.applySelection(result);
      // Trigger a rebuild so HomeScreen (and any chips in drawer summary)
      // can react immediately after dismiss.
      if (mounted) setState(() {});
    }
  }

  bool _isCompact(BuildContext context) =>
      MediaQuery.of(context).size.width < 900;

  @override
  Widget build(BuildContext context) {
    final compact = _isCompact(context);
    // Bottom nav should appear on phones & web.
    final showBottomNav = kIsWeb || compact;

    return WillPopScope(
      // If we have pushed routes (e.g. StoryDetails), back pops those first.
      onWillPop: () async {
        final canPop = Navigator.of(context).canPop();
        if (canPop) Navigator.of(context).maybePop();
        return !canPop;
      },
      child: Scaffold(
        key: _scaffoldKey,

        // RIGHT-SIDE drawer. Edge-swipe disabled so we don't
        // fight the Android back gesture on the left.
        drawer: null,
        drawerEnableOpenDragGesture: false,
        endDrawerEnableOpenDragGesture: false,
        endDrawer: Builder(
          // Builder gives us a context INSIDE the drawer so we can
          // close it from callbacks (Navigator.pop(drawerContext)).
          builder: (drawerCtx) {
            return AppDrawer(
              onClose: () => Navigator.of(drawerCtx).pop(),
              onFiltersChanged: () => setState(() {}),
              onThemeTap: () => _openThemePicker(drawerCtx),
              onCategoryTap: () => _openCategoryPicker(drawerCtx),
              appShareUrl: 'https://cinepulse.netlify.app',
              privacyUrl: 'https://example.com/privacy', // TODO real link
              termsUrl: 'https://example.com/terms', // TODO real link
            );
          },
        ),

        // Main pages stay alive via IndexedStack.
        // We also clamp width on larger displays.
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

        // Bottom nav (Home / Search / Saved / Alerts).
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

/* ───────────────────────────── THEME PICKER SHEET ───────────────────────── */

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.current});
  final ThemeMode current;

  @override
  Widget build(BuildContext context) {
    final options = <ThemeMode, (String label, IconData icon)>{
      ThemeMode.system: ('System', Icons.auto_awesome),
      ThemeMode.light: ('Light', Icons.light_mode_outlined),
      ThemeMode.dark: ('Dark', Icons.dark_mode_outlined),
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
 * Shown from the drawer when user taps "Categories".
 * Lets user multi-select verticals. We keep local state in the sheet so the
 * user can tick multiple before hitting "Apply".
 * Returns Set<String> via Navigator.pop(context, selectedSet).
 * ───────────────────────────────────────────────────────────────────────────*/

class _CategoryPicker extends StatefulWidget {
  const _CategoryPicker({required this.initial});
  final Set<String> initial; // CategoryPrefs.instance.selected

  @override
  State<_CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<_CategoryPicker> {
  late Set<String> _local; // working copy

  @override
  void initState() {
    super.initState();
    _local = Set<String>.of(widget.initial);
  }

  void _toggle(String key) {
    final all = CategoryPrefs.keyAll;

    if (key == all) {
      // if tapping "All": just keep "all"
      _local
        ..clear()
        ..add(all);
    } else {
      // toggle that key on/off
      if (_local.contains(key)) {
        _local.remove(key);
      } else {
        _local.add(key);
      }
      // remove "all"
      _local.remove(all);
      // never allow empty
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
      required String key,
      required IconData icon,
      required String title,
      required String desc,
    }) {
      final active = _isChecked(key);
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _toggle(key),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: active,
                onChanged: (_) => _toggle(key),
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
              key: CategoryPrefs.keyAll,
              icon: Icons.apps_rounded,
              title: 'All',
              desc: 'Everything',
            ),

            // Entertainment
            row(
              key: CategoryPrefs.keyEntertainment,
              icon: Icons.local_movies_rounded,
              title: 'Entertainment',
              desc: 'Movies, OTT, celebrity updates',
            ),

            // Sports
            row(
              key: CategoryPrefs.keySports,
              icon: Icons.sports_cricket_rounded,
              title: 'Sports',
              desc: 'Cricket, match talk, highlights',
            ),

            // Travel
            row(
              key: CategoryPrefs.keyTravel,
              icon: Icons.flight_takeoff_rounded,
              title: 'Travel',
              desc: 'Trips, destinations, culture clips',
            ),

            // Fashion
            row(
              key: CategoryPrefs.keyFashion,
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
 * Centers content on big screens. On phones it just returns the child.
 * Same behavior as your original _ResponsiveWidth.
 * ───────────────────────────────────────────────────────────────────────────*/

class _ResponsiveWidth extends StatelessWidget {
  const _ResponsiveWidth({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        if (w <= 720) return child; // phones: full-bleed

        // Tablets / desktop: keep a comfortable max width
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
      },
    );
  }
}
