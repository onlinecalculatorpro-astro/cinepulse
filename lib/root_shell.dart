// lib/root_shell.dart
//
// RootShell = main scaffold / shell for the whole app.
// It owns:
//  • Tab pages (Home / Discover / Saved / Alerts) via an IndexedStack
//  • The global right-side drawer (AppDrawer)
//  • The bottom nav on phones only (<768px width)
//  • Deep link handling for /s/<id> → StoryDetailsScreen
//
// This version matches the new drawer / header experience you showed:
//
// 1. Drawer speaks in CinePulse voice.
//    - Header shows "<CategorySummary> · <LanguageSummary>"
//      e.g. "Entertainment · English"
//    - About row shows "Version 0.1.0 · Early access"
//    - Rows are now:
//        Show stories in      (> opens language sheet)
//        What to show         (> opens category sheet)
//        Theme                (> opens theme sheet)
//        Share / Report
//        About / Privacy / Terms
//
// 2. Drawer rows are now just previews + chevrons.
//    There are no inline chips/checkboxes in the drawer anymore.
//    When you tap a row, RootShell opens a bottom sheet:
//      • _openLanguagePicker()
//      • _openCategoryPicker()
//      • _openThemePicker()
//
// 3. RootShell keeps lightweight session state:
//    • Which page is active
//    • Whether HomeScreen is showing its inline search bar
//    • The current language pref ('english' | 'hindi' | 'mixed')
//      so we can label the drawer and header line
//
// 4. Responsive stays the same:
//    • On <768px width we show the frosted bottom nav
//    • On ≥768px width we hide bottom nav and center content up to 1300px
//
// NOTE: AppDrawer (widgets/app_drawer.dart) is updated to expect:
//    onLanguageTap, onCategoryTap, onThemeTap, and it shows
//    just the summary badge + label for language / category,
//    not full pickers.
//
// NOTE: We persist language via SharedPreferences under 'cp.lang'.
//       CategoryPrefs is a ChangeNotifier so the drawer can react to it.

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
 * "What to show" categories that drive the feed.
 * ────────────────────────────────────────────────────────────────────────────*/
class CategoryPrefs extends ChangeNotifier {
  CategoryPrefs._internal();
  static final CategoryPrefs instance = CategoryPrefs._internal();

  static const String keyAll = 'all';
  static const String keyEntertainment = 'entertainment';
  static const String keySports = 'sports';
  static const String keyTravel = 'travel';
  static const String keyFashion = 'fashion';

  // default feed is "All" (which basically means Entertainment today)
  final Set<String> _selected = {keyAll};

  Set<String> get selected => Set.unmodifiable(_selected);

  bool isSelected(String k) => _selected.contains(k);

  /// Called after user taps "Apply" in the category sheet.
  void applySelection(Set<String> incoming) {
    _selected
      ..clear()
      ..addAll(incoming);
    _sanitize();
    notifyListeners();
  }

  /// Human summary for UI ("All", "Entertainment", "Entertainment +2", ...)
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
  ///  - If "all" and others are both set, collapse back to just "all".
  ///  - Never allow empty.
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

  // Which tab page is visible:
  // 0 = Home, 1 = Discover, 2 = Saved, 3 = Alerts
  int _pageIndex = 0;

  // Which bottom nav item is active:
  // 0 = Home, 1 = Search (Home+search bar), 2 = Saved, 3 = Alerts
  int _navIndex = 0;

  // Whether HomeScreen should reveal the inline search bar.
  // This is how the "Search" tab works on phones.
  bool _showSearchBar = false;

  // Language pref from SharedPreferences:
  // 'english' | 'hindi' | 'mixed'
  String _currentLang = 'mixed';

  // Deep link stuff for /s/<id>
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

  /// Pull the saved language so drawer header has the right value.
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

  /// Convert pref string to a nice header string.
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

  /// Look for "/s/<id>" in the initial URL so we can open StoryDetails on launch.
  void _captureInitialDeepLink() {
    final frag = Uri.base.fragment; // e.g. "#/s/abc123" on web
    final path = (frag.isNotEmpty ? frag : Uri.base.path).trim();
    final match = RegExp(r'(^|/)+s/([^/?#]+)').firstMatch(path);
    if (match != null) {
      _pendingDeepLinkId = match.group(2);
    }
  }

  /// Try to resolve the pending story:
  /// 1. Poll FeedCache briefly
  /// 2. Fallback to fetchStory()
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
      // swallow errors; just don't open anything
    }
  }

  /// Push StoryDetailsScreen for that Story.
  /// Make sure Home tab is active beneath.
  Future<void> _openDetails(Story s) async {
    _deepLinkHandled = true;

    if (_pageIndex != 0) {
      setState(() => _pageIndex = 0);
    }

    // wait a tick so Scaffold / Navigator are laid out
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
      // if bottom nav was highlighting Search (index=1), reset to Home highlight
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
   * Bottom nav:
   *   0 = Home
   *   1 = Search (still Home page, but showSearchBar=true)
   *   2 = Saved
   *   3 = Alerts
   */
  void _onDestinationSelected(int i) {
    if (i == 1) {
      // Search tap
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

  /* ───────────────────────── THEME PICKER SHEET ─────────────────────────
   *
   * Drawer row "Theme" → close drawer → open bottom sheet.
   */
  Future<void> _openThemePicker(BuildContext drawerContext) async {
    final current = AppSettings.instance.themeMode;

    // close drawer first
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

  /* ─────────────────────── CATEGORY PICKER SHEET ───────────────────────
   *
   * Drawer row "What to show"
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

  /* ─────────────────────── LANGUAGE PICKER SHEET ───────────────────────
   *
   * Drawer row "Show stories in"
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
   * "compact" == phone-ish. On compact we show the frosted bottom nav.
   * On >=768px we hide it so the app feels like desktop web.
   */
  bool _isCompact(BuildContext context) =>
      MediaQuery.of(context).size.width < 768;

  @override
  Widget build(BuildContext context) {
    final compact = _isCompact(context);
    final showBottomNav = compact;

    // Drawer header status line:
    // "<CategorySummary> · <LanguageSummary>"
    // e.g. "Entertainment · English"
    final categorySummary = CategoryPrefs.instance.summary();
    final langSummary = _langHeaderSummary(_currentLang);
    final feedStatusLine = '$categorySummary · $langSummary';

    // About CinePulse row label:
    final versionLabel = 'Version $_kAppVersion · Early access';

    return WillPopScope(
      onWillPop: () async {
        // Android back btn behavior:
        // If there's something pushed above RootShell (like StoryDetails),
        // pop that instead of exiting the shell entirely.
        final canPop = Navigator.of(context).canPop();
        if (canPop) Navigator.of(context).maybePop();
        return !canPop;
      },
      child: Scaffold(
        key: _scaffoldKey,

        // Left drawer is unused
        drawer: null,
        drawerEnableOpenDragGesture: false,

        // Right drawer ("Menu")
        endDrawerEnableOpenDragGesture: false,
        endDrawer: Builder(
          builder: (drawerCtx) {
            return AppDrawer(
              // Tap X in the header
              onClose: () => Navigator.of(drawerCtx).pop(),

              // Not strictly required with new sheets, but keep so we can refresh UI
              onFiltersChanged: () => setState(() {}),

              // Drawer rows:
              onLanguageTap: () => _openLanguagePicker(drawerCtx),
              onCategoryTap: () => _openCategoryPicker(drawerCtx),
              onThemeTap: () => _openThemePicker(drawerCtx),

              // Links
              appShareUrl: 'https://cinepulse.netlify.app',
              privacyUrl: 'https://example.com/privacy', // TODO real link
              termsUrl: 'https://example.com/terms',     // TODO real link

              // Header + About section text
              feedStatusLine: feedStatusLine,
              versionLabel: versionLabel,
            );
          },
        ),

        // Body content. We clamp the width on desktop via _ResponsiveWidth.
        body: _ResponsiveWidth(
          child: IndexedStack(
            index: _pageIndex,
            children: [
              _DebugPageWrapper(
                builder: (ctx) => HomeScreen(
                  // Search state (Search tab just toggles this)
                  showSearchBar: _showSearchBar,

                  // Header actions inside HomeScreen
                  onMenuPressed: _openEndDrawer,
                  onOpenDiscover: _openDiscover,
                  onOpenSaved: _openSaved,
                  onOpenAlerts: _openAlerts,

                  // Pull-to-refresh / manual refresh from header
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

        // Frosted bottom nav only on phones
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
 * We use the app voice + keep System / Light / Dark radio list.
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
 * Bottom sheet for "Show stories in".
 * Returns 'english' | 'hindi' | 'mixed'.
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

  Widget _langTile({
    required String value,
    required String label,
    required String desc,
  }) {
    final active = (_local == value);
    final theme = Theme.of(context);

    return RadioListTile<String>(
      value: value,
      groupValue: _local,
      onChanged: (val) => _setLang(val ?? value),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
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
              'Show stories in',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Pick the language you want surfaced first.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            _langTile(
              value: 'english',
              label: 'English',
              desc: 'Mostly English titles / captions',
            ),
            _langTile(
              value: 'hindi',
              label: 'Hindi',
              desc: 'Mostly Hindi titles / captions',
            ),
            _langTile(
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
 * Bottom sheet for "What to show".
 * Explains each vertical in normal language.
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

  Widget _row({
    required String catKey,
    required IconData icon,
    required String title,
    required String desc,
  }) {
    final active = _isChecked(catKey);
    final theme = Theme.of(context);

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

            _row(
              catKey: CategoryPrefs.keyAll,
              icon: Icons.apps_rounded,
              title: 'All',
              desc: 'Everything we have (Entertainment)',
            ),
            _row(
              catKey: CategoryPrefs.keyEntertainment,
              icon: Icons.local_movies_rounded,
              title: 'Entertainment',
              desc: 'Movies, OTT, on-air drama, box office',
            ),
            _row(
              catKey: CategoryPrefs.keySports,
              icon: Icons.sports_cricket_rounded,
              title: 'Sports',
              desc: 'Match talk, highlights (coming soon)',
            ),
            _row(
              catKey: CategoryPrefs.keyTravel,
              icon: Icons.flight_takeoff_rounded,
              title: 'Travel',
              desc: 'Trips, destinations, culture clips (coming soon)',
            ),
            _row(
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
 * Placeholder tab for "Discover" until it's built.
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
 * On desktop/tablet we center and clamp the width to 1300px
 * so cards don't stretch across absurdly long rows.
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

/* ───────────────────────── CINE BOTTOM NAV BAR ─────────────────────────
 *
 * Frosted bottom nav (phone only).
 *   0 = Home
 *   1 = Search (Home + inline search bar)
 *   2 = Saved
 *   3 = Alerts
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

/// Single bottom-nav item (Home / Search / Saved / Alerts) with red glow on active.
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

/* ───────────────────────── DEBUG WRAPPER / ERROR FALLBACK ─────────────────────
 *
 * If a tab/widget throws during build (esp. in release builds),
 * Flutter might just render a blank region.
 * _DebugPageWrapper instead shows an error page with the exception + stack,
 * so you can screenshot it and send it.
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
