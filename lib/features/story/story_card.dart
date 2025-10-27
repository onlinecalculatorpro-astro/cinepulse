// lib/features/story/story_card.dart
//
// CinePulse card (mobile-first).
//
// - Dark navy card (#0f172a in dark mode), subtle 1px border, 10px radius,
//   shadow/glow on hover (web / desktop).
// - 16:9 thumbnail cropped from the TOP, min height ~160px so we keep visual
//   consistency between cards even if the source image is short.
// - Meta row:
//      [Release] 27 Oct 2025, 3:30 PM  +6m
//   with a COLORED pill per kind:
//      Release  -> red
//      News     -> blue
//      OTT      -> purple
//      Trailer  -> amber
//      fallback -> gray
// - Title: Inter 14px, up to 3 lines.
// - CTA row (Watch/Read + Save + Share) is PINNED to the bottom of the card
//   body. "Source: domain.com" sits just under it.
// - We now *reserve* extra bottom padding (reservedBottom) so the CTA/footer
//   area never overlaps the last line of the title, even when:
//      * textScaleFactor is large
//      * meta row wraps
//      * 3-line headline
//
// Note: final vertical height in the grid is still affected by the grid's
// childAspectRatio in home_screen.dart.

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
import 'story_image_url.dart';
import 'story_pager.dart';

class StoryCard extends StatefulWidget {
  const StoryCard({
    super.key,
    required this.story,
    this.allStories,
    this.index,
  });

  final Story story;

  /// Entire list this card belongs to (used for swipe paging in StoryPagerScreen).
  final List<Story>? allStories;

  /// Index of [story] within [allStories].
  final int? index;

  @override
  State<StoryCard> createState() => _StoryCardState();
}

class _StoryCardState extends State<StoryCard> {
  bool _hover = false;

  /* ───────────────────────────── CTA / link helpers ───────────────────────── */

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

  // For pager handoff
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

  /* ───────────────────────────── formatting helpers ───────────────────────── */

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

  // 'Release', 'Trailer', 'OTT', 'News', etc → display label.
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

  /* ─────────────────────────────────── build ───────────────────────────────── */

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final story = widget.story;
    final kindRaw = story.kind.toLowerCase();

    // Timestamps for meta row.
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

    final hasUrl = _linkUrl != null;
    final imageUrl = resolveStoryImageUrl(story);
    final srcText = _sourceDomain(story);

    // Card chrome:
    final Color cardBg = isDark ? const Color(0xFF0f172a) : scheme.surface;
    final Color borderColor = isDark
        ? Colors.white.withOpacity(0.07)
        : Colors.black.withOpacity(0.08);

    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      transform:
          _hover ? (vm.Matrix4.identity()..translate(0.0, -2.0, 0.0)) : null,
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
          // Whole card tap opens details. CTA buttons below do their own onTap.
          onTap: () => _openDetails(
            autoplay: _isWatchCta && _videoUrl != null,
          ),
          child: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;

              // Top image (16:9) cropped from top, but never shorter than 160px.
              final baseH = w / (16 / 9); // h = w * 0.5625
              final mediaH = math.max(160.0, baseH);

              // Reserve body bottom so text never collides with CTA row.
              //
              // CTA row height (36)
              // + gap under CTA (8)
              // + source line (~16 if present)
              final baseCtaBlock =
                  36.0 + 8.0 + (srcText.isNotEmpty ? 16.0 : 0.0);

              // extra breathing room above CTA block so a 3-line headline
              // + long meta row + high textScale won't overlap
              final safetyGap = 32.0; // bumped from 16 → 32

              // scale padding with textScale (up to 1.4x) so large fonts get
              // even more room.
              final textScale = MediaQuery.textScaleFactorOf(context);
              final double reservedBottom =
                  (baseCtaBlock + safetyGap) * textScale.clamp(1.0, 1.4);

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  /* ───── THUMBNAIL / HERO ───── */
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

                            // subtle bottom fade overlay on the image
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

                  // Divider under thumbnail
                  Container(
                    height: 1,
                    color: Colors.white.withOpacity(0.07),
                  ),

                  /* ───── BODY / TEXT / CTA ───── */
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: LayoutBuilder(
                        builder: (context, bodyBox) {
                          return Stack(
                            children: [
                              // Top content (meta row + title).
                              Padding(
                                padding: EdgeInsets.only(bottom: reservedBottom),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _MetaLine(
                                      kindRaw: kindRaw,
                                      kindLabel: _kindDisplay(kindRaw),
                                      timestampText: primaryTsText,
                                      freshnessText: freshnessText,
                                    ),

                                    const SizedBox(height: 8),

                                    // Title (up to 3 lines)
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

                              // Bottom CTA row + Source, pinned.
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
                                          // Red Watch/Read button
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
                                                            autoplay: true,
                                                          );
                                                        } else {
                                                          _openExternalLink(
                                                            context,
                                                          );
                                                        }
                                                      }
                                                    : null,
                                                style:
                                                    ElevatedButton.styleFrom(
                                                  backgroundColor:
                                                      const Color(0xFFdc2626),
                                                  foregroundColor:
                                                      Colors.white,
                                                  elevation: 0,
                                                  minimumSize:
                                                      const Size(0, 36),
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                    horizontal: 12,
                                                  ),
                                                  shape:
                                                      RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      6,
                                                    ),
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

                                          // Save (🔖)
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

                                          // Share (📤)
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

                                    // Source footer
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

    // Hover lift/glow only matters on desktop/web.
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: card,
    );
  }
}

/* ───────────────────────────── badge color helper ────────────────────────── */

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

// Pick badge colors by kind. Keeps text readable on dark cards.
_KindStyle _styleForKind(String rawKind) {
  final k = rawKind.toLowerCase().trim();

  // Tailwind-ish palette references:
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

  // fallback / generic
  return _KindStyle(
    bg: gray.withOpacity(0.16),
    border: gray.withOpacity(0.4),
    text: gray,
  );
}

/* ─────────────────────────── META LINE ROW ──────────────────────────────── */

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

    final pill = kindLabel.isEmpty
        ? const SizedBox.shrink()
        : Container(
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

/* ─────────────────────────── SOURCE FOOTER LINE ─────────────────────────── */

class _SourceLine extends StatelessWidget {
  const _SourceLine({required this.domain});

  final String domain;

  @override
  Widget build(BuildContext context) {
    // "Source:" dimmer (~45% white). Domain brighter (~65%) semi-bold.
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

/* ────────────────────────── fallback thumbnail ─────────────────────────── */

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

/* ─────────────────────── icon in fallback thumbnail ────────────────────── */

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

/* ───────────────────────────── emoji text ──────────────────────────────── */

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

/* ───────────────────── Save / Share square buttons ─────────────────────── */

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

    // dark square w/ thin border, matches the current CinePulse mock
    final bgColor =
        isDark ? const Color(0xFF0b0f17) : Colors.black.withOpacity(0.06);

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
            child: Center(child: null), // replaced below via LayoutBuilder
          ),
        ),
      ),
    );
  }
}

// We can't inject `icon` into the const child above, so give InkWell a builder.
// Simpler: redefine _ActionIconBox with the icon child inline instead of const:

class _ActionIconBoxFixed extends StatelessWidget {
  final Widget icon;
  final VoidCallback onTap;
  final String tooltip;

  const _ActionIconBoxFixed({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bgColor =
        isDark ? const Color(0xFF0b0f17) : Colors.black.withOpacity(0.06);

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
}

// Alias so callsites can keep using _ActionIconBox(...)
typedef _ActionIconBox = _ActionIconBoxFixed;

/* ─────────────────────── back-compat for ingestedAt ────────────────────── */

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
