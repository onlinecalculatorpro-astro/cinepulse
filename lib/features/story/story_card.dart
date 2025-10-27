// lib/features/story/story_card.dart
//
// CinePulse "approved view" card:
//
// - Dark navy card (#0f172a style), subtle 1px border, 10-12px radius,
//   heavy shadow. No glass blur on mobile anymore.
//
// - Thumbnail:
//   * Always a 16:9 box aligned to Alignment.topCenter so we crop bottom.
//   * Minimum height ~160px so very narrow columns don't create tiny postage stamps.
//   * After the image we ALWAYS draw a 1px divider line. This visually
//     separates media from text, and makes cards look aligned even if
//     thumbnails differ in real content.
//
// - Meta line (SINGLE ROW):
//     [Release] [27 Oct 2025, 3:30 PM] [+6m]
//   * "Release" is a small pill (11px text, white on translucent bg).
//   * Date/time uses 12px, medium weight, white-ish.
//   * Freshness (+6m) uses accent red #dc2626.
//   * We no longer show 2 separate timestamp rows.
//
// - Title:
//   * Inter 14px, weight 600, up to 3 lines, white.
//   * Sits under the meta line with tight spacing.
//   * No giant gap after title.
//
// - CTA row pinned to bottom of the card body using a Stack:
//   * Red button ("Watch" or "Read"), 36px height, radius 6px.
//   * Two square icon boxes (🔖 / 📤), each 36x36, same baseline.
//   * Row left-aligned, not stretched wide.
//   * On web/desktop we later can tooltip+hover outline red, but base visuals
//     match the mock: dark boxes w/ subtle border.
//
// - "Source: xyz.com" footer line under the CTA row:
//   * Dim "Source:" label (≈45% white).
//   * Domain is slightly brighter (~65%) with semi-bold.
//   * 12px text.
//
// - Hover lift on desktop/web: raise card by ~2px, stronger shadow / glow.
//   * On mobile we still wrap in MouseRegion but _hover just never triggers.
//
// NOTE:
// Remaining per-card height also depends on the grid's childAspectRatio
// in home_screen.dart. The card itself is now as tight as the approved mock.

import 'dart:math' as math;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

import '../../core/api.dart';
import '../../core/cache.dart';
import '../../core/models.dart';
import '../../core/utils.dart';
import 'story_pager.dart';        // StoryPagerScreen
import 'story_image_url.dart';   // resolveStoryImageUrl

class StoryCard extends StatefulWidget {
  const StoryCard({
    super.key,
    required this.story,
    this.allStories,
    this.index,
  });

  final Story story;

  /// Entire list this card belongs to (for swipe-in-pager context).
  final List<Story>? allStories;

  /// Index of [story] within [allStories].
  final int? index;

  @override
  State<StoryCard> createState() => _StoryCardState();
}

class _StoryCardState extends State<StoryCard> {
  bool _hover = false;

  /* ─────────────────────────── CTA / link helpers ───────────────────────── */

  Uri? get _videoUrl => storyVideoUrl(widget.story);

  Uri? get _linkUrl {
    // Prefer playable URL first.
    final v = _videoUrl;
    if (v != null) return v;

    final raw = (widget.story.url ?? '').trim();
    if (raw.isEmpty) return null;

    final u = Uri.tryParse(raw);
    if (u == null || !(u.isScheme('http') || u.isScheme('https'))) return null;
    return u;
  }

  bool get _isWatchCta {
    if (_videoUrl != null) return true;

    final host = _linkUrl?.host?.toLowerCase() ?? '';
    final byHost = host.contains('youtube.com') || host.contains('youtu.be');
    final byType = widget.story.kind.toLowerCase() == 'trailer';
    final bySource = (widget.story.source ?? '').toLowerCase() == 'youtube';

    return byHost || byType || bySource;
  }

  String get _ctaLabel => _isWatchCta ? 'Watch' : 'Read';

  Future<void> _openExternalLink(BuildContext context) async {
    final url = _linkUrl;
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
      await Clipboard.setData(ClipboardData(text: deep));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copied to clipboard')),
        );
      }
    }
  }

  // For pager
  List<Story> get _effectiveStories =>
      (widget.allStories != null && widget.allStories!.isNotEmpty)
          ? widget.allStories!
          : <Story>[widget.story];

  int get _effectiveIndex =>
      (widget.index != null && widget.index! >= 0) ? widget.index! : 0;

  void _openDetails({bool autoplay = false}) {
    Navigator.of(context).push(
      fadeRoute(
        StoryPagerScreen(
          stories: _effectiveStories,
          initialIndex: _effectiveIndex,
          autoplayInitial: autoplay,
        ),
      ),
    );
  }

  Widget _ctaLeading() => _isWatchCta
      ? const Icon(Icons.play_arrow_rounded, size: 20, color: Colors.white)
      : const _Emoji(emoji: '📖', size: 16);

  /* ───────────────────────── formatting helpers ────────────────────────── */

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

  // 'Release', 'Trailer', 'OTT', etc.
  String _kindDisplay(String k) {
    final lower = k.toLowerCase();
    if (lower == 'ott') return 'OTT';
    if (lower.isEmpty) return '';
    return lower[0].toUpperCase() + lower.substring(1);
  }

  // "koimoi.com" / "youtube.com" / fallback from source.
  String _sourceDomain(Story s) {
    final dom = (s.sourceDomain ?? '').trim();
    if (dom.isNotEmpty) return dom;
    final src = (s.source ?? '').trim();
    if (src.isNotEmpty) return src;
    return '';
  }

  /* ─────────────────────────────── build ──────────────────────────────── */

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final story = widget.story;
    final kind = story.kind.toLowerCase();

    // Published vs ingested/normalized, to compute freshness delta.
    final DateTime? publishedAt = story.publishedAt ?? story.releaseDate;
    final DateTime? addedAt = story.normalizedAt ?? story.ingestedAtCompat;

    // Pick which timestamp to actually show in the meta line:
    // (fallback to whichever exists).
    final DateTime? primaryTs = publishedAt ?? addedAt;
    final String? primaryTsText =
        (primaryTs != null) ? _formatMetaTimestamp(primaryTs) : null;

    // Fresh delta (e.g. +6m):
    String? freshnessText;
    if (publishedAt != null && addedAt != null) {
      final diff = addedAt.difference(publishedAt);
      // Only show if it's meaningful (> 0 min).
      if (diff.inMinutes.abs() >= 1) {
        freshnessText = _formatGapShort(diff);
      }
    }

    final hasUrl = _linkUrl != null;
    final imageUrl = resolveStoryImageUrl(story);
    final srcText = _sourceDomain(story);

    // Card chrome from approved mock:
    // - bg: dark navy (#0f172a style) in dark mode, surface in light mode
    // - border: 1px rgba(255,255,255,0.07) in dark
    // - radius: ~10-12px
    // - strong shadow
    final Color cardBg = isDark
        ? const Color(0xFF0f172a)
        : scheme.surface;
    final Color borderColor = isDark
        ? Colors.white.withOpacity(0.07)
        : Colors.black.withOpacity(0.08);

    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      transform: _hover
          ? (vm.Matrix4.identity()..translate(0.0, -2.0, 0.0))
          : null,
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: borderColor,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(_hover ? 0.9 : 0.8),
            blurRadius: _hover ? 70 : 50,
            spreadRadius: 0,
            offset: const Offset(0, 30),
          ),
          if (_hover)
            BoxShadow(
              color: const Color(0xFFdc2626).withOpacity(0.18),
              blurRadius: 30,
              spreadRadius: 0,
              offset: const Offset(0, 0),
            ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          // Whole card tap opens details (pager). CTA buttons override if tapped.
          onTap: () => _openDetails(
            autoplay: _isWatchCta && _videoUrl != null,
          ),
          child: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;

              // fixed 16:9 hero box. Keep a min height so narrow columns
              // don't become too short.
              final baseH = w / (16 / 9); // 16:9 => h = w * 0.5625
              final mediaH = math.max(160.0, baseH);

              // vertical space we must reserve for the pinned CTA section:
              // CTA row (36) + gap(8) + "Source" (~16) if present
              final reservedBottom =
                  36 +
                  8 +
                  (srcText.isNotEmpty ? 16 : 0);

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  /* ───── THUMBNAIL / HERO (top-cropped 16:9) ───── */
                  SizedBox(
                    height: mediaH,
                    child: Hero(
                      tag: 'thumb-${story.id}',
                      child: ClipRect(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (imageUrl.isNotEmpty)
                              CachedNetworkImage(
                                imageUrl: imageUrl,
                                fit: BoxFit.cover,
                                alignment: Alignment.topCenter,
                                memCacheWidth:
                                    (w.isFinite ? (w * 2).toInt() : 1600),
                                fadeInDuration:
                                    const Duration(milliseconds: 160),
                                errorWidget: (_, __, ___) => _FallbackThumb(
                                  isDark: isDark,
                                  scheme: scheme,
                                  kind: story.kind,
                                ),
                              )
                            else
                              _FallbackThumb(
                                isDark: isDark,
                                scheme: scheme,
                                kind: story.kind,
                              ),

                            // subtle bottom fade overlay
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

                  // divider under thumbnail for consistent visual break
                  Container(
                    height: 1,
                    color: Colors.white.withOpacity(0.07),
                  ),

                  /* ───── BODY / TEXT / CTA (stacked) ───── */
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: LayoutBuilder(
                        builder: (context, bodyBox) {
                          return Stack(
                            children: [
                              // main text content above reserved CTA space
                              Padding(
                                padding:
                                    EdgeInsets.only(bottom: reservedBottom),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // META LINE (single row)
                                    // [Release] [27 Oct 2025, 3:30 PM] [+6m]
                                    _MetaLine(
                                      kindLabel: _kindDisplay(kind),
                                      timestampText: primaryTsText,
                                      freshnessText: freshnessText,
                                    ),

                                    const SizedBox(height: 8),

                                    // TITLE (max 3 lines)
                                    Text(
                                      story.title,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: GoogleFonts.inter(
                                        fontSize: 14,
                                        height: 1.4,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // bottom CTA + source footer (pinned)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // CTA row
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          // Main red button ("Read"/"Watch")
                                          Semantics(
                                            button: true,
                                            label:
                                                '${_ctaLabel} ${story.title}',
                                            child: SizedBox(
                                              height: 36,
                                              child: ElevatedButton.icon(
                                                icon: _ctaLeading(),
                                                onPressed: hasUrl
                                                    ? () {
                                                        if (_isWatchCta &&
                                                            _videoUrl !=
                                                                null) {
                                                          _openDetails(
                                                              autoplay: true);
                                                        } else {
                                                          _openExternalLink(
                                                              context);
                                                        }
                                                      }
                                                    : null,
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor:
                                                      const Color(0xFFdc2626),
                                                  foregroundColor: Colors.white,
                                                  elevation: 0,
                                                  minimumSize:
                                                      const Size(0, 36),
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 12,
                                                  ),
                                                  shape:
                                                      RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            6),
                                                    side: BorderSide(
                                                      color: Colors.white
                                                          .withOpacity(0.08),
                                                      width: 1,
                                                    ),
                                                  ),
                                                  textStyle: const TextStyle(
                                                    fontWeight: FontWeight.w600,
                                                    fontSize: 14,
                                                    height: 1.2,
                                                  ),
                                                ),
                                                label: Text(_ctaLabel),
                                              ),
                                            ),
                                          ),

                                          const SizedBox(width: 6),

                                          // Save button (🔖)
                                          AnimatedBuilder(
                                            animation: SavedStore.instance,
                                            builder: (_, __) {
                                              final saved = SavedStore.instance
                                                  .isSaved(story.id);
                                              return _ActionIconBox(
                                                tooltip:
                                                    saved ? 'Saved' : 'Save',
                                                onTap: () => SavedStore.instance
                                                    .toggle(story.id),
                                                icon: const _Emoji(
                                                  emoji: '🔖',
                                                  size: 16,
                                                ),
                                              );
                                            },
                                          ),

                                          const SizedBox(width: 6),

                                          // Share button (📤)
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
                                    ),

                                    const SizedBox(height: 8),

                                    // Source footer line
                                    if (srcText.isNotEmpty)
                                      _SourceLine(domain: srcText),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
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

    // Hover lift on desktop / web. On mobile, _hover never really triggers,
    // but MouseRegion is fine (no visual cost).
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: card,
    );
  }
}

/* ─────────────────────── META LINE ROW WIDGET ──────────────────────────── */

class _MetaLine extends StatelessWidget {
  const _MetaLine({
    required this.kindLabel,
    required this.timestampText,
    required this.freshnessText,
  });

  final String kindLabel;
  final String? timestampText;
  final String? freshnessText;

  @override
  Widget build(BuildContext context) {
    final accent = const Color(0xFFdc2626);

    final pill = kindLabel.isEmpty
        ? const SizedBox.shrink()
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              kindLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
          );

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

/* ───────────────────────── SOURCE FOOTER LINE ─────────────────────────── */

class _SourceLine extends StatelessWidget {
  const _SourceLine({required this.domain});

  final String domain;

  @override
  Widget build(BuildContext context) {
    // "Source:" is dimmer (~45% white). Domain is brighter (~65%) bold-ish.
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
              color: Colors.white.withOpacity(0.45),
              fontWeight: FontWeight.w400,
            ),
          ),
          TextSpan(
            text: domain,
            style: TextStyle(
              fontSize: 12,
              height: 1.3,
              color: Colors.white.withOpacity(0.65),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/* ─────────────────────── fallback thumbnail widget ─────────────────────── */

class _FallbackThumb extends StatelessWidget {
  final bool isDark;
  final ColorScheme scheme;
  final String kind;

  const _FallbackThumb({
    required this.isDark,
    required this.scheme,
    required this.kind,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        // simple dark vertical gradient for missing images
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            isDark
                ? const Color(0xFF0F1625)
                : scheme.surfaceVariant.withOpacity(0.2),
            isDark
                ? const Color(0xFF1E2433)
                : scheme.surfaceVariant.withOpacity(0.4),
          ],
        ),
      ),
      child: Center(
        child: _SampleIcon(kind: kind),
      ),
    );
  }
}

/* ───────────────────── icon in fallback thumbnail ─────────────────────── */

class _SampleIcon extends StatelessWidget {
  final String kind;
  const _SampleIcon({required this.kind});

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
      size: 52,
      color: iconColor.withOpacity(0.9),
    );
  }
}

/* ───────────────────────────── emoji text ─────────────────────────────── */

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

/* ───────────────────── Save / Share square buttons ────────────────────── */

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

    // Matches mock: a dark little square w/ thin border.
    final bgColor = isDark
        ? const Color(0xFF0b0f17)
        : Colors.black.withOpacity(0.06);

    final borderColor = isDark
        ? Colors.white.withOpacity(0.12)
        : Colors.black.withOpacity(0.12);

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
          child: const SizedBox(
            width: 36,
            height: 36,
            child: Center(
              // icon is passed in, but SizedBox const can't contain non-const,
              // so we keep this const wrapper minimal and let icon above be const.
              child: null,
            ),
          ),
        ),
      ),
    );
  }

  // We can't put the icon directly in the const SizedBox above because "icon"
  // isn't const. So we override build() again using Stack to overlay "icon".
  // (Tiny trick to keep InkWell ripple nice & centered without extra padding.)
  @override
  Widget buildInkWell(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bgColor = isDark
        ? const Color(0xFF0b0f17)
        : Colors.black.withOpacity(0.06);

    final borderColor = isDark
        ? Colors.white.withOpacity(0.12)
        : Colors.black.withOpacity(0.12);

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

  // Actually return buildInkWell in build().
  @override
  Widget build(BuildContext context) => buildInkWell(context);
}

/* ───────────────────── back-compat for ingestedAt ─────────────────────── */

extension _StoryCompat on Story {
  // Handle older payloads where "ingestedAt" might be nested strangely.
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
