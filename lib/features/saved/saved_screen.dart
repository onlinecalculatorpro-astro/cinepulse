// lib/features/saved/saved_screen.dart
//
// Saved tab (redesigned to match Home look):
// - Frosted gradient header bar like HomeScreen
// - Toolbar row under the header with search / sort / export / clear
// - Count row
// - Responsive grid just like Home
// - Local-only data from SavedStore
//
// Still supports: search, sort (Recent / Title), export, clear all,
// and pull-to-refresh (which just re-runs local filter/sort).

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/cache.dart';
import '../../core/models.dart';
import '../story/story_card.dart';

// We assume SavedSort is already defined in your cache layer:
// enum SavedSort { recent, title }

class SavedScreen extends StatefulWidget {
  const SavedScreen({super.key});

  @override
  State<SavedScreen> createState() => _SavedScreenState();
}

class _SavedScreenState extends State<SavedScreen> {
  static const _accent = Color(0xFFdc2626);

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

  /* ───────────────────────────────── helpers ───────────────────────────────── */

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

  // "Refresh" here just means: rebuild from local store again.
  Future<void> _refreshLocal() async {
    setState(() {});
  }

  // same responsive card math as Home feed grid
  SliverGridDelegate _gridDelegateFor(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final textScale = MediaQuery.textScaleFactorOf(context);

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

    // Mirrors Home logic: tweak aspect ratio per column count
    double baseRatio;
    if (estCols == 1) {
      baseRatio = 0.88;
    } else if (estCols == 2) {
      baseRatio = 0.95;
    } else {
      baseRatio = 1.00;
    }

    // text zoom gets a little more height
    final scaleForHeight = textScale.clamp(1.0, 1.4);
    final effectiveRatio = baseRatio / scaleForHeight;

    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxTileW,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: effectiveRatio,
    );
  }

  // Little red-accent pill with current sort label, same vibe as Home's sort chip
  Widget _buildSortPill() {
    final isRecent = _sort == SavedSort.recent;
    final icon = isRecent ? Icons.history : Icons.sort_by_alpha;
    final text = isRecent ? 'Recent' : 'Title';

    return Container(
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
            text,
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
    );
  }

  // Small square icon button that matches the header buttons from Home
  Widget _smallIconButton({
    required BuildContext context,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark
        ? const Color(0xFF0f172a).withOpacity(0.7)
        : Colors.black.withOpacity(0.06);
    final borderColor = _accent.withOpacity(0.3);
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

  // Frosted / gradient header bar like HomeScreen
  PreferredSizeWidget _buildHeaderBar(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return PreferredSize(
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
              children: const [
                _ModernBrandLogo(), // same CinePulse pill from Home
                Spacer(),
                // We’re on the Saved tab already - no extra header icons here
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Top toolbar under header: search + sort + export + clear
  Widget _buildToolbarRow({
    required BuildContext context,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final borderColor = isDark
        ? Colors.white.withOpacity(0.06)
        : Colors.black.withOpacity(0.06);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0b0f17) : theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(width: 1, color: borderColor),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: LayoutBuilder(
        builder: (ctx, c) {
          // Single row layout that wraps on tiny widths (Wrap handles overflow)
          return Wrap(
            runSpacing: 12,
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // Search field should try to take as much horizontal as possible.
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 220, maxWidth: 500),
                child: _SavedSearchField(
                  controller: _query,
                  onClear: () {
                    _query.clear();
                    FocusScope.of(context).unfocus();
                  },
                ),
              ),

              // Sort popup
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
                child: _buildSortPill(),
              ),

              // Export
              _smallIconButton(
                context: context,
                icon: Icons.ios_share,
                tooltip: 'Export saved',
                onTap: () => _export(context),
              ),

              // Clear all
              _smallIconButton(
                context: context,
                icon: Icons.delete_outline,
                tooltip: 'Clear all',
                onTap: () => _clearAll(context),
              ),
            ],
          );
        },
      ),
    );
  }

  // "2 items" row under toolbar
  Widget _buildCountRow({
    required String countText,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          countText,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }

  /* ───────────────────────────────── build ───────────────────────────────── */

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor =
        isDark ? const Color(0xFF0b0f17) : theme.colorScheme.surface;

    // Safe paddings similar to Home grid usage
    const horizontalPad = 12.0;
    const topPad = 8.0;
    final bottomSafe = MediaQuery.viewPaddingOf(context).bottom;
    final bottomPad = 28.0 + bottomSafe;

    return AnimatedBuilder(
      animation: SavedStore.instance,
      builder: (context, _) {
        // show spinner until SavedStore finished initializing bookmarks
        if (!SavedStore.instance.isReady) {
          return Scaffold(
            backgroundColor: bgColor,
            appBar: _buildHeaderBar(context),
            body: const Center(child: CircularProgressIndicator()),
          );
        }

        // 1. pull raw saved stories in desired sort order
        final ids = SavedStore.instance.orderedIds(_sort);
        final stories = ids.map(FeedCache.get).whereType<Story>().toList();

        // 2. filter by search text
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

        final gridDelegate = _gridDelegateFor(context);

        // empty state UI
        final emptyWidget = Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.bookmark_add_outlined,
                  size: 48,
                  color: theme.colorScheme.onSurfaceVariant,
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
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );

        return Scaffold(
          backgroundColor: bgColor,
          appBar: _buildHeaderBar(context),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // toolbar row below header
              _buildToolbarRow(context: context),

              // "2 items"
              _buildCountRow(countText: countText),

              const SizedBox(height: 4),

              // The grid / empty state fills the rest.
              Expanded(
                child: RefreshIndicator.adaptive(
                  color: _accent,
                  onRefresh: _refreshLocal,
                  child: filtered.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: EdgeInsets.fromLTRB(
                            horizontalPad,
                            24,
                            horizontalPad,
                            bottomPad,
                          ),
                          children: [emptyWidget],
                        )
                      : GridView.builder(
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

/* ────────────────────────── Search field pill ────────────────────────── */

class _SavedSearchField extends StatelessWidget {
  const _SavedSearchField({
    required this.controller,
    required this.onClear,
  });

  final TextEditingController controller;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = isDark
        ? const Color(0xFF0f172a).withOpacity(0.7)
        : Colors.black.withOpacity(0.06);
    final borderColor = const Color(0xFFdc2626).withOpacity(0.3);
    final fg = isDark ? Colors.white : Colors.black87;

    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: borderColor,
          width: 1,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Icon(
            Icons.search_rounded,
            size: 18,
            color: fg,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: controller,
              textInputAction: TextInputAction.search,
              style: TextStyle(
                color: fg,
                fontSize: 14,
                height: 1.2,
              ),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: 'Search saved…',
                hintStyle: TextStyle(
                  color: fg.withOpacity(0.6),
                  fontSize: 14,
                  height: 1.2,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ),
          if (controller.text.trim().isNotEmpty)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: onClear,
              child: Padding(
                padding: const EdgeInsets.all(4.0),
                child: Icon(
                  Icons.close_rounded,
                  size: 16,
                  color: fg,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/* ────────────────────────── CinePulse brand pill ──────────────────────────
   same look as HomeScreen._ModernBrandLogo
   (duplicated here so we don't import HomeScreen and fight privacy/_ names)
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
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}
