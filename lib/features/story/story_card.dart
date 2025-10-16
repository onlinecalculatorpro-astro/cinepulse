import 'dart:ui';

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
import 'story_details.dart';

class StoryCard extends StatelessWidget {
  const StoryCard({super.key, required this.story});
  final Story story;

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

  /// Share a **deep link** that opens inside the app.
  /// We use a hash fragment so it works on static hosts (#/s/<id>).
  Future<void> _share(BuildContext context) async {
    final base = Uri.base;
    final deepLink = Uri(
      scheme: base.scheme.isEmpty ? 'https' : base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      fragment: '/s/${story.id}',
    ).toString();

    try {
      if (!kIsWeb) {
        await Share.share(deepLink);
      } else {
        await Clipboard.setData(ClipboardData(text: deepLink));
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(kIsWeb ? 'Link copied to clipboard' : 'Share sheet opened'),
          ),
        );
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: deepLink));
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final width = MediaQuery.of(context).size.width;
    final isMobileColumn = width < 520; // responsive cutoff
    final date = story.publishedAt == null
        ? null
        : DateFormat('EEE, d MMM • HH:mm').format(story.publishedAt!.toLocal());

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
                      dateText: date,
                      onWatch: () => _watch(context),
                      onShare: () => _share(context),
                    )
                  : _HorizontalCard(
                      story: story,
                      dateText: date,
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
    required this.dateText,
    required this.onWatch,
    required this.onShare,
  });

  final Story story;
  final String? dateText;
  final VoidCallback onWatch;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Image header with actions overlay (matches details styling)
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
                        icon:
                            saved ? Icons.bookmark : Icons.bookmark_add_outlined,
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
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(label: Text(story.kind.toUpperCase())),
            if ((story.source ?? '').isNotEmpty)
              Chip(label: Text(story.source!)),
            if (dateText != null) Chip(label: Text(dateText!)),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: onWatch,
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Watch'),
        ),
      ],
    );
  }
}

/* -------------------------- TABLET/DESKTOP (ROW) -------------------------- */

class _HorizontalCard extends StatelessWidget {
  const _HorizontalCard({
    required this.story,
    required this.dateText,
    required this.onWatch,
    required this.onShare,
  });

  final Story story;
  final String? dateText;
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
              width: 120,
              height: 72,
              child: (story.thumbUrl == null || story.thumbUrl!.isEmpty)
                  ? Container(color: scheme.surfaceTint.withOpacity(0.1))
                  : CachedNetworkImage(
                      imageUrl: story.thumbUrl!,
                      fit: BoxFit.cover,
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
                        icon: Icon(
                          saved
                              ? Icons.bookmark
                              : Icons.bookmark_add_outlined,
                        ),
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
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Chip(label: Text(story.kind.toUpperCase())),
                  if ((story.source ?? '').isNotEmpty)
                    Chip(label: Text(story.source!)),
                  if (dateText != null) Chip(label: Text(dateText!)),
                ],
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: onWatch,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Watch'),
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
            child: Icon(Icons.circle, size: 0), // size holder replaced below
          ),
        ),
      ),
    );
  }
}
