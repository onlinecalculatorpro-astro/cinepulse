// lib/root_shell.dart
//
// RootShell = main scaffold / shell for the whole app.
//
// It owns:
//  • Tab pages (Home / Discover / Saved / Alerts) via an IndexedStack
//  • The global right-side drawer ("Menu")
//  • The bottom nav on phones only (<768px width)
//  • Deep link handling for /s/<id> → StoryDetailsScreen
//
// ─────────────────────────────────────────────────────────────────────
// FINAL NAV / HEADER MODEL
// ─────────────────────────────────────────────────────────────────────
//
// MOBILE (<768px):
//   Bottom nav has 4 CTA icons:
//     0 = Home
//     1 = Discover
//     2 = Saved
//     3 = Alerts
//
//   Screen headers DO NOT duplicate bottom-nav destinations. They only
//   show utility actions (Search / Refresh / Menu, etc.).
//
// DESKTOP / WIDE (≥768px):
//   No bottom nav. Each screen header can show more nav-style pills
//   (Home / Discover / Saved / Alerts / Search / Refresh / Menu), with
//   the rule that a screen never shows a pill for itself
//   (SavedScreen won't show "Saved", etc.).
//
// RootShell exposes navigation callbacks so headers can switch tabs,
// and also opens the global drawer ("Menu").
//
// Drawer also exposes settings sheets (theme, categories, language, etc.).
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

const String _kLangPrefKey = 'cp.lang'; // 'english' | 'hindi' | 'mixed' | etc.
const String _kContentTypePrefKey =
    'cp.contentType'; // 'all' | 'read' | 'video' | 'audio'

/* ────────────────────────────────────────────────────────────────────────────
 * CATEGORY PREFS (drawer "Categories")
 * ────────────────────────────────────────────────────────────────────────────*/
class CategoryPrefs extends ChangeNotifier {
  CategoryPrefs._internal();
  static final CategoryPrefs instance = CategoryPrefs._internal();

  static const String keyAll = 'all';
  static const String keyEntertainment = 'entertainment';
  static const String keySports = 'sports';
  static const String keyTravel = 'travel';
  static const String keyFashion = 'fashion';

  // Default feed selection = "All".
  final Set<String> _selected = {keyAll};

  Set<String> get selected => Set.unmodifiable(_selected);
  bool isSelected(String k) => _selected.contains(k);

  void applySelection(Set<String> incoming) {
    _selected
      ..clear()
      ..addAll(incoming);
    _sanitize();
    notifyListeners();
  }

  /// Human label for drawer header ("Entertainment +2", etc.).
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
    // If "all" and others both set → collapse to just "all".
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
 * CONTENT TYPE PREFS (drawer "Content type")
 * 'all' | 'read' | 'video' | 'audio'
 * ────────────────────────────────────────────────────────────────────────────*/
class ContentTypePrefs extends ChangeNotifier {
  ContentTypePrefs._internal();
  static final ContentTypePrefs instance = ContentTypePrefs._internal();

  static const String typeAll = 'all';
  static const String typeRead = 'read';
  static const String typeVideo = 'video';
  static const String typeAudio = 'audio';

  String _selected = typeAll;
  String get selected => _selected;

  void setSelected(String v) {
    _selected = v;
    notifyListeners();
  }

  String summary() {
    switch (_selected) {
      case typeRead:
        return 'Read';
      case typeVideo:
        return 'Video';
      case typeAudio:
        return 'Audio';
      default:
        return 'All';
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

  // Which item is highlighted in the bottom nav (phones only):
  // 0 = Home
  // 1 = Discover
  // 2 = Saved
  // 3 = Alerts
  int _navIndex = 0;

  // feed language for drawer status line ("Entertainment · English")
  // 'english' | 'hindi' | 'mixed' | etc.
  String _currentLang = 'mixed';

  // CinePulse UI chrome language (drawer "App language")
  String _appUiLanguageCode = 'english_ui';

  // Content type filter ('all' | 'read' | 'video' | 'audio')
  String _currentContentType = ContentTypePrefs.typeAll;

  // Deep link (/s/<id>) support
  String? _pendingDeepLinkId;
  bool _deepLinkHandled = false;

  @override
  void initState() {
    super.initState();
    _captureInitialDeepLink();
    _loadLangPref();
    _loadContentTypePref();

    // After first frame, try to open the deep link story if any.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryOpenPendingDeepLink();
    });
  }

  /* ─────────────────── prefs bootstrap ─────────────────── */

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

  Future<void> _loadContentTypePref() async {
    final sp = await SharedPreferences.getInstance();
    final stored = sp.getString(_kContentTypePrefKey);
    if (!mounted) return;
    if (stored != null && stored.isNotEmpty) {
      setState(() {
        _currentContentType = stored;
        ContentTypePrefs.instance.setSelected(stored);
      });
    }
  }

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

  /* ─────────────────── deep link /s/<id> ─────────────────── */

  void _captureInitialDeepLink() {
    // On web, may come as path "/s/xyz" or hash "#/s/xyz".
    final frag = Uri.base.fragment;
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

    // 1. Poll FeedCache briefly to give feed a chance to warm up.
    while (mounted && DateTime.now().difference(started) < maxWait) {
      final Story? cached = FeedCache.get(_pendingDeepLinkId!);
      if (cached != null) {
        await _openDetails(cached);
        return;
      }
      await Future<void>.delayed(tick);
    }

    // 2. Fallback to network.
    try {
      final s = await fetchStory(_pendingDeepLinkId!);
      if (!mounted) return;
      FeedCache.put(s);
      await _openDetails(s);
      return;
    } catch (_) {
      // ignore; we'll just land on normal UI
    }
  }

  Future<void> _openDetails(Story s) async {
    _deepLinkHandled = true;

    // Make sure Home tab is visible behind the details view.
    if (_pageIndex != 0) {
      setState(() {
        _pageIndex = 0;
        _navIndex = 0;
      });
    }

    // tiny delay so Navigator is definitely ready
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;

    Navigator.of(context).push(
      fadeRoute(StoryDetailsScreen(story: s)),
    );
  }

  /* ─────────────────── header / nav callbacks ───────────────────
   *
   * These get passed into HomeScreen, SavedScreen, AlertsScreen so
   * their header icon pills can trigger tab changes or open the drawer.
   */

  void _openHome() {
    setState(() {
      _pageIndex = 0;
      _navIndex = 0;
    });
  }

  void _openDiscover() {
    setState(() {
      _pageIndex = 1;
      _navIndex = 1;
    });
  }

  void _openSaved() {
    setState(() {
      _pageIndex = 2;
      _navIndex = 2;
    });
  }

  void _openAlerts() {
    setState(() {
      _pageIndex = 3;
      _navIndex = 3;
    });
  }

  void _openEndDrawer() {
    _scaffoldKey.currentState?.openEndDrawer();
  }

  /* ─────────────────── bottom nav taps (phones) ───────────────────
   *
   *   0 = Home
   *   1 = Discover
   *   2 = Saved
   *   3 = Alerts
   */
  void _onDestinationSelected(int i) {
    setState(() {
      _navIndex = i;
      if (i == 0) _pageIndex = 0;
      if (i == 1) _pageIndex = 1;
      if (i == 2) _pageIndex = 2;
      if (i == 3) _pageIndex = 3;
    });
  }

  /* ─────────────────── drawer sheet helpers ─────────────────── */

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

  Future<void> _openCategoriesPicker(BuildContext drawerContext) async {
    Navigator.pop(drawerContext); // close drawer

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

  Future<void> _openContentTypePicker(BuildContext drawerContext) async {
    Navigator.pop(drawerContext); // close drawer

    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ContentTypePicker(current: _currentContentType),
    );

    if (picked != null && picked.isNotEmpty) {
      if (!mounted) return;
      setState(() {
        _currentContentType = picked;
      });

      ContentTypePrefs.instance.setSelected(picked);

      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kContentTypePrefKey, picked);
    }
  }

  Future<void> _openAppLanguageSettings(BuildContext drawerContext) async {
    Navigator.pop(drawerContext); // close drawer

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

  Future<void> _openSubscriptionSettings() async {
    await _showComingSoonSheet(
      title: 'Subscription',
      message:
          'Remove ads & unlock extras. This will show our paywall / plans.',
    );
  }

  Future<void> _openAccountSettings() async {
    await _showComingSoonSheet(
      title: 'Sign in',
      message:
          'Log in to sync your saved stories and alerts across devices.',
    );
  }

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

  /* ─────────────────── responsive helpers ─────────────────── */

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

    // "Content type" pill text in drawer
    final contentTypeLabel = ContentTypePrefs.instance.summary();

    // About footer text in drawer
    final versionLabel = 'Version $_kAppVersion · Early access';

    return WillPopScope(
      onWillPop: () async {
        // Android back:
        // If StoryDetailsScreen (or anything else) is pushed above RootShell,
        // pop that first instead of exiting the entire shell.
        final canPop = Navigator.of(context).canPop();
        if (canPop) {
          Navigator.of(context).maybePop();
        }
        return !canPop;
      },
      child: Scaffold(
        key: _scaffoldKey,

        drawer: null,
        drawerEnableOpenDragGesture: false,

        // We use ONLY an endDrawer (right side) for "Menu".
        endDrawerEnableOpenDragGesture: false,
        endDrawer: Builder(
          builder: (drawerCtx) {
            return AppDrawer(
              // header bits
              onClose: () => Navigator.of(drawerCtx).pop(),
              feedStatusLine: feedStatusLine,
              versionLabel: versionLabel,
              contentTypeLabel: contentTypeLabel,

              // so Home/Saved can rebuild if filters changed
              onFiltersChanged: () => setState(() {}),

              // CONTENT & FILTERS
              onCategoriesTap: () => _openCategoriesPicker(drawerCtx),
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

              // SHARE / LEGAL
              appShareUrl: 'https://cinepulse.netlify.app',
              privacyUrl: 'https://example.com/privacy', // TODO real link
              termsUrl: 'https://example.com/terms', // TODO real link
            );
          },
        ),

        // BODY:
        // SafeArea(top:true,bottom:false) so our custom headers don't sit
        // under the OS status bar on phones, but we still allow our own
        // frosted bottom nav to hug the bottom.
        body: SafeArea(
          top: true,
          bottom: false,
          child: _ResponsiveWidth(
            child: IndexedStack(
              index: _pageIndex,
              children: [
                const _HomeTabHost(),
                const _DiscoverPlaceholder(),
                SavedScreen(
                  onOpenHome: _openHome,
                  onOpenDiscover: _openDiscover,
                  onOpenAlerts: _openAlerts,
                  onOpenMenu: _openEndDrawer,
                ),
                AlertsScreen(
                  onOpenHome: _openHome,
                  onOpenDiscover: _openDiscover,
                  onOpenSaved: _openSaved,
                  onOpenMenu: _openEndDrawer,
                ),
              ],
            ),
          ),
        ),

        // Frosted bottom nav (phones only)
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

/* ─────────────────── Home tab host ───────────────────
 *
 * Helper widget so we can grab _RootShellState via context and pass
 * its callbacks / flags into HomeScreen cleanly.
 *
 * NOTE:
 *  HomeScreen itself will control its own header Search toggle
 *  (to reveal the inline search row under the chips). RootShell no longer
 *  tries to drive that via a "Search" bottom-tab.
 */
class _HomeTabHost extends StatelessWidget {
  const _HomeTabHost();

  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_RootShellState>()!;
    return HomeScreen(
      // RootShell no longer forces search row open;
      // HomeScreen manages its own search CTA in the header.
      showSearchBar: false,

      // header actions
      onMenuPressed: state._openEndDrawer,
      onHeaderRefresh: () {
        // keep this hook if HomeScreen wants to call back after refresh
      },

      // nav CTA callbacks (for wide header versions)
      onOpenDiscover: state._openDiscover,
      onOpenSaved: state._openSaved,
      onOpenAlerts: state._openAlerts,
    );
  }
}

/* ───────────────────────── THEME PICKER SHEET ───────────────────────── */
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

/* ───────────────────────── CATEGORY PICKER SHEET ───────────────────────── */
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
      // once you pick a specific vertical, drop "all"
      _local.remove(all);
      // never allow empty
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

/* ───────────────────────── CONTENT TYPE PICKER SHEET ───────────────────────── */
class _ContentTypePicker extends StatefulWidget {
  const _ContentTypePicker({required this.current});
  final String current;

  @override
  State<_ContentTypePicker> createState() => _ContentTypePickerState();
}

class _ContentTypePickerState extends State<_ContentTypePicker> {
  late String _localType;

  @override
  void initState() {
    super.initState();
    _localType = widget.current;
  }

  void _pick(String v) {
    setState(() {
      _localType = v;
    });
  }

  Widget _typeTile({
    required String value,
    required String title,
    required String desc,
  }) {
    final theme = Theme.of(context);
    final active = (_localType == value);

    return RadioListTile<String>(
      value: value,
      groupValue: _localType,
      onChanged: (val) => _pick(val ?? value),
      title: Column(
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
              value: ContentTypePrefs.typeAll,
              title: 'All',
              desc: 'Everything',
            ),
            _typeTile(
              value: ContentTypePrefs.typeRead,
              title: 'Read',
              desc: 'Text / captions',
            ),
            _typeTile(
              value: ContentTypePrefs.typeVideo,
              title: 'Video',
              desc: 'Clips, trailers, interviews',
            ),
            _typeTile(
              value: ContentTypePrefs.typeAudio,
              title: 'Audio',
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
                  Navigator.pop(context, _localType);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ───────────────────────── APP LANGUAGE SHEET ───────────────────────── */
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
              'Change the CinePulse UI language. '
              'Headlines and story text still follow your '
              'Categories / Content type settings.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            Flexible(
              fit: FlexFit.loose,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _langs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (_, i) => _langRow(_langs[i], theme),
                ),
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

/* ───────────────────────── RESPONSIVE WIDTH WRAPPER ─────────────────────────
 *
 * On desktop/tablet we clamp max width to ~1300px so the feed grid doesn't
 * stretch into ultra-wide 1-row galleries. On phones we just fill width.
 */
class _ResponsiveWidth extends StatelessWidget {
  const _ResponsiveWidth({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        if (w < 768) return child;

        const maxW = 1300.0;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: maxW),
            child: child,
          ),
        );
      },
    );
  }
}

/* ───────────────────────── CINE BOTTOM NAV BAR ─────────────────────────
 *
 * Frosted/blurred bottom nav for compact screens (<768px):
 *
 *   0 = Home
 *   1 = Discover
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
        icon: Icons.explore_rounded,
        label: 'Discover',
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

/// Single bottom-nav button ("Home", "Discover", etc.) with red glow when active.
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
        : const <BoxShadow>[];

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
