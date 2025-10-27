// lib/features/story/story_details.dart
//
// This version does JUST TWO visual syncs with StoryCard:
//
// 1. Meta line under the title now matches _MetaLine from story_card.dart:
//      [Release] 27 Oct 2025, 3:30 PM +6m
//
// 2. The CTA row now matches StoryCard bottom CTA row style:
//      [▶ Watch] [🔖] [📤]
//    (red Watch/Read pill button, then square Save + Share boxes,
//     all left-aligned, and no Spacer pushing Save to the far right)
//
// All other features/logic (hero header, inline player, share logic,
// saved/bookmark logic in the AppBar actions, source attribution text, etc.)
// stay the same.

import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart'; // deepLinkForStoryId, storyVideoUrl
import '../../core/cache.dart'; // SavedStore
import '../../core/models.dart';
import '../../widgets/smart_video_player.dart';
import 'story_image_url.dart'; // resolveStoryImageUrl

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
    final ok = await launchUrl(
      url,
      mode: kIsWeb ? LaunchMode.platformDefault : LaunchMode.externalApplication,
      webOnlyWindowName: kIsWeb ? '_blank' : null,
    );
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

  /* ---------------- Formatting helpers (copied from StoryCard logic) ----- */

  static const List<String> _mon = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  // "27 Oct 2025, 3:30 PM"
  String _formatMetaTimestamp(DateTime dt) {
    final d = dt.toLocal();
    final day = d.day;
    final m = _mon[d.month - 1];
    final y = d.year;

    var h = d.hour % 12;
    if (h == 0) h = 12;

    final mm = d.minute.toString().padLeft(2, '0');
    final ap = d.hour >= 12 ? 'PM' : 'AM';

    return '$day $m $y, $h:$mm $ap';
  }

  // "+6m", "+2h", "+1d"
  String _formatGapShort(Duration d) {
    final abs = d.isNegative ? -d : d;
    if (abs.inMinutes < 60) return '+${abs.inMinutes}m';
    if (abs.inHours < 48) return '+${abs.inHours}h';
    return '+${abs.inDays}d';
  }

  // 'release' -> 'Release', 'news' -> 'News', etc
  String _kindDisplay(String k) {
    final lower = k.toLowerCase();
    if (lower == 'ott') return 'OTT';
    if (lower.isEmpty) return '';
    return lower[0].toUpperCase() + lower.substring(1);
  }

  /* ---------------- UI ---------------- */

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

    // ----- NEW: figure out meta line data EXACTLY like StoryCard -------------
    final story = widget.story;
    final kindRaw = story.kind.toLowerCase();
    final String kindLabel = _kindDisplay(kindRaw);

    // timestamps
    final DateTime? publishedAt = story.publishedAt ?? story.releaseDate;
    final DateTime? addedAt = story.normalizedAt ?? story.ingestedAtCompat;

    final DateTime? primaryTs = publishedAt ?? addedAt;
    final String? primaryTsText =
        (primaryTs != null) ? _formatMetaTimestamp(primaryTs) : null;

    String? freshnessText;
    if (publishedAt != null && addedAt != null) {
      final diff = addedAt.difference(publishedAt);
      if (diff.inMinutes.abs() >= 1) {
        freshnessText = _formatGapShort(diff);
      }
    }
    // ------------------------------------------------------------------------

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

                      // ── NEW: meta line styled like StoryCard _MetaLine ──
                      _MetaLine(
                        kindRaw: kindRaw,
                        kindLabel: kindLabel,
                        timestampText: primaryTsText,
                        freshnessText: freshnessText,
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

                      // KEEPING facets block feature
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

                      // ── NEW CTA row: match StoryCard bottom row exactly ──
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Big red Watch/Read button
                          Semantics(
                            button: true,
                            label: _ctaLabel,
                            enabled: hasPrimary,
                            child: SizedBox(
                              height: 36,
                              child: ElevatedButton.icon(
                                onPressed: hasPrimary
                                    ? () {
                                        if (_hasVideo) {
                                          _openPlayerInHeader();
                                        } else {
                                          _openExternalPrimary(context);
                                        }
                                      }
                                    : null,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFdc2626),
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  minimumSize: const Size(0, 36),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(6),
                                    side: BorderSide(
                                      color: Colors.white.withOpacity(0.08),
                                      width: 1,
                                    ),
                                  ),
                                  textStyle: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                    height: 1.2,
                                  ),
                                ),
                                icon: _isWatchCta
                                    ? const Icon(
                                        Icons.play_arrow_rounded,
                                        size: 20,
                                        color: Colors.white,
                                      )
                                    : const _Emoji(
                                        emoji: '📖',
                                        size: 16,
                                      ),
                                label: Text(_ctaLabel),
                              ),
                            ),
                          ),

                          const SizedBox(width: 6),

                          // Save square 🔖
                          AnimatedBuilder(
                            animation: SavedStore.instance,
                            builder: (_, __) {
                              final saved = SavedStore.instance
                                  .isSaved(widget.story.id);
                              return _ActionIconBox(
                                tooltip: saved ? 'Saved' : 'Save',
                                onTap: () => SavedStore.instance
                                    .toggle(widget.story.id),
                                icon: const _Emoji(
                                  emoji: '🔖',
                                  size: 16,
                                ),
                              );
                            },
                          ),

                          const SizedBox(width: 6),

                          // Share square 📤
                          _ActionIconBox(
                            tooltip: 'Share',
                            onTap: () => _share(context),
                            icon: const _Emoji(
                              emoji: '📤',
                              size: 16,
                            ),
                          ),
                        ],
                      ),

                      // legal / source attribution footer (unchanged)
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

    final imgUrl = resolveStoryImageUrl(story);

    return Hero(
      tag: 'thumb-${story.id}',
      child: Stack(
        fit: StackFit.expand,
        children: [
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

          // inline player overlay
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

/* ---------------- Facet chip (kept for completeness) ---------------- */

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

/* ---------------- fallback icon for hero ---------------- */

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

/* ---------------- SAME helpers from StoryCard ---------------- */

class _KindStyle {
  final Color bg;
  final Color border;
  final Color text;
  const _KindStyle({
    required this.bg,
    required this.border,
    required this.text,
  });
}

// Pick badge colors by kind (Release red, News blue, etc).
_KindStyle _styleForKind(String rawKind) {
  final k = rawKind.toLowerCase().trim();

  const red = Color(0xFFdc2626);
  const blue = Color(0xFF3b82f6);
  const purple = Color(0xFF8b5cf6);
  const amber = Color(0xFFFACC15);
  const gray = Color(0xFF94a3b8);

  if (k.contains('release')) {
    return _KindStyle(
      bg: red.withOpacity(0.16),
      border: red.withOpacity(0.4),
      text: red,
    );
  }
  if (k.contains('news')) {
    return _KindStyle(
      bg: blue.withOpacity(0.16),
      border: blue.withOpacity(0.4),
      text: blue,
    );
  }
  if (k.contains('ott')) {
    return _KindStyle(
      bg: purple.withOpacity(0.16),
      border: purple.withOpacity(0.4),
      text: purple,
    );
  }
  if (k.contains('trailer')) {
    return _KindStyle(
      bg: amber.withOpacity(0.16),
      border: amber.withOpacity(0.4),
      text: amber,
    );
  }

  return _KindStyle(
    bg: gray.withOpacity(0.16),
    border: gray.withOpacity(0.4),
    text: gray,
  );
}

// Meta line row, exactly like StoryCard
class _MetaLine extends StatelessWidget {
  const _MetaLine({
    required this.kindRaw,
    required this.kindLabel,
    required this.timestampText,
    required this.freshnessText,
  });

  final String kindRaw;
  final String kindLabel;
  final String? timestampText;
  final String? freshnessText;

  @override
  Widget build(BuildContext context) {
    final accent = const Color(0xFFdc2626);
    final style = _styleForKind(kindRaw);

    final pill = kindLabel.isNotEmpty
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: style.bg,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: style.border,
                width: 1,
              ),
            ),
            child: Text(
              kindLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: style.text,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
          )
        : const SizedBox.shrink();

    final ts = (timestampText == null)
        ? const SizedBox.shrink()
        : Flexible(
            child: Text(
              timestampText!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                height: 1.3,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          );

    final fresh = (freshnessText == null)
        ? const SizedBox.shrink()
        : Text(
            freshnessText!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              height: 1.3,
              color: accent,
              fontWeight: FontWeight.w500,
            ),
          );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (kindLabel.isNotEmpty) pill,
        if (kindLabel.isNotEmpty && timestampText != null)
          const SizedBox(width: 6),
        if (timestampText != null) ts,
        if (freshnessText != null) const SizedBox(width: 6),
        if (freshnessText != null) fresh,
      ],
    );
  }
}

// Emoji text helper
class _Emoji extends StatelessWidget {
  const _Emoji({required this.emoji, this.size = 16});
  final String emoji;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Text(
      emoji,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: size,
        height: 1,
        fontFamily: null,
        fontFamilyFallback: const [
          'Apple Color Emoji',
          'Segoe UI Emoji',
          'Noto Color Emoji',
          'EmojiOne Color',
        ],
      ),
    );
  }
}

// Square Save / Share boxes, identical to StoryCard
class _ActionIconBox extends StatelessWidget {
  final Widget icon;
  final VoidCallback onTap;
  final String tooltip;

  const _ActionIconBox({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bgColor =
        isDark ? const Color(0xFF0b0f17) : Colors.black.withOpacity(0.06);

    final borderColor =
        isDark ? Colors.white.withOpacity(0.12) : Colors.black.withOpacity(0.12);

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: bgColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: borderColor, width: 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Center(child: icon),
          ),
        ),
      ),
    );
  }
}

/* ---------------- back-compat for ingestedAt from StoryCard ------------- */

extension _StoryCompat on Story {
  // Handle older payloads where "ingestedAt" might be nested.
  DateTime? get ingestedAtCompat {
    try {
      final dyn = (this as dynamic);
      final v = dyn.ingestedAt;
      if (v is DateTime) return v;
      if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
    } catch (_) {}

    try {
      final dyn = (this as dynamic);
      final extra = dyn.extra ?? dyn.metadata ?? dyn.payload ?? dyn.raw;
      if (extra is Map) {
        final raw = extra['ingested_at'] ?? extra['ingestedAt'];
        if (raw is DateTime) return raw;
        if (raw is String && raw.isNotEmpty) return DateTime.tryParse(raw);
      }
    } catch (_) {}

    return null;
  }
}
