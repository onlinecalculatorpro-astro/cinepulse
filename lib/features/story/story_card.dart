// lib/features/story/story_card.dart
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart'; // deepLinkForStoryId
import '../../core/cache.dart';
import '../../core/models.dart'; // Story + storyVideoUrl + metaLine/kindLabel
import '../../core/utils.dart';
import '../../widgets/kind_badge.dart'; // <-- reusable badge
import 'story_details.dart';
import 'ott_badge.dart';

class StoryCard extends StatefulWidget {
  const StoryCard({super.key, required this.story});
  final Story story;

  @override
  State<StoryCard> createState() => _StoryCardState();
}

class _StoryCardState extends State<StoryCard> {
  bool _hover = false;

  Uri? get _videoUrl => storyVideoUrl(widget.story);

  /// Prefer a playable video URL; otherwise fall back to canonical `story.url`.
  Uri? get _linkUrl {
    final v = _videoUrl;
    if (v != null) return v;

    final raw = (widget.story.url ?? '').trim();
    if (raw.isEmpty) return null;
    final u = Uri.tryParse(raw);
    if (u == null || !(u.isScheme('http') || u.isScheme('https'))) return null;
    return u;
  }

  bool get _isWatchCta {
    final host = _linkUrl?.host?.toLowerCase() ?? '';
    final byHost = host.contains('youtube.com') || host.contains('youtu.be');
    final byType = widget.story.kind.toLowerCase() == 'trailer';
    final bySource = (widget.story.source ?? '').toLowerCase() == 'youtube';
    return byHost || byType || bySource;
  }

  String get _ctaLabel => _isWatchCta ? 'Watch' : 'Read';

  Future<void> _openLink(BuildContext context) async {
    final url = _linkUrl;
    if (url == null) return;
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open link')),
      );
    }
  }

  // Share a deep link that opens inside the app; clipboard on web.
  Future<void> _share(BuildContext context) async {
    final deep = deepLinkForStoryId(widget.story.id).toString();
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
    Navigator.of(context)
        .push(fadeRoute(StoryDetailsScreen(story: widget.story)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final metaText = widget.story.metaLine;
    final hasUrl = _linkUrl != null;

    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      transform: _hover ? Matrix4.identity()..translate(0.0, -2.0, 0.0) : null,
      decoration: BoxDecoration(
        color: scheme.surface.withOpacity(0.60),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: _hover
              ? const Color(0x33dc2626)
              : Colors.white.withOpacity(0.04),
          width: 1,
        ),
        boxShadow: _hover
            ? [
                BoxShadow(
                  color: const Color(0xFFdc2626).withOpacity(0.18),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ]
            : const [],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openDetails(context),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Thumbnail / poster (16:9) with subtle gradient scrim + quick actions
                _Thumb(
                  story: widget.story,
                  onShare: () => _share(context),
                ),
                const SizedBox(height: 12),

                // Badge + meta line (e.g., NEWS • 20 Oct 2025, 7:23 PM)
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    KindBadge(
                      widget.story.kindLabel ?? widget.story.kind,
                      compact: true,
                    ),
                    // Optional OTT badge if streaming information exists
                    if (OttBadge.canBuildFrom(widget.story))
                      OttBadge.fromStory(widget.story, dense: true),
                    Text(
                      metaText,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Title
                Text(
                  widget.story.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 12),

                // Actions
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: hasUrl ? () => _openLink(context) : null,
                      icon: Icon(_isWatchCta
                          ? Icons.play_arrow_rounded
                          : Icons.open_in_new_rounded),
                      label: Text(_ctaLabel),
                    ),
                    const Spacer(),
                    AnimatedBuilder(
                      animation: SavedStore.instance,
                      builder: (_, __) {
                        final saved =
                            SavedStore.instance.isSaved(widget.story.id);
                        return _ActionIcon(
                          tooltip: saved ? 'Remove from Saved' : 'Save',
                          icon:
                              saved ? Icons.bookmark : Icons.bookmark_add_outlined,
                          onTap: () => SavedStore.instance.toggle(widget.story.id),
                        );
                      },
                    ),
                    const SizedBox(width: 8),
                    _ActionIcon(
                      tooltip: 'Share',
                      icon: Icons.ios_share,
                      onTap: () => _share(context),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: kIsWeb
          ? card // Skip BackdropFilter blur on web for perf
          : ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                child: card,
              ),
            ),
    );
  }
}

/* ------------------------------- Thumbnail ------------------------------- */

class _Thumb extends StatelessWidget {
  const _Thumb({required this.story, required this.onShare});

  final Story story;
  final VoidCallback onShare;

  IconData _placeholderFor(String k) {
    final kind = k.toLowerCase();
    if (kind.contains('trailer')) return Icons.play_circle_filled_rounded;
    if (kind.contains('release') || kind.contains('theatre')) {
      return Icons.local_movies_rounded;
    }
    if (kind.contains('ott') || kind.contains('stream')) {
      return Icons.tv_rounded;
    }
    return Icons.article_rounded; // news/others
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasThumb = (story.thumbUrl != null && story.thumbUrl!.isNotEmpty);

    return Stack(
      children: [
        Hero(
          tag: 'thumb-${story.id}',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: hasThumb
                  ? CachedNetworkImage(
                      imageUrl: story.thumbUrl!,
                      fit: BoxFit.cover,
                      memCacheWidth: 900,
                      fadeInDuration: const Duration(milliseconds: 150),
                      placeholder: (c, _) => Container(
                        color: scheme.surfaceVariant.withOpacity(0.20),
                      ),
                      errorWidget: (c, _, __) => Container(
                        color: scheme.surfaceVariant.withOpacity(0.20),
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            scheme.surfaceVariant.withOpacity(0.18),
                            scheme.surfaceVariant.withOpacity(0.10),
                          ],
                        ),
                      ),
                      child: Center(
                        child: Icon(
                          _placeholderFor(story.kind),
                          size: 48,
                          color: scheme.onSurfaceVariant.withOpacity(0.7),
                        ),
                      ),
                    ),
            ),
          ),
        ),

        // Bottom gradient scrim for future text overlays (visual depth)
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withOpacity(0.25),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.5],
                ),
              ),
            ),
          ),
        ),

        // Quick actions (top-right)
        Positioned(
          right: 8,
          top: 8,
          child: _CircleIconButton(
            tooltip: 'Share',
            icon: Icons.ios_share,
            onPressed: onShare,
          ),
        ),
      ],
    );
  }
}

/* --------------------------------- UI bits -------------------------------- */

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 24,
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surface.withOpacity(0.65),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withOpacity(0.06),
              width: 1,
            ),
          ),
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 20, color: scheme.onSurface),
        ),
      ),
    );
  }
}

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
        color: scheme.surface.withOpacity(0.70),
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
