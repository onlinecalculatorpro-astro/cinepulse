// lib/root_shell.dart
//
// RootShell = the global app shell / scaffold.
// It owns:
//   • The 4 primary tabs (Home / Discover / Saved / Alerts) via an IndexedStack
//   • The right-side drawer ("Menu")
//   • Bottom nav on compact layouts (<768px width)
//   • Cross-tab navigation callbacks for wide headers (≥768px)
//   • Initial deep link handling (/s/<id> → StoryDetailsScreen)
//
// NAV MODEL
// -----------------------------------------------------------------------------
// COMPACT (<768px width)
//   - Frosted bottom nav with 4 icons: Home / Discover / Saved / Alerts
//   - Each tab's header only shows utility CTAs: [Search] [Refresh] [Menu]
//
// WIDE (≥768px width)
//   - NO bottom nav.
//   - Each tab's header shows cross-nav CTA pills (omitting itself).
//
// Drawer
// -----------------------------------------------------------------------------
// Surfaces: Categories, Content type, Theme, App language, Subscription, Account
// Shows header summary like: "Entertainment · English" and content type.
//
// Deep links
// -----------------------------------------------------------------------------
// On first launch, checks current URL for "/s/<id>" and opens details.
//
// Responsive width
// -----------------------------------------------------------------------------
// On wide screens we center content in max ~1300px column.

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app_settings.dart';
import 'core/api.dart' show fetchStory;
import 'core/cache.dart'; // FeedCache
import 'core/models.dart';
import 'core/utils.dart'; // fadeRoute()
import 'features/alerts/alerts_screen.dart';
import 'features/discover/discover_screen.dart';
import 'features/home/home_screen.dart';
import 'features/saved/saved_screen.dart';
import 'features/story/story_details.dart';
import 'theme/theme_colors.dart'; // tokens & helpers
import 'widgets/app_drawer.dart';
// NEW: shared picker sheets
import 'widgets/picker_sheets.dart';

const String _kAppVersion = '0.1.0';

// persisted prefs keys
const String _kLangPrefKey = 'cp.lang'; // feed language: 'english' | 'hindi' | 'mixed' | ...
const String _kContentTypePrefKey =
    'cp.contentType'; // 'all' | 'read' | 'video' | 'audio'

/* ──────────────────────────────────────────────────────────────────────────
 * CATEGORY PREFS
 * ───────────────────────────────────────────────────────────────────────── */
class CategoryPrefs extends ChangeNotifier {
  CategoryPrefs._internal();
  static final CategoryPrefs instance = CategoryPrefs._internal();

  static const keyAll = 'all';
  static const keyEntertainment = 'entertainment';
  static const keySports = 'sports';
  static const keyTravel = 'travel';
  static const keyFashion = 'fashion';

  // default = All
  final Set<String> _selected = {keyAll};

  Set<String> get selected => Set.unmodifiable(_selected);
  bool isSelected(String k) => _selected.contains(k);

  void applySelection(Set<String> incoming) {
    _selected
      ..clear()
      ..addAll(incoming);
    _normalize();
    notifyListeners();
  }

  String summary() {
    if (_selected.contains(keyAll)) return 'All';

    final labels = _selected.map((k) {
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

    if (labels.isEmpty) return 'All';
    if (labels.length == 1) return labels.first;
    return '${labels.first} +${labels.length - 1}';
  }

  void _normalize() {
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

/* ──────────────────────────────────────────────────────────────────────────
 * CONTENT TYPE PREFS
 * 'all' | 'read' | 'video' | 'audio'
 * ───────────────────────────────────────────────────────────────────────── */
class ContentTypePrefs extends ChangeNotifier {
  ContentTypePrefs._internal();
  static final ContentTypePrefs instance = ContentTypePrefs._internal();

  static const typeAll = 'all';
  static const typeRead = 'read';
  static const typeVideo = 'video';
  static const typeAudio = 'audio';

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

/* ──────────────────────────────────────────────────────────────────────────
 * RootShell
 * ───────────────────────────────────────────────────────────────────────── */
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // IndexedStack page:
  //   0 = Home
  //   1 = Discover
  //   2 = Saved
  //   3 = Alerts
  int _pageIndex = 0;

  // Bottom nav highlight (compact layouts only).
  int _navIndex = 0;

  // Feed language preference (content language)
  String _currentLang = 'mixed';

  // UI chrome language code (drawer "App language")
  String _appUiLanguageCode = 'english_ui';

  // Content type pref ('all' | 'read' | 'video' | 'audio')
  String _currentContentType = ContentTypePrefs.typeAll;

  // Deep link bootstrap (/s/<id>)
  String? _pendingDeepLinkId;
  bool _deepLinkHandled = false;

  @override
  void initState() {
    super.initState();
    _captureInitialDeepLink();
    _loadLangPref();
    _loadContentTypePref();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openPendingDeepLinkIfAny();
    });
  }

  /* ───────────────────────── prefs bootstrap ───────────────────────── */

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

  /* ───────────────────────── deep link (/s/<id>) ───────────────────────── */

  void _captureInitialDeepLink() {
    final frag = Uri.base.fragment;
    final path = (frag.isNotEmpty ? frag : Uri.base.path).trim();
    final match = RegExp(r'(^|/)+s/([^/?#]+)').firstMatch(path);
    if (match != null) {
      _pendingDeepLinkId = match.group(2);
    }
  }

  Future<void> _openPendingDeepLinkIfAny() async {
    if (_deepLinkHandled || _pendingDeepLinkId == null) return;

    const maxWait = Duration(seconds: 4);
    const pollEvery = Duration(milliseconds: 200);
    final started = DateTime.now();

    while (mounted && DateTime.now().difference(started) < maxWait) {
      final Story? cached = FeedCache.get(_pendingDeepLinkId!);
      if (cached != null) {
        await _openStoryDetails(cached);
        return;
      }
      await Future<void>.delayed(pollEvery);
    }

    try {
      final story = await fetchStory(_pendingDeepLinkId!);
      if (!mounted) return;
      FeedCache.put(story);
      await _openStoryDetails(story);
    } catch (_) {
      // ignore (fall back to Home)
    }
  }

  Future<void> _openStoryDetails(Story s) async {
    _deepLinkHandled = true;

    if (_pageIndex != 0) {
      setState(() {
        _pageIndex = 0;
        _navIndex = 0;
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;

    Navigator.of(context).push(
      fadeRoute(StoryDetailsScreen(story: s)),
    );
  }

  /* ───────────────────────── tab nav helpers ───────────────────────── */

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

  void _onBottomNavTap(int i) {
    setState(() {
      _navIndex = i;
      _pageIndex = i;
    });
  }

  /* ───────────────────────── drawer sheets ───────────────────────── */

  Future<void> _openThemePicker(BuildContext drawerContext) async {
    final currentThemeMode = AppSettings.instance.themeMode;
    Navigator.pop(drawerContext);

    final picked = await showModalBottomSheet<ThemeMode>(
      context: context,
      showDragHandle: true,
      builder: (_) => ThemePickerSheet(current: currentThemeMode),
    );

    if (picked != null) {
      await AppSettings.instance.setThemeMode(picked);
      if (mounted) setState(() {});
    }
  }

  Future<void> _openCategoriesPicker(BuildContext drawerContext) async {
    Navigator.pop(drawerContext);

    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => CategoryPickerSheet(initial: CategoryPrefs.instance.selected),
    );

    if (picked != null && picked.isNotEmpty) {
      CategoryPrefs.instance.applySelection(picked);
      if (mounted) setState(() {});
    }
  }

  Future<void> _openContentTypePicker(BuildContext drawerContext) async {
    Navigator.pop(drawerContext);

    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => ContentTypePickerSheet(current: _currentContentType),
    );

    if (picked != null && picked.isNotEmpty) {
      if (!mounted) return;
      setState(() => _currentContentType = picked);
      ContentTypePrefs.instance.setSelected(picked);
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kContentTypePrefKey, picked);
    }
  }

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
      setState(() => _appUiLanguageCode = picked);
    }
  }

  Future<void> _openSubscriptionSettings() async {
    await _showComingSoonSheet(
      title: 'Subscription',
      message: 'Remove ads & unlock extras. This will show our plans / paywall.',
    );
  }

  Future<void> _openAccountSettings() async {
    await _showComingSoonSheet(
      title: 'Sign in',
      message: 'Sign in to sync your saved stories and alerts across devices.',
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
        final scheme = theme.colorScheme;
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
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('OK'),
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      textStyle: const TextStyle(fontWeight: FontWeight.w600),
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

  /* ───────────────────────── responsive helpers ───────────────────────── */

  bool _isCompactLayout(BuildContext context) =>
      MediaQuery.of(context).size.width < 768;

  /* ───────────────────────── build ───────────────────────── */
  @override
  Widget build(BuildContext context) {
    final isCompact = _isCompactLayout(context);
    final showBottomNav = isCompact;

    final categorySummary = CategoryPrefs.instance.summary();
    final langSummary = _langHeaderSummary(_currentLang);
    final feedStatusLine = '$categorySummary · $langSummary';

    final contentTypeSummary = ContentTypePrefs.instance.summary();
    final versionLabel = 'Version $_kAppVersion · Early access';

    return WillPopScope(
      onWillPop: () async {
        final nav = Navigator.of(context);
        final canPop = nav.canPop();
        if (canPop) {
          nav.maybePop();
        }
        return !canPop;
      },
      child: Scaffold(
        key: _scaffoldKey,

        drawer: null,
        drawerEnableOpenDragGesture: false,

        // Right-side drawer only.
        endDrawerEnableOpenDragGesture: false,
        endDrawer: Builder(
          builder: (drawerCtx) {
            return AppDrawer(
              // HEADER META
              onClose: () => Navigator.of(drawerCtx).pop(),
              feedStatusLine: feedStatusLine,
              versionLabel: versionLabel,
              contentTypeLabel: contentTypeSummary,

              // Refresh RootShell after filters/theme changes.
              onFiltersChanged: () => setState(() {}),

              // FILTERS
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

        // BODY
        body: SafeArea(
          top: true,
          bottom: false,
          child: _ResponsiveWidth(
            child: IndexedStack(
              index: _pageIndex,
              children: [
                // HOME
                const _HomeTabHost(),

                // DISCOVER
                _DiscoverTabHost(
                  onOpenHome: _openHome,
                  onOpenSaved: _openSaved,
                  onOpenAlerts: _openAlerts,
                  onOpenMenu: _openEndDrawer,
                ),

                // SAVED
                SavedScreen(
                  onOpenHome: _openHome,
                  onOpenDiscover: _openDiscover,
                  onOpenAlerts: _openAlerts,
                  onOpenMenu: _openEndDrawer,
                ),

                // ALERTS
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

        // Frosted bottom nav (phones / narrow only)
        bottomNavigationBar: showBottomNav
            ? CineBottomNavBar(
                currentIndex: _navIndex,
                onTap: _onBottomNavTap,
              )
            : null,
      ),
    );
  }
}

/* ───────────────────────── HOME TAB HOST ───────────────────────── */
class _HomeTabHost extends StatelessWidget {
  const _HomeTabHost();

  @override
  Widget build(BuildContext context) {
    final shell = context.findAncestorStateOfType<_RootShellState>()!;
    return HomeScreen(
      showSearchBar: false, // RootShell no longer drives inline search
      onMenuPressed: shell._openEndDrawer,
      onHeaderRefresh: () {
        // optional hook
      },
      onOpenDiscover: shell._openDiscover,
      onOpenSaved: shell._openSaved,
      onOpenAlerts: shell._openAlerts,
    );
  }
}

/* ───────────────────────── DISCOVER TAB HOST ───────────────────────── */
class _DiscoverTabHost extends StatelessWidget {
  const _DiscoverTabHost({
    required this.onOpenHome,
    required this.onOpenSaved,
    required this.onOpenAlerts,
    required this.onOpenMenu,
  });

  final VoidCallback onOpenHome;
  final VoidCallback onOpenSaved;
  final VoidCallback onOpenAlerts;
  final VoidCallback onOpenMenu;

  @override
  Widget build(BuildContext context) {
    return DiscoverScreen(
      onOpenHome: onOpenHome,
      onOpenSaved: onOpenSaved,
      onOpenAlerts: onOpenAlerts,
      onOpenMenu: onOpenMenu,
    );
  }
}

/* ───────────────────────── APP LANGUAGE SHEET (kept local) ───────────────── */
class _AppLanguageSheet extends StatefulWidget {
  const _AppLanguageSheet({required this.currentCode});
  final String currentCode;

  @override
  State<_AppLanguageSheet> createState() => _AppLanguageSheetState();
}

class _AppLanguageSheetState extends State<_AppLanguageSheet> {
  late String _localCode;

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

  void _pick(String code) => setState(() => _localCode = code);

  Widget _langRow(
    ({String code, String primary, String secondary}) lang,
    ThemeData theme,
  ) {
    final scheme = theme.colorScheme;
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
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  if (lang.secondary != lang.primary)
                    Text(
                      lang.secondary,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (selected)
              Icon(
                Icons.check_rounded,
                color: scheme.primary,
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
              'Change CinePulse UI chrome. Headlines and story text still '
              'follow your content settings.',
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
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                  textStyle: const TextStyle(fontWeight: FontWeight.w600),
                ),
                onPressed: () => Navigator.pop(context, _localCode),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ───────────────────────── RESPONSIVE WIDTH WRAPPER ───────────────────────── */
class _ResponsiveWidth extends StatelessWidget {
  const _ResponsiveWidth({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
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

/* ───────────────────────── CINE BOTTOM NAV BAR ───────────────────────── */
class CineBottomNavBar extends StatelessWidget {
  const CineBottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // Use theme tokens for frosted gradient instead of hard-coded colors
    final gradientColors = isDark
        ? [
            kCardTop.withOpacity(0.90),
            kDarkBgEnd.withOpacity(0.95),
          ]
        : [
            scheme.surface.withOpacity(0.95),
            scheme.surface.withOpacity(0.90),
          ];

    final borderColor = outlineHairline(context);

    final navItems = <_NavItemSpec>[
      const _NavItemSpec(icon: Icons.home_rounded, label: 'Home'),
      const _NavItemSpec(icon: Icons.explore_rounded, label: 'Discover'),
      const _NavItemSpec(icon: Icons.bookmark_rounded, label: 'Saved'),
      const _NavItemSpec(icon: Icons.notifications_rounded, label: 'Alerts'),
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
              colors: gradientColors,
            ),
            border: Border(
              top: BorderSide(color: borderColor, width: 1),
            ),
            boxShadow: [
              BoxShadow(
                color: theme.shadowColor.withOpacity(isDark ? 0.60 : 0.12),
                blurRadius: 30,
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
            children: List.generate(navItems.length, (i) {
              final spec = navItems[i];
              final selected = (i == currentIndex);
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
  const _NavItemSpec({required this.icon, required this.label});
  final IconData icon;
  final String label;
}

/// A single pill in the bottom nav ("Home", "Discover", etc.).
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // All pill colors sourced from theme helpers
    final inactiveBg = neutralPillBg(context);
    final inactiveBorder = scheme.primary.withOpacity(0.30);
    final inactiveText = primaryTextColor(context);

    final activeBg = scheme.primary.withOpacity(0.12);
    final activeBorder = scheme.primary;
    final activeText = scheme.primary;

    final bg = selected ? activeBg : inactiveBg;
    final borderColor = selected ? activeBorder : inactiveBorder;
    final fg = selected ? activeText : inactiveText;

    final glow = selected
        ? [
            BoxShadow(
              color: scheme.primary.withOpacity(0.40),
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
              border: Border.all(color: borderColor, width: 1),
              boxShadow: glow,
            ),
            child: Icon(icon, size: 20, color: fg),
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
