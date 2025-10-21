// lib/features/story/story_details.dart
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';           // deepLinkForStoryId, storyVideoUrl
import '../../core/cache.dart';
import '../../core/models.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/smart_video_player.dart';
import 'ott_badge.dart';

class StoryDetailsScreen extends StatefulWidget {
  const StoryDetailsScreen({
    super.key,
    required this.story,
    this.autoplay = false, // ignored by design: player shows only on Watch tap
  });

  final Story story;
  final bool autoplay;

  @override
  State<StoryDetailsScreen> createState() => _StoryDetailsScreenState();
}

class _StoryDetailsScreenState extends State<StoryDetailsScreen> {
  // Player state (mounted in the HERO/header, not in the body)
  bool _showPlayer = false;
  final _heroPlayerKey = GlobalKey();

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

  /// Prefer inline playable video when present.
  Uri? get _primaryUrl => _videoUrl ?? _canonicalUrl;

  bool get _hasVideo => _videoUrl != null;

  bool get _isWatchCta {
    if (_hasVideo) return true;
    final host = _primaryUrl?.host.toLowerCase() ?? '';
    final kind = widget.story.kind.toLowerCase();
    final source = (widget.story.source ?? '').toLowerCase();
    final isYoutube = host.contains('youtube.com') || host.contains('youtu.be') || source == 'youtube';
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open link')),
      );
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
          SnackBar(content: Text(kIsWeb ? 'Link copied to clipboard' : 'Share sheet opened')),
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

  void _openPlayerInHeader() {
    if (!_hasVideo) return;
    setState(() => _showPlayer = true);

    // Ensure the header is visible after mounting the player
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _heroPlayerKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 350),
          alignment: 0.02, // near the top
        );
      }
    });
  }

  void _hidePlayer({String? toast}) {
    if (!mounted) return;
    setState(() => _showPlayer = false);
    if (toast != null && toast.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(toast)));
    }
  }

  /* --------------------------------- UI ------------------------------------ */

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final onSurface = cs.onSurface;
    final screenW = MediaQuery.of(context).size.width;
    final isPhone = screenW < 600;
    final hasPrimary = _primaryUrl != null;

    // When the player is visible, give the header more room (keep 16:9 nicely framed).
    final expandedHeight =
        _showPlayer ? (screenW * 9 / 16 + (isPhone ? 96 : 120)) : (isPhone ? 260 : 340);

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
            expandedHeight: expandedHeight,
            backgroundColor: cs.surface.withOpacity(0.95),
            surfaceTintColor: Colors.transparent,
            title: Text('CinePulse', style: GoogleFonts.inter(fontWeight: FontWeight.w800)),
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
              titlePadding: const EdgeInsetsDirectional.only(start: 56, bottom: 16, end: 16),
              stretchModes: const [StretchMode.zoomBackground, StretchMode.blurBackground],
              background: _HeaderHero(
                key: _heroPlayerKey,
                story: widget.story,
                showPlayer: _showPlayer,
                videoUrl: _videoUrl?.toString(),
                onClosePlayer: () => _hidePlayer(),
                onEndedPlayer: () => _hidePlayer(),
                onErrorPlayer: (e) => _hidePlayer(
                  toast: (e.toString().trim().isNotEmpty) ? e.toString() : 'Playback error',
                ),
              ),
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

                      // Kind badge + OTT badge + Meta line
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          KindBadge(widget.story.kindLabel ?? widget.story.kind),
                          OttBadge.fromStory(widget.story, dense: true),
                          Text(
                            widget.story.metaLine,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      // Summary (single short paragraph)
                      if ((widget.story.summary ?? '').isNotEmpty)
                        Text(
                          widget.story.summary!,
                          style: GoogleFonts.inter(fontSize: 16, height: 1.4, color: onSurface),
                        ),

                      // Optional facets (languages/genres) if present
                      if (widget.story.languages.isNotEmpty || widget.story.genres.isNotEmpty) ...[
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

                      // Primary CTA + Share + Save
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
                                        _openPlayerInHeader();
                                      } else {
                                        _openExternalPrimary(context);
                                      }
                                    }
                                  : null,
                              icon: Icon(_isWatchCta
                                  ? Icons.play_arrow_rounded
                                  : Icons.open_in_new_rounded),
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
  const _HeaderHero({
    super.key,
    required this.story,
    required this.showPlayer,
    required this.videoUrl,
    required this.onClosePlayer,
    required this.onEndedPlayer,
    required this.onErrorPlayer,
  });

  final Story story;
  final bool showPlayer;
  final String? videoUrl;
  final VoidCallback onClosePlayer;
  final VoidCallback onEndedPlayer;
  final ValueChanged<Object> onErrorPlayer;

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
          // Background image (always present under the player)
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

          // When player is visible, center it and constrain width
          if (showPlayer && (videoUrl?.isNotEmpty ?? false))
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: SmartVideoPlayer(
                      url: videoUrl!,
                      autoPlay: true,
                      onEnded: onEndedPlayer,
                      onClose: onClosePlayer,
                      onError: onErrorPlayer,
                    ),
                  ),
                ),
              ),
            )
          else
            // Gradient for legibility on top of the poster
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black.withOpacity(0.55), Colors.transparent],
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
