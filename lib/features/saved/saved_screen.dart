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

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
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
          SnackBar(content: Text(kIsWeb ? 'Copied to clipboard' : 'Shared')),
        );
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Copied to clipboard')),
        );
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
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) {
      await SavedStore.instance.clearAll();
    }
  }

  @override
  Widget build(BuildContext context) {
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

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _query,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        hintText: 'Search saved…',
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
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
                      label:
                          Text(_sort == SavedSort.recent ? 'Recent' : 'Title'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Export saved',
                    icon: const Icon(Icons.ios_share),
                    onPressed: () => _export(context),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Clear all',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _clearAll(context),
                  ),
                ],
              ),
            ),
            if (filtered.isEmpty)
              const Expanded(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child:
                        Text('No saved items yet. Tap the bookmark to save.'),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.only(top: 4, bottom: 24),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => StoryCard(story: filtered[i]),
                ),
              ),
          ],
        );
      },
    );
  }
}
