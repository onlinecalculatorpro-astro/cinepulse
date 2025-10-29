// lib/features/saved/saved_screen.dart
//
// SAVED TAB (updated to match new HomeScreen behavior)
//
// What changed in this version:
//
// 1. HEADER
//    - Uses the same frosted header style as Home.
//    - Icon order on desktop/wide now mirrors Home:
//        [Search] [Saved] [Alerts] [Discover] [Refresh] ... [Menu]
//      • Search taps `onOpenHome` (takes user back to Home where search lives).
//      • Saved button is shown for visual parity (does nothing here).
//      • Alerts -> onOpenAlerts
//      • Discover -> onOpenDiscover
//      • Refresh -> locally refreshes saved list (no network)
//      • Menu -> onOpenMenu
//
//    Note: we did NOT change the constructor, so we ONLY use the callbacks
//    that already exist: onOpenHome / onOpenDiscover / onOpenAlerts / onOpenMenu.
//    We do not add new required callbacks (so RootShell keeps compiling).
//
// 2. TOOLBAR ROW (row under header)
//    - The old inline search bar is REMOVED.
//    - Left side now shows the same red-accent pill chips used on Home:
//        All / Entertainment / Sports
//      We track which one is active so the pill styling matches Home.
//      (Right now this is just visual; it does not filter the list yet.)
//    - Right side shows:
//        • Sort pill (Recent / Title)
//        • Export button
//        • Clear All button
//      styled with the same red-outline accent vibe.
//
// 3. GRID
//    - Still uses the exact same sizing math as Home feed (_FeedListState)
//      so StoryCard tiles look identical.
//    - We show saved items in whatever sort (Recent / Title) the user picked.
//    - We removed text search filtering since we removed the search field.
//
// 4. OTHER
//    - Export copies links (web) or opens share sheet (mobile).
//    - Clear All wipes local bookmarks.
//    - "X items" line still shows below the toolbar.
//    - Live updates via SavedStore.instance (AnimatedBuilder).
//

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/cache.dart'; // SavedStore, SavedSort, FeedCache
import '../../core/models.dart';
import '../story/story_card.dart';

class SavedScreen extends StatefulWidget {
  const SavedScreen({
    super.key,
    this.onOpenHome,
    this.onOpenDiscover,
    this.onOpenAlerts,
    this.onOpenMenu,
  });

  /// Go to the Home tab (RootShell implements this).
  /// We also reuse this for the "Search" icon, since real search UX
  /// lives in Home.
  final VoidCallback? onOpenHome;

  /// Go to Discover tab.
  final VoidCallback? onOpenDiscover;

  /// Go to Alerts tab.
  final VoidCallback? onOpenAlerts;

  /// Open the drawer / menu.
  final VoidCallback? onOpenMenu;

  @override
  State<SavedScreen> createState() => _SavedScreenState();
}

class _SavedScreenState extends State<SavedScreen> {
  // current sort mode for saved list (SavedSort is defined in core/cache.dart)
  SavedSort _sort = SavedSort.recent;

  // which category chip is "active"
  // 0 = All, 1 = Entertainment, 2 = Sports
  int _activeCatIndex = 0;

  /* ───────────────────────── Export / Clear all / Refresh ───────────────── */

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
      // fallback: just copy
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

  void _refreshSaved() {
    // We just rebuild from SavedStore. There's no network call here.
    if (mounted) setState(() {});
  }

  void _pickCategory(int i) {
    setState(() {
      _activeCatIndex = i;
    });
  }

  /* ───────────────────────── Grid sizing helper ─────────────────────────
   *
   * EXACT SAME math as HomeScreen _FeedListState._gridDelegateFor
   * so StoryCard tiles are visually identical across tabs.
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

    // same breakpoint HomeScreen uses to show the desktop header icons
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= 768;

    return AnimatedBuilder(
      animation: SavedStore.instance,
      builder: (context, _) {
        if (!SavedStore.instance.isReady) {
          return const Center(child: CircularProgressIndicator());
        }

        // obtain saved stories in the chosen sort order
        final ids = SavedStore.instance.orderedIds(_sort);
        final stories =
            ids.map(FeedCache.get).whereType<Story>().toList(growable: false);

        // NOTE: we removed text search from Saved, so no filtering here.
        final displayList = stories;

        // count text: "No items", "1 item", "3 items"
        final total = displayList.length;
        final countText = switch (total) {
          0 => 'No items',
          1 => '1 item',
          _ => '$total items',
        };

        return Scaffold(
          backgroundColor: bgColor,

          /* ───────────────── Header bar (mirrors HomeScreen header) ───────── */
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

                      // Desktop / wide icons:
                      // match HomeScreen order:
                      // [Search] [Saved] [Alerts] [Discover] [Refresh]
                      if (isWide) ...[
                        _HeaderIconButton(
                          tooltip: 'Search',
                          icon: Icons.search_rounded,
                          // We'll just bounce you back to Home for now,
                          // since full search UX lives there.
                          onTap: widget.onOpenHome,
                        ),
                        const SizedBox(width: 8),
                        _HeaderIconButton(
                          tooltip: 'Saved',
                          icon: Icons.bookmark_rounded,
                          // Already on Saved. No-op is fine.
                          onTap: null,
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
                      ],

                      // Menu (drawer) always last, visible even on mobile
                      _HeaderIconButton(
                        tooltip: 'Menu',
                        icon: Icons.menu_rounded,
                        onTap: widget.onOpenMenu,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          /* ───────────────── Body ───────────────── */
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Pills / sort / export / clear row
              _SavedToolbarRow(
                isDark: isDark,
                activeCatIndex: _activeCatIndex,
                onPickCategory: _pickCategory,
                currentSort: _sort,
                onSortPicked: (v) {
                  setState(() => _sort = v);
                },
                onExportTap: () => _export(context),
                onClearAllTap: () => _clearAll(context),
              ),

              // items count
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
              const SizedBox(height: 4),

              // main grid of cards
              Expanded(
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    final w = constraints.maxWidth;
                    final textScale = MediaQuery.textScaleFactorOf(ctx);
                    final gridDelegate = _gridDelegateFor(w, textScale);

                    const horizontalPad = 12.0;
                    const topPad = 8.0;
                    final bottomSafe =
                        MediaQuery.viewPaddingOf(ctx).bottom; // iOS safe area
                    final bottomPad = 28.0 + bottomSafe;

                    if (displayList.isEmpty) {
                      // show empty state, still scrollable so pull-to-refresh
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
                      itemCount: displayList.length,
                      itemBuilder: (_, i) {
                        final story = displayList[i];
                        return StoryCard(
                          story: story,
                          allStories: displayList,
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

/* ───────────────────────── Toolbar row under header ──────────────────────
 *
 * Mirrors HomeScreen._FiltersRow style:
 * - dark strip with bottom border
 * - left: category chips (All / Entertainment / Sports) in CinePulse red-pill style
 * - right: sort pill, export, clear
 *
 * NOTE: The category selection is currently cosmetic / future-proof.
 *       We just store activeCatIndex so we can style the chip.
 */
class _SavedToolbarRow extends StatelessWidget {
  const _SavedToolbarRow({
    required this.isDark,
    required this.activeCatIndex,
    required this.onPickCategory,
    required this.currentSort,
    required this.onSortPicked,
    required this.onExportTap,
    required this.onClearAllTap,
  });

  final bool isDark;
  final int activeCatIndex;
  final ValueChanged<int> onPickCategory;

  final SavedSort currentSort;
  final ValueChanged<SavedSort> onSortPicked;

  final VoidCallback onExportTap;
  final VoidCallback onClearAllTap;

  static const _accent = Color(0xFFdc2626);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget catChip({
      required int index,
      required String label,
    }) {
      final sel = (activeCatIndex == index);
      if (sel) {
        return InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => onPickCategory(index),
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

      // inactive
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => onPickCategory(index),
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

    // pill-style sort dropdown ("Recent"/"Title") with red outline
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

    // square pill buttons for Export / Clear,
    // visually same style as header icon pills.
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
          // scrollable chip row (All / Entertainment / Sports)
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  catChip(index: 0, label: 'All'),
                  const SizedBox(width: 8),
                  catChip(index: 1, label: 'Entertainment'),
                  const SizedBox(width: 8),
                  catChip(index: 2, label: 'Sports'),
                ],
              ),
            ),
          ),

          const SizedBox(width: 12),

          // trailing actions (sort / export / clear)
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

/* ───────────────────────── Shared header UI bits ─────────────────────────
 *
 * These mirror the private widgets in HomeScreen so the SavedScreen header
 * looks/feels identical: red CinePulse logo block, and square icon pills.
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
        const Text(
          'CinePulse',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}
