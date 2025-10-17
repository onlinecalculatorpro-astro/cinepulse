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

import '../../core/api.dart'; // deepLinkForStoryId
import '../../core/cache.dart';
import '../../core/models.dart';
import '../../core/utils.dart';
import 'story_details.dart';
import 'ott_badge.dart';

class StoryCard extends StatelessWidget {
  const StoryCard({super.key, required this.story});
  final Story story;

  bool get _isWatchCta {
    final kind = story.kind.toLowerCase();
    final source = (story.source ?? '').toLowerCase();
    return kind == 'trailer' || source == 'youtube';
  }

  Uri? get _url => storyVideoUrl(story);

  // Open external playable URL.
  Future<void> _openLink(BuildContext context) async {
    final url = _url;
    if (url == null) return; // Button will be disabled when null.
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not open link')));
    }
  }

  // Share a deep link that opens inside the app; clipboard on web.
  Future<void> _share(BuildContext context) async {
    final deep = deepLinkForStoryId(story.id).toString();
    try {
      if (!kIsWeb) {
        await Share.share(deep);
      } else {
        await Clipboard.setData(ClipboardData(text: deep));
      }
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(kIsWeb ? 'Link copied to clipboard' : 'Share sheet opened'),
        ),
      );
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

  String _metaLine() {
    // Platform or source
    final platform = (story.ottPlatform ?? story.source ?? '').trim();

    // Context tag
    final ctx = story.isTheatrical
        ? (story.isUpcoming ? 'Coming soon' : 'In theatres')
        : (story.kind.isNotEmpty ? _titleCase(story.kind) : '');

    // Prefer release date; fallback to publish time
    final d = story.releaseDate ?? story.publishedAt;
    String when = '';
    if (d != null) {
      final now = DateTime.now().toUtc();
      final diff = now.difference(d);
      if (diff.inDays >= 0 && diff.inDays <= 10) {
        if (diff.inDays == 0) {
          when = 'Today';
        } else if (diff.inDays == 1) {
          when = 'Yesterday';
        } else {
          when = '${diff.inDays}d ago';
        }
      } else {
        when = DateFormat('d MMM').format(d.toLocal());
      }
    }

    final parts = <String>[]; // Platform shown via OttBadge, so omit here
    if (ctx.isNotEmpty) parts.add(ctx);
    if (when.isNotEmpty) parts.add(when);
    return parts.join(' • ');
  }

  String _titleCase(String s) => s.isEmpty ? s : (s[0].toUpperCase() + s.substring(1));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final width = MediaQuery.of(context).size.width;
    final isMobileColumn = width < 520;
    final metaText = _metaLine();
    final hasUrl = _url != null;

    final child = InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: () => _openDetails(context),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: isMobileColumn
            ? _VerticalCard(
                story: story,
                metaText: metaText,
                isWatchCta: _isWatchCta,
                hasUrl: hasUrl,
                onPrimaryAction: () => _openLink(context),
                onShare: () => _share(context),
              )
            : _HorizontalCard(
                story: story,
                metaText: metaText,
                isWatchCta: _isWatchCta,
                hasUrl: hasUrl,
                onPrimaryAction: () => _openLink(context),
                onShare: () => _share(context),
              ),
      ),
    );

    return Card(
      color: scheme.surface.withOpacity(0.6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: kIsWeb
            ? child // Skip blur on web for perf
            : BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                child: child,
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
    required this.isWatchCta,
    required this.hasUrl,
    required this.onPrimaryAction,
    required this.onShare,
  });

  final Story story;
  final String metaText;
  final bool isWatchCta;
  final bool hasUrl;
  final VoidCallback onPrimaryAction;
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
                          placeholder: (c, _) =>
                              Container(color: scheme.surfaceVariant.withOpacity(0.2)),
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
        // Badge + meta line
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            OttBadge.fromStory(story, dense: true),
            Text(
              metaText,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: hasUrl ? onPrimaryAction : null, // disabled if no link
          icon: Icon(isWatchCta ? Icons.play_arrow_rounded : Icons.open_in_new_rounded),
          label: Text(isWatchCta ? 'Watch' : 'Open'),
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
    required this.isWatchCta,
    required this.hasUrl,
    required this.onPrimaryAction,
    required this.onShare,
  });

  final Story story;
  final String metaText;
  final bool isWatchCta;
  final bool hasUrl;
  final VoidCallback onPrimaryAction;
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
              // Badge + meta line
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  OttBadge.fromStory(story, dense: true),
                  Text(
                    metaText,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: hasUrl ? onPrimaryAction : null, // disabled if no link
                  icon:
                      Icon(isWatchCta ? Icons.play_arrow_rounded : Icons.open_in_new_rounded),
                  label: Text(isWatchCta ? 'Watch' : 'Open'),
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
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 20, color: scheme.onSurface),
          ),
        ),
      ),
    );
  }
}
