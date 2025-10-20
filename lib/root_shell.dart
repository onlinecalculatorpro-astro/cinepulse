// lib/root_shell.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
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
  int _index = 0;

  // Keep pages alive; constructors should be const for perf.
  static const List<Widget> _pages = [
    HomeScreen(),
    _DiscoverPlaceholder(),
    SavedScreen(),
    AlertsScreen(),
  ];

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
    if (_index != 0) setState(() => _index = 0); // ensure Home is visible beneath
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    Navigator.of(context).push(fadeRoute(StoryDetailsScreen(story: s)));
  }

  void _goTo(int i) {
    if (_index == i) return;
    setState(() => _index = i);
    Navigator.of(context).maybePop(); // close drawer if open
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

    // Show bottom nav on web (always) and on compact layouts for mobile/tablet.
    final showBottomNav = kIsWeb || compact;

    return WillPopScope(
      // Back button pops detail routes if any; otherwise allow system back.
      onWillPop: () async {
        final canPop = Navigator.of(context).canPop();
        if (canPop) Navigator.of(context).maybePop();
        return !canPop;
      },
      child: Scaffold(
        drawer: Drawer(
          child: SafeArea(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                const _BrandDrawerHeader(),
                // Quick navigation
                ListTile(
                  leading: const Icon(Icons.home_outlined),
                  title: const Text('Home'),
                  onTap: () => _goTo(0),
                ),
                ListTile(
                  leading: const Icon(Icons.explore_outlined),
                  title: const Text('Discover'),
                  onTap: () => _goTo(1),
                ),
                ListTile(
                  leading: const Icon(Icons.bookmark_outline),
                  title: const Text('Saved'),
                  onTap: () => _goTo(2),
                ),
                ListTile(
                  leading: const Icon(Icons.notifications_outlined),
                  title: const Text('Alerts'),
                  onTap: () => _goTo(3),
                ),
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
          child: IndexedStack(index: _index, children: _pages),
        ),

        // Bottom nav: emoji exact for Saved (🔖)
        bottomNavigationBar: showBottomNav
            ? SafeArea(
                top: false,
                child: NavigationBar(
                  selectedIndex: _index,
                  labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                  onDestinationSelected: _goTo,
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.home_outlined),
                      selectedIcon: Icon(Icons.home),
                      label: 'Home',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.explore_outlined),
                      selectedIcon: Icon(Icons.explore),
                      label: 'Discover',
                    ),
                    // 🔖 exact emoji for Saved
                    NavigationDestination(
                      icon: Text('🔖', style: TextStyle(fontSize: 20, height: 1)),
                      selectedIcon: Text('🔖', style: TextStyle(fontSize: 22, height: 1)),
                      label: 'Saved',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.notifications_outlined),
                      selectedIcon: Icon(Icons.notifications),
                      label: 'Alerts',
                    ),
                  ],
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
            Text('Theme',
                style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700)),
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
