// lib/features/story/story_card.dart
//
// VISUAL SPEC (matches the HTML mock approved):
//
// Card:
//   - radius: 8
//   - bg: rgba(30,37,51,0.35) on dark
//   - border: 1px solid rgba(255,255,255,0.2)
//   - padding inside body: 12 all around
//
// Layout inside body:
//   Row A  : "<Kind>  •  <publishedAt formatted like '27 Oct 2025, 11:57 AM'>"
//   Row B  : [🕒 badge]  "<addedAt (+Δm)>"
//   Gap 8
//   Title  : max 3 lines
//   Spacer()
//   CTA row: [ big red Watch/Read button ][ save ][ share ]
//   Gap 8
//   Source : "Source: <domain or source>"
//
// Row spacing:
//   RowA
//   4px
//   RowB
//   8px
//   Title
//   12px -> CTA row
//   8px  -> Source
//
// NOTE:
// - Title, CTA, etc are still interactive like before.
// - We keep Spacer() before CTA so all cards stay equal height in the grid.
// - We keep hover translateY(-2) on web, but with new radius/border/shadow.
//

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
import 'story_details.dart';
import 'story_image_url.dart'; // hero/thumbnail resolver

class StoryCard extends StatefulWidget {
  const StoryCard({super.key, required this.story});
  final Story story;

  @override
  State<StoryCard> createState() => _StoryCardState();
}

class _StoryCardState extends State<StoryCard> {
  bool _hover = false;

  // ------------------------------------------------------------------
  // Link / CTA helpers
  // ------------------------------------------------------------------

  Uri? get _videoUrl => storyVideoUrl(widget.story);

  Uri? get _linkUrl {
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

  void _openDetails({bool autoplay = false}) {
    Navigator.of(context).push(
      fadeRoute(StoryDetailsScreen(story: widget.story, autoplay: autoplay)),
    );
  }

  Widget _ctaLeading() => _isWatchCta
      ? const Icon(Icons.play_arrow_rounded, size: 22, color: Colors.white)
      : const _Emoji(emoji: '📖', size: 18);

  // ------------------------------------------------------------------
  // Formatting helpers
  // ------------------------------------------------------------------

  static const List<String> _mon = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  // e.g. "27 Oct 2025, 11:57 AM"
  String _formatMetaLike(DateTime dt) {
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

  // "(+12m)" etc
  String _formatGap(Duration d) {
    final abs = d.isNegative ? -d : d;
    if (abs.inMinutes < 60) return '${abs.inMinutes}m';
    if (abs.inHours < 48) return '${abs.inHours}h';
    return '${abs.inDays}d';
  }

  // Little rounded badge with 🕒, used in Row B
  Widget _timeBadge(String emoji) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        emoji,
        style: const TextStyle(
          fontSize: 12,
          height: 1.0,
          fontFamilyFallback: [
            'Apple Color Emoji',
            'Segoe UI Emoji',
            'Noto Color Emoji',
            'EmojiOne Color',
          ],
        ),
      ),
    );
  }

  // Capitalize kind
  String _kindDisplay(String k) {
    final lower = k.toLowerCase();
    if (lower == 'ott') return 'OTT';
    if (lower.isEmpty) return '';
    return lower[0].toUpperCase() + lower.substring(1);
  }

  // Bottom "Source: <x>" logic.
  // Prefer domain, else source.
  String _attribution(Story s) {
    final dom = (s.sourceDomain ?? '').trim();
    if (dom.isNotEmpty) return dom;
    final src = (s.source ?? '').trim();
    if (src.isNotEmpty) return src;
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final kind = widget.story.kind.toLowerCase();

    // timestamps
    final DateTime? publishedAt = widget.story.publishedAt;
    final DateTime? addedAt =
        widget.story.ingestedAtCompat ?? widget.story.normalizedAt;

    final String? publishedText =
        (publishedAt != null) ? _formatMetaLike(publishedAt) : null;

    final String? addedText = (addedAt != null)
        ? _formatMetaLike(addedAt) +
            (publishedAt != null
                ? ' (+${_formatGap(addedAt.difference(publishedAt))})'
                : '')
        : null;

    final hasUrl = _linkUrl != null;

    // hero/thumbnail
    final imageUrl = resolveStoryImageUrl(widget.story);

    // attribution text
    final srcText = _attribution(widget.story);

    // COLORS from mock:
    //   card bg ~ rgba(30,37,51,0.35) on dark
    final Color cardBgDark = const Color(0xFF1e2533).withOpacity(0.35);
    final Color cardBgLight = scheme.surface;

    final Color borderColor =
        isDark ? Colors.white.withOpacity(0.20) : Colors.black.withOpacity(0.08);

    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      transform:
          _hover ? (vm.Matrix4.identity()..translate(0.0, -2.0, 0.0)) : null,
      decoration: BoxDecoration(
        color: isDark ? cardBgDark : cardBgLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _hover
              ? (isDark
                  ? Colors.white.withOpacity(0.28)
                  : Colors.black.withOpacity(0.16))
              : borderColor,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.6),
            blurRadius: 40,
            offset: const Offset(0, 20),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openDetails(
            autoplay: _isWatchCta && _videoUrl != null,
          ),
          child: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              final mediaH = math.max(130.0, w / (16 / 9));

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ------------------------------------------------------------------
                  // THUMBNAIL (16:9)
                  // ------------------------------------------------------------------
                  SizedBox(
                    height: mediaH,
                    child: Hero(
                      tag: 'thumb-${widget.story.id}',
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(8),
                        ),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (imageUrl.isNotEmpty)
                              CachedNetworkImage(
                                imageUrl: imageUrl,
                                fit: BoxFit.cover,
                                alignment: Alignment.center,
                                memCacheWidth:
                                    (w.isFinite ? (w * 2).toInt() : 1600),
                                fadeInDuration:
                                    const Duration(milliseconds: 160),
                                errorWidget: (_, __, ___) => Container(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        isDark
                                            ? const Color(0xFF0F1625)
                                            : scheme.surfaceVariant
                                                .withOpacity(0.2),
                                        isDark
                                            ? const Color(0xFF1E2433)
                                            : scheme.surfaceVariant
                                                .withOpacity(0.4),
                                      ],
                                    ),
                                  ),
                                  child: Center(
                                    child: _SampleIcon(kind: widget.story.kind),
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
                                          : scheme.surfaceVariant
                                              .withOpacity(0.2),
                                      isDark
                                          ? const Color(0xFF1E2433)
                                          : scheme.surfaceVariant
                                              .withOpacity(0.4),
                                    ],
                                  ),
                                ),
                                child: Center(
                                  child: _SampleIcon(kind: widget.story.kind),
                                ),
                              ),

                            // subtle bottom gradient overlay
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

                  // ------------------------------------------------------------------
                  // BODY
                  // ------------------------------------------------------------------
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(12), // <-- tighter padding (12)
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // ----------------------------------------------------------
                          // Row A: "<Kind>  •  <publishedAt>"
                          // ----------------------------------------------------------
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Flexible(
                                flex: 0,
                                child: Text(
                                  _kindDisplay(kind),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                              if (publishedText != null) ...[
                                const SizedBox(width: 8),
                                // dot •
                                Container(
                                  width: 6,
                                  height: 6,
                                  margin: const EdgeInsets.only(top: 6),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.9),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    publishedText!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      height: 1.3,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),

                          const SizedBox(height: 4),

                          // ----------------------------------------------------------
                          // Row B: [🕒 badge]  "<addedAt (+Δm)>"
                          // ----------------------------------------------------------
                          if (addedText != null)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _timeBadge('🕒'),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    addedText!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.grey[400],
                                      fontSize: 13,
                                      fontWeight: FontWeight.w400,
                                      height: 1.3,
                                    ),
                                  ),
                                ),
                              ],
                            ),

                          const SizedBox(height: 8),

                          // ----------------------------------------------------------
                          // Title (max 3 lines)
                          // ----------------------------------------------------------
                          Flexible(
                            fit: FlexFit.loose,
                            child: Text(
                              widget.story.title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 15,
                                height: 1.35,
                                fontWeight: FontWeight.w600,
                                color: Colors.white.withOpacity(0.96),
                              ),
                            ),
                          ),

                          const SizedBox(height: 12),

                          // push CTA row to bottom for consistent card height
                          const Spacer(),

                          // ----------------------------------------------------------
                          // CTA row
                          // ----------------------------------------------------------
                          Row(
                            children: [
                              // Big red Watch/Read button
                              Expanded(
                                child: Semantics(
                                  button: true,
                                  label: '${_ctaLabel} ${widget.story.title}',
                                  child: SizedBox(
                                    height: 40,
                                    child: ElevatedButton.icon(
                                      icon: _ctaLeading(),
                                      onPressed: hasUrl
                                          ? () {
                                              if (_isWatchCta &&
                                                  _videoUrl != null) {
                                                _openDetails(autoplay: true);
                                              } else {
                                                _openExternalLink(context);
                                              }
                                            }
                                          : null,
                                      style: ElevatedButton.styleFrom(
                                        foregroundColor: Colors.white,
                                        backgroundColor:
                                            const Color(0xFFdc2626),
                                        elevation: 0,
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                        ),
                                        textStyle: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 15,
                                          height: 1.2,
                                        ),
                                      ),
                                      label: Text(_ctaLabel),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),

                              // Save
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
                                      size: 18,
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(width: 8),

                              // Share
                              _ActionIconBox(
                                tooltip: 'Share',
                                onTap: () => _share(context),
                                icon: const _Emoji(
                                  emoji: '📤',
                                  size: 18,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 8),

                          // ----------------------------------------------------------
                          // Source row
                          // ----------------------------------------------------------
                          if (srcText.isNotEmpty)
                            Text(
                              'Source: $srcText',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.grey[400],
                                fontSize: 12,
                                fontWeight: FontWeight.w400,
                                height: 1.3,
                              ),
                            ),
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

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: kIsWeb
          ? card
          : ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
                child: card,
              ),
            ),
    );
  }
}

/* ------------------------- Category/fallback icon ------------------------- */
class _SampleIcon extends StatelessWidget {
  final String kind;
  const _SampleIcon({required this.kind});

  @override
  Widget build(BuildContext context) {
    IconData iconData = Icons.movie_rounded;
    Color iconColor = const Color(0xFFECC943);

    final k = kind.toLowerCase();
    if (k.contains('trailer')) {
      iconData = Icons.theater_comedy_rounded;
      iconColor = const Color(0xFF56BAF8);
    } else if (k.contains('release')) {
      iconData = Icons.balance_rounded;
      iconColor = const Color(0xFFF9D359);
    } else if (k.contains('ott')) {
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

/* --------------------------------- Utils -------------------------------- */
class _Emoji extends StatelessWidget {
  const _Emoji({required this.emoji, this.size = 18});
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

/* --------- Secondary action icon chip (Save / Share) --------- */
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

    // dark translucent chip from mock:
    final bgColor = isDark
        ? Colors.black.withOpacity(0.4)
        : Colors.black.withOpacity(0.06);

    final borderColor = isDark
        ? Colors.white.withOpacity(0.15)
        : Colors.black.withOpacity(0.15);

    return Tooltip(
      message: tooltip,
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

/* ---------------------- Back-compat extension ---------------------- */
extension _StoryCompat on Story {
  // Some older payloads stick ingested_at in different places.
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
