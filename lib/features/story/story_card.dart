// lib/features/story/story_card.dart
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

class StoryCard extends StatefulWidget {
  const StoryCard({super.key, required this.story});
  final Story story;

  @override
  State<StoryCard> createState() => _StoryCardState();
}

class _StoryCardState extends State<StoryCard> {
  bool _hover = false;

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
        SnackBar(content: Text(kIsWeb ? 'Link copied to clipboard' : 'Share sheet opened')),
      );
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: deep));
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Link copied to clipboard')));
      }
    }
  }

  void _openDetails({bool autoplay = false}) {
    Navigator.of(context).push(
      fadeRoute(StoryDetailsScreen(story: widget.story, autoplay: autoplay)),
    );
  }

  Widget _ctaLeading() =>
      _isWatchCta ? const Icon(Icons.play_arrow_rounded, size: 22, color: Colors.white)
                  : const _Emoji(emoji: '📖', size: 18);

  String _stripKindPrefix(String meta) {
    var out = meta;
    for (final p in const ['news', 'release', 'trailer', 'ott']) {
      final re = RegExp(r'^\s*' + RegExp.escape(p) + r'\s*•\s*', caseSensitive: false);
      out = out.replaceFirst(re, '');
    }
    return out.trim();
  }

  // ---------- Time helpers ----------
  static const List<String> _mon = [
    'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
  ];

  String _formatMetaLike(DateTime dt) {
    final d = dt.toLocal();
    final day = d.day;
    final m   = _mon[d.month - 1];
    final y   = d.year;
    var h = d.hour % 12;
    if (h == 0) h = 12;
    final mm = d.minute.toString().padLeft(2, '0');
    final ap = d.hour >= 12 ? 'PM' : 'AM';
    return '$day $m $y, $h:$mm $ap';
  }

  String _formatGap(Duration d) {
    final abs = d.isNegative ? -d : d;
    if (abs.inMinutes < 60) return '${abs.inMinutes}m';
    if (abs.inHours < 48) return '${abs.inHours}h';
    return '${abs.inDays}d';
  }

  Widget _timePill({required String emoji, required String text}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.13),
            shape: BoxShape.circle,
          ),
          child: _Emoji(emoji: emoji, size: 14),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: Colors.grey[400], fontSize: 13.5),
        ),
      ],
    );
  }
  // -----------------------------------

  // ---------- Image URL sanitizer ----------
  String _cleanImageUrl() {
    final cand = (widget.story.posterUrl?.isNotEmpty == true)
        ? widget.story.posterUrl!
        : (widget.story.thumbUrl ?? '');

    if (cand.isEmpty) return '';

    // 1. If the URL contains demo.tagdiv.com anywhere -> reject.
    if (cand.contains('demo.tagdiv.com')) return '';

    // 2. If it's our proxy style /v1/img?u=..., extract inner u=... and
    //    reject if THAT host is demo.tagdiv.com
    final uri = Uri.tryParse(cand);
    if (uri != null) {
      final isProxy = uri.path.contains('/v1/img');
      if (isProxy) {
        final inner = uri.queryParameters['u'] ?? uri.queryParameters['url'] ?? '';
        if (inner.contains('demo.tagdiv.com')) {
          return '';
        }
      }
    }

    // Looks fine
    return cand;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final kind = widget.story.kind.toLowerCase();

    final rawMeta = widget.story.metaLine;
    final metaText = _stripKindPrefix(rawMeta);

    final DateTime? publishedAt = widget.story.publishedAt;
    final DateTime? addedAt = widget.story.ingestedAtCompat ?? widget.story.normalizedAt;
    final String? addedText = (addedAt != null)
        ? _formatMetaLike(addedAt) +
            (publishedAt != null ? ' (+${_formatGap(addedAt.difference(publishedAt))})' : '')
        : null;

    final hasUrl = _linkUrl != null;
    final imageUrl = _cleanImageUrl(); // <-- use sanitizer here

    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      transform: _hover ? (vm.Matrix4.identity()..translate(0.0, -2.0, 0.0)) : null,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF181E2A).withOpacity(0.92)
                      : scheme.surface.withOpacity(0.97),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: _hover ? const Color(0x33dc2626) : Colors.white.withOpacity(0.08),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openDetails(autoplay: _isWatchCta && _videoUrl != null),
          child: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              final mediaH = math.max(130.0, w / (16 / 9));

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Media
                  SizedBox(
                    height: mediaH,
                    child: Hero(
                      tag: 'thumb-${widget.story.id}',
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (imageUrl.isNotEmpty)
                              CachedNetworkImage(
                                imageUrl: imageUrl,
                                fit: BoxFit.cover,
                                alignment: Alignment.center,
                                memCacheWidth: (w.isFinite ? (w * 2).toInt() : 1600),
                                fadeInDuration: const Duration(milliseconds: 160),
                                errorWidget: (_, __, ___) => Container(
                                  decoration: BoxDecoration(
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
                                          : scheme.surfaceVariant.withOpacity(0.2),
                                      isDark
                                          ? const Color(0xFF1E2433)
                                          : scheme.surfaceVariant.withOpacity(0.4),
                                    ],
                                  ),
                                ),
                                child: Center(child: _SampleIcon(kind: widget.story.kind)),
                              ),
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

                  // Meta + CTA
                  Expanded(
                    child: Padding(
                      // tighter padding than original
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              KindMetaBadge(kind),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Wrap(
                                  spacing: 10,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    _timePill(emoji: '🕐', text: metaText),
                                    if (addedText != null)
                                      _timePill(emoji: '🕐', text: addedText),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Flexible(
                            fit: FlexFit.loose,
                            child: Text(
                              widget.story.title,
                              maxLines: 3,
                              softWrap: true,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 14.5,
                                height: 1.26,
                                fontWeight: FontWeight.w800,
                                color: isDark ? Colors.white.withOpacity(0.96) : scheme.onSurface,
                              ),
                            ),
                          ),
                          const Spacer(),
                          Row(
                            children: [
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
                                              if (_isWatchCta && _videoUrl != null) {
                                                _openDetails(autoplay: true);
                                              } else {
                                                _openExternalLink(context);
                                              }
                                            }
                                          : null,
                                      style: ElevatedButton.styleFrom(
                                        foregroundColor: Colors.white,
                                        backgroundColor: const Color(0xFFdc2626),
                                        elevation: 0,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        padding: const EdgeInsets.symmetric(horizontal: 12),
                                        textStyle: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 14,
                                        ),
                                      ),
                                      label: Text(_ctaLabel),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              AnimatedBuilder(
                                animation: SavedStore.instance,
                                builder: (_, __) {
                                  final saved = SavedStore.instance.isSaved(widget.story.id);
                                  return _ActionIconBox(
                                    tooltip: saved ? 'Saved' : 'Save',
                                    onTap: () => SavedStore.instance.toggle(widget.story.id),
                                    icon: const _Emoji(emoji: '🔖', size: 18),
                                  );
                                },
                              ),
                              const SizedBox(width: 6),
                              _ActionIconBox(
                                tooltip: 'Share',
                                onTap: () => _share(context),
                                icon: const _Emoji(emoji: '📤', size: 18),
                              ),
                            ],
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
              borderRadius: BorderRadius.circular(18),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
                child: card,
              ),
            ),
    );
  }
}

/* --------------------------- Kind badge --------------------------- */
Widget KindMetaBadge(String kind) {
  final lower = kind.toLowerCase();
  Color bg;
  String label = kind.toUpperCase();

  if (lower == 'news') {
    bg = const Color(0xFF723A3C);
  } else if (lower == 'release') {
    bg = const Color(0xFFF9D359);
  } else if (lower == 'trailer') {
    bg = const Color(0xFF56BAF8);
  } else if (lower == 'ott') {
    bg = const Color(0xFFC377F2);
  } else {
    bg = Colors.grey.shade800;
  }

  return Container(
    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 11),
    decoration: BoxDecoration(
      color: bg.withOpacity(0.96),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: lower == 'release' ? Colors.black : Colors.white,
        fontWeight: FontWeight.w700,
        fontSize: 12.5,
        letterSpacing: 0.15,
      ),
    ),
  );
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
    return Icon(iconData, size: 60, color: iconColor.withOpacity(0.9));
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

/* --------- Compact secondary action icon --------- */
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
    return Tooltip(
      message: tooltip,
      child: Material(
        color: isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.06),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: const SizedBox(
            width: 36,
            height: 36,
            child: Center(child: null), // icon drawn below with Stack
          ),
        ),
      ),
    );
  }
}

/* ---------------------- Back-compat extension ---------------------- */
extension _StoryCompat on Story {
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
