// lib/features/story/story_details.dart
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart'; // deepLinkForStoryId, storyVideoUrl
import '../../core/cache.dart';
import '../../core/models.dart';
import '../../core/utils.dart';
import 'ott_badge.dart';

class StoryDetailsScreen extends StatelessWidget {
  const StoryDetailsScreen({super.key, required this.story});
  final Story story;

  // -- URL helpers ------------------------------------------------------------

  /// Prefer a playable video URL; fallback to canonical URL if present.
  Uri? get _linkUrl {
    final Uri? video = storyVideoUrl(story);
    if (video != null) return video;

    final String? raw = (story.url ?? '').trim();
    if (raw.isEmpty) return null;
    final Uri? parsed = Uri.tryParse(raw);
    if (parsed == null || !(parsed.isScheme('http') || parsed.isScheme('https'))) return null;
    return parsed;
  }

  bool get _isWatchCta {
    final host = _linkUrl?.host?.toLowerCase() ?? '';
    final kind = story.kind.toLowerCase();
    final source = (story.source ?? '').toLowerCase();
    final isYoutube = host.contains('youtube.com') || host.contains('youtu.be') || source == 'youtube';
    return isYoutube || kind == 'trailer';
  }

  String _ctaLabel() => _isWatchCta ? 'Watch' : 'Read';

  String _shareText() {
    // Prefer deep link (keeps users inside app). Fallback to the external link.
    final deep = deepLinkForStoryId(story.id).toString();
    if (deep.isNotEmpty) return deep;
    final link = _linkUrl?.toString();
    return (link != null && link.isNotEmpty) ? link : story.title;
    }

  Future<void> _openExternal(BuildContext context) async {
    final url = _linkUrl;
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

  // -- Meta line --------------------------------------------------------------

  String _metaLine() {
    final String ctx;
    if (story.isTheatrical) {
      ctx = story.isUpcoming ? 'Coming soon' : 'In theatres';
    } else {
      ctx = story.kind.toLowerCase() == 'ott' ? 'OTT' : _titleCase(story.kind);
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

    // Append source domain if available (e.g., variety.com / youtube.com)
    final String sourceDomain = (story.sourceDomain ?? '').trim();

    final parts = <String>[];
    if (ctx.isNotEmpty) parts.add(ctx);
    if (dateText.isNotEmpty) parts.add(dateText);
    if (extras.isNotEmpty) parts.add(extras.join(' • '));
    if (sourceDomain.isNotEmpty) parts.add(sourceDomain);
    return parts.join(' • ');
  }

  String _titleCase(String s) => s.isEmpty ? s : (s[0].toUpperCase() + s.substring(1));

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final onSurface = s.onSurface;
    final isPhone = MediaQuery.of(context).size.width < 600;
    final hasUrl = _linkUrl != null;

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
                      const SizedBox(height: 8),

                      // OTT badge + Meta line
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

                      // Summary (single short paragraph)
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
                          Semantics(
                            button: true,
                            label: _ctaLabel(),
                            enabled: hasUrl,
                            child: FilledButton.icon(
                              onPressed: hasUrl ? () => _openExternal(context) : null,
                              icon: Icon(_isWatchCta
                                  ? Icons.play_arrow_rounded
                                  : Icons.open_in_new_rounded),
                              label: Text(_ctaLabel()),
                            ),
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
                  errorWidget: (_, __, ___) => Container(
                    color: s.surfaceVariant.withOpacity(0.2),
                    child: const Center(child: Icon(Icons.broken_image_outlined)),
                  ),
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
