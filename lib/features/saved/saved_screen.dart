// lib/features/saved/saved_screen.dart
//
// Saved tab (desktop + mobile)
//
// What this screen does now:
//  • Uses the same frosted header bar style as HomeScreen
//  • Header has CinePulse brand + nav/action icons
//      - Home (go back to feed)
//      - Alerts
//      - Discover
//      - Refresh (local refresh)
//      - Menu (opens drawer)
//    On phones (<768px) bottom nav will still exist from RootShell, but on
//    desktop this header is how you get back.
//  • Under the header: search + sort + export + clear-all row
//  • "x items" counter
//  • Responsive grid of StoryCard tiles (same visual style as Home)
//
// Data comes from SavedStore.instance (local bookmarks).
//
// NOTE: this screen depends on RootShell to pass the callbacks
// (onOpenHome, onOpenAlerts, etc).

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/cache.dart';
import '../../core/models.dart';
import '../story/story_card.dart';

enum SavedSort { recent, title }

class SavedScreen extends StatefulWidget {
  const SavedScreen({
    super.key,
    this.onOpenHome,
    this.onOpenAlerts,
    this.onOpenDiscover,
    this.onOpenMenu,
  });

  /// Jump back to the main feed (Home tab in RootShell).
  final VoidCallback? onOpenHome;

  /// Open Alerts tab in RootShell.
  final VoidCallback? onOpenAlerts;

  /// Open Discover tab in RootShell.
  final VoidCallback? onOpenDiscover;

  /// Open the right-side drawer from RootShell.
  final VoidCallback? onOpenMenu;

  @override
  State<SavedScreen> createState() => _SavedScreenState();
}

class _SavedScreenState extends State<SavedScreen> {
  SavedSort _sort = SavedSort.recent;

  final _query = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQueryChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.removeListener(_onQueryChanged);
    _query.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() {});
    });
  }

  /// Just forces rebuild so we re-pull latest SavedStore data.
  void _refreshLocal() {
    setState(() {});
  }

  Future<void> _export(BuildContext context) async {
    final text = SavedStore.instance.exportLinks();
    try {
      if (!kIsWeb) {
        // native share sheet (mobile / desktop shell)
        await Share.share(text);
      } else {
        // web fallback: copy to clipboard
        await Clipboard.setData(ClipboardData(text: text));
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            kIsWeb ? 'Copied to clipboard' : 'Share sheet opened',
          ),
        ),
      );
    } catch (_) {
      // super fallback → clipboard
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied to clipboard')),
      );
    }
  }

  Future<void> _clearAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear all saved?'),
        content: const Text('This will remove all bookmarks on this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await SavedStore.instance.clearAll();
      if (mounted) setState(() {});
    }
  }

  // Same responsive math we use everywhere:
  // Pick a maxCrossAxisExtent bucket and map that to a childAspectRatio.
  SliverGridDelegate _gridDelegateFor(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final textScale = MediaQuery.textScaleFactorOf(context);

    double maxTileW;
    if (screenW < 520) {
      maxTileW = screenW; // 1 col on very narrow
    } else if (screenW < 900) {
      maxTileW = screenW / 2; // 2 cols
    } else if (screenW < 1400) {
      maxTileW = screenW / 3; // 3 cols
    } else {
      maxTileW = screenW / 4; // 4 cols on wide
    }
    maxTileW = maxTileW.clamp(320.0, 480.0);

    // childAspectRatio = width / height
    // lower ratio => taller tiles.
    double ratio;
    if (maxTileW <= 340) {
      ratio = 0.56;
    } else if (maxTileW <= 380) {
      ratio = 0.64;
    } else if (maxTileW <= 420) {
      ratio = 0.72;
    } else {
      ratio = 0.80;
    }

    // But if user bumped text scale, give more height
    ratio /= textScale.clamp(1.0, 1.8);

    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxTileW,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: ratio,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor =
        isDark ? const Color(0xFF0b0f17) : theme.colorScheme.surface;

    final isWide = MediaQuery.of(context).size.width >= 768;

    return AnimatedBuilder(
      animation: SavedStore.instance,
      builder: (context, _) {
        // Before SavedStore finishes loading from disk, just show loader.
        if (!SavedStore.instance.isReady) {
          return Scaffold(
            backgroundColor: bgColor,
            body: Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(
                  const Color(0xFFdc2626),
                ),
              ),
            ),
          );
        }

        // 1. pull stories in sort order
        final ids = SavedStore.instance.orderedIds(_sort);
        final stories = ids.map(FeedCache.get).whereType<Story>().toList();

        // 2. apply search
        final q = _query.text.trim().toLowerCase();
        final filtered = q.isEmpty
            ? stories
            : stories.where((s) {
                final title = s.title.toLowerCase();
                final summ = (s.summary ?? '').toLowerCase();
                return title.contains(q) || summ.contains(q);
              }).toList();

        // 3. count label
        final total = stories.length;
        final countText = switch (total) {
          0 => 'No items',
          1 => '1 item',
          _ => '$total items',
        };

        // paddings for grid
        const horizontalPad = 12.0;
        const topPad = 8.0;
        final bottomSafe = MediaQuery.viewPaddingOf(context).bottom;
        final bottomPad = 28.0 + bottomSafe;

        return Scaffold(
          backgroundColor: bgColor,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --------------- Frosted header (like Home) ---------------
              _SavedHeader(
                isWide: isWide,
                onOpenHome: widget.onOpenHome,
                onOpenAlerts: widget.onOpenAlerts,
                onOpenDiscover: widget.onOpenDiscover,
                onOpenMenu: widget.onOpenMenu,
                onRefresh: _refreshLocal,
              ),

              // --------------- Toolbar row (search / sort / export / clear) ---------------
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: _SavedToolbarRow(
                  queryController: _query,
                  sort: _sort,
                  onChangeSort: (v) => setState(() => _sort = v),
                  onExport: () => _export(context),
                  onClearAll: () => _clearAll(context),
                ),
              ),

              // count text ("3 items")
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    countText,
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),

              const SizedBox(height: 4),

              // --------------- Body list / grid ---------------
              Expanded(
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    // empty state
                    if (filtered.isEmpty) {
                      return ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
                        children: const [
                          _EmptySaved(),
                        ],
                      );
                    }

                    // grid of StoryCard, same vibe as Home
                    final gridDelegate = _gridDelegateFor(context);
                    return GridView.builder(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPad,
                        topPad,
                        horizontalPad,
                        bottomPad,
                      ),
                      physics: const AlwaysScrollableScrollPhysics(),
                      cacheExtent: 2000,
                      gridDelegate: gridDelegate,
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final story = filtered[i];
                        return StoryCard(
                          story: story,
                          allStories: filtered,
                          index: i,
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/* ───────────────────────── SAVED HEADER BAR ─────────────────────────
 * Frosted/blurred top bar to match HomeScreen header, with nav buttons.
 * On wide screens:
 *    [CinePulse]            [Home] [Alerts] [Discover] [Refresh] [Menu]
 * On phone we still render it, but bottom nav in RootShell will ALSO exist.
 */
class _SavedHeader extends StatelessWidget {
  const _SavedHeader({
    required this.isWide,
    required this.onOpenHome,
    required this.onOpenAlerts,
    required this.onOpenDiscover,
    required this.onOpenMenu,
    required this.onRefresh,
  });

  final bool isWide;
  final VoidCallback? onOpenHome;
  final VoidCallback? onOpenAlerts;
  final VoidCallback? onOpenDiscover;
  final VoidCallback? onOpenMenu;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final gradientColors = isDark
        ? <Color>[
            const Color(0xFF1e2537).withOpacity(0.9),
            const Color(0xFF0b0f17).withOpacity(0.95),
          ]
        : <Color>[
            theme.colorScheme.surface.withOpacity(0.95),
            theme.colorScheme.surface.withOpacity(0.9),
          ];

    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          height: 64,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: gradientColors,
            ),
            border: const Border(
              bottom: BorderSide(
                color: Color(0x0FFFFFFF),
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              const _ModernBrandLogo(),
              const Spacer(),

              if (isWide) ...[
                _HeaderIconButton(
                  tooltip: 'Home',
                  icon: Icons.home_rounded,
                  onTap: onOpenHome,
                ),
                const SizedBox(width: 8),
                _HeaderIconButton(
                  tooltip: 'Alerts',
                  icon: Icons.notifications_rounded,
                  onTap: onOpenAlerts,
                ),
                const SizedBox(width: 8),
              ],

              _HeaderIconButton(
                tooltip: 'Discover',
                icon: kIsWeb
                    ? Icons.explore_outlined
                    : Icons.manage_search_rounded,
                onTap: onOpenDiscover,
              ),
              const SizedBox(width: 8),
              _HeaderIconButton(
                tooltip: 'Refresh',
                icon: Icons.refresh_rounded,
                onTap: onRefresh,
              ),
              const SizedBox(width: 8),
              _HeaderIconButton(
                tooltip: 'Menu',
                icon: Icons.menu_rounded,
                onTap: onOpenMenu,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ───────────────────────── TOOLBAR ROW UNDER HEADER ─────────────────────────
 * Search field, sort pill, Export, Clear all
 */
class _SavedToolbarRow extends StatelessWidget {
  const _SavedToolbarRow({
    required this.queryController,
    required this.sort,
    required this.onChangeSort,
    required this.onExport,
    required this.onClearAll,
  });

  final TextEditingController queryController;
  final SavedSort sort;
  final ValueChanged<SavedSort> onChangeSort;
  final VoidCallback onExport;
  final VoidCallback onClearAll;

  static const accent = Color(0xFFdc2626);

  @override
  Widget build(BuildContext context) {
    Widget sortSelector() {
      final label = (sort == SavedSort.recent) ? 'Recent' : 'Title';
      final icon =
          (sort == SavedSort.recent) ? Icons.history : Icons.sort_by_alpha;

      // pill look copied from Home's sort pill style
      final pill = Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            width: 1,
            color: accent.withOpacity(0.4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: accent),
            const SizedBox(width: 6),
            Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                height: 1.2,
                color: accent,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(
              Icons.arrow_drop_down_rounded,
              size: 18,
              color: accent,
            ),
          ],
        ),
      );

      return PopupMenuButton<SavedSort>(
        tooltip: 'Sort',
        position: PopupMenuPosition.under,
        onSelected: onChangeSort,
        itemBuilder: (_) => [
          PopupMenuItem(
            value: SavedSort.recent,
            child: Row(
              children: [
                const Icon(Icons.history, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Recently saved',
                  style: GoogleFonts.inter(),
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: SavedSort.title,
            child: Row(
              children: [
                const Icon(Icons.sort_by_alpha, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Title (A–Z)',
                  style: GoogleFonts.inter(),
                ),
              ],
            ),
          ),
        ],
        child: pill,
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Search field
        Expanded(
          child: TextField(
            controller: queryController,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search saved…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: (queryController.text.trim().isEmpty)
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      onPressed: () {
                        queryController.clear();
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
        ),
        const SizedBox(width: 12),

        // Sort (Recent / Title)
        sortSelector(),
        const SizedBox(width: 8),

        // Export list of links
        _HeaderIconButton(
          tooltip: 'Export saved',
          icon: Icons.ios_share,
          onTap: onExport,
        ),
        const SizedBox(width: 8),

        // Clear all
        _HeaderIconButton(
          tooltip: 'Clear all',
          icon: Icons.delete_outline,
          onTap: onClearAll,
        ),
      ],
    );
  }
}

/* ───────────────────────── HEADER ICON BUTTON ─────────────────────────
 * Square 32x32 pill with border + icon, same as HomeScreen header icons.
 * We duplicate it here because _HeaderIconButton in HomeScreen is private
 * to that file.
 */
class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark
        ? const Color(0xFF0f172a).withOpacity(0.7)
        : Colors.black.withOpacity(0.06);
    final borderColor = const Color(0xFFdc2626).withOpacity(0.3);
    final iconColor = isDark ? Colors.white : Colors.black87;

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: borderColor,
              width: 1,
            ),
          ),
          child: Icon(
            icon,
            size: 16,
            color: iconColor,
          ),
        ),
      ),
    );
  }
}

/* ───────────────────────── BRAND LOGO ─────────────────────────
 * Same CinePulse badge we use in Home header.
 */
class _ModernBrandLogo extends StatelessWidget {
  const _ModernBrandLogo();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: const Color(0xFFdc2626),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFdc2626).withOpacity(0.4),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: const Center(
            child: Text(
              '🎬',
              style: TextStyle(
                fontSize: 16,
                height: 1,
                color: Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        const Text(
          'CinePulse',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: Colors.white, // matches Home header
          ),
        ),
      ],
    );
  }
}

/* ───────────────────────── EMPTY STATE ───────────────────────── */
class _EmptySaved extends StatelessWidget {
  const _EmptySaved();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bookmark_add_outlined,
              size: 48,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'No saved items yet',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Tap the bookmark on any card to save it here.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
