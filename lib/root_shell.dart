// lib/root_shell.dart
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
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

class RootShell extends StatefulWidget {
  const RootShell({super.key});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  // We’ll use this to open the right-side drawer (endDrawer).
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // Which page is visible in the body (Home, Discover, Saved, Alerts).
  int _pageIndex = 0;

  // Which item is highlighted in the bottom nav (Home, Search, Saved, Alerts).
  int _navIndex = 0;

  // Whether HomeScreen should show its search bar (toggled via bottom-nav Search).
  bool _showSearchBar = false;

  String? _pendingDeepLinkId;
  bool _deepLinkHandled = false;

  @override
  void initState() {
    super.initState();
    _captureInitialDeepLink();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryOpenPendingDeepLink());
  }

  /// Parses links like `/#/s/<id>` or `/s/<id>` from the current URL.
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

    // 1) Try to find it in in-memory cache quickly (ideal path).
    while (mounted && DateTime.now().difference(started) < maxWait) {
      final Story? s = FeedCache.get(_pendingDeepLinkId!);
      if (s != null) {
        await _openDetails(s);
        return;
      }
      await Future<void>.delayed(tick);
    }

    // 2) Fallback: fetch the story directly (cold start / first run).
    try {
      final s = await fetchStory(_pendingDeepLinkId!);
      if (!mounted) return;
      FeedCache.put(s);
      await _openDetails(s);
      return;
    } catch (_) {
      // Ignore; we’ll just show Home. Optional toast could be shown for web.
    }
  }

  Future<void> _openDetails(Story s) async {
    _deepLinkHandled = true;
    if (_pageIndex != 0) setState(() => _pageIndex = 0); // ensure Home beneath
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    Navigator.of(context).push(fadeRoute(StoryDetailsScreen(story: s)));
  }

  // Called by header "Discover" action.
  void _openDiscover() {
    setState(() {
      _pageIndex = 1; // Discover page in the body
      _navIndex = (_navIndex == 1) ? 0 : _navIndex; // de-highlight Search if needed
      _showSearchBar = false;
    });
  }

  // Called by the menu icon in HomeScreen header.
  // This now opens the RIGHT SIDE drawer (endDrawer).
  void _openEndDrawer() {
    _scaffoldKey.currentState?.openEndDrawer();
  }

  // Called by bottom navigation.
  void _onDestinationSelected(int i) {
    // Index map for bottom nav: 0=Home, 1=Search, 2=Saved, 3=Alerts
    if (i == 1) {
      // Search item: show Home and reveal search bar
      setState(() {
        _pageIndex = 0;        // ensure Home is visible
        _navIndex = 1;         // highlight Search item
        _showSearchBar = true; // HomeScreen should render & focus search
      });
      return;
    }

    // Normal navigation for other items
    setState(() {
      _navIndex = i;
      _showSearchBar = false; // hide search when leaving Search/Home trigger
      if (i == 0) _pageIndex = 0; // Home
      if (i == 2) _pageIndex = 2; // Saved
      if (i == 3) _pageIndex = 3; // Alerts
    });
  }

  Future<void> _openThemePicker(BuildContext context) async {
    final current = AppSettings.instance.themeMode;
    Navigator.pop(context); // close drawer before sheet
    final picked = await showModalBottomSheet<ThemeMode>(
      context: context,
      showDragHandle: true,
      builder: (_) => _ThemePicker(current: current),
    );
    if (picked != null) {
      await AppSettings.instance.setThemeMode(picked);
    }
  }

  bool _isCompact(BuildContext context) => MediaQuery.of(context).size.width < 900;

  @override
  Widget build(BuildContext context) {
    final compact = _isCompact(context);
    // Show bottom nav on web (always) and on compact layouts.
    final showBottomNav = kIsWeb || compact;

    return WillPopScope(
      // Back button pops detail routes if any; otherwise allow system back.
      onWillPop: () async {
        final canPop = Navigator.of(context).canPop();
        if (canPop) Navigator.of(context).maybePop();
        return !canPop;
      },
      child: Scaffold(
        key: _scaffoldKey,

        // IMPORTANT:
        // We move the app drawer to the RIGHT side so it's thumb-friendly.
        // We also disable edge-swipe so it doesn't fight Android back gesture.
        drawer: null,
        drawerEnableOpenDragGesture: false,
        endDrawerEnableOpenDragGesture: false,
        endDrawer: AppDrawer(
          onClose: () => Navigator.of(context).pop(),
          onFiltersChanged: () => setState(() {}),   // Home can re-read prefs immediately
          onThemeTap: () => _openThemePicker(context),
          appShareUrl: 'https://cinepulse.netlify.app',
          privacyUrl: 'https://example.com/privacy', // TODO: replace with real link
          termsUrl: 'https://example.com/terms',     // TODO: replace with real link
        ),

        // Keep tab states with an IndexedStack. Center on wide screens.
        body: _ResponsiveWidth(
          child: IndexedStack(
            index: _pageIndex,
            children: [
              HomeScreen(
                showSearchBar: _showSearchBar,
                onMenuPressed: _openEndDrawer, // <-- now opens RIGHT drawer
                onOpenDiscover: _openDiscover,
                onHeaderRefresh: () {},
              ),
              const _DiscoverPlaceholder(),
              const SavedScreen(),
              const AlertsScreen(),
            ],
          ),
        ),

        // Bottom nav: Home=🏠, Search=🔍, Saved=🔖, Alerts=🔔
        bottomNavigationBar: showBottomNav
            ? SafeArea(
                top: false,
                child: NavigationBarTheme(
                  data: NavigationBarThemeData(
                    // Match header-ish thickness
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
                    labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                    onDestinationSelected: _onDestinationSelected,
                    destinations: const [
                      NavigationDestination(
                        icon: Text('🏠', style: TextStyle(fontSize: 20, height: 1)),
                        selectedIcon: Text('🏠', style: TextStyle(fontSize: 22, height: 1)),
                        label: 'Home',
                      ),
                      NavigationDestination(
                        icon: Text('🔍', style: TextStyle(fontSize: 20, height: 1)),
                        selectedIcon: Text('🔍', style: TextStyle(fontSize: 22, height: 1)),
                        label: 'Search',
                      ),
                      NavigationDestination(
                        icon: Text('🔖', style: TextStyle(fontSize: 20, height: 1)),
                        selectedIcon: Text('🔖', style: TextStyle(fontSize: 22, height: 1)),
                        label: 'Saved',
                      ),
                      NavigationDestination(
                        icon: Text('🔔', style: TextStyle(fontSize: 20, height: 1)),
                        selectedIcon: Text('🔔', style: TextStyle(fontSize: 22, height: 1)),
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

/* --------------------------- Theme picker sheet --------------------------- */

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.current});
  final ThemeMode current;

  @override
  Widget build(BuildContext context) {
    final options = <ThemeMode, (String, IconData)>{
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
            Text('Theme', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final entry in options.entries)
              RadioListTile<ThemeMode>(
                value: entry.key,
                groupValue: current,
                onChanged: (val) => Navigator.pop(context, val),
                title: Row(
                  children: [
                    Icon(entry.value.$2, size: 18),
                    const SizedBox(width: 8),
                    Text(entry.value.$1),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/* --------------------------- Discover placeholder ------------------------ */

class _DiscoverPlaceholder extends StatelessWidget {
  const _DiscoverPlaceholder();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Discover (coming soon)',
        style: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 22),
      ),
    );
  }
}

/* ----------------------------- Responsiveness ----------------------------- */

/// Centers content on tablets/desktop so pages don’t grow too wide.
/// On phones, it passes the page through unchanged.
class _ResponsiveWidth extends StatelessWidget {
  const _ResponsiveWidth({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      if (w <= 720) return child; // phones: full-bleed

      // Tablets & web: center with a comfortable max width.
      final maxW = w >= 1400 ? 1200.0 : (w >= 1200 ? 1080.0 : 980.0);
      return Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: child,
        ),
      );
    });
  }
}
