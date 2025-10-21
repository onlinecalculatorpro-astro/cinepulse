// lib/root_shell.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

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

        // Drawer with the sections you approved
        drawer: _CineDrawer(
          onClose: () => Navigator.of(context).pop(),
          onFiltersChanged: () => setState(() {}), // force rebuild; Home can re-read prefs
          onThemeTap: () => _openThemePicker(context),
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

/* ----------------------------- The Drawer ----------------------------- */

class _CineDrawer extends StatefulWidget {
  const _CineDrawer({
    required this.onClose,
    required this.onFiltersChanged,
    required this.onThemeTap,
  });

  final VoidCallback onClose;
  final VoidCallback onFiltersChanged;
  final VoidCallback onThemeTap;

  @override
  State<_CineDrawer> createState() => _CineDrawerState();
}

class _CineDrawerState extends State<_CineDrawer> {
  // Pref keys
  static const _kRegion = 'cp.region';        // 'india' | 'global'
  static const _kLang   = 'cp.lang';          // 'english' | 'hindi' | 'mixed'
  static const _kCats   = 'cp.categories';    // JSON list: ['all','trailers',...]

  // Local state (defaults)
  String _region = 'india';
  String _lang = 'mixed';
  final Set<String> _cats = {'all', 'trailers', 'ott', 'intheatres', 'comingsoon'};

  late Future<void> _loader;

  @override
  void initState() {
    super.initState();
    _loader = _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final sp = await SharedPreferences.getInstance();
    _region = sp.getString(_kRegion) ?? _region;
    _lang = sp.getString(_kLang) ?? _lang;

    final raw = sp.getString(_kCats);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = (jsonDecode(raw) as List).map((e) => e.toString()).toList();
        if (list.isNotEmpty) {
          _cats
            ..clear()
            ..addAll(list);
        }
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Future<void> _savePrefs() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kRegion, _region);
    await sp.setString(_kLang, _lang);
    await sp.setString(_kCats, jsonEncode(_cats.toList()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Filters updated')),
    );
    widget.onFiltersChanged();
  }

  Widget _sectionTitle(String text) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: cs.onSurface.withOpacity(0.72),
        ),
      ),
    );
  }

  Widget _emoji(String e, {double size = 16}) => Text(
        e,
        style: TextStyle(
          fontSize: size,
          height: 1,
          fontFamily: null,
          fontFamilyFallback: const [
            'Apple Color Emoji',
            'Segoe UI Emoji',
            'Noto Color Emoji',
            'EmojiOne Color',
          ],
        ),
      );

  String get _shareLink {
    if (kIsWeb) {
      final origin = Uri.base.origin;
      final path = Uri.base.path; // preserves / if deployed in subpath
      return '$origin$path';
    }
    return 'https://cinepulse.netlify.app';
    // Replace with your official website/store link when ready.
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Drawer(
      child: SafeArea(
        child: FutureBuilder<void>(
          future: _loader,
          builder: (context, _) {
            return ListView(
              padding: EdgeInsets.zero,
              children: [
                const _BrandDrawerHeader(),

                // ===== Content & filters =====
                _sectionTitle('Content & filters'),

                // Region
                ListTile(
                  leading: _emoji('🌐'),
                  title: const Text('Region'),
                  subtitle: Text(_region == 'india' ? 'India' : 'Global',
                      style: TextStyle(color: cs.onSurfaceVariant)),
                  trailing: DropdownButton<String>(
                    value: _region,
                    onChanged: (v) => setState(() => _region = v ?? _region),
                    items: const [
                      DropdownMenuItem(value: 'india', child: Text('India')),
                      DropdownMenuItem(value: 'global', child: Text('Global')),
                    ],
                  ),
                ),

                // Language preference
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _emoji('🗣️'),
                          const SizedBox(width: 16),
                          const Text('Language preference'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('English'),
                            selected: _lang == 'english',
                            onSelected: (_) => setState(() => _lang = 'english'),
                          ),
                          ChoiceChip(
                            label: const Text('Hindi'),
                            selected: _lang == 'hindi',
                            onSelected: (_) => setState(() => _lang = 'hindi'),
                          ),
                          ChoiceChip(
                            label: const Text('Mixed'),
                            selected: _lang == 'mixed',
                            onSelected: (_) => setState(() => _lang = 'mixed'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Categories multi-select
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _emoji('🗂️'),
                          const SizedBox(width: 16),
                          const Text('Categories'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _catChip('all', 'All'),
                          _catChip('trailers', 'Trailers'),
                          _catChip('ott', 'OTT'),
                          _catChip('intheatres', 'In Theatres'),
                          _catChip('comingsoon', 'Coming Soon'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () {
                            setState(() {
                              _cats
                                ..clear()
                                ..addAll({'all', 'trailers', 'ott', 'intheatres', 'comingsoon'});
                            });
                          },
                          icon: const Icon(Icons.select_all_rounded),
                          label: const Text('Select all'),
                        ),
                      ),
                    ],
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _savePrefs,
                      icon: const Icon(Icons.done_all_rounded),
                      label: const Text('Apply filters'),
                    ),
                  ),
                ),

                const Divider(height: 24),

                // ===== Appearance =====
                _sectionTitle('Appearance'),
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Theme'),
                  subtitle: const Text('System / Light / Dark'),
                  onTap: widget.onThemeTap,
                ),

                const Divider(height: 24),

                // ===== Share & support =====
                _sectionTitle('Share & support'),
                ListTile(
                  leading: _emoji('📣'),
                  title: const Text('Share CinePulse'),
                  onTap: () async {
                    final link = _shareLink;
                    if (!kIsWeb) {
                      await Share.share(link);
                    } else {
                      await Clipboard.setData(ClipboardData(text: link));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Link copied to clipboard')),
                        );
                      }
                    }
                  },
                ),
                ListTile(
                  leading: _emoji('🛠️'),
                  title: const Text('Report an issue'),
                  onTap: () async {
                    final uri = Uri.parse('mailto:feedback@cinepulse.app?subject=CinePulse%20Feedback');
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  },
                ),

                const Divider(height: 24),

                // ===== About & legal =====
                _sectionTitle('About & legal'),
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('About CinePulse'),
                  subtitle: const Text('Version 0.1.0'),
                  onTap: widget.onClose,
                ),
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('Privacy Policy'),
                  onTap: () async {
                    final uri = Uri.parse('https://example.com/privacy'); // TODO: replace
                    await launchUrl(uri, mode: LaunchMode.platformDefault);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.gavel_outlined),
                  title: const Text('Terms of Use'),
                  onTap: () async {
                    final uri = Uri.parse('https://example.com/terms'); // TODO: replace
                    await launchUrl(uri, mode: LaunchMode.platformDefault);
                  },
                ),
                const SizedBox(height: 18),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _catChip(String key, String label) {
    return FilterChip(
      label: Text(label),
      selected: _cats.contains(key),
      onSelected: (v) => setState(() {
        if (v) {
          _cats.add(key);
        } else {
          _cats.remove(key);
        }
      }),
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
