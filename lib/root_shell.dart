// lib/root_shell.dart
//
// RootShell = main scaffold / shell for the whole app.
//
// It owns:
//  • Tab pages (Home / Discover / Saved / Alerts) via an IndexedStack
//  • The global right-side drawer (AppDrawer)
//  • The bottom nav on phones only (<768px width)
//  • Deep link handling for /s/<id> → StoryDetailsScreen
//
// DRAWER SPEC (LATEST):
//
// HEADER
//   CinePulse brand block
//   tagline ("Movies & OTT, in a minute.")
//   "<CategorySummary> · <LanguageSummary>"  (feedStatusLine from RootShell)
//   "x" close button
//
// CONTENT & FILTERS
//   Categories          (> opens _openCategoryPicker sheet)
//   Content type        (> opens _openContentTypePicker sheet)
//
// APPEARANCE
//   Theme               (> opens _openThemePicker sheet)
//
// SHARE & SUPPORT
//   Share CinePulse     (> share / copy link)
//   Report an issue     (> email)
//
// SETTINGS
//   App language        (> opens _openAppLanguageSettings bottom sheet
//                          with 7 Indian languages for CinePulse UI chrome)
//   Subscription        (> _openSubscriptionSettings() bottom sheet)
//   Sign in             (> _openAccountSettings() bottom sheet)
//
// ABOUT & LEGAL
//   About CinePulse     (uses versionLabel, ex: "Version 0.1.0 · Early access")
//   Privacy Policy
//   Terms of Use
//
// RootShell is responsible for:
//   • reading feed language preference from SharedPreferences
//       ('english' | 'hindi' | 'mixed' ...). This ONLY affects the header
//       summary line right now.
//   • holding category filter state (CategoryPrefs.instance)
//   • holding content type state ('all' | 'read' | 'video' | 'audio')
//   • exposing callbacks the drawer calls for each row
//   • handling responsive layout (bottom nav only under 768px width)
//
// NOTE: AppDrawer is "dumb". It just renders rows and calls the callbacks:
//       onCategoryTap, onContentTypeTap, onThemeTap,
//       onAppLanguageTap, onSubscriptionTap, onLoginTap.
//
// We close the drawer first, then RootShell shows a bottom sheet.
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
 * Drives "Categories".
 * ────────────────────────────────────────────────────────────────────────────*/
class CategoryPrefs extends ChangeNotifier {
  CategoryPrefs._internal();
  static final CategoryPrefs instance = CategoryPrefs._internal();

  static const String keyAll = 'all';
  static const String keyEntertainment = 'entertainment';
  static const String keySports = 'sports';
  static const String keyTravel = 'travel';
  static const String keyFashion = 'fashion';

  // Default feed is "All" (which basically equals "Entertainment" for now)
  final Set<String> _selected = {keyAll};

  Set<String> get selected => Set.unmodifiable(_selected);

  bool isSelected(String k) => _selected.contains(k);

  /// Apply new selection from the bottom sheet.
  void applySelection(Set<String> incoming) {
    _selected
      ..clear()
      ..addAll(incoming);
    _sanitize();
    notifyListeners();
  }

  /// Human-friendly summary for UI surfaces:
  ///  "All"
  ///  "Entertainment"
  ///  "Entertainment +2"
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

  /// Guardrails so state never becomes illegal.
  void _sanitize() {
    // If "all" and others are both set → collapse to just "all".
    if (_selected.contains(keyAll) && _selected.length > 1) {
      _selected
        ..clear()
        ..add(keyAll);
      return;
    }
    // Never allow empty.
    if (_selected.isEmpty) {
      _selected.add(keyAll);
    }
  }
}

/* ────────────────────────────────────────────────────────────────────────────
 * ROOT SHELL
 * Main scaffold for the app.
 * ────────────────────────────────────────────────────────────────────────────*/
class RootShell extends StatefulWidget {
  const RootShell({super.key});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // Which tab is visible in the IndexedStack:
  // 0 = Home, 1 = Discover, 2 = Saved, 3 = Alerts
  int _pageIndex = 0;

  // Which item is highlighted in the bottom nav:
  // 0 = Home, 1 = Search (Home with inline search bar),
  // 2 = Saved, 3 = Alerts
  int _navIndex = 0;

  // Whether HomeScreen should show its inline search bar (Search tab behavior)
  bool _showSearchBar = false;

  // 'english' | 'hindi' | 'mixed' | etc.
  // This is the feed-language pref. We still surface it in the header
  // line inside the drawer as part of feedStatusLine, but we no longer
  // expose a row to change it in the drawer.
  String _currentLang = 'mixed';

  // App UI language for CinePulse chrome ("App language" setting).
  // We'll start with English and let the user pick from the 7-language sheet.
  String _appUiLanguageCode = 'english_ui';

  // Content type filter code for the drawer's "Content type".
  // 'all' | 'read' | 'video' | 'audio'
  String _contentType = 'all';

  // Deep link handling (/s/<id>)
  String? _pendingDeepLinkId;
  bool _deepLinkHandled = false;

  @override
  void initState() {
    super.initState();
    _captureInitialDeepLink();
    _loadLangPref();

    // After first frame, try to open the story deep link if any.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _tryOpenPendingDeepLink(),
    );
  }

  /// Read feed language preference so drawer header text is correct.
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

  /// Convert feed language pref code → friendly string for the drawer header.
  /// english → "English"
  /// hindi   → "Hindi"
  /// mixed   → "Mixed language"
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

  /// Convert content type code → user-facing label for the drawer row.
  /// 'all'   → "All"
  /// 'read'  → "Read"
  /// 'video' → "Video"
  /// 'audio' → "Audio"
  String _contentTypeLabel(String code) {
    switch (code) {
      case 'read':
        return 'Read';
      case 'video':
        return 'Video';
      case 'audio':
        return 'Audio';
      default:
        return 'All';
    }
  }

  /* ───────────────────── Deep link handling ───────────────────── */

  /// Grab /s/<id> from initial URL (web deep links).
  void _captureInitialDeepLink() {
    final frag = Uri.base.fragment; // on web could be "#/s/abcdef"
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

    // Poll cache first (gives feed a chance to warm up)
    while (mounted && DateTime.now().difference(started) < maxWait) {
      final Story? cached = FeedCache.get(_pendingDeepLinkId!);
      if (cached != null) {
        await _openDetails(cached);
        return;
      }
      await Future<void>.delayed(tick);
    }

    // Fallback to network
    try {
      final s = await fetchStory(_pendingDeepLinkId!);
      if (!mounted) return;
      FeedCache.put(s);
      await _openDetails(s);
      return;
    } catch (_) {
      // ignore failures
    }
  }

  /// Push StoryDetailsScreen on top of RootShell.
  /// Make sure Home tab is active beneath.
  Future<void> _openDetails(Story s) async {
    _deepLinkHandled = true;

    if (_pageIndex != 0) {
      setState(() => _pageIndex = 0);
    }

    // tiny delay so Scaffold/Navigator are stable
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;

    Navigator.of(context).push(
      fadeRoute(StoryDetailsScreen(story: s)),
    );
  }

  /* ───────────────────── Header actions from HomeScreen ───────────────────── */

  // "Discover" icon
  void _openDiscover() {
    setState(() {
      _pageIndex = 1;
      // If Search was highlighted in bottom nav, drop back to Home highlight.
      _navIndex = (_navIndex == 1) ? 0 : _navIndex;
      _showSearchBar = false;
    });
  }

  // "Menu" icon
  void _openEndDrawer() {
    _scaffoldKey.currentState?.openEndDrawer();
  }

  // "Saved" icon
  void _openSaved() {
    setState(() {
      _pageIndex = 2;
      _navIndex = 2;
      _showSearchBar = false;
    });
  }

  // "Alerts" icon
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
   *   1 = Search (still Home page, but showSearchBar=true)
   *   2 = Saved
   *   3 = Alerts
   */
  void _onDestinationSelected(int i) {
    if (i == 1) {
      // "Search": highlight Search, keep Home tab visible, show inline search bar
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

  /* ───────────────────────── PICKER SHEETS ─────────────────────────
   *
   * Each of these is triggered from the drawer rows.
   * We close the drawer first (Navigator.pop(drawerContext)) so
   * the sheet isn't stacked on top of an open Drawer.
   */

  // THEME
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

  // CATEGORIES ("Categories")
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

  // CONTENT TYPE ("Content type")
  Future<void> _openContentTypePicker(BuildContext drawerContext) async {
    Navigator.pop(drawerContext);

    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => _ContentTypePicker(current: _contentType),
    );

    if (picked != null && picked.isNotEmpty) {
      if (mounted) {
        setState(() {
          _contentType = picked;
        });
      }
    }
  }

  // SETTINGS → "App language"
  //
  // We close the drawer and then open a dedicated bottom sheet that lists
  // 7 UI languages for CinePulse chrome (English, Hindi, Bengali, Marathi,
  // Telugu, Tamil, Gujarati). User picks one and taps Apply.
  Future<void> _openAppLanguageSettings(BuildContext drawerContext) async {
    Navigator.pop(drawerContext);

    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _AppLanguageSheet(currentCode: _appUiLanguageCode),
    );

    if (picked != null && picked.isNotEmpty) {
      if (!mounted) return;
      setState(() {
        _appUiLanguageCode = picked;
      });
    }
  }

  // SETTINGS → "Subscription"
  Future<void> _openSubscriptionSettings() async {
    await _showComingSoonSheet(
      title: 'Subscription',
      message:
          'Remove ads & unlock extras. This will show our paywall / plans.',
    );
  }

  // SETTINGS → "Sign in"
  Future<void> _openAccountSettings() async {
    await _showComingSoonSheet(
      title: 'Sign in',
      message: 'Log in to sync your saved stories and alerts across devices.',
    );
  }

  // Generic "coming soon" bottom sheet used by Subscription / Sign in.
  Future<void> _showComingSoonSheet({
    required String title,
    required String message,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('OK'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFdc2626),
                      foregroundColor: Colors.white,
                      textStyle: const TextStyle(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /* ───────────────────────── Responsive helpers ─────────────────────────
   *
   * "compact" = phone-ish width.
   * On compact we show bottom nav.
   * On ≥768px we hide bottom nav (desktop vibe).
   */
  bool _isCompact(BuildContext context) =>
      MediaQuery.of(context).size.width < 768;

  @override
  Widget build(BuildContext context) {
    final compact = _isCompact(context);
    final showBottomNav = compact;

    // Drawer header line, e.g. "Entertainment · English"
    final categorySummary = CategoryPrefs.instance.summary();
    final langSummary = _langHeaderSummary(_currentLang);
    final feedStatusLine = '$categorySummary · $langSummary';

    // About row text, e.g. "Version 0.1.0 · Early access"
    final versionLabel = 'Version $_kAppVersion · Early access';

    // Content type label for drawer row
    final ctLabel = _contentTypeLabel(_contentType);

    return WillPopScope(
      onWillPop: () async {
        // Android back button behavior:
        // If something (like StoryDetailsScreen) is pushed above RootShell,
        // pop that first instead of closing the entire shell.
        final canPop = Navigator.of(context).canPop();
        if (canPop) Navigator.of(context).maybePop();
        return !canPop;
      },
      child: Scaffold(
        key: _scaffoldKey,

        // We don't use a left drawer in this design.
        drawer: null,
        drawerEnableOpenDragGesture: false,

        // Right-side drawer ("Menu")
        endDrawerEnableOpenDragGesture: false,
        endDrawer: Builder(
          builder: (drawerCtx) {
            return AppDrawer(
              // close button in header
              onClose: () => Navigator.of(drawerCtx).pop(),

              // keep this to allow HomeScreen refresh if prefs change
              onFiltersChanged: () => setState(() {}),

              // CONTENT & FILTERS
              onCategoryTap: () => _openCategoryPicker(drawerCtx),
              onContentTypeTap: () => _openContentTypePicker(drawerCtx),

              // APPEARANCE
              onThemeTap: () => _openThemePicker(drawerCtx),

              // SETTINGS
              onAppLanguageTap: () => _openAppLanguageSettings(drawerCtx),
              onSubscriptionTap: () {
                Navigator.of(drawerCtx).pop();
                _openSubscriptionSettings();
              },
              onLoginTap: () {
                Navigator.of(drawerCtx).pop();
                _openAccountSettings();
              },

              // SHARE / LEGAL links
              appShareUrl: 'https://cinepulse.netlify.app',
              privacyUrl: 'https://example.com/privacy', // TODO real link
              termsUrl: 'https://example.com/terms', // TODO real link

              // info shown in drawer header + About section
              feedStatusLine: feedStatusLine,
              versionLabel: versionLabel,

              // new: content type display for the "Content type" row
              contentTypeLabel: ctLabel,
            );
          },
        ),

        // Main body: active tab page, width-clamped on desktop
        body: _ResponsiveWidth(
          child: IndexedStack(
            index: _pageIndex,
            children: const [
              _HomeTabHost(),
              _DiscoverPlaceholder(),
              SavedScreen(),
              AlertsScreen(),
            ],
          ),
        ),

        // Frosted bottom nav only on compact / phone
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

/* Small host widget to pass callbacks into HomeScreen without wrappers above */
class _HomeTabHost extends StatelessWidget {
  const _HomeTabHost();

  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_RootShellState>()!;
    return HomeScreen(
      showSearchBar: state._showSearchBar,
      onMenuPressed: state._openEndDrawer,
      onOpenDiscover: state._openDiscover,
      onOpenSaved: state._openSaved,
      onOpenAlerts: state._openAlerts,
      onHeaderRefresh: () {},
    );
  }
}

/* ───────────────────────── THEME PICKER SHEET ─────────────────────────
 *
 * Bottom sheet for Theme.
 * "System / Light / Dark"
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

/* ───────────────────────── CONTENT TYPE PICKER SHEET ─────────────────────────
 *
 * Bottom sheet for "Content type".
 * Lets user pick one of:
 *   All / Read / Video / Audio
 *
 * Returns 'all' | 'read' | 'video' | 'audio'.
 */
class _ContentTypePicker extends StatefulWidget {
  const _ContentTypePicker({required this.current});
  final String current;

  @override
  State<_ContentTypePicker> createState() => _ContentTypePickerState();
}

class _ContentTypePickerState extends State<_ContentTypePicker> {
  late String _local;

  @override
  void initState() {
    super.initState();
    _local = widget.current;
  }

  void _setType(String v) {
    setState(() {
      _local = v;
    });
  }

  Widget _typeTile({
    required String value,
    required String label,
    required String desc,
  }) {
    final active = (_local == value);
    final theme = Theme.of(context);

    return RadioListTile<String>(
      value: value,
      groupValue: _local,
      onChanged: (val) => _setType(val ?? value),
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
              'Content type',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Pick what format you want first.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            _typeTile(
              value: 'all',
              label: 'All',
              desc: 'Everything',
            ),
            _typeTile(
              value: 'read',
              label: 'Read',
              desc: 'Text / captions',
            ),
            _typeTile(
              value: 'video',
              label: 'Video',
              desc: 'Clips, trailers, interviews',
            ),
            _typeTile(
              value: 'audio',
              label: 'Audio',
              desc: 'Pod bites (coming soon)',
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
 * Bottom sheet for "Categories".
 * Lets user pick All / Entertainment / Sports / Travel / Fashion.
 * Multi-select except "All" which is exclusive.
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
      // as soon as you pick a specific vertical, drop "All"
      _local.remove(all);
      // but never allow empty
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
              'Categories',
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

/* ───────────────────────── APP LANGUAGE SHEET ─────────────────────────
 *
 * Bottom sheet for "App language".
 * Lists CinePulse UI languages (not feed/story language).
 * We show 7 options:
 *
 *  english_ui   English / English
 *  hindi_ui     हिन्दी / Hindi
 *  bengali_ui   বাংলা / Bengali
 *  marathi_ui   मराठी / Marathi
 *  telugu_ui    తెలుగు / Telugu
 *  tamil_ui     தமிழ் / Tamil
 *  gujarati_ui  ગુજરાતી / Gujarati
 *
 * Returns the picked code on "Apply".
 */
class _AppLanguageSheet extends StatefulWidget {
  const _AppLanguageSheet({required this.currentCode});
  final String currentCode;

  @override
  State<_AppLanguageSheet> createState() => _AppLanguageSheetState();
}

class _AppLanguageSheetState extends State<_AppLanguageSheet> {
  late String _localCode;

  static const _accent = Color(0xFFdc2626);

  final List<({String code, String primary, String secondary})> _langs = const [
    (code: 'english_ui', primary: 'English', secondary: 'English'),
    (code: 'hindi_ui', primary: 'हिन्दी', secondary: 'Hindi'),
    (code: 'bengali_ui', primary: 'বাংলা', secondary: 'Bengali'),
    (code: 'marathi_ui', primary: 'मराठी', secondary: 'Marathi'),
    (code: 'telugu_ui', primary: 'తెలుగు', secondary: 'Telugu'),
    (code: 'tamil_ui', primary: 'தமிழ்', secondary: 'Tamil'),
    (code: 'gujarati_ui', primary: 'ગુજરાતી', secondary: 'Gujarati'),
  ];

  @override
  void initState() {
    super.initState();
    _localCode = widget.currentCode;
  }

  void _pick(String code) {
    setState(() {
      _localCode = code;
    });
  }

  Widget _langRow(
    ({String code, String primary, String secondary}) lang,
    ThemeData theme,
  ) {
    final selected = (lang.code == _localCode);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _pick(lang.code),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    lang.primary,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  if (lang.secondary != lang.primary)
                    Text(
                      lang.secondary,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (selected)
              const Icon(
                Icons.check_rounded,
                color: _accent,
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
              'App language',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Change the CinePulse UI language. Headlines and story text '
              'still follow your feed settings.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _langs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 4),
                itemBuilder: (_, i) => _langRow(_langs[i], theme),
              ),
            ),

            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.check_rounded),
                label: const Text('Apply'),
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onPressed: () {
                  Navigator.pop(context, _localCode);
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
 * Simple placeholder until we actually build Discover.
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
 * On desktop/tablet we clamp max width to ~1300px so the feed grid doesn't
 * stretch into silly long rows. On phones we just fill the width normally.
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
 * Frosted/blurred bottom nav for phones:
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

/// Single button in the bottom nav ("Home", "Search", ...) with red glow when active.
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
