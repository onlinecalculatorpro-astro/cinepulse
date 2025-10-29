// lib/features/story/story_card.dart
//
// StoryCard
// -----------------------------------------------------------------------------
// This is the tile used in Home / Discover / Saved / Alerts.
//
// Visual goals (mirrors SkeletonCard):
// - Rounded 22px card
// - Soft 2px border
// - Gentle drop shadow
// - Responsive media block up top
// - Body with:
//      • meta row (kind pill + timestamp + "+6m")
//      • title (3 lines max)
//      • optional summary (2–3 lines)
//      • bottom row: [ big red CTA ] [ Save ] [ Share ]
//        then a tiny "Source: example.com"
//
// Behavior:
// - Tapping anywhere on the card opens StoryPagerScreen.
// - CTA button:
//     • Label is "Watch" for clips/trailers/video-like things, else "Read".
//     • If it's a playable clip we understand, we jump into pager with autoplay.
//       Otherwise we just open the external link.
// - Save toggles SavedStore.
// - Share copies deep link on web, opens native sheet on device.
//
// Theming:
// - Card background and border match SkeletonCard so loading feels smooth.
// - All text pulls from theme_colors.dart for contrast in both dark/light.
// - Accent red is #dc2626 across the app.
//
// Layout details:
// - Media height depends on the card width (to keep grid harmonious).
// - We reserve bottom space so the CTA row doesn't overlap the title/summary
//   even with large text scale.
// - Thumbnail uses Hero(tag: 'thumb-<id>') for a snappy open transition.
//
// Data resilience:
// - We try multiple possible timestamp fields (publishedAt, releaseDate, etc.).
// - We try to guess "Watch" vs "Read" based on URL / kind / source.
//
// Dependencies:
//   cached_network_image
//   share_plus
//   url_launcher
//   google_fonts
//
// Local helpers referenced:
//   SavedStore                (core/cache.dart)
//   deepLinkForStoryId()      (core/utils.dart)
//   StoryPagerScreen          (features/story/story_pager.dart)
//   resolveStoryImageUrl()    (features/story/story_image_url.dart)
//   storyVideoUrl()           (core/api.dart)
// -----------------------------------------------------------------------------

import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart'; // storyVideoUrl
import '../../core/cache.dart'; // SavedStore
import '../../core/models.dart';
import '../../core/utils.dart'; // fadeRoute(), deepLinkForStoryId()
import '../../theme/theme_colors.dart'; // primaryTextColor(), secondaryTextColor(), faintTextColor()
import 'story_image_url.dart'; // resolveStoryImageUrl()
import 'story_pager.dart'; // StoryPagerScreen

class StoryCard extends StatefulWidget {
  const StoryCard({
    super.key,
    required this.story,
    this.allStories,
    this.index,
  });

  /// Story content for this tile.
  final Story story;

  /// Full list of stories currently rendered in the grid (for swipe paging).
  final List<Story>? allStories;

  /// Index of this story within [allStories].
  final int? index;

  @override
  State<StoryCard> createState() => _StoryCardState();
}

class _StoryCardState extends State<StoryCard> {
  static const _accent = Color(0xFFdc2626);

  /* ───────────────────────── CTA / URL helpers ───────────────────────── */

  Uri? get _videoUrl => storyVideoUrl(widget.story);

  /// Primary link to open (video URL wins, else story.url).
  Uri? get _primaryUrl {
    final v = _videoUrl;
    if (v != null) return v;

    final raw = (widget.story.url ?? '').trim();
    if (raw.isEmpty) return null;

    final u = Uri.tryParse(raw);
    if (u == null) return null;
    final httpish = u.isScheme('http') || u.isScheme('https');
    return httpish ? u : null;
  }

  /// Decide if CTA should say "Watch" vs "Read".
  bool get _isWatchCta {
    if (_videoUrl != null) return true;

    final host = _primaryUrl?.host?.toLowerCase() ?? '';
    final kindL = widget.story.kind.toLowerCase();
    final srcL = (widget.story.source ?? '').toLowerCase();

    final youtubeLike =
        host.contains('youtube.com') || host.contains('youtu.be');
    final looksLikeTrailer = kindL.contains('trailer') || kindL.contains('clip');
    final sourceSoundsVideo =
        srcL.contains('youtube') || srcL.contains('yt');

    return youtubeLike || looksLikeTrailer || sourceSoundsVideo;
  }

  String get _ctaLabel => _isWatchCta ? 'Watch' : 'Read';

  Future<void> _openPrimaryLink(BuildContext context) async {
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

  Future<void> _shareStory(BuildContext context) async {
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
          content: Text(
            kIsWeb ? 'Link copied to clipboard' : 'Share sheet opened',
          ),
        ),
      );
    } catch (_) {
      // Fallback: just copy.
      await Clipboard.setData(ClipboardData(text: deep));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copied to clipboard')),
        );
      }
    }
  }

  List<Story> get _storiesForPager {
    final list = widget.allStories;
    if (list != null && list.isNotEmpty) return list;
    return [widget.story];
  }

  int get _initialPagerIndex {
    final i = widget.index ?? 0;
    return i >= 0 ? i : 0;
  }

  void _openDetails({bool autoplay = false}) {
    Navigator.of(context).push(
      fadeRoute(
        StoryPagerScreen(
          stories: _storiesForPager,
          initialIndex: _initialPagerIndex,
          autoplayInitial: autoplay,
        ),
      ),
    );
  }

  /* ───────────────────────── Timestamp helpers ───────────────────────── */

  static const List<String> _mon = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  // "27 Oct 2025, 3:30 PM"
  String _fmtFullTs(DateTime dt) {
    final d = dt.toLocal();
    final dd = d.day;
    final m = _mon[d.month - 1];
    final y = d.year;

    var h = d.hour % 12;
    if (h == 0) h = 12;

    final mm = d.minute.toString().padLeft(2, '0');
    final ap = d.hour >= 12 ? 'PM' : 'AM';

    return '$dd $m $y, $h:$mm $ap';
  }

  // "+6m", "+2h", "+1d"
  String _fmtAgeShort(Duration delta) {
    final abs = delta.isNegative ? -delta : delta;
    if (abs.inMinutes < 60) return '+${abs.inMinutes}m';
    if (abs.inHours < 48) return '+${abs.inHours}h';
    return '+${abs.inDays}d';
  }

  /* ───────────────────── Story data helpers ───────────────────── */

  String get _kindRaw => widget.story.kind.toLowerCase().trim();

  String get _kindLabel {
    if (_kindRaw.isEmpty) return '';
    if (_kindRaw == 'ott') return 'OTT';
    return _kindRaw[0].toUpperCase() + _kindRaw.substring(1);
  }

  /// Which timestamp do we surface?
  /// Priority: publishedAt -> releaseDate -> normalizedAt -> ingestedAtCompat.
  DateTime? get _primaryTimestamp {
    return widget.story.publishedAt ??
        widget.story.releaseDate ??
        widget.story.normalizedAt ??
        widget.story.ingestedAtCompat;
  }

  /// e.g. "youtube.com" or "koimoi.com"
  String _sourceDomain(Story s) {
    final dom = (s.sourceDomain ?? '').trim();
    if (dom.isNotEmpty) return dom;
    final src = (s.source ?? '').trim();
    if (src.isNotEmpty) return src;
    return '';
  }

  /* ────────────────────────────── build() ────────────────────────────── */

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final story = widget.story;
    final imgUrl = resolveStoryImageUrl(story);

    // meta row timestamps / freshness
    final ts = _primaryTimestamp;
    final tsText = (ts != null) ? _fmtFullTs(ts) : null;

    String? freshnessText;
    if (story.publishedAt != null && story.normalizedAt != null) {
      final diff = story.normalizedAt!.difference(story.publishedAt!);
      if (diff.inMinutes.abs() >= 1) {
        freshnessText = _fmtAgeShort(diff);
      }
    }

    final domain = _sourceDomain(story);

    // Card chrome (matches SkeletonCard)
    final cardBg =
        cs.surface.withOpacity(isDark ? 0.92 : 0.97); // frosted feel
    final borderColor = Colors.white.withOpacity(0.08);

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: borderColor, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          // Whole card tap → open pager.
          onTap: () => _openDetails(
            autoplay: _isWatchCta && _videoUrl != null,
          ),
          child: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              final h = box.maxHeight;

              // Responsive media height (same math we used in SkeletonCard)
              final targetAspect = w >= 1200
                  ? (16 / 7)
                  : w >= 900
                      ? (16 / 9)
                      : w >= 600
                          ? (3 / 2)
                          : (4 / 3);

              final mediaH = (w / targetAspect)
                  .clamp(120.0, math.max(140.0, h.isFinite ? h * 0.45 : 220.0));

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  /* ───── Thumbnail / Hero ───── */
                  SizedBox(
                    height: mediaH.toDouble(),
                    child: Hero(
                      tag: 'thumb-${story.id}',
                      child: ClipRect(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (imgUrl.isNotEmpty)
                              CachedNetworkImage(
                                imageUrl: imgUrl,
                                fit: BoxFit.cover,
                                alignment: Alignment.topCenter,
                                memCacheWidth:
                                    (w.isFinite ? (w * 2).toInt() : 1600),
                                fadeInDuration:
                                    const Duration(milliseconds: 160),
                                errorWidget: (_, __, ___) => _FallbackThumb(
                                  isDark: isDark,
                                  scheme: cs,
                                  kind: story.kind,
                                ),
                              )
                            else
                              _FallbackThumb(
                                isDark: isDark,
                                scheme: cs,
                                kind: story.kind,
                              ),

                            // Subtle bottom overlay gradient
                            Positioned.fill(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.bottomCenter,
                                    end: Alignment.topCenter,
                                    colors: [
                                      Colors.black.withOpacity(0.35),
                                      Colors.transparent,
                                    ],
                                    stops: const [0.0, 0.6],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // divider under image
                  Container(
                    height: 1,
                    color: Colors.white.withOpacity(0.06),
                  ),

                  /* ───── Body ───── */
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 18,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // meta line
                          _MetaLine(
                            kindRaw: _kindRaw,
                            kindLabel: _kindLabel,
                            timestampText: tsText,
                            freshnessText: freshnessText,
                          ),
                          const SizedBox(height: 14),

                          // title
                          Text(
                            story.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              height: 1.4,
                              fontWeight: FontWeight.w600,
                              color: primaryTextColor(context),
                            ),
                          ),

                          // summary (if any)
                          if ((story.summary ?? '').trim().isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text(
                              story.summary!.trim(),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                height: 1.4,
                                fontWeight: FontWeight.w400,
                                color: secondaryTextColor(context),
                              ),
                            ),
                          ],

                          const Spacer(),

                          // CTA row
                          Row(
                            children: [
                              // Big red CTA
                              Expanded(
                                child: SizedBox(
                                  height: 46,
                                  child: ElevatedButton.icon(
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
                                    onPressed: _primaryUrl == null
                                        ? null
                                        : () {
                                            if (_isWatchCta &&
                                                _videoUrl != null) {
                                              _openDetails(autoplay: true);
                                            } else {
                                              _openPrimaryLink(context);
                                            }
                                          },
                                    style: ElevatedButton.styleFrom(
                                      elevation: 0,
                                      backgroundColor: _accent,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                      ),
                                      textStyle: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14,
                                        height: 1.2,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(10),
                                        side: BorderSide(
                                          color: Colors.white.withOpacity(0.08),
                                          width: 1,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),

                              const SizedBox(width: 12),

                              // Save toggle
                              AnimatedBuilder(
                                animation: SavedStore.instance,
                                builder: (_, __) {
                                  final saved =
                                      SavedStore.instance.isSaved(story.id);
                                  return _SquareActionButton(
                                    tooltip: saved ? 'Saved' : 'Save',
                                    onTap: () =>
                                        SavedStore.instance.toggle(story.id),
                                    child: const _Emoji(
                                      emoji: '🔖',
                                      size: 16,
                                    ),
                                  );
                                },
                              ),

                              const SizedBox(width: 8),

                              // Share
                              _SquareActionButton(
                                tooltip: 'Share',
                                onTap: () => _shareStory(context),
                                child: const _Emoji(
                                  emoji: '📤',
                                  size: 16,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 12),

                          // "Source:" footer
                          if (domain.isNotEmpty) _SourceLine(domain: domain),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/* ─────────────────────── Meta line row ─────────────────────── */

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

_KindStyle _styleForKind(String rawKind) {
  final k = rawKind.toLowerCase().trim();

  // Tailwind-ish tones
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

  // fallback
  return _KindStyle(
    bg: gray.withOpacity(0.16),
    border: gray.withOpacity(0.4),
    text: gray,
  );
}

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
    final style = _styleForKind(kindRaw);
    const accent = Color(0xFFdc2626);

    final pill = kindLabel.isEmpty
        ? const SizedBox.shrink()
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: style.bg,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: style.border, width: 1),
            ),
            child: Text(
              kindLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: style.text,
              ),
            ),
          );

    final tsWidget = (timestampText == null)
        ? const SizedBox.shrink()
        : Flexible(
            child: Text(
              timestampText!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                fontWeight: FontWeight.w500,
                color: secondaryTextColor(context),
              ),
            ),
          );

    final freshWidget = (freshnessText == null)
        ? const SizedBox.shrink()
        : Text(
            freshnessText!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              height: 1.3,
              fontWeight: FontWeight.w500,
              color: accent,
            ),
          );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (kindLabel.isNotEmpty) pill,
        if (kindLabel.isNotEmpty && timestampText != null)
          const SizedBox(width: 10),
        if (timestampText != null) tsWidget,
        if (freshnessText != null) const SizedBox(width: 8),
        if (freshnessText != null) freshWidget,
      ],
    );
  }
}

/* ─────────────────────── Source footer line ─────────────────────── */

class _SourceLine extends StatelessWidget {
  const _SourceLine({required this.domain});
  final String domain;

  @override
  Widget build(BuildContext context) {
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        children: [
          TextSpan(
            text: 'Source: ',
            style: TextStyle(
              fontSize: 12,
              height: 1.3,
              fontWeight: FontWeight.w400,
              color: faintTextColor(context),
            ),
          ),
          TextSpan(
            text: domain,
            style: TextStyle(
              fontSize: 12,
              height: 1.3,
              fontWeight: FontWeight.w500,
              color: secondaryTextColor(context),
            ),
          ),
        ],
      ),
    );
  }
}

/* ─────────────────────── Square icon buttons ─────────────────────── */

class _SquareActionButton extends StatelessWidget {
  const _SquareActionButton({
    required this.child,
    required this.onTap,
    required this.tooltip,
  });

  final Widget child;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bg = isDark
        ? const Color(0xFF0b0f17).withOpacity(0.8)
        : Colors.black.withOpacity(0.04);

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: Colors.white.withOpacity(0.08),
            width: 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

/* ─────────────────────── Fallback thumbnail ─────────────────────── */

class _FallbackThumb extends StatelessWidget {
  const _FallbackThumb({
    required this.isDark,
    required this.scheme,
    required this.kind,
  });

  final bool isDark;
  final ColorScheme scheme;
  final String kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        // Light vertical gradient when we have no actual image
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? const [Color(0xFF101626), Color(0xFF232941)]
              : [
                  const Color(0xFFE7EBF2),
                  const Color(0xFFD1D5DC),
                ],
        ),
      ),
      child: Center(
        child: _KindGlyph(kind: kind),
      ),
    );
  }
}

class _KindGlyph extends StatelessWidget {
  const _KindGlyph({required this.kind});
  final String kind;

  @override
  Widget build(BuildContext context) {
    // Quick visual hint when no thumbnail image
    IconData iconData = Icons.movie_rounded;
    Color iconColor = const Color(0xFFECC943);

    final lower = kind.toLowerCase();
    if (lower.contains('trailer')) {
      iconData = Icons.live_tv_rounded;
      iconColor = const Color(0xFF56BAF8);
    } else if (lower.contains('release')) {
      iconData = Icons.event_available_rounded;
      iconColor = const Color(0xFFF9D359);
    } else if (lower.contains('ott')) {
      iconData = Icons.videocam_rounded;
      iconColor = const Color(0xFFC377F2);
    }

    return Icon(
      iconData,
      size: 52,
      color: iconColor.withOpacity(0.9),
    );
    }
}

/* ─────────────────────── Emoji text helper ─────────────────────── */

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

/* ─────────────────────── Legacy ingestion timestamp ─────────────────────── */

extension _StoryCompat on Story {
  // Some payloads have ingestedAt in weird places / formats.
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
