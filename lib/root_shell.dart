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

class RootShell extends StatefulWidget {
  const RootShell({super.key});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>(); // for hamburger open

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
      // Ignore; we’ll just show Home. Optional toast below for web.
    }

    if (mounted && kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Opening… fetching story may take a moment')),
      );
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

  // Called by hamburger in HomeScreen.
  void _openDrawer() {
    _scaffoldKey.currentState?.openDrawer();
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

        // Drawer: keep only non-bottom-nav items (no Home/Search/Saved/Alerts here)
        drawer: Drawer(
          child: SafeArea(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                const _BrandDrawerHeader(),
                const Divider(height: 24),
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Theme'),
                  subtitle: const Text('System / Light / Dark'),
                  onTap: () => _openThemePicker(context),
                ),
                ListTile(
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('Settings'),
                  onTap: () => Navigator.pop(context),
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('About'),
                  onTap: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        ),

        // Keep tab states with an IndexedStack. Center on wide screens.
        body: _ResponsiveWidth(
          child: IndexedStack(
            index: _pageIndex,
            children: [
              HomeScreen(
                showSearchBar: _showSearchBar,
                onMenuPressed: _openDrawer,
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
                    // Match header thickness (AppBar toolbarHeight = 70)
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

/* ------------------------------ Branding ------------------------------ */

class _BrandDrawerHeader extends StatelessWidget {
  const _BrandDrawerHeader();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DrawerHeader(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primaryContainer.withOpacity(0.85),
            scheme.surfaceContainerHighest.withOpacity(0.6),
          ],
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const _LogoMark(size: 44),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'CinePulse',
                style: GoogleFonts.inter(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              Text(
                'Movies & OTT, in a minute.',
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  color: scheme.onPrimaryContainer.withOpacity(0.8),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Uses your branded asset for the logomark; falls back to a simple glyph if missing.
class _LogoMark extends StatelessWidget {
  const _LogoMark({this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: Container(
        width: size,
        height: size,
        color: scheme.surface,
        child: Image.asset(
          'assets/logo.png',
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) {
            // Fallback: minimal CP mark if asset not found yet.
            return Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [scheme.primary, scheme.tertiary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                'CP',
                style: GoogleFonts.inter(
                  fontSize: size * 0.42,
                  fontWeight: FontWeight.w900,
                  color: scheme.onPrimary,
                  letterSpacing: 0.5,
                ),
              ),
            );
          },
        ),
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
