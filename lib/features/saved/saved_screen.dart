// lib/features/saved/saved_screen.dart
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(kIsWeb ? 'Copied to clipboard' : 'Share sheet opened')),
        );
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
      }
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
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: SavedStore.instance,
      builder: (context, _) {
        if (!SavedStore.instance.isReady) {
          return const Center(child: CircularProgressIndicator());
        }

        final ids = SavedStore.instance.orderedIds(_sort);
        final stories = ids.map(FeedCache.get).whereType<Story>().toList();

        final q = _query.text.trim().toLowerCase();
        final filtered = q.isEmpty
            ? stories
            : stories
                .where((s) =>
                    s.title.toLowerCase().contains(q) ||
                    (s.summary ?? '').toLowerCase().contains(q))
                .toList();

        final total = stories.length;
        final countText = total == 0
            ? 'No items'
            : total == 1
                ? '1 item'
                : '$total items';

        return Column(
          children: [
            // Toolbar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
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
                  // Sort selector
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
                            Text('Recently saved', style: GoogleFonts.inter()),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: SavedSort.title,
                        child: Row(
                          children: [
                            const Icon(Icons.sort_by_alpha, size: 18),
                            const SizedBox(width: 8),
                            Text('Title (A–Z)', style: GoogleFonts.inter()),
                          ],
                        ),
                      ),
                    ],
                    child: FilledButton.tonalIcon(
                      onPressed: null,
                      icon: const Icon(Icons.sort),
                      label: Text(_sort == SavedSort.recent ? 'Recent' : 'Title'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Export
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

            // Count
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  countText,
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ),

            const SizedBox(height: 4),

            // Content
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: filtered.isEmpty
                    ? const _EmptySaved()
                    : _SavedResultsList(stories: filtered),
              ),
            ),
          ],
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
            Icon(Icons.bookmark_add_outlined, size: 48, color: cs.onSurfaceVariant),
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

/* ---------------------------- Results (list/grid) ---------------------------- */

class _SavedResultsList extends StatelessWidget {
  const _SavedResultsList({required this.stories});
  final List<Story> stories;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size.width;

    // Responsive: list on small screens, grid on wider screens.
    final int columns = size >= 1200 ? 3 : (size >= 840 ? 2 : 1);

    if (columns == 1) {
      // List
      return ListView.builder(
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        itemCount: stories.length,
        itemBuilder: (_, i) => StoryCard(story: stories[i]),
      );
    }

    // Grid
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        // StoryCard adapts to available width; this ratio keeps cards comfy.
        childAspectRatio: 0.95,
      ),
      itemCount: stories.length,
      itemBuilder: (_, i) => StoryCard(story: stories[i]),
    );
  }
}
