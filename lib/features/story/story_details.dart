// lib/features/story/story_details.dart
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart'; // deepLinkForStoryId, storyVideoUrl
import '../../core/cache.dart';
import '../../core/models.dart'; // Story + metaLine
import '../../core/utils.dart'; // fadeRoute()
import '../../widgets/kind_badge.dart'; // reusable KindBadge
import '../../widgets/smart_video_player.dart';
import 'ott_badge.dart';

class StoryDetailsScreen extends StatefulWidget {
  const StoryDetailsScreen({
    super.key,
    required this.story,
    this.autoplay = false,
  });

  final Story story;
  final bool autoplay;

  @override
  State<StoryDetailsScreen> createState() => _StoryDetailsScreenState();
}

class _StoryDetailsScreenState extends State<StoryDetailsScreen> {
  final _playerKey = GlobalKey();
  late bool _showPlayer;

  /* ------------------------------ URL helpers ------------------------------ */

  Uri? get _videoUrl => storyVideoUrl(widget.story);

  Uri? get _canonicalUrl {
    final raw = (widget.story.url ?? '').trim();
    if (raw.isEmpty) return null;
    final u = Uri.tryParse(raw);
    if (u == null) return null;
    if (!(u.isScheme('http') || u.isScheme('https'))) return null;
    return u;
  }

  /// Primary link preference: playable video if available, else article URL.
  Uri? get _primaryUrl => _videoUrl ?? _canonicalUrl;

  bool get _hasVideo => _videoUrl != null;

  bool get _isWatchCta {
    // Prefer "Watch" when we have any playable video URL.
    if (_hasVideo) return true;
    // Fallback heuristics (kept for parity with old behavior)
    final host = _primaryUrl?.host.toLowerCase() ?? '';
    final kind = widget.story.kind.toLowerCase();
    final source = (widget.story.source ?? '').toLowerCase();
    final isYoutube =
        host.contains('youtube.com') || host.contains('youtu.be') || source == 'youtube';
    return isYoutube || kind == 'trailer';
  }

  String get _ctaLabel => _isWatchCta ? 'Watch' : 'Read';

  String _shareText() {
    final deep = deepLinkForStoryId(widget.story.id).toString();
    if (deep.isNotEmpty) return deep;
    final link = _primaryUrl?.toString();
    return (link != null && link.isNotEmpty) ? link : widget.story.title;
  }

  Future<void> _openExternalPrimary(BuildContext context) async {
    final url = _primaryUrl;
    if (url == null) return;
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

  void _openPlayerInline() {
    if (!_hasVideo) return;
    setState(() => _showPlayer = true);
    // Scroll the player into view after layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _playerKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 350));
      }
    });
  }

  /* --------------------------------- UI ------------------------------------ */

  @override
  void initState() {
    super.initState();
    _showPlayer = widget.autoplay && _hasVideo;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final onSurface = cs.onSurface;
    final isPhone = MediaQuery.of(context).size.width < 600;
    final hasPrimary = _primaryUrl != null;

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
            expandedHeight: isPhone ? 260 : 340,
            backgroundColor: cs.surface.withOpacity(0.95),
            surfaceTintColor: Colors.transparent,
            title: Text(
              'CinePulse',
              style: GoogleFonts.inter(fontWeight: FontWeight.w800),
            ),
            actions: [
              AnimatedBuilder(
                animation: SavedStore.instance,
                builder: (_, __) {
                  final saved = SavedStore.instance.isSaved(widget.story.id);
                  return IconButton(
                    tooltip: saved ? 'Remove from Saved' : 'Save bookmark',
                    onPressed: () => SavedStore.instance.toggle(widget.story.id),
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
              background: _HeaderHero(story: widget.story),
            ),
          ),

          // Body
          SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), // extra bottom for nav
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title
                      Text(
                        widget.story.title,
                        style: GoogleFonts.inter(
                          fontSize: 22,
                          height: 1.22,
                          fontWeight: FontWeight.w800,
                          color: onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),

                      // Kind badge + OTT badge + Meta line ("News • 20 Oct 2025, 1:59 PM")
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          KindBadge(widget.story.kindLabel ?? widget.story.kind),
                          OttBadge.fromStory(widget.story, dense: true),
                          Text(
                            widget.story.metaLine,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      // Inline player (only when requested or autoplayed)
                      if (_hasVideo && _showPlayer) ...[
                        KeyedSubtree(
                          key: _playerKey,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: SmartVideoPlayer(
                              url: _videoUrl!.toString(),
                              autoPlay: true,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Summary (single short paragraph)
                      if ((widget.story.summary ?? '').isNotEmpty)
                        Text(
                          widget.story.summary!,
                          style: GoogleFonts.inter(fontSize: 16, height: 1.4, color: onSurface),
                        ),

                      // Optional facets (languages/genres) if present
                      if (widget.story.languages.isNotEmpty ||
                          widget.story.genres.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (widget.story.languages.isNotEmpty)
                              _Facet(label: 'Language', value: widget.story.languages.join(', ')),
                            if (widget.story.genres.isNotEmpty)
                              _Facet(label: 'Genre', value: widget.story.genres.join(', ')),
                          ],
                        ),
                      ],

                      const SizedBox(height: 20),

                      // Single primary CTA + Share + Save
                      Row(
                        children: [
                          Semantics(
                            button: true,
                            label: _ctaLabel,
                            enabled: hasPrimary,
                            child: FilledButton.icon(
                              onPressed: hasPrimary
                                  ? () {
                                      if (_hasVideo) {
                                        _openPlayerInline();
                                      } else {
                                        _openExternalPrimary(context);
                                      }
                                    }
                                  : null,
                              icon: Icon(
                                _isWatchCta
                                    ? Icons.play_arrow_rounded
                                    : Icons.open_in_new_rounded,
                              ),
                              label: Text(_ctaLabel),
                            ),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton.icon(
                            onPressed: () => _share(context),
                            icon: const Icon(Icons.ios_share),
                            label: const Text('Share'),
                          ),
                          const Spacer(),
                          AnimatedBuilder(
                            animation: SavedStore.instance,
                            builder: (_, __) {
                              final saved = SavedStore.instance.isSaved(widget.story.id);
                              return IconButton.filledTonal(
                                tooltip: saved ? 'Remove from Saved' : 'Save bookmark',
                                onPressed: () => SavedStore.instance.toggle(widget.story.id),
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
    final cs = Theme.of(context).colorScheme;
    final imageUrl =
        (story.posterUrl?.isNotEmpty == true) ? story.posterUrl! : (story.thumbUrl ?? '');

    return Hero(
      tag: 'thumb-${story.id}',
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Image or fallback color
          imageUrl.isEmpty
              ? Container(color: cs.surfaceContainerHighest)
              : CachedNetworkImage(
                  imageUrl: imageUrl,
                  fit: BoxFit.cover,
                  memCacheWidth: 1600,
                  fadeInDuration: const Duration(milliseconds: 180),
                  errorWidget: (_, __, ___) => Container(
                    color: cs.surfaceVariant.withOpacity(0.2),
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
                    Colors.black.withOpacity(0.55),
                    Colors.transparent,
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
