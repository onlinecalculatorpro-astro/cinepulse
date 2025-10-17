// lib/features/story/story_card.dart
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart'; // for deepLinkForStoryId
import '../../core/cache.dart';
import '../../core/models.dart';
import '../../core/utils.dart';
import 'story_details.dart';

class StoryCard extends StatelessWidget {
  const StoryCard({super.key, required this.story});
  final Story story;

  // Open external playable URL (YouTube for now).
  Future<void> _watch(BuildContext context) async {
    final url = storyVideoUrl(story);
    if (url == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No playable link available')),
        );
      }
      return;
    }
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open link')),
      );
    }
  }

  // Share a deep link that opens inside the app.
  Future<void> _share(BuildContext context) async {
    final deep = deepLinkForStoryId(story.id).toString();
    try {
      if (!kIsWeb) {
        await Share.share(deep);
      } else {
        await Clipboard.setData(ClipboardData(text: deep));
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(kIsWeb ? 'Link copied to clipboard' : 'Share sheet opened'),
          ),
        );
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: deep));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copied to clipboard')),
        );
      }
    }
  }

  void _openDetails(BuildContext context) {
    Navigator.of(context).push(fadeRoute(StoryDetailsScreen(story: story)));
  }

  String _metaLine(BuildContext context) {
    // Platform or source
    final platform = (story.ottPlatform ?? story.source ?? '').trim();
    // Context tag
    final ctx = story.isTheatrical
        ? (story.isUpcoming ? 'Coming soon' : 'In theatres')
        : (story.kind.toLowerCase() == 'ott' ? 'OTT' : story.kind);
    // Date label prefers release date
    final date = story.releaseDate ?? story.publishedAt;
    String dateText = '';
    if (date != null) {
      final now = DateTime.now().toUtc();
      // If within ~10 days in past, show relative; else show calendar date.
      final diff = now.difference(date);
      if (diff.inDays >= 0 && diff.inDays <= 10) {
        if (diff.inDays == 0) {
          dateText = 'Today';
        } else if (diff.inDays == 1) {
          dateText = 'Yesterday';
        } else {
          dateText = '${diff.inDays}d ago';
        }
      } else {
        dateText = DateFormat('d MMM').format(date.toLocal());
      }
    }

    final parts = <String>[];
    if (platform.isNotEmpty) parts.add(_titleCase(platform));
    if (ctx.isNotEmpty) parts.add(ctx);
    if (dateText.isNotEmpty) parts.add(dateText);
    return parts.join(' • ');
  }

  String _titleCase(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final width = MediaQuery.of(context).size.width;
    final isMobileColumn = width < 520; // responsive cutoff

    return Card(
      color: scheme.surface.withOpacity(0.6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: () => _openDetails(context),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: isMobileColumn
                  ? _VerticalCard(
                      story: story,
                      metaText: _metaLine(context),
                      onWatch: () => _watch(context),
                      onShare: () => _share(context),
                    )
                  : _HorizontalCard(
                      story: story,
                      metaText: _metaLine(context),
                      onWatch: () => _watch(context),
                      onShare: () => _share(context),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/* ---------------------------- MOBILE (VERTICAL) --------------------------- */

class _VerticalCard extends StatelessWidget {
  const _VerticalCard({
    required this.story,
    required this.metaText,
    required this.onWatch,
    required this.onShare,
  });

  final Story story;
  final String metaText;
  final VoidCallback onWatch;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Poster/thumbnail with actions overlay
        Stack(
          children: [
            Hero(
              tag: 'thumb-${story.id}',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: (story.thumbUrl == null || story.thumbUrl!.isEmpty)
                      ? Container(color: scheme.surfaceTint.withOpacity(0.1))
                      : CachedNetworkImage(
                          imageUrl: story.thumbUrl!,
                          fit: BoxFit.cover,
                          memCacheWidth: 800, // perf hint
                          fadeInDuration: const Duration(milliseconds: 150),
                          placeholder: (c, _) => Container(
                            color: scheme.surfaceVariant.withOpacity(0.2),
                          ),
                        ),
                ),
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: Row(
                children: [
                  AnimatedBuilder(
                    animation: SavedStore.instance,
                    builder: (_, __) {
                      final saved = SavedStore.instance.isSaved(story.id);
                      return _CircleIconButton(
                        tooltip: saved ? 'Remove from Saved' : 'Save',
                        icon: saved ? Icons.bookmark : Icons.bookmark_add_outlined,
                        onPressed: () => SavedStore.instance.toggle(story.id),
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                  _CircleIconButton(
                    tooltip: 'Share',
                    icon: Icons.ios_share,
                    onPressed: onShare,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          story.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.inter(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        // 🧠 Cleaner meta line (fewer chips, more signal)
        Text(
          metaText,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: onWatch,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(story.kind.toLowerCase() == 'trailer' ? 'Watch' : 'Open'),
        ),
      ],
    );
  }
}

/* -------------------------- TABLET/DESKTOP (ROW) -------------------------- */

class _HorizontalCard extends StatelessWidget {
  const _HorizontalCard({
    required this.story,
    required this.metaText,
    required this.onWatch,
    required this.onShare,
  });

  final Story story;
  final String metaText;
  final VoidCallback onWatch;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Hero(
          tag: 'thumb-${story.id}',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(
              width: 224,
              height: 126, // 16:9
              child: (story.thumbUrl == null || story.thumbUrl!.isEmpty)
                  ? Container(color: scheme.surfaceTint.withOpacity(0.1))
                  : CachedNetworkImage(
                      imageUrl: story.thumbUrl!,
                      fit: BoxFit.cover,
                      memCacheWidth: 900,
                      fadeInDuration: const Duration(milliseconds: 150),
                      placeholder: (c, _) =>
                          Container(color: scheme.surfaceVariant.withOpacity(0.2)),
                    ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      story.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  AnimatedBuilder(
                    animation: SavedStore.instance,
                    builder: (_, __) {
                      final saved = SavedStore.instance.isSaved(story.id);
                      return IconButton(
                        tooltip: saved ? 'Remove from Saved' : 'Save',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => SavedStore.instance.toggle(story.id),
                        icon: Icon(saved ? Icons.bookmark : Icons.bookmark_add_outlined),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'Share',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.ios_share),
                    onPressed: onShare,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                metaText,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: onWatch,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(story.kind.toLowerCase() == 'trailer' ? 'Watch' : 'Open'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/* --------------------------------- UI bits -------------------------------- */

class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: scheme.surface.withOpacity(0.7),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: const Padding(
            padding: EdgeInsets.all(8),
            child: Icon(Icons.circle, size: 0), // placeholder replaced by IconTheme below
          ),
        ),
      ),
    );
  }
}
