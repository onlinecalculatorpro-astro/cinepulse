// lib/features/story/story_card.dart
//
// CinePulse card (mobile-first).
//
// Uses theme tokens/helpers (theme/theme_colors.dart, app theme) — no
// hard-coded colors for themed elements.

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
import '../../theme/theme_colors.dart';
import 'story_pager.dart'; // StoryPagerScreen
import 'story_image_url.dart'; // resolveStoryImageUrl

class StoryCard extends StatefulWidget {
  const StoryCard({
    super.key,
    required this.story,
    this.allStories,
    this.index,
  });

  final Story story;

  /// Entire list this card belongs to (for swipe paging in StoryPagerScreen).
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

  Widget _ctaLeading(BuildContext ctx) => _isWatchCta
      ? Icon(Icons.play_arrow_rounded, size: 20, color: Theme.of(ctx).colorScheme.onPrimary)
      : _Emoji(emoji: '📖', size: 16, color: Theme.of(ctx).colorScheme.onPrimary);

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

  /* ─────────────────────────────── build ──────────────────────────────── */

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

    // Card chrome (theme-aware):
    final Color cardBg = theme.cardColor;
    final Color borderColor = outlineHairline(context);

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
            color: theme.shadowColor.withOpacity(isDark ? 0.9 : 0.25),
            blurRadius: _hover ? 70 : 50,
            spreadRadius: 0,
            offset: const Offset(0, 30),
          ),
          if (_hover)
            BoxShadow(
              color: scheme.primary.withOpacity(0.18),
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
          // Whole card tap opens details (pager). CTA buttons override.
          onTap: () => _openDetails(
            autoplay: _isWatchCta && _videoUrl != null,
          ),
          child: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;

              // Thumbnail height = 16:9 crop aligned to top, min 160.
              final baseH = w / (16 / 9); // h = w * 0.5625
              final mediaH = math.max(160.0, baseH);

              // Keep title from colliding with CTA:
              final textScale = MediaQuery.textScaleFactorOf(context);

              final baseCtaBlock =
                  36.0 + // button row
                  8.0 + // gap between row and source
                  (srcText.isNotEmpty ? 16.0 : 0.0); // "Source:" line

              const safetyGap = 32.0;

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

                            // subtle bottom gradient overlay (theme scrim)
                            Positioned.fill(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.bottomCenter,
                                    end: Alignment.topCenter,
                                    colors: [
                                      scheme.scrim.withOpacity(0.35),
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

                  // divider under thumbnail (hairline)
                  Container(
                    height: 1,
                    color: outlineHairline(context),
                  ),

                  /* ───── BODY / TEXT / CTA ───── */
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: LayoutBuilder(
                        builder: (context, bodyBox) {
                          return Stack(
                            children: [
                              // Top content (meta row + title)
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
                                        color: primaryTextColor(context),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Bottom CTA row + Source (pinned)
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
                                          // Primary Watch/Read button
                                          Semantics(
                                            button: true,
                                            label:
                                                '${_ctaLabel} ${story.title}',
                                            child: SizedBox(
                                              height: 36,
                                              child: ElevatedButton.icon(
                                                icon: _ctaLeading(context),
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
                                                      scheme.primary,
                                                  foregroundColor:
                                                      scheme.onPrimary,
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
                                                      color: outlineHairline(
                                                          context),
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
                                                onTap: () =>
                                                    SavedStore.instance
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

    // Hover lift/glow is mainly for desktop/web.
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: card,
    );
  }
}

/* ─────────────────────── badge color helper ───────────────────────────── */

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

// Pick badge colors by kind — themed.
// release → error, news → primary, ott → tertiary, trailer → secondary.
// fallback → onSurfaceVariant tones.
_KindStyle _styleForKind(BuildContext ctx, String rawKind) {
  final cs = Theme.of(ctx).colorScheme;
  final k = rawKind.toLowerCase().trim();

  Color base;
  if (k.contains('release')) {
    base = cs.error;
  } else if (k.contains('news')) {
    base = cs.primary;
  } else if (k.contains('ott')) {
    base = cs.tertiary;
  } else if (k.contains('trailer')) {
    base = cs.secondary;
  } else {
    base = cs.onSurfaceVariant;
  }

  return _KindStyle(
    bg: base.withOpacity(0.16),
    border: base.withOpacity(0.40),
    text: base,
  );
}

/* ─────────────────────── META LINE ROW WIDGET ──────────────────────────── */

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
    final accent = Theme.of(context).colorScheme.primary;
    final style = _styleForKind(context, kindRaw);

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
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                color: secondaryTextColor(context),
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
    // "Source:" dimmer, domain a bit brighter.
    final Color labelColor = faintTextColor(context);
    final Color domainColor = secondaryTextColor(context);

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
              color: labelColor,
              fontWeight: FontWeight.w400,
            ),
          ),
          TextSpan(
            text: domain,
            style: TextStyle(
              fontSize: 12,
              height: 1.3,
              color: domainColor,
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
        // theme-aware vertical gradient for missing images
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [neutralPillBg(context), Theme.of(context).cardColor]
              : [
                  scheme.surfaceVariant.withOpacity(0.20),
                  scheme.surfaceVariant.withOpacity(0.40),
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
    final cs = Theme.of(context).colorScheme;

    IconData iconData = Icons.movie_rounded;
    Color iconColor = cs.primary;

    final lower = kind.toLowerCase();
    if (lower.contains('trailer')) {
      iconData = Icons.theater_comedy_rounded;
      iconColor = cs.secondary;
    } else if (lower.contains('release')) {
      iconData = Icons.balance_rounded;
      iconColor = cs.error;
    } else if (lower.contains('ott')) {
      iconData = Icons.videocam_rounded;
      iconColor = cs.tertiary;
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
  const _Emoji({required this.emoji, this.size = 16, this.color});
  final String emoji;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      emoji,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: size,
        height: 1,
        color: color,
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
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: neutralPillBg(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: outlineHairline(context), width: 1),
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

/* ───────────────────── back-compat for ingestedAt ─────────────────────── */

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
