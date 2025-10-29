// lib/features/saved/saved_screen.dart
//
// SAVED TAB (restyled to match HomeScreen)
// ---------------------------------------
// • Header bar now matches HomeScreen header style (CinePulse + pill icons).
// • The row right under the header now matches HomeScreen's _FiltersRow style:
//   - dark strip with red-accent pills
//   - left: search box for saved items
//   - right: sort pill ("Recent"/"Title"), export, clear-all
// • The grid uses the SAME sizing logic as Home feed (_FeedListState._gridDelegateFor)
//   so StoryCard tiles are identical size everywhere in the app.
//
// Notes:
// - We listen to SavedStore.instance so the screen live-updates when bookmarks
//   change.
// - We debounce search (250ms).
// - "Export" copies/shares the links.
// - "Clear all" wipes SavedStore after confirm.
//

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/services.dart';

import '../../core/cache.dart'; // SavedStore, SavedSort, FeedCache
import '../../core/models.dart';
import '../story/story_card.dart';

class SavedScreen extends StatefulWidget {
  const SavedScreen({super.key});

  @override
  State<SavedScreen> createState() => _SavedScreenState();
}

class _SavedScreenState extends State<SavedScreen> {
  // sort mode for saved list (SavedSort comes from core/cache.dart)
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

  /* ───────────────────────── Helpers ───────────────────────── */

  // label for the sort pill
  String _sortLabel(SavedSort s) {
    return s == SavedSort.recent ? 'Recent' : 'Title';
  }

  // same grid sizing logic as HomeScreen feed (_FeedListState._gridDelegateFor)
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

  /* ───────────────────────── UI build ───────────────────────── */

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor =
        isDark ? const Color(0xFF0b0f17) : theme.colorScheme.surface;

    // breakpoint for wide layouts, same as HomeScreen
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= 768;

    return AnimatedBuilder(
      animation: SavedStore.instance,
      builder: (context, _) {
        if (!SavedStore.instance.isReady) {
          return const Center(child: CircularProgressIndicator());
        }

        // Pull saved stories from cache in the requested sort order.
        final ids = SavedStore.instance.orderedIds(_sort);
        final stories =
            ids.map(FeedCache.get).whereType<Story>().toList(growable: false);

        // Filter by local search.
        final q = _query.text.trim().toLowerCase();
        final filtered = q.isEmpty
            ? stories
            : stories.where((s) {
                final title = s.title.toLowerCase();
                final summ = (s.summary ?? '').toLowerCase();
                return title.contains(q) || summ.contains(q);
              }).toList();

        // "3 items", "1 item", etc. (this uses *total* saved count, like before)
        final total = stories.length;
        final countText = switch (total) {
          0 => 'No items',
          1 => '1 item',
          _ => '$total items',
        };

        return Scaffold(
          backgroundColor: bgColor,

          /* ───────────────── Header bar (matches HomeScreen style) ──────────── */
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

                      // On wide / desktop, surface quick nav icons.
                      if (isWide) ...[
                        _HeaderIconButton(
                          tooltip: 'Home',
                          icon: Icons.home_rounded,
                          onTap: null, // nav handled by RootShell
                        ),
                        const SizedBox(width: 8),
                        _HeaderIconButton(
                          tooltip: 'Alerts',
                          icon: Icons.notifications_rounded,
                          onTap: null, // nav handled by RootShell
                        ),
                        const SizedBox(width: 8),
                      ],

                      _HeaderIconButton(
                        tooltip: 'Menu',
                        icon: Icons.menu_rounded,
                        onTap: null, // drawer opened by RootShell
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
              // Row under header: styled like HomeScreen._FiltersRow
              _SavedToolbarRow(
                queryController: _query,
                currentSort: _sort,
                onSortPicked: (v) {
                  setState(() => _sort = v);
                },
                onExportTap: () => _export(context),
                onClearAllTap: () => _clearAll(context),
              ),

              // count line (left aligned)
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

              // main grid of saved cards
              Expanded(
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    final w = constraints.maxWidth;
                    final textScale = MediaQuery.textScaleFactorOf(ctx);
                    final gridDelegate = _gridDelegateFor(w, textScale);

                    const horizontalPad = 12.0;
                    const topPad = 8.0;
                    final bottomSafe =
                        MediaQuery.viewPaddingOf(ctx).bottom; // for iOS notch
                    final bottomPad = 28.0 + bottomSafe;

                    if (filtered.isEmpty) {
                      // empty state centered
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

/* ───────────────────────── Toolbar row under header ─────────────────────────
 *
 * Visually matches HomeScreen._FiltersRow:
 * - same background color band
 * - same bottom border line
 * - red-accent pill controls
 * But instead of chips we show:
 *   [ Search box .................. ]  [Sort pill] [Export] [Clear]
 */
class _SavedToolbarRow extends StatelessWidget {
  const _SavedToolbarRow({
    required this.queryController,
    required this.currentSort,
    required this.onSortPicked,
    required this.onExportTap,
    required this.onClearAllTap,
  });

  final TextEditingController queryController;
  final SavedSort currentSort;
  final ValueChanged<SavedSort> onSortPicked;
  final VoidCallback onExportTap;
  final VoidCallback onClearAllTap;

  static const _accent = Color(0xFFdc2626);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // pill for sort ("Recent"/"Title") with popup menu, styled like Home sort pill
    Widget sortPill() {
      IconData icon =
          (currentSort == SavedSort.recent) ? Icons.history : Icons.sort_by_alpha;
      final label = currentSort == SavedSort.recent ? 'Recent' : 'Title';

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
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: null, // tap handled by PopupMenuButton
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
                  icon,
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
        ),
      );
    }

    // export button and clear-all button use same visual style
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
          // Search field expands
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

          // trailing pills / buttons
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

/* ───────────────────────── Shared UI bits ─────────────────────────
 *
 * These mirror the private widgets in HomeScreen so SavedScreen header
 * looks/feels identical: red CinePulse logo block and square icon pills.
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
