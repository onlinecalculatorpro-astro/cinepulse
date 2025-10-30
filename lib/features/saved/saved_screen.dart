// lib/features/saved/saved_screen.dart
//
// SAVED TAB
// ----------------------------------------------------------------------
// Header rules (matches global nav spec):
// WIDE (≥768px):    [Home] [Search] [Alerts] [Discover] [Refresh] [Menu]
// COMPACT (<768px): [Search] [Refresh] [Menu]
// Search toggles an inline bar INSIDE Saved (Row 3).
// Row 2  = shared AppToolbar (chips + sort pill; theme-safe colors)
// Row 2b = Saved-only actions (Export / Clear)
// Row 2.5 = "N items" (for current chip + search result)
// Body   = grid of StoryCard.
// ----------------------------------------------------------------------

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/cache.dart';            // SavedStore, SavedSort, FeedCache
import '../../core/models.dart';
import '../../theme/theme_colors.dart';    // primaryTextColor, neutralPillBg, outlineHairline
import '../../widgets/app_toolbar.dart';   // ✅ shared toolbar row
import '../../widgets/search_bar.dart';    // SearchBarInput
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
  static const List<String> _tabs = ['All', 'Entertainment', 'Sports'];

  final List<GlobalKey> _chipKeys =
      List.generate(_tabs.length, (_) => GlobalKey());

  SavedSort _sort = SavedSort.recent;
  int _activeCatIndex = 0;

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
      if (!_showSearchRow) _query.clear();
    });
  }

  void _setCategory(int i) {
    if (i < 0 || i >= _tabs.length) return;
    setState(() => _activeCatIndex = i);

    // Ensure the tapped chip scrolls into view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _chipKeys[i].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        );
      }
    });
  }

  void _refreshSaved() => setState(() {}); // local only

  /* ─────────────── Category filter helpers ─────────────── */

  String _verticalOf(Story s) {
    try {
      final dyn = (s as dynamic);
      final v = dyn.vertical ?? dyn.category ?? dyn.section ?? '';
      if (v is String) return v.toLowerCase();
    } catch (_) {}
    return '';
  }

  bool _matchesActiveCategory(Story s) {
    if (_activeCatIndex == 0) return true; // All
    final v = _verticalOf(s);
    if (_activeCatIndex == 1) {
      return v.contains('entertain');
    } else {
      return v.contains('sport');
    }
  }

  /* ─────────────── Export / Clear all ─────────────── */

  Future<void> _export(BuildContext context) async {
    final text = SavedStore.instance.exportLinks();
    try {
      if (!kIsWeb) {
        await Share.share(text);
      } else {
        await Clipboard.setData(ClipboardData(text: text));
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(kIsWeb ? 'Copied to clipboard' : 'Share sheet opened')),
    );
  }

  Future<void> _clearAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear all saved?'),
        content: const Text('This will remove all bookmarks on this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) {
      await SavedStore.instance.clearAll();
      if (mounted) setState(() {});
    }
  }

  /* ─────────────── Grid sizing (matches Home) ─────────────── */

  SliverGridDelegate _gridDelegateFor(double width, double textScale) {
    int estCols;
    if (width < 520)      estCols = 1;
    else if (width < 900) estCols = 2;
    else if (width < 1400)estCols = 3;
    else                  estCols = 4;

    double maxTileW = (width / estCols).clamp(320.0, 480.0);
    final baseRatio = (estCols == 1) ? 0.88 : (estCols == 2 ? 0.95 : 1.00);
    final scaleForHeight = textScale.clamp(1.0, 1.4);
    final effectiveRatio = baseRatio / scaleForHeight;

    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxTileW,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: effectiveRatio,
    );
  }

  /* ─────────────── Sort sheet (Saved) ─────────────── */

  Future<void> _showSortSheet(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    final picked = await showModalBottomSheet<SavedSort>(
      context: context,
      showDragHandle: true,
      backgroundColor: cs.surface,
      builder: (ctx) {
        Widget tile({
          required SavedSort value,
          required IconData icon,
          required String title,
          required String subtitle,
        }) {
          final selected = (_sort == value);
          return ListTile(
            leading: Icon(icon, color: selected ? cs.primary : cs.onSurface),
            title: Text(
              title,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: cs.onSurface,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
            trailing: selected ? Icon(Icons.check_rounded, color: cs.primary) : null,
            onTap: () => Navigator.pop(ctx, value),
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              tile(
                value: SavedSort.recent,
                icon: Icons.history,
                title: 'Recently saved',
                subtitle: 'Latest bookmarks first',
              ),
              tile(
                value: SavedSort.title,
                icon: Icons.sort_by_alpha,
                title: 'Title (A–Z)',
                subtitle: 'Alphabetical by title',
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );

    if (picked != null && picked != _sort) {
      setState(() => _sort = picked);
    }
  }

  /* ─────────────── UI ─────────────── */

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= 768;

    return AnimatedBuilder(
      animation: SavedStore.instance,
      builder: (context, _) {
        if (!SavedStore.instance.isReady) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        // 1) order; 2) category filter; 3) search filter
        final ids = SavedStore.instance.orderedIds(_sort);
        final base = ids.map(FeedCache.get).whereType<Story>().toList(growable: false);
        final byCategory = base.where(_matchesActiveCategory).toList(growable: false);

        final q = _query.text.trim().toLowerCase();
        final filtered = (q.isEmpty)
            ? byCategory
            : byCategory.where((s) {
                final title = s.title.toLowerCase();
                final summ = (s.summary ?? '').toLowerCase();
                return title.contains(q) || summ.contains(q);
              }).toList(growable: false);

        final countText = switch (filtered.length) {
          0 => 'No items',
          1 => '1 item',
          _ => '${filtered.length} items'
        };

        return Scaffold(
          backgroundColor: theme.scaffoldBackgroundColor,

          /* ── Row 1: Frosted header ── */
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
                      colors: [
                        cs.surface.withOpacity(0.95),
                        cs.surface.withOpacity(0.90),
                      ],
                    ),
                    border: Border(
                      bottom: BorderSide(color: outlineHairline(context), width: 1),
                    ),
                  ),
                  child: Row(
                    children: [
                      const _ModernBrandLogo(),
                      const Spacer(),

                      if (isWide) ...[
                        _HeaderIconButton(tooltip: 'Home',   icon: Icons.home_rounded,          onTap: widget.onOpenHome),
                        const SizedBox(width: 8),
                        _HeaderIconButton(tooltip: 'Search', icon: Icons.search_rounded,        onTap: _toggleSearchRow),
                        const SizedBox(width: 8),
                        _HeaderIconButton(tooltip: 'Alerts', icon: Icons.notifications_rounded, onTap: widget.onOpenAlerts),
                        const SizedBox(width: 8),
                        _HeaderIconButton(
                          tooltip: 'Discover',
                          icon: kIsWeb ? Icons.explore_outlined : Icons.manage_search_rounded,
                          onTap: widget.onOpenDiscover,
                        ),
                        const SizedBox(width: 8),
                        _HeaderIconButton(tooltip: 'Refresh', icon: Icons.refresh_rounded, onTap: _refreshSaved),
                        const SizedBox(width: 8),
                        _HeaderIconButton(tooltip: 'Menu',    icon: Icons.menu_rounded,    onTap: widget.onOpenMenu),
                      ] else ...[
                        _HeaderIconButton(tooltip: 'Search',  icon: Icons.search_rounded,  onTap: _toggleSearchRow),
                        const SizedBox(width: 8),
                        _HeaderIconButton(tooltip: 'Refresh', icon: Icons.refresh_rounded, onTap: _refreshSaved),
                        const SizedBox(width: 8),
                        _HeaderIconButton(tooltip: 'Menu',    icon: Icons.menu_rounded,    onTap: widget.onOpenMenu),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),

          /* ── Body ── */
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Row 2: ✅ shared toolbar (chips + sort pill with neutral text)
              AppToolbar(
                tabs: _tabs,
                activeIndex: _activeCatIndex,
                onSelect: _setCategory,
                chipKeys: _chipKeys,
                sortLabel: (_sort == SavedSort.recent) ? 'Recent' : 'Title',
                sortIcon: (_sort == SavedSort.recent) ? Icons.history : Icons.sort_by_alpha,
                onSortTap: () => _showSortSheet(context),
              ),

              // Row 2b: Saved-only actions (right-aligned; same surface bg, no extra border)
              Container(
                color: cs.surface,
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: Row(
                  children: [
                    const Spacer(),
                    _HeaderIconButton(
                      icon: Icons.ios_share,
                      tooltip: 'Export saved',
                      onTap: () => _export(context),
                    ),
                    const SizedBox(width: 8),
                    _HeaderIconButton(
                      icon: Icons.delete_outline,
                      tooltip: 'Clear all',
                      onTap: () => _clearAll(context),
                    ),
                  ],
                ),
              ),

              // Row 2.5: count (for current chip/search result)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  countText,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),

              // Row 3: inline search
              if (_showSearchRow)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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

              // Grid / empty
              Expanded(
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    final w = constraints.maxWidth;
                    final textScale = MediaQuery.textScaleFactorOf(ctx);
                    final gridDelegate = _gridDelegateFor(w, textScale);

                    const horizontalPad = 12.0;
                    const topPad = 8.0;
                    final bottomSafe = MediaQuery.viewPaddingOf(ctx).bottom;
                    final bottomPad = 28.0 + bottomSafe;

                    if (filtered.isEmpty) {
                      // Empty because nothing saved OR no match.
                      final isSearching = _query.text.trim().isNotEmpty || _activeCatIndex != 0;
                      return ListView(
                        padding: EdgeInsets.fromLTRB(horizontalPad, 24, horizontalPad, bottomPad),
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          if (!isSearching)
                            const _EmptySaved()
                          else
                            Center(
                              child: Text(
                                'No matching items.',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                              ),
                            ),
                        ],
                      );
                    }

                    return GridView.builder(
                      padding: EdgeInsets.fromLTRB(horizontalPad, topPad, horizontalPad, bottomPad),
                      physics: const AlwaysScrollableScrollPhysics(),
                      cacheExtent: 2000,
                      gridDelegate: gridDelegate,
                      itemCount: filtered.length,
                      itemBuilder: (_, i) => StoryCard(
                        story: filtered[i],
                        allStories: filtered,
                        index: i,
                      ),
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

/* ───────── Empty state ───────── */

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
            Icon(Icons.bookmark_add_outlined, size: 48, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('No saved items yet', style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(
              'Tap the bookmark on any card to save it here.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/* ───────── Shared header bits (match Home) ───────── */

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
    final cs = Theme.of(context).colorScheme;
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
            color: neutralPillBg(context),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: cs.primary.withOpacity(0.30), width: 1),
          ),
          child: Icon(icon, size: 16, color: cs.onSurface),
        ),
      ),
    );
  }
}

class _ModernBrandLogo extends StatelessWidget {
  const _ModernBrandLogo();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: cs.primary,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: cs.primary.withOpacity(0.35),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Center(
            child: Text('🎬', style: TextStyle(fontSize: 16, height: 1, color: cs.onPrimary)),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'CinePulse',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: primaryTextColor(context),
          ),
        ),
      ],
    );
  }
}
