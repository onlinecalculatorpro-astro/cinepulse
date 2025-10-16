// lib/root_shell.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app/app_settings.dart';
import 'core/cache.dart';
import 'core/models.dart';
import 'core/utils.dart'; // for fadeRoute()
import 'features/home/home_screen.dart';
import 'features/saved/saved_screen.dart';
import 'features/story/story_details.dart';
import 'features/alerts/alerts_screen.dart'; // NEW

class RootShell extends StatefulWidget {
  const RootShell({super.key});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  final _pages = const [
    HomeScreen(),
    _DiscoverPlaceholder(),
    SavedScreen(),
    AlertsScreen(), // NEW
  ];

  String? _pendingDeepLinkId;
  bool _deepLinkHandled = false;

  @override
  void initState() {
    super.initState();
    _captureInitialDeepLink();
    // Try to resolve deep link shortly after first frame so feeds have a tick to start.
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryOpenPendingDeepLink());
  }

  /// Parses a link like `/#/s/<id>` (or `#/s/<id>`) from the current URL.
  void _captureInitialDeepLink() {
    // On web, Uri.base.fragment contains anything after '#' (e.g. "/s/abc123").
    // On mobile deep link, some hosts may pass the whole path; handle both.
    final frag = Uri.base.fragment; // "" on non-web or when not using hash URLs
    final path = (frag.isNotEmpty ? frag : Uri.base.path).trim();

    final match = RegExp(r'(^|/)+s/([^/?#]+)').firstMatch(path);
    if (match != null) {
      _pendingDeepLinkId = match.group(2);
    }
  }

  Future<void> _tryOpenPendingDeepLink() async {
    if (_deepLinkHandled || _pendingDeepLinkId == null) return;

    // Poll the in-memory feed cache briefly in case feeds are still loading.
    // Stop as soon as we find a Story with this id.
    const maxWait = Duration(seconds: 4);
    const tick = Duration(milliseconds: 200);
    final started = DateTime.now();

    while (mounted && DateTime.now().difference(started) < maxWait) {
      final Story? s = _getStoryFromCache(_pendingDeepLinkId!);
      if (s != null) {
        _deepLinkHandled = true;
        // Jump to Home tab (index 0) then open details.
        if (_index != 0) setState(() => _index = 0);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (!mounted) return;
        Navigator.of(context).push(fadeRoute(StoryDetailsScreen(story: s)));
        return;
      }
      await Future<void>.delayed(tick);
    }

    if (mounted && kIsWeb && _pendingDeepLinkId != null) {
      // Give the user a hint if nothing turned up.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link opened, loading feed…')),
      );
    }
  }

  // Lightweight helper to read from the app's in-memory cache without coupling
  // RootShell to networking. Feed code already calls FeedCache.put(s).
  Story? _getStoryFromCache(String id) {
    try {
      // Adjust to your cache API if different (e.g., FeedCache.lookup / byId).
      return FeedCache.get(id);
    } catch (_) {
      return null;
    }
  }

  Future<void> _openThemePicker(BuildContext context) async {
    final current = AppSettings.instance.themeMode;
    final picked = await showModalBottomSheet<ThemeMode>(
      context: context,
      showDragHandle: true,
      builder: (_) => _ThemePicker(current: current),
    );
    if (picked != null) {
      await AppSettings.instance.setThemeMode(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              const _BrandDrawerHeader(),
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('Theme'),
                subtitle: const Text('System / Light / Dark'),
                onTap: () => _openThemePicker(context),
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Settings'),
                onTap: () {},
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('About'),
                onTap: () {},
              ),
            ],
          ),
        ),
      ),

      // Center pages on wide screens; animate transitions slightly.
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: _ResponsiveWidth(child: _pages[_index], key: ValueKey(_index)),
      ),

      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (i) => setState(() => _index = i),
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
          NavigationDestination(
            icon: Icon(Icons.bookmark_outline),
            selectedIcon: Icon(Icons.bookmark),
            label: 'Saved',
          ),
          NavigationDestination(
            icon: Icon(Icons.notifications_outlined),
            selectedIcon: Icon(Icons.notifications),
            label: 'Alerts', // NEW
          ),
        ],
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

/// Minimal “CP” logomark so the app feels branded even before we ship assets.
class _LogoMark extends StatelessWidget {
  const _LogoMark({this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [scheme.primary, scheme.tertiary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: 10,
            spreadRadius: 0,
            offset: const Offset(0, 3),
            color: scheme.primary.withOpacity(0.25),
          ),
        ],
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
  }
}

/* --------------------------- Theme picker sheet --------------------------- */

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.current});
  final ThemeMode current;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Theme',
                style: GoogleFonts.inter(
                    fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final entry in {
              ThemeMode.system: ('System', Icons.auto_awesome),
              ThemeMode.light: ('Light', Icons.light_mode_outlined),
              ThemeMode.dark: ('Dark', Icons.dark_mode_outlined),
            }.entries)
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
      final maxW = w >= 1200 ? 980.0 : 900.0;
      return Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: child,
        ),
      );
    });
  }
}
