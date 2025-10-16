// lib/app/features/story/story_details.dart
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/cache.dart';
import '../../core/models.dart';
import '../../core/utils.dart';

class StoryDetailsScreen extends StatelessWidget {
  const StoryDetailsScreen({super.key, required this.story});
  final Story story;

  Uri? get _videoUrl => storyVideoUrl(story);

  Future<void> _watch(BuildContext context) async {
    final url = _videoUrl;
    if (url == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('No playable link available')));
      }
      return;
    }
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not open link')));
    }
  }

  Future<void> _share(BuildContext context) async {
    final text = _videoUrl?.toString() ?? story.title;
    try {
      if (!kIsWeb) {
        await Share.share(text);
      } else {
        await Clipboard.setData(ClipboardData(text: text));
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(kIsWeb ? 'Copied to clipboard' : 'Shared')));
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final onSurface = s.onSurface;
    final date = story.publishedAt == null
        ? null
        : DateFormat('EEE, d MMM • HH:mm').format(story.publishedAt!.toLocal());

    final isPhone = MediaQuery.of(context).size.width < 600;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            pinned: true,
            centerTitle: false,
            expandedHeight: isPhone ? 220 : 280,
            title: Text(
              'CinePulse',
              style: GoogleFonts.inter(fontWeight: FontWeight.w800),
            ),
            actions: [
              AnimatedBuilder(
                animation: SavedStore.instance,
                builder: (_, __) {
                  final saved = SavedStore.instance.isSaved(story.id);
                  return IconButton(
                    tooltip: saved ? 'Remove from Saved' : 'Save bookmark',
                    onPressed: () => SavedStore.instance.toggle(story.id),
                    icon: Icon(saved ? Icons.bookmark : Icons.bookmark_add_outlined),
                  );
                },
              ),
              IconButton(
                tooltip: 'Share',
                onPressed: () => _share(context),
                icon: const Icon(Icons.ios_share),
              ),
              const SizedBox(width: 4),
            ],
            flexibleSpace: FlexibleSpaceBar(
              collapseMode: CollapseMode.parallax,
              titlePadding: const EdgeInsetsDirectional.only(start: 56, bottom: 16, end: 16),
              stretchModes: const [StretchMode.zoomBackground, StretchMode.blurBackground],
              background: _HeaderHero(story: story),
            ),
          ),

          // Body
          SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title
                      Text(
                        story.title,
                        style: GoogleFonts.inter(
                          fontSize: 22,
                          height: 1.22,
                          fontWeight: FontWeight.w800,
                          color: onSurface,
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Meta chips
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          Chip(label: Text(story.kind.toUpperCase())),
                          if ((story.source ?? '').isNotEmpty) Chip(label: Text(story.source!)),
                          if (date != null) Chip(label: Text(date)),
                        ],
                      ),

                      const SizedBox(height: 16),

                      // Summary
                      if ((story.summary ?? '').isNotEmpty)
                        Text(
                          story.summary!,
                          style: GoogleFonts.inter(fontSize: 16, height: 1.4, color: onSurface),
                        ),

                      const SizedBox(height: 20),

                      // Actions
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: () => _watch(context),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('Watch'),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton.icon(
                            onPressed: () => _share(context),
                            icon: const Icon(Icons.ios_share),
                            label: const Text('Share'),
                          ),
                          const Spacer(),
                          AnimatedBuilder(
                            animation: SavedStore.instance,
                            builder: (_, __) {
                              final saved = SavedStore.instance.isSaved(story.id);
                              return IconButton.filledTonal(
                                tooltip: saved ? 'Remove from Saved' : 'Save bookmark',
                                onPressed: () => SavedStore.instance.toggle(story.id),
                                icon: Icon(saved ? Icons.bookmark : Icons.bookmark_add),
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/* ------------------------------ Header Hero ------------------------------ */

class _HeaderHero extends StatelessWidget {
  const _HeaderHero({required this.story});
  final Story story;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Hero(
      tag: 'thumb-${story.id}',
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Image or fallback color
          (story.thumbUrl == null || story.thumbUrl!.isEmpty)
              ? Container(color: s.surfaceContainerHighest)
              : CachedNetworkImage(
                  imageUrl: story.thumbUrl!,
                  fit: BoxFit.cover,
                ),
          // Gradient for legibility
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    s.surface.withOpacity(0.65),
                    s.surface.withOpacity(0.0),
                  ],
                  stops: const [0.0, 0.6],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
