// lib/features/saved/saved_screen.dart
//
// Saved tab
// - Local bookmarks from SavedStore.
// - Search + sort (recent vs title).
// - Export and Clear All actions.
// - Pull to refresh just re-runs the filter/sort to update UI.
// - Cards open into StoryPagerScreen (swipe prev/next).
//
// IMPORTANT LAYOUT CHANGE:
// StoryCard now has internal Expanded widgets, so it MUST live in a
// bounded-height tile (a Grid with a fixed childAspectRatio), not in a
// plain ListView row with intrinsic height.
//
// So we render saved items in a responsive SliverGrid exactly like Home/
// Alerts, and we pass (stories, index) to StoryCard so horizontal paging
// works in the detail view.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/cache.dart';
import '../../core/models.dart';
import '../story/story_card.dart';

class SavedScreen extends StatefulWidget {
  const SavedScreen({super.key});

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

  // Just re-run filters/sort. There's no network fetch for saved items.
  Future<void> _refreshLocal() async {
    setState(() {});
  }

  // Same responsive grid logic we use in home/alerts:
  // We pick a maxCrossAxisExtent based on screen width and compute a
  // childAspectRatio bucket so each StoryCard tile has a stable "card-ish"
  // height (required because StoryCard uses Expanded internally).
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // Safe padding to match Home / Alerts
    final horizontalPad = 12.0;
    final topPad = 8.0;
    final bottomSafe = MediaQuery.viewPaddingOf(context).bottom;
    final bottomPad = 28.0 + bottomSafe;

    return AnimatedBuilder(
      animation: SavedStore.instance,
      builder: (context, _) {
        if (!SavedStore.instance.isReady) {
          return const Center(child: CircularProgressIndicator());
        }

        // Pull stories from cache in the requested sort order.
        final ids = SavedStore.instance.orderedIds(_sort);
        final stories = ids.map(FeedCache.get).whereType<Story>().toList();

        // Filter by search.
        final q = _query.text.trim().toLowerCase();
        final filtered = q.isEmpty
            ? stories
            : stories.where((s) {
                final title = s.title.toLowerCase();
                final summ = (s.summary ?? '').toLowerCase();
                return title.contains(q) || summ.contains(q);
              }).toList();

        // Count text.
        final total = stories.length;
        final countText = switch (total) {
          0 => 'No items',
          1 => '1 item',
          _ => '$total items',
        };

        return RefreshIndicator.adaptive(
          onRefresh: _refreshLocal,
          color: const Color(0xFFdc2626),
          child: CustomScrollView(
            slivers: [
              // Top bar – pinned so the user always knows where they are.
              SliverAppBar(
                pinned: true,
                title: Text(
                  'Saved',
                  style: GoogleFonts.inter(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                // no actions here (Export / Clear live in the toolbar row below)
              ),

              // Toolbar row: search, sort, export, clear
              SliverToBoxAdapter(
                child: Padding(
                  padding:
                      const EdgeInsets.fromLTRB(16, 16, 16, 8), // same as before
                  child: Row(
                    children: [
                      // Search field
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

                      // Sort selector popup
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
                        child: FilledButton.tonalIcon(
                          onPressed: null,
                          icon: const Icon(Icons.sort),
                          label: Text(
                            _sort == SavedSort.recent ? 'Recent' : 'Title',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),

                      // Export list of saved links
                      IconButton.filledTonal(
                        tooltip: 'Export saved',
                        icon: const Icon(Icons.ios_share),
                        onPressed: () => _export(context),
                      ),
                      const SizedBox(width: 4),

                      // Clear all bookmarks
                      IconButton(
                        tooltip: 'Clear all',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _clearAll(context),
                      ),
                    ],
                  ),
                ),
              ),

              // Count row
              SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Text(
                      countText,
                      style: Theme.of(context)
                          .textTheme
                          .labelMedium
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 4)),

              // Empty state
              if (filtered.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: const _EmptySaved(),
                )
              else
                // Grid of saved cards
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPad,
                    topPad,
                    horizontalPad,
                    bottomPad,
                  ),
                  sliver: SliverGrid(
                    gridDelegate: _gridDelegateFor(context),
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
