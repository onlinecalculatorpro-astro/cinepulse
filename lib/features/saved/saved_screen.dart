// lib/features/saved/saved_screen.dart
//
// Saved tab
// - Local bookmarks from SavedStore.
// - CinePulse-style header (same vibe as HomeScreen).
// - Search + sort (recent vs title) + export + clear
// - Responsive SliverGrid like Home.
// - Cards open into StoryPagerScreen via StoryCard (already handled there).

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/cache.dart'; // SavedStore, SavedSort, FeedCache
import '../../core/models.dart';
import '../story/story_card.dart';

class SavedScreen extends StatefulWidget {
  const SavedScreen({
    super.key,
    this.onOpenHome,
    this.onOpenAlerts,
    this.onOpenDiscover,
    this.onOpenMenu,
  });

  // Header actions passed from RootShell so user can navigate without browser back.
  final VoidCallback? onOpenHome;
  final VoidCallback? onOpenAlerts;
  final VoidCallback? onOpenDiscover;
  final VoidCallback? onOpenMenu;

  @override
  State<SavedScreen> createState() => _SavedScreenState();
}

class _SavedScreenState extends State<SavedScreen> {
  // We use SavedSort from core/cache.dart. DO NOT redeclare another enum.
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

  // Just re-run filters/sort, there's no network fetch for local saved items.
  Future<void> _refreshLocal() async {
    setState(() {});
  }

  // same responsive grid math we used before
  SliverGridDelegate _gridDelegateFor(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final textScale = MediaQuery.textScaleFactorOf(context);

    double maxTileW;
    if (screenW < 520) {
      maxTileW = screenW; // 1 col on narrow phones
    } else if (screenW < 900) {
      maxTileW = screenW / 2; // 2 cols
    } else if (screenW < 1400) {
      maxTileW = screenW / 3; // 3 cols
    } else {
      maxTileW = screenW / 4; // 4 cols on wide layouts
    }
    maxTileW = maxTileW.clamp(320.0, 480.0);

    // childAspectRatio = width / height (lower -> taller).
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

    // Bigger text -> give more height.
    ratio /= textScale.clamp(1.0, 1.8);

    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxTileW,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: ratio,
    );
  }

  String _sortChipLabel(SavedSort s) {
    switch (s) {
      case SavedSort.recent:
        return 'Recent';
      case SavedSort.title:
        return 'Title';
    }
  }

  IconData _sortChipIcon(SavedSort s) {
    switch (s) {
      case SavedSort.recent:
        return Icons.history;
      case SavedSort.title:
        return Icons.sort_by_alpha;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bgColor =
        isDark ? const Color(0xFF0b0f17) : theme.colorScheme.surface;

    // header gradient colors copied from HomeScreen style
    final headerGradientColors = isDark
        ? [
            const Color(0xFF1e2537).withOpacity(0.9),
            const Color(0xFF0b0f17).withOpacity(0.95),
          ]
        : [
            theme.colorScheme.surface.withOpacity(0.95),
            theme.colorScheme.surface.withOpacity(0.9),
          ];

    final borderBottomColor =
        isDark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.06);

    return Scaffold(
      backgroundColor: bgColor,
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
                  colors: headerGradientColors,
                ),
                border: Border(
                  bottom: BorderSide(
                    color: borderBottomColor,
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  const _SavedBrandLogo(),
                  const Spacer(),
                  // Nav icons so user can move around without browser Back.
                  _SavedHeaderIconButton(
                    tooltip: 'Home',
                    icon: Icons.home_rounded,
                    onTap: widget.onOpenHome,
                  ),
                  const SizedBox(width: 8),
                  _SavedHeaderIconButton(
                    tooltip: 'Alerts',
                    icon: Icons.notifications_rounded,
                    onTap: widget.onOpenAlerts,
                  ),
                  const SizedBox(width: 8),
                  _SavedHeaderIconButton(
                    tooltip: 'Discover',
                    icon: kIsWeb
                        ? Icons.explore_outlined
                        : Icons.manage_search_rounded,
                    onTap: widget.onOpenDiscover,
                  ),
                  const SizedBox(width: 8),
                  _SavedHeaderIconButton(
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
      body: AnimatedBuilder(
        animation: SavedStore.instance,
        builder: (context, _) {
          if (!SavedStore.instance.isReady) {
            return const Center(child: CircularProgressIndicator());
          }

          // pull stories from local store in chosen sort order
          final ids = SavedStore.instance.orderedIds(_sort);
          final stories =
              ids.map(FeedCache.get).whereType<Story>().toList(growable: false);

          // apply search filter
          final q = _query.text.trim().toLowerCase();
          final filtered = q.isEmpty
              ? stories
              : stories.where((s) {
                  final title = s.title.toLowerCase();
                  final summ = (s.summary ?? '').toLowerCase();
                  return title.contains(q) || summ.contains(q);
                }).toList();

          // for count label
          final total = stories.length;
          final countText = switch (total) {
            0 => 'No items',
            1 => '1 item',
            _ => '$total items',
          };

          // paddings mimic Home grid
          const horizontalPad = 12.0;
          const topPad = 8.0;
          final bottomSafe = MediaQuery.viewPaddingOf(context).bottom;
          final bottomPad = 28.0 + bottomSafe;

          final gridDelegate = _gridDelegateFor(context);

          return RefreshIndicator.adaptive(
            onRefresh: _refreshLocal,
            color: const Color(0xFFdc2626),
            child: CustomScrollView(
              slivers: [
                // TOOLBAR ROW
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // search field
                        Expanded(
                          child: TextField(
                            controller: _query,
                            textInputAction: TextInputAction.search,
                            decoration: InputDecoration(
                              hintText: 'Search saved…',
                              prefixIcon: const Icon(Icons.search),
                              suffixIcon: (_query.text.trim().isEmpty)
                                  ? null
                                  : IconButton(
                                      tooltip: 'Clear',
                                      onPressed: () {
                                        _query.clear();
                                      },
                                      icon: const Icon(Icons.close_rounded),
                                    ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),

                        // sort pill popup
                        PopupMenuButton<SavedSort>(
                          tooltip: 'Sort',
                          onSelected: (v) => setState(() => _sort = v),
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
                          child: _SavedSortChip(
                            label: _sortChipLabel(_sort),
                            icon: _sortChipIcon(_sort),
                          ),
                        ),
                        const SizedBox(width: 8),

                        // Export (share / copy links)
                        IconButton.filledTonal(
                          tooltip: 'Export saved',
                          icon: const Icon(Icons.ios_share),
                          onPressed: () => _export(context),
                        ),
                        const SizedBox(width: 4),

                        // Clear all
                        IconButton(
                          tooltip: 'Clear all',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _clearAll(context),
                        ),
                      ],
                    ),
                  ),
                ),

                // count row
                SliverToBoxAdapter(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: Text(
                        countText,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),

                const SliverToBoxAdapter(child: SizedBox(height: 4)),

                // empty state
                if (filtered.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: const _EmptySaved(),
                  )
                else
                  // grid of saved cards
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPad,
                      topPad,
                      horizontalPad,
                      bottomPad,
                    ),
                    sliver: SliverGrid(
                      gridDelegate: gridDelegate,
                      delegate: SliverChildBuilderDelegate(
                        (ctx, i) {
                          final story = filtered[i];
                          return StoryCard(
                            story: story,
                            allStories: filtered,
                            index: i,
                          );
                        },
                        childCount: filtered.length,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/* ------------------------- Sort chip pill ------------------------- */

class _SavedSortChip extends StatelessWidget {
  const _SavedSortChip({
    required this.label,
    required this.icon,
  });

  final String label;
  final IconData icon;

  static const _accent = Color(0xFFdc2626);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
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
            Icon(icon, size: 16, color: _accent),
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
}

/* ------------------------- Header helpers ------------------------- */

class _SavedHeaderIconButton extends StatelessWidget {
  const _SavedHeaderIconButton({
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

class _SavedBrandLogo extends StatelessWidget {
  const _SavedBrandLogo();

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

/* ------------------------------ Empty state ------------------------------ */

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
