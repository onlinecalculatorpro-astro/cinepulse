// lib/features/saved/saved_screen.dart
//
// SAVED TAB
// ----------------------------------------------------------------------
// Header rules (matches global nav spec):
//
// WIDE (≥768px):
//   [Home] [Search] [Alerts] [Discover] [Refresh] [Menu]
//   - DO NOT show "Saved" CTA here because we're already on Saved.
//
// COMPACT (<768px):
//   [Search] [Refresh] [Menu]
//   - We skip Home / Alerts / Discover in the compact header because
//     mobile bottom nav already has Home / Discover / Saved / Alerts.
//
// Search button behavior:
//   - Tapping "Search" in the header toggles a dedicated Row 3 search bar
//     *inside this Saved tab* (not navigating to Home).
//   - Closing that bar clears the query.
//
// Layout stack for Saved tab body:
//
//   Row 1 (header): CinePulse brand + icon CTAs (above rules)
//   Row 2 (SavedToolbarRow): category chips on left and actions on right
//       Chips: [ All ] [ Entertainment ] [ Sports ]
//       Right side: [ Recent ▼ ] [ Export ] [ Clear ]
//         - Recent ▼ is sort popup
//         - Export copies/shares all saved links
//         - Clear wipes all saved items on this device
//   Row 2.5: "3 items" count line (total saved items, not filtered count)
//   Row 3 (conditional): the inline search bar shown when header Search is active
//   Body: grid of StoryCard for filtered saved stories
//
// Notes:
// - Category chips don't actually filter yet (visual only).
// - "Refresh" here just rebuilds local state (no network).
// - Local search filters only within saved items, not the main feed.
// ----------------------------------------------------------------------

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/services.dart';

import '../../core/cache.dart'; // SavedStore, SavedSort, FeedCache
import '../../core/models.dart';
import '../../widgets/search_bar.dart'; // shared SearchBarInput
import '../../theme/theme_colors.dart'; // theme-aware text colors
import '../story/story_card.dart';

class SavedScreen extends StatefulWidget {
  const SavedScreen({
    super.key,
    this.onOpenHome,
    this.onOpenDiscover,
    this.onOpenAlerts,
    this.onOpenMenu,
  });

  final VoidCallback? onOpenHome;
  final VoidCallback? onOpenDiscover;
  final VoidCallback? onOpenAlerts;
  final VoidCallback? onOpenMenu;

  @override
  State<SavedScreen> createState() => _SavedScreenState();
}

class _SavedScreenState extends State<SavedScreen> {
  // The sort mode used in Saved (SavedSort is defined in core/cache.dart).
  SavedSort _sort = SavedSort.recent;

  // Which category chip is highlighted (0=All,1=Entertainment,2=Sports).
  int _activeCatIndex = 0;

  // Controls the inline search row (Row 3).
  bool _showSearchRow = false;
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

  void _toggleSearchRow() {
    setState(() {
      _showSearchRow = !_showSearchRow;
      if (!_showSearchRow) {
        _query.clear();
      }
    });
  }

  void _setCategory(int i) {
    setState(() {
      _activeCatIndex = i;
    });
    // (future: implement category filtering)
  }

  void _refreshSaved() {
    // Saved is local, so "refresh" is just a rebuild.
    setState(() {});
  }

  /* ───────────────────────── Export / Clear all ───────────────────────── */

  Future<void> _export(BuildContext context) async {
    final text = SavedStore.instance.exportLinks();
    try {
      if (!kIsWeb) {
        await Share.share(text);
      } else {
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
      // fallback: copy
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
        content:
            const Text('This will remove all bookmarks on this device.'),
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

  /* ───────────────────────── Grid sizing helper ─────────────────────────
   * Matches HomeScreen _FeedListState._gridDelegateFor so StoryCard tiles
   * line up visually across tabs.
   */
  SliverGridDelegate _gridDelegateFor(double width, double textScale) {
    int estCols;
    if (width < 520) {
      estCols = 1;
    } else if (width < 900) {
      estCols = 2;
    } else if (width < 1400) {
      estCols = 3;
    } else {
      estCols = 4;
    }

    double maxTileW = width / estCols;
    maxTileW = maxTileW.clamp(320.0, 480.0);

    double baseRatio;
    if (estCols == 1) {
      baseRatio = 0.88;
    } else if (estCols == 2) {
      baseRatio = 0.95;
    } else {
      baseRatio = 1.00;
    }

    final scaleForHeight = textScale.clamp(1.0, 1.4);
    final effectiveRatio = baseRatio / scaleForHeight;

    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxTileW,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: effectiveRatio,
    );
  }

  /* ───────────────────────── UI BUILD ───────────────────────── */

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor =
        isDark ? const Color(0xFF0b0f17) : theme.colorScheme.surface;

    // same breakpoint as HomeScreen to decide which header CTAs to show
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= 768;

    return AnimatedBuilder(
      animation: SavedStore.instance,
      builder: (context, _) {
        if (!SavedStore.instance.isReady) {
          return const Center(child: CircularProgressIndicator());
        }

        // Pull saved stories from cache in selected sort order.
        final ids = SavedStore.instance.orderedIds(_sort);
        final stories =
            ids.map(FeedCache.get).whereType<Story>().toList(growable: false);

        // Local search filter.
        final q = _query.text.trim().toLowerCase();
        final filtered = q.isEmpty
            ? stories
            : stories.where((s) {
                final title = s.title.toLowerCase();
                final summ = (s.summary ?? '').toLowerCase();
                return title.contains(q) || summ.contains(q);
              }).toList();

        // "3 items", "1 item", etc., based on TOTAL saved (not filtered).
        final total = stories.length;
        final countText = switch (total) {
          0 => 'No items',
          1 => '1 item',
          _ => '$total items',
        };

        return Scaffold(
          backgroundColor: bgColor,

          /* ───────── Row 1: Frosted CinePulse header ───────── */
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(64),
            child: ClipRRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  height: 64,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: isDark
                          ? [
                              const Color(0xFF1e2537).withOpacity(0.9),
                              const Color(0xFF0b0f17).withOpacity(0.95),
                            ]
                          : [
                              theme.colorScheme.surface.withOpacity(0.95),
                              theme.colorScheme.surface.withOpacity(0.9),
                            ],
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

                      // WIDE (≥768px):
                      // [Home] [Search] [Alerts] [Discover] [Refresh] [Menu]
                      // (No "Saved" because we're already here.)
                      if (isWide) ...[
                        _HeaderIconButton(
                          tooltip: 'Home',
                          icon: Icons.home_rounded,
                          onTap: widget.onOpenHome,
                        ),
                        const SizedBox(width: 8),

                        _HeaderIconButton(
                          tooltip: 'Search',
                          icon: Icons.search_rounded,
                          onTap: _toggleSearchRow,
                        ),
                        const SizedBox(width: 8),

                        _HeaderIconButton(
                          tooltip: 'Alerts',
                          icon: Icons.notifications_rounded,
                          onTap: widget.onOpenAlerts,
                        ),
                        const SizedBox(width: 8),

                        _HeaderIconButton(
                          tooltip: 'Discover',
                          icon: kIsWeb
                              ? Icons.explore_outlined
                              : Icons.manage_search_rounded,
                          onTap: widget.onOpenDiscover,
                        ),
                        const SizedBox(width: 8),

                        _HeaderIconButton(
                          tooltip: 'Refresh',
                          icon: Icons.refresh_rounded,
                          onTap: _refreshSaved,
                        ),
                        const SizedBox(width: 8),

                        _HeaderIconButton(
                          tooltip: 'Menu',
                          icon: Icons.menu_rounded,
                          onTap: widget.onOpenMenu,
                        ),
                      ],

                      // COMPACT (<768px):
                      // [Search] [Refresh] [Menu]
                      if (!isWide) ...[
                        _HeaderIconButton(
                          tooltip: 'Search',
                          icon: Icons.search_rounded,
                          onTap: _toggleSearchRow,
                        ),
                        const SizedBox(width: 8),

                        _HeaderIconButton(
                          tooltip: 'Refresh',
                          icon: Icons.refresh_rounded,
                          onTap: _refreshSaved,
                        ),
                        const SizedBox(width: 8),

                        _HeaderIconButton(
                          tooltip: 'Menu',
                          icon: Icons.menu_rounded,
                          onTap: widget.onOpenMenu,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),

          /* ───────── Body ───────── */
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Row 2: category chips + sort/export/clear
              _SavedToolbarRow(
                activeIndex: _activeCatIndex,
                onCategoryTap: _setCategory,
                currentSort: _sort,
                onSortPicked: (v) => setState(() => _sort = v),
                onExportTap: () => _export(context),
                onClearAllTap: () => _clearAll(context),
              ),

              // Row 2.5: "3 items"
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  countText,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),

              // Row 3: inline search bar (if toggled)
              if (_showSearchRow)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: SearchBarInput(
                    controller: _query,
                    onExitSearch: () {
                      setState(() {
                        _query.clear();
                        _showSearchRow = false;
                      });
                      FocusScope.of(context).unfocus();
                    },
                  ),
                ),

              // Grid / empty state
              Expanded(
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    final w = constraints.maxWidth;
                    final textScale = MediaQuery.textScaleFactorOf(ctx);
                    final gridDelegate = _gridDelegateFor(w, textScale);

                    const horizontalPad = 12.0;
                    const topPad = 8.0;
                    final bottomSafe =
                        MediaQuery.viewPaddingOf(ctx).bottom;
                    final bottomPad = 28.0 + bottomSafe;

                    if (filtered.isEmpty) {
                      // empty / no matches
                      return ListView(
                        padding: EdgeInsets.fromLTRB(
                          horizontalPad,
                          24,
                          horizontalPad,
                          bottomPad,
                        ),
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          _EmptySaved(),
                        ],
                      );
                    }

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

/* ───────────────────────── Toolbar row under header (Row 2) ─────────────────
 *
 * Left side: pill chips [ All ] [ Entertainment ] [ Sports ]
 * Right side: [ Recent ▼ ] [ Export ] [ Clear ]
 *
 * "Recent ▼" is a popup sort menu (recent vs title).
 */
class _SavedToolbarRow extends StatelessWidget {
  const _SavedToolbarRow({
    required this.activeIndex,
    required this.onCategoryTap,
    required this.currentSort,
    required this.onSortPicked,
    required this.onExportTap,
    required this.onClearAllTap,
  });

  final int activeIndex;
  final ValueChanged<int> onCategoryTap;

  final SavedSort currentSort;
  final ValueChanged<SavedSort> onSortPicked;

  final VoidCallback onExportTap;
  final VoidCallback onClearAllTap;

  static const _accent = Color(0xFFdc2626);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    Widget inactiveChip(String label, VoidCallback onTap) {
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: _accent.withOpacity(0.4),
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              height: 1.2,
              color: _accent,
            ),
          ),
        ),
      );
    }

    // Active chip (red fill + glow)
    Widget activeChip(String label, int index) {
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => onCategoryTap(index),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _accent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _accent, width: 1),
            boxShadow: [
              BoxShadow(
                color: _accent.withOpacity(0.4),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: const Text(
            'All', // label overridden below when actually built
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.2,
              color: Colors.white,
            ),
          ),
        ),
      );
    }

    Widget chip(int index, String label) {
      final sel = (activeIndex == index);
      if (!sel) {
        return inactiveChip(label, () => onCategoryTap(index));
      }
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => onCategoryTap(index),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _accent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _accent, width: 1),
            boxShadow: [
              BoxShadow(
                color: _accent.withOpacity(0.4),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.2,
              color: Colors.white,
            ),
          ),
        ),
      );
    }

    // "Recent ▼" / "Title ▼" sort pill with popup
    Widget sortPill() {
      final isRecent = (currentSort == SavedSort.recent);
      final iconData = isRecent ? Icons.history : Icons.sort_by_alpha;
      final label = isRecent ? 'Recent' : 'Title';

      return PopupMenuButton<SavedSort>(
        tooltip: 'Sort',
        onSelected: onSortPicked,
        itemBuilder: (_) => [
          PopupMenuItem(
            value: SavedSort.recent,
            child: Row(
              children: const [
                Icon(Icons.history, size: 18),
                SizedBox(width: 8),
                Text('Recently saved'),
              ],
            ),
          ),
          PopupMenuItem(
            value: SavedSort.title,
            child: Row(
              children: const [
                Icon(Icons.sort_by_alpha, size: 18),
                SizedBox(width: 8),
                Text('Title (A–Z)'),
              ],
            ),
          ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              width: 1,
              color: _accent.withOpacity(0.4),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                iconData,
                size: 16,
                color: _accent,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.2,
                  color: _accent,
                ),
              ),
              const SizedBox(width: 2),
              const Icon(
                Icons.arrow_drop_down_rounded,
                size: 18,
                color: _accent,
              ),
            ],
          ),
        ),
      );
    }

    // Square icon outline buttons on the right
    Widget actionSquare({
      required IconData icon,
      required String tooltip,
      required VoidCallback onTap,
    }) {
      return _HeaderIconButton(
        icon: icon,
        tooltip: tooltip,
        onTap: onTap,
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0b0f17) : theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            width: 1,
            color: isDark
                ? Colors.white.withOpacity(0.06)
                : Colors.black.withOpacity(0.06),
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // left: category chips (horizontal scroll on overflow)
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  chip(0, 'All'),
                  const SizedBox(width: 8),
                  chip(1, 'Entertainment'),
                  const SizedBox(width: 8),
                  chip(2, 'Sports'),
                ],
              ),
            ),
          ),

          const SizedBox(width: 12),

          // right: sort / export / clear
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              sortPill(),
              actionSquare(
                icon: Icons.ios_share,
                tooltip: 'Export saved',
                onTap: onExportTap,
              ),
              actionSquare(
                icon: Icons.delete_outline,
                tooltip: 'Clear all',
                onTap: onClearAllTap,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/* ───────────────────────── Empty state ───────────────────────── */

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

/* ───────────────────────── Shared header UI bits ───────────────────────── */

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
    final borderColor = const Color(0xFFdc2626).withOpacity(0.3);
    final Color bg = isDark
        ? const Color(0xFF0f172a).withOpacity(0.7)
        : Colors.black.withOpacity(0.06);
    final Color fg = isDark ? Colors.white : Colors.black87;

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
            color: fg,
          ),
        ),
      ),
    );
  }
}

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
        Text(
          'CinePulse',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: primaryTextColor(context), // theme-aware brand text color
          ),
        ),
      ],
    );
  }
}
