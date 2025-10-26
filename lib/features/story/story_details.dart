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
import '../../core/models.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/smart_video_player.dart';
import 'ott_badge.dart';

class StoryDetailsScreen extends StatefulWidget {
  const StoryDetailsScreen({
    super.key,
    required this.story,
    this.autoplay = false, // autoplay is only relevant for inline video
  });

  final Story story;
  final bool autoplay;

  @override
  State<StoryDetailsScreen> createState() => _StoryDetailsScreenState();
}

class _StoryDetailsScreenState extends State<StoryDetailsScreen> {
  // video player is mounted inline in the hero/header when active
  bool _showPlayer = false;
  final _heroPlayerKey = GlobalKey();

  /* ---------------- URL helpers ---------------- */

  Uri? get _videoUrl => storyVideoUrl(widget.story);

  Uri? get _canonicalUrl {
    final raw = (widget.story.url ?? '').trim();
    if (raw.isEmpty) return null;
    final u = Uri.tryParse(raw);
    if (u == null) return null;
    if (!(u.isScheme('http') || u.isScheme('https'))) return null;
    return u;
  }

  /// Prefer an inline playable URL (YouTube etc.) over just the article link.
  Uri? get _primaryUrl => _videoUrl ?? _canonicalUrl;

  bool get _hasVideo => _videoUrl != null;

  bool get _isWatchCta {
    if (_hasVideo) return true;
    final host = _primaryUrl?.host.toLowerCase() ?? '';
    final kind = widget.story.kind.toLowerCase();
    final source = (widget.story.source ?? '').toLowerCase();
    final isYoutube = host.contains('youtube.com') ||
        host.contains('youtu.be') ||
        source == 'youtube';
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
          SnackBar(
            content: Text(
              kIsWeb ? 'Link copied to clipboard' : 'Share sheet opened',
            ),
          ),
        );
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copied to clipboard')),
        );
      }
    }
  }

  void _openPlayerInHeader() {
    if (!_hasVideo) return;
    setState(() => _showPlayer = true);

    // after mounting the player, scroll hero back into view
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _heroPlayerKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 350),
          alignment: 0.02,
        );
      }
    });
  }

  void _hidePlayer({String? toast}) {
    if (!mounted) return;
    setState(() => _showPlayer = false);
    if (toast != null && toast.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(toast)),
      );
    }
  }

  /* ---------------- UI ---------------- */

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final onSurface = cs.onSurface;

    final screenW = MediaQuery.of(context).size.width;
    final isPhone = screenW < 600;
    final hasPrimary = _primaryUrl != null;

    // dynamic app bar height:
    // - if player is showing: reserve 16:9 video box + controls row height
    // - else: fixed hero height (taller on tablet/desktop)
    final double expandedHeight = _showPlayer
        ? (screenW * 9.0 / 16.0 + (isPhone ? 96.0 : 120.0))
        : (isPhone ? 260.0 : 340.0);

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
                    tooltip: saved
                        ? 'Remove from Saved'
                        : 'Save bookmark',
                    onPressed: () =>
                        SavedStore.instance.toggle(widget.story.id),
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
                onPressed: () => _share(context),
                icon: const Icon(Icons.ios_share),
              ),
              const SizedBox(width: 4),
            ],
            flexibleSpace: FlexibleSpaceBar(
              collapseMode: CollapseMode.parallax,
              titlePadding: const EdgeInsetsDirectional.only(
                start: 56,
                bottom: 16,
                end: 16,
              ),
              stretchModes: const [
                StretchMode.zoomBackground,
                StretchMode.blurBackground,
              ],
              background: _HeaderHero(
                key: _heroPlayerKey,
                story: widget.story,
                showPlayer: _showPlayer,
                videoUrl: _videoUrl?.toString(),
                onClosePlayer: () => _hidePlayer(),
                onEndedPlayer: () => _hidePlayer(),
                onErrorPlayer: (e) => _hidePlayer(
                  toast: (e.toString().trim().isNotEmpty)
                      ? e.toString()
                      : 'Playback error',
                ),
              ),
            ),
          ),

          // body content
          SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Padding(
                  // big bottom pad so the bottom nav doesn't cover CTA
                  padding: const EdgeInsets.fromLTRB(
                    16,
                    16,
                    16,
                    96,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // title
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

                      // badges row
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          KindBadge(
                            widget.story.kindLabel ??
                                widget.story.kind,
                          ),
                          OttBadge.fromStory(
                            widget.story,
                            dense: true,
                          ),
                          Text(
                            widget.story.metaLine,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      // summary / description
                      if ((widget.story.summary ?? '').isNotEmpty)
                        Text(
                          widget.story.summary!,
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            height: 1.4,
                            color: onSurface,
                          ),
                        ),

                      // optional language / genre chips
                      if (widget.story.languages.isNotEmpty ||
                          widget.story.genres.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (widget.story.languages.isNotEmpty)
                              _Facet(
                                label: 'Language',
                                value: widget.story.languages
                                    .join(', '),
                              ),
                            if (widget.story.genres.isNotEmpty)
                              _Facet(
                                label: 'Genre',
                                value: widget.story.genres
                                    .join(', '),
                              ),
                          ],
                        ),
                      ],

                      const SizedBox(height: 20),

                      // CTA row
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
                                        _openExternalPrimary(
                                          context,
                                        );
                                      }
                                    }
                                  : null,
                              icon: Icon(
                                _isWatchCta
                                    ? Icons.play_arrow_rounded
                                    : Icons
                                        .open_in_new_rounded,
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
                              final saved = SavedStore.instance
                                  .isSaved(widget.story.id);
                              return IconButton.filledTonal(
                                tooltip: saved
                                    ? 'Remove from Saved'
                                    : 'Save bookmark',
                                onPressed: () =>
                                    SavedStore.instance
                                        .toggle(widget.story.id),
                                icon: Icon(
                                  saved
                                      ? Icons.bookmark
                                      : Icons.bookmark_add,
                                ),
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

/* ---------------- HEADER HERO (image + optional player) ---------------- */

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

  // same idea as StoryCard._cleanImageUrl(), plus stricter /v1/img rejection
  String _cleanImageUrlForStory(Story s) {
    // prefer posterUrl, fallback to thumbUrl
    final cand = (s.posterUrl?.isNotEmpty == true)
        ? s.posterUrl!
        : (s.thumbUrl ?? '');

    if (cand.isEmpty) return '';

    // 1. nuke obvious garbage domains
    if (cand.contains('demo.tagdiv.com')) return '';

    final uri = Uri.tryParse(cand);
    if (uri != null) {
      final pathLower = uri.path.toLowerCase();

      // 2. if it's our proxy (/v1/img?...), just don't use it in detail header.
      //    on web this causes CORS + 404 noise.
      if (pathLower.contains('/v1/img')) {
        return '';
      }

      // 3. if proxy-style URL has an inner "u"/"url" param that points to
      //    demo.tagdiv.com, also reject
      final inner =
          uri.queryParameters['u'] ?? uri.queryParameters['url'] ?? '';
      if (inner.contains('demo.tagdiv.com')) {
        return '';
      }
    }

    return cand;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final imgUrl = _cleanImageUrlForStory(story);

    return Hero(
      tag: 'thumb-${story.id}',
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. background image OR gradient fallback
          if (imgUrl.isNotEmpty)
            CachedNetworkImage(
              imageUrl: imgUrl,
              fit: BoxFit.cover,
              alignment: Alignment.center,
              memCacheWidth: 1600,
              fadeInDuration: const Duration(milliseconds: 180),
              errorWidget: (_, __, ___) => Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      isDark
                          ? const Color(0xFF0F1625)
                          : cs.surfaceVariant.withOpacity(0.2),
                      isDark
                          ? const Color(0xFF1E2433)
                          : cs.surfaceVariant.withOpacity(0.4),
                    ],
                  ),
                ),
                child: Center(
                  child: _SampleIcon(kind: story.kind),
                ),
              ),
            )
          else
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    isDark
                        ? const Color(0xFF0F1625)
                        : cs.surfaceVariant.withOpacity(0.2),
                    isDark
                        ? const Color(0xFF1E2433)
                        : cs.surfaceVariant.withOpacity(0.4),
                  ],
                ),
              ),
              child: Center(
                child: _SampleIcon(kind: story.kind),
              ),
            ),

          // 2. if player is active, overlay the player
          if (showPlayer && (videoUrl?.isNotEmpty ?? false))
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
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
            // 3. otherwise dark gradient at bottom so title area is readable
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

/* ---------------- Facet chip ---------------- */

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
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ],
      ),
    );
  }
}

/* ---------------- fallback icon (same vibe as StoryCard) ---------------- */

class _SampleIcon extends StatelessWidget {
  const _SampleIcon({required this.kind});
  final String kind;

  @override
  Widget build(BuildContext context) {
    IconData iconData = Icons.movie_rounded;
    Color iconColor = const Color(0xFFECC943);

    final lower = kind.toLowerCase();
    if (lower.contains('trailer')) {
      iconData = Icons.theater_comedy_rounded;
      iconColor = const Color(0xFF56BAF8);
    } else if (lower.contains('release')) {
      iconData = Icons.balance_rounded;
      iconColor = const Color(0xFFF9D359);
    } else if (lower.contains('ott')) {
      iconData = Icons.videocam_rounded;
      iconColor = const Color(0xFFC377F2);
    }

    return Icon(
      iconData,
      size: 60,
      color: iconColor.withOpacity(0.9),
    );
  }
}
