// lib/features/story/story_details.dart
//
// Notes in this version:
// - Meta row under the title now matches the card style
//   (pill(s) + timestamp + freshness, no "•" bullets).
// - CTA row order/align now matches the mock:
//   [Watch/Read] [Save] [Share] all left-aligned.
// - All other behavior is unchanged.

import 'dart:math' as math;

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
import 'story_image_url.dart'; // shared image sanitizing / fallback logic

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
  // inline video player state (lives in the header hero)
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

  /// Prefer inline playable URL over article URL.
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
    // prefer our deep link
    final deep = deepLinkForStoryId(widget.story.id).toString();
    if (deep.isNotEmpty) return deep;
    // fallback to upstream link
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

    // after mounting player, make sure header is visible
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

  /* ---------------- Source attribution helpers ---------------- */

  // remove leading "rss:" or "rss " or "rss-" etc.
  String _cleanupSourcePiece(String s) {
    var out = s.trim();
    out = out.replaceFirst(RegExp(r'^\s*rss[:\s-]+', caseSensitive: false), '');
    return out.trim();
  }

  // Build "YouTube / BollywoodHungama.com" style attribution for footer
  String _sourceAttribution(Story s) {
    final aRaw = (s.source ?? '').trim();
    final bRaw = (s.sourceDomain ?? '').trim();

    final a = _cleanupSourcePiece(aRaw);
    final b = _cleanupSourcePiece(bRaw);

    if (a.isNotEmpty && b.isNotEmpty) {
      // Avoid duplicating if they basically match each other
      final al = a.toLowerCase();
      final bl = b.toLowerCase();
      if (bl.contains(al) || al.contains(bl)) {
        return a.isNotEmpty ? a : b;
      }
      return '$a / $b';
    }
    if (a.isNotEmpty) return a;
    if (b.isNotEmpty) return b;
    return '';
  }

  /* ---------------- Small helpers for UI rows ---------------- */

  /// Build RichText spans for the meta line under the title,
  /// matching the card style:
  ///   [Release] [Netflix] Fri 27 Oct 2025, 3:30 PM +6m
  /// We:
  ///   - strip the "•" bullets from story.metaLine
  ///   - color any trailing "+6m"/"+1h"/etc. in red
  InlineSpan _buildMetaRichSpan(Color baseColor) {
    final meta = (widget.story.metaLine).trim();
    if (meta.isEmpty) {
      return TextSpan(text: '', style: TextStyle(color: baseColor));
    }

    // Split on "•" so we can drop the bullets and insert spacing instead.
    final parts = meta.split('•').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();

    final spans = <TextSpan>[];
    for (var i = 0; i < parts.length; i++) {
      final chunk = parts[i];

      // Add manual "  " spacing instead of the bullet.
      if (i != 0) {
        spans.add(TextSpan(text: '  ', style: TextStyle(color: baseColor)));
      }

      // If the chunk looks like "+6m", "+1h", etc. -> highlight red accent.
      final looksFreshness = chunk.startsWith('+') || chunk.startsWith('-');
      spans.add(
        TextSpan(
          text: chunk,
          style: TextStyle(
            color: looksFreshness ? const Color(0xFFdc2626) : baseColor,
            fontWeight: looksFreshness ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      );
    }

    return TextSpan(
      children: spans,
      style: TextStyle(
        fontSize: 13,
        height: 1.3,
        color: baseColor,
        fontWeight: FontWeight.w400,
      ),
    );
  }

  /// One row under the title:
  /// [KindBadge?] [OttBadge?] <timestamp + freshness>
  Widget _MetaRow({
    required Color textColor,
    required bool kindIsNews,
  }) {
    final chips = <Widget>[];

    // only show the big colored kind badge if it's *not* plain "news"
    if (!kindIsNews) {
      chips.add(KindBadge(widget.story.kindLabel ?? widget.story.kind));
    }

    // show OTT / platform chip like "YouTube" / "Netflix" etc.
    chips.add(
      OttBadge.fromStory(
        widget.story,
        dense: true,
      ),
    );

    // meta timestamp / +Xm freshness as RichText
    final metaText = RichText(
      text: _buildMetaRichSpan(textColor),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // chips with small horizontal gaps
        ...chips.where((w) => w is! SizedBox || (w as SizedBox).child != null).map((w) {
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: w,
          );
        }),

        // timestamp/+Xm
        Expanded(child: metaText),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final onSurface = cs.onSurface;

    final screenW = MediaQuery.of(context).size.width;
    final isPhone = screenW < 600;
    final hasPrimary = _primaryUrl != null;

    // hero height logic (~16:9, capped, expands if inline player is visible)
    final desired16x9 = screenW * 9.0 / 16.0;
    final maxHeightCap = isPhone ? 340.0 : 400.0;
    final baseHeroHeight = math.min(desired16x9, maxHeightCap);

    final double expandedHeight = _showPlayer
        ? (desired16x9 + (isPhone ? 96.0 : 120.0))
        : baseHeroHeight;

    // cleaned attribution footer string
    final attribution = _sourceAttribution(widget.story);

    // decide if we should draw the big colored badge:
    // hide for plain "news"
    final storyKindDisplay = widget.story.kindLabel ?? widget.story.kind;
    final kindIsNews = storyKindDisplay.toLowerCase() == 'news';

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
                    tooltip: saved ? 'Remove from Saved' : 'Save bookmark',
                    onPressed: () => SavedStore.instance.toggle(widget.story.id),
                    icon: Icon(
                      saved ? Icons.bookmark : Icons.bookmark_add_outlined,
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
                  // bottom padding so bottom nav bar doesn't hide footer/CTA
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
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

                      // NEW meta row (was Wrap before)
                      _MetaRow(
                        textColor: cs.onSurfaceVariant,
                        kindIsNews: kindIsNews,
                      ),

                      const SizedBox(height: 16),

                      // summary
                      if ((widget.story.summary ?? '').isNotEmpty)
                        Text(
                          widget.story.summary!,
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            height: 1.4,
                            color: onSurface,
                          ),
                        ),

                      // optional facets (Language / Genre chips)
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
                                value: widget.story.languages.join(', '),
                              ),
                            if (widget.story.genres.isNotEmpty)
                              _Facet(
                                label: 'Genre',
                                value: widget.story.genres.join(', '),
                              ),
                          ],
                        ),
                      ],

                      const SizedBox(height: 20),

                      // CTA row (reordered / left aligned)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          // Watch / Read
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
                              icon: Icon(
                                _isWatchCta
                                    ? Icons.play_arrow_rounded
                                    : Icons.open_in_new_rounded,
                              ),
                              label: Text(_ctaLabel),
                            ),
                          ),

                          const SizedBox(width: 10),

                          // Save bookmark (icon-only tonal)
                          AnimatedBuilder(
                            animation: SavedStore.instance,
                            builder: (_, __) {
                              final saved =
                                  SavedStore.instance.isSaved(widget.story.id);
                              return IconButton.filledTonal(
                                tooltip: saved
                                    ? 'Remove from Saved'
                                    : 'Save bookmark',
                                onPressed: () =>
                                    SavedStore.instance.toggle(widget.story.id),
                                icon: Icon(
                                  saved
                                      ? Icons.bookmark
                                      : Icons.bookmark_add,
                                ),
                              );
                            },
                          ),

                          const SizedBox(width: 10),

                          // Share
                          OutlinedButton.icon(
                            onPressed: () => _share(context),
                            icon: const Icon(Icons.ios_share),
                            label: const Text('Share'),
                          ),
                        ],
                      ),

                      // legal / source attribution footer
                      if (attribution.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        Text(
                          'Source: $attribution',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            height: 1.3,
                            fontWeight: FontWeight.w500,
                            color: cs.onSurfaceVariant.withOpacity(0.7),
                          ),
                        ),
                      ],
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

/* ---------------- HEADER HERO ---------------- */

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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // unified "safe hero" URL (proxy cleaned, demo.tagdiv nuked, etc.)
    final imgUrl = resolveStoryImageUrl(story);

    return Hero(
      tag: 'thumb-${story.id}',
      child: Stack(
        fit: StackFit.expand,
        children: [
          // hero background image or nice gradient fallback
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

          // inline player overlay (only when user taps Watch)
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
            // dark gradient at the bottom for contrast
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

/* ---------------- fallback icon ---------------- */

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
