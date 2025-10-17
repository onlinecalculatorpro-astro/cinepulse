// lib/features/story/story_details.dart
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart'; // deepLinkForStoryId
import '../../core/cache.dart';
import '../../core/models.dart';
import '../../core/utils.dart';
import 'ott_badge.dart';

class StoryDetailsScreen extends StatelessWidget {
  const StoryDetailsScreen({super.key, required this.story});
  final Story story;

  bool get _isWatchCta {
    final kind = story.kind.toLowerCase();
    final source = (story.source ?? '').toLowerCase();
    return kind == 'trailer' || source == 'youtube';
  }

  Uri? get _videoUrl => storyVideoUrl(story);

  // Prefer deep link (opens inside app). Fallback to video URL if available.
  String _shareText() {
    final deep = deepLinkForStoryId(story.id).toString();
    return deep.isNotEmpty ? deep : (_videoUrl?.toString() ?? story.title);
  }

  Future<void> _openExternal(BuildContext context) async {
    final url = _videoUrl;
    if (url == null) return; // Button disabled in UI when null
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not open link')));
    }
  }

  Future<void> _share(BuildContext context) async {
    final text = _shareText();
    try {
      if (!kIsWeb) {
        await Share.share(text);
      } else {
        await Clipboard.setData(ClipboardData(text: text));
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(kIsWeb ? 'Link copied to clipboard' : 'Share sheet opened'),
          ),
        );
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Link copied to clipboard')));
      }
    }
  }

  String _metaLine() {
    final platform = (story.ottPlatform ?? story.source ?? '').trim();

    final String ctx;
    if (story.isTheatrical) {
      ctx = story.isUpcoming ? 'Coming soon' : 'In theatres';
    } else {
      ctx = story.kind.toLowerCase() == 'ott' ? 'OTT' : story.kind;
    }

    final DateTime? d = story.releaseDate ?? story.publishedAt;
    String dateText = '';
    if (d != null) {
      final now = DateTime.now().toUtc();
      final diff = now.difference(d);
      if (diff.inDays >= 0 && diff.inDays <= 10) {
        if (diff.inDays == 0) {
          dateText = 'Today';
        } else if (diff.inDays == 1) {
          dateText = 'Yesterday';
        } else {
          dateText = '${diff.inDays}d ago';
        }
      } else {
        dateText = DateFormat('d MMM').format(d.toLocal());
      }
    }

    final extras = <String>[];
    if ((story.ratingCert ?? '').isNotEmpty) extras.add(story.ratingCert!);
    if ((story.runtimeMinutes ?? 0) > 0) extras.add('${story.runtimeMinutes}m');

    final parts = <String>[]; // Platform is shown via OttBadge
    if (ctx.isNotEmpty) parts.add(ctx);
    if (dateText.isNotEmpty) parts.add(dateText);
    if (extras.isNotEmpty) parts.add(extras.join(' • '));
    return parts.join(' • ');
  }

  String _titleCase(String s) => s.isEmpty ? s : (s[0].toUpperCase() + s.substring(1));

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final onSurface = s.onSurface;
    final isPhone = MediaQuery.of(context).size.width < 600;
    final hasUrl = _videoUrl != null;

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
            expandedHeight: isPhone ? 240 : 320,
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
              titlePadding:
                  const EdgeInsetsDirectional.only(start: 56, bottom: 16, end: 16),
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
                      const SizedBox(height: 8),

                      // OTT badge + Meta line (platform • context • date • cert • runtime)
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          OttBadge.fromStory(story, dense: true),
                          Text(
                            _metaLine(),
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: s.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      // Summary
                      if ((story.summary ?? '').isNotEmpty)
                        Text(
                          story.summary!,
                          style: GoogleFonts.inter(fontSize: 16, height: 1.4, color: onSurface),
                        ),

                      // Optional facets (languages/genres) if present
                      if (story.languages.isNotEmpty || story.genres.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (story.languages.isNotEmpty)
                              _Facet(label: 'Language', value: story.languages.join(', ')),
                            if (story.genres.isNotEmpty)
                              _Facet(label: 'Genre', value: story.genres.join(', ')),
                          ],
                        ),
                      ],

                      const SizedBox(height: 20),

                      // Actions
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: hasUrl ? () => _openExternal(context) : null,
                            icon: Icon(_isWatchCta
                                ? Icons.play_arrow_rounded
                                : Icons.open_in_new_rounded),
                            label: Text(_isWatchCta ? 'Watch' : 'Open'),
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
    final imageUrl =
        (story.posterUrl?.isNotEmpty == true) ? story.posterUrl! : (story.thumbUrl ?? '');

    return Hero(
      tag: 'thumb-${story.id}',
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Image or fallback color
          imageUrl.isEmpty
              ? Container(color: s.surfaceContainerHighest)
              : CachedNetworkImage(
                  imageUrl: imageUrl,
                  fit: BoxFit.cover,
                  memCacheWidth: 1600,
                  fadeInDuration: const Duration(milliseconds: 180),
                ),
          // Gradient for legibility
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    s.surface.withOpacity(0.70),
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

/* --------------------------------- Facet --------------------------------- */

class _Facet extends StatelessWidget {
  const _Facet({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600),
          ),
          Text(value, style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
    );
  }
}
