// lib/root_shell.dart
//
// RootShell = main scaffold / shell for the whole app.
// It owns:
//  - the tab pages (Home / Discover / Saved / Alerts) via IndexedStack
//  - the global right-side drawer (AppDrawer)
//  - the bottom nav on phones only (<768px width)
//  - deep link handling for /s/<id> → StoryDetailsScreen
//
// In this version we align RootShell with the new drawer/UX model:
//
// 1. Drawer talks in CinePulse voice:
//    - Header shows “<CategorySummary> · <LanguageSummary>”
//      e.g. “All · Mixed language”
//    - “Version 0.1.0 · Early access”
//    - Rows are: Show stories in / What to show / Theme / Share / Report / About…
//
// 2. Category, Theme, and Language are all changed via bottom sheets
//    (not inline inside the drawer).
//    - _openCategoryPicker(), _openThemePicker(), _openLanguagePicker()
//
// 3. RootShell keeps minimal session state:
//    - Which tab is active
//    - Whether HomeScreen should show its inline search bar
//    - The user’s current language pref (cp.lang)
//
// 4. We still keep phone-vs-desktop responsive behavior exactly the same.
//
// NOTE: AppDrawer must expose `onLanguageTap`, `onCategoryTap`, `onThemeTap`,
// and display summary pills for language/categories instead of full controls.
//

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
const String _kLangPrefKey = 'cp.lang'; // 'english' | 'hindi' | 'mixed'

/* ────────────────────────────────────────────────────────────────────────────
 * CATEGORY PREFS
 * (What verticals the feed shows)
 * ────────────────────────────────────────────────────────────────────────────*/

class CategoryPrefs extends ChangeNotifier {
  CategoryPrefs._internal();
  static final CategoryPrefs instance = CategoryPrefs._internal();

  static const String keyAll = 'all';
  static const String keyEntertainment = 'entertainment';
  static const String keySports = 'sports';
  static const String keyTravel = 'travel';
  static const String keyFashion = 'fashion';

  // default feed is "All" (mostly Entertainment right now)
  final Set<String> _selected = {keyAll};

  Set<String> get selected => Set.unmodifiable(_selected);

  bool isSelected(String k) => _selected.contains(k);

  /// Accept a new choice from the sheet, clean it up, and notify.
  void applySelection(Set<String> incoming) {
    _selected
      ..clear()
      ..addAll(incoming);
    _sanitize();
    notifyListeners();
  }

  /// For UI surfaces (“What to show” badge, Drawer header, etc.)
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

  /// Guardrails:
  /// - If “all” plus others are both selected, collapse back to just “all”.
  /// - Never allow empty.
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

/* ────────────────────────────────────────────────────────────────────────────
 * ROOT SHELL
 * ────────────────────────────────────────────────────────────────────────────*/

class RootShell extends StatefulWidget {
  const RootShell({super.key});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // IndexedStack page index:
  // 0 = Home, 1 = Discover, 2 = Saved, 3 = Alerts
  int _pageIndex = 0;

  // Bottom nav highlight:
  // 0 = Home, 1 = Search (Home+search), 2 = Saved, 3 = Alerts
  int _navIndex = 0;

  // Whether HomeScreen should reveal the inline search bar
  // (used by tapping the "Search" item in bottom nav).
  bool _showSearchBar = false;

  // Language preference (persisted via SharedPreferences).
  // Values: 'english' | 'hindi' | 'mixed'
  String _currentLang = 'mixed';

  // Deep link handling (/s/<id>)
  String? _pendingDeepLinkId;
  bool _deepLinkHandled = false;

  @override
  void initState() {
    super.initState();
    _captureInitialDeepLink();
    _loadLangPref();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _tryOpenPendingDeepLink(),
    );
  }

  /// Load language pref from SharedPreferences so drawer header + pills
  /// reflect the real setting the first time we open it.
  Future<void> _loadLangPref() async {
    final sp = await SharedPreferences.getInstance();
    final stored = sp.getString(_kLangPrefKey);
    if (!mounted) return;
    if (stored != null && stored.isNotEmpty) {
      setState(() {
        _currentLang = stored;
      });
    }
  }

  /// For the drawer header line:
  /// english -> "English"
  /// hindi   -> "Hindi"
  /// mixed   -> "Mixed language"
  String _langHeaderSummary(String code) {
    switch (code) {
      case 'english':
        return 'English';
      case 'hindi':
        return 'Hindi';
      default:
        return 'Mixed language';
    }
  }

  /* ───────────────────── Deep link helpers ───────────────────── */

  /// Look for /s/<id> in the launch URL, stash it so we can push details later.
  void _captureInitialDeepLink() {
    final frag = Uri.base.fragment; // on web we might have "#/s/abcdef"
    final path = (frag.isNotEmpty ? frag : Uri.base.path).trim();
    final match = RegExp(r'(^|/)+s/([^/?#]+)').firstMatch(path);
    if (match != null) {
      _pendingDeepLinkId = match.group(2);
    }
  }

  /// Try to open pending deep link:
  /// 1. Poll FeedCache for up to ~4s
  /// 2. Otherwise fetchStory() directly
  Future<void> _tryOpenPendingDeepLink() async {
    if (_deepLinkHandled || _pendingDeepLinkId == null) return;

    const maxWait = Duration(seconds: 4);
    const tick = Duration(milliseconds: 200);
    final started = DateTime.now();

    while (mounted && DateTime.now().difference(started) < maxWait) {
      final Story? cached = FeedCache.get(_pendingDeepLinkId!);
      if (cached != null) {
        await _openDetails(cached);
        return;
      }
      await Future<void>.delayed(tick);
    }

    try {
      final s = await fetchStory(_pendingDeepLinkId!);
      if (!mounted) return;
      FeedCache.put(s);
      await _openDetails(s);
      return;
    } catch (_) {
      // swallow network error
    }
  }

  /// Push StoryDetailsScreen on top of the shell.
  /// We make sure Home tab is active underneath first.
  Future<void> _openDetails(Story s) async {
    _deepLinkHandled = true;

    if (_pageIndex != 0) {
      setState(() => _pageIndex = 0);
    }

    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;

    Navigator.of(context).push(
      fadeRoute(StoryDetailsScreen(story: s)),
    );
  }

  /* ───────────────────── Header icon actions from HomeScreen ───────────────────── */

  void _openDiscover() {
    setState(() {
      _pageIndex = 1;
      // If Search was highlighted in nav, reset it to Home highlight.
      _navIndex = (_navIndex == 1) ? 0 : _navIndex;
      _showSearchBar = false;
    });
  }

  void _openEndDrawer() {
    _scaffoldKey.currentState?.openEndDrawer();
  }

  void _openSaved() {
    setState(() {
      _pageIndex = 2;
      _navIndex = 2;
      _showSearchBar = false;
    });
  }

  void _openAlerts() {
    setState(() {
      _pageIndex = 3;
      _navIndex = 3;
      _showSearchBar = false;
    });
  }

  /* ───────────────────────── Bottom nav taps ─────────────────────────
   *
   * Bottom nav items:
   *   0 = Home
   *   1 = Search (Home + inline search bar)
   *   2 = Saved
   *   3 = Alerts
   */
  void _onDestinationSelected(int i) {
    if (i == 1) {
      // "Search"
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

  /* ───────────────────────── Theme picker (drawer → bottom sheet) ─────────────────────────
   *
   * Sequence:
   *  - Close the drawer
   *  - showModalBottomSheet<_ThemePicker>()
   *  - Save new ThemeMode to AppSettings
   */
  Future<void> _openThemePicker(BuildContext drawerContext) async {
    final current = AppSettings.instance.themeMode;

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

  /* ─────────────────────── Category picker (drawer → bottom sheet) ───────────────────────
   *
   * Sequence:
   *  - Close the drawer
   *  - showModalBottomSheet<_CategoryPicker>()
   *  - CategoryPrefs.instance.applySelection(...)
   */
  Future<void> _openCategoryPicker(BuildContext drawerContext) async {
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

  /* ─────────────────────── Language picker (drawer → bottom sheet) ───────────────────────
   *
   * Drawer row "Show stories in" should act like Theme / Category rows.
   *
   * Sequence:
   *  - Close drawer
   *  - showModalBottomSheet<_LanguagePicker>()
   *  - Save new language string ('english' | 'hindi' | 'mixed') to SharedPreferences
   *  - setState() so Drawer header + pills update next open
   */
  Future<void> _openLanguagePicker(BuildContext drawerContext) async {
    Navigator.pop(drawerContext);

    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => _LanguagePicker(current: _currentLang),
    );

    if (picked != null && picked.isNotEmpty) {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kLangPrefKey, picked);
      if (mounted) {
        setState(() {
          _currentLang = picked;
        });
      }
    }
  }

  /* ───────────────────────── Responsive helpers ─────────────────────────
   *
   * "compact" == phone-ish width
   * On compact: bottom nav is visible
   * On >=768px: bottom nav hidden, desktop-style layout
   */
  bool _isCompact(BuildContext context) =>
      MediaQuery.of(context).size.width < 768;

  @override
  Widget build(BuildContext context) {
    final compact = _isCompact(context);
    final showBottomNav = compact;

    // "What you're seeing right now" line for the drawer header.
    // e.g. "All · Mixed language"
    final categorySummary = CategoryPrefs.instance.summary();
    final langSummary = _langHeaderSummary(_currentLang);
    final feedStatusLine = '$categorySummary · $langSummary';

    // for About CinePulse row
    final versionLabel = 'Version $_kAppVersion · Early access';

    return WillPopScope(
      onWillPop: () async {
        // Android back button:
        // If StoryDetailsScreen (or similar) is pushed on top of RootShell's
        // Navigator, pop that instead of tearing down the whole app.
        final canPop = Navigator.of(context).canPop();
        if (canPop) Navigator.of(context).maybePop();
        return !canPop;
      },
      child: Scaffold(
        key: _scaffoldKey,

        drawer: null,
        drawerEnableOpenDragGesture: false,

        // Right-side drawer
        endDrawerEnableOpenDragGesture: false,
        endDrawer: Builder(
          builder: (drawerCtx) {
            return AppDrawer(
              // Close button in header
              onClose: () => Navigator.of(drawerCtx).pop(),

              // RootShell should refresh badges/summary text if prefs change
              onFiltersChanged: () => setState(() {}),

              // Rows in drawer, each opens a bottom sheet
              onLanguageTap: () => _openLanguagePicker(drawerCtx),
              onCategoryTap: () => _openCategoryPicker(drawerCtx),
              onThemeTap: () => _openThemePicker(drawerCtx),

              // basic links
              appShareUrl: 'https://cinepulse.netlify.app',
              privacyUrl: 'https://example.com/privacy', // TODO real
              termsUrl: 'https://example.com/terms',     // TODO real

              // drawer header + about section metadata
              feedStatusLine: feedStatusLine,
              versionLabel: versionLabel,
            );
          },
        ),

        // Body with tabs
        body: _ResponsiveWidth(
          child: IndexedStack(
            index: _pageIndex,
            children: [
              _DebugPageWrapper(
                builder: (ctx) => HomeScreen(
                  // "Search" state
                  showSearchBar: _showSearchBar,

                  // header buttons
                  onMenuPressed: _openEndDrawer,
                  onOpenDiscover: _openDiscover,
                  onOpenSaved: _openSaved,
                  onOpenAlerts: _openAlerts,

                  // pull-to-refresh / header refresh icon
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

        // Bottom nav bar only on compact screens
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

/* ───────────────────────── THEME PICKER SHEET ─────────────────────────
 *
 * Bottom sheet for Theme.
 * We keep the CinePulse voice: "Affects Home and story cards".
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

/* ───────────────────────── LANGUAGE PICKER SHEET ─────────────────────────
 *
 * Bottom sheet for language selection ("Show stories in").
 * Options:
 *   - English
 *   - Hindi
 *   - Mixed
 *
 * Returns the chosen string ('english' | 'hindi' | 'mixed') via Navigator.pop.
 * RootShell then persists it and updates state.
 */
class _LanguagePicker extends StatefulWidget {
  const _LanguagePicker({required this.current});
  final String current;

  @override
  State<_LanguagePicker> createState() => _LanguagePickerState();
}

class _LanguagePickerState extends State<_LanguagePicker> {
  late String _local;

  @override
  void initState() {
    super.initState();
    _local = widget.current;
  }

  void _setLang(String v) {
    setState(() {
      _local = v;
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget langTile({
      required String value,
      required String label,
      required String desc,
    }) {
      final active = (_local == value);
      return RadioListTile<String>(
        value: value,
        groupValue: _local,
        onChanged: (val) => _setLang(val ?? value),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  ),
            ),
            Text(
              desc,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
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
              'Show stories in',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Pick the language you want surfaced first.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),

            langTile(
              value: 'english',
              label: 'English',
              desc: 'Mostly English titles / captions',
            ),
            langTile(
              value: 'hindi',
              label: 'Hindi',
              desc: 'Mostly Hindi titles / captions',
            ),
            langTile(
              value: 'mixed',
              label: 'Mixed',
              desc: 'Bit of both where it makes sense',
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

/* ───────────────────────── CATEGORY PICKER SHEET ─────────────────────────
 *
 * Bottom sheet for "What to show" categories.
 * We keep the CinePulse tone and explain what's in each bucket.
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
      _local.remove(all);
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

/* ───────────────────────── DISCOVER PLACEHOLDER ─────────────────────────
 *
 * Simple placeholder for tab 1 until Discover is actually built.
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

/* ───────────────────────── RESPONSIVE WIDTH ─────────────────────────
 *
 * Centers & clamps content on desktop/tablet so the grid doesn't get too wide.
 * On narrow screens (<768px) we just use full width.
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

/* ───────────────────────── CINE BOTTOM NAV BAR ─────────────────────────
 *
 * Frosted bottom nav for phones.
 * 0 = Home
 * 1 = Search (Home with inline search bar)
 * 2 = Saved
 * 3 = Alerts
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

/// A single nav button (Home / Search / Saved / Alerts)
/// Red glow/red border when selected.
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

/* ───────────────────── DEBUG WRAPPER / ERROR FALLBACK ─────────────────────
 *
 * If a tab throws during build in release APK, you'd normally see blank/white.
 * _DebugPageWrapper catches that and shows a text dump instead, so we can
 * screenshot and debug.
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
