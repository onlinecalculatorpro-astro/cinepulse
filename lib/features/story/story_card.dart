// lib/features/story/story_card.dart
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
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
    final host = _linkUrl?.host?.toLowerCase() ?? '';
    final byHost = host.contains('youtube.com') || host.contains('youtu.be');
    final byType = widget.story.kind.toLowerCase() == 'trailer';
    final bySource = (widget.story.source ?? '').toLowerCase() == 'youtube';
    return byHost || byType || bySource;
  }

  String get _ctaLabel => _isWatchCta ? 'Watch' : 'Read';

  Future<void> _openLink(BuildContext context) async {
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copied to clipboard')),
        );
      }
    }
  }

  void _openDetails(BuildContext context) {
    Navigator.of(context).push(fadeRoute(StoryDetailsScreen(story: widget.story)));
  }

  // Leading for CTA: ▶ (Material icon) for watch, 📖 emoji for read
  Widget _ctaLeading() {
    if (_isWatchCta) {
      return const Icon(Icons.play_arrow_rounded, size: 22, color: Colors.white);
    }
    return const _Emoji(emoji: '📖', size: 18);
    }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final metaText = widget.story.metaLine;
    final hasUrl = _linkUrl != null;
    final kind = widget.story.kind.toLowerCase();

    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      transform: _hover ? (vm.Matrix4.identity()..translate(0.0, -4.0, 0.0)) : null,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF181E2A).withOpacity(0.92) : scheme.surface.withOpacity(0.97),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: _hover ? const Color(0x33dc2626) : Colors.white.withOpacity(0.08),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.22),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openDetails(context),
          child: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              final h = box.maxHeight;

              // Media height adapts to tile size & width.
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
                  // Icon/Thumbnail Section (responsive height)
                  SizedBox(
                    height: mediaH.toDouble(),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: isDark
                              ? [const Color(0xFF101626), const Color(0xFF232941)]
                              : [const Color(0xFFE7EBF2), const Color(0xFFD1D5DC)],
                        ),
                      ),
                      child: Center(child: _SampleIcon(kind: widget.story.kind)),
                    ),
                  ),

                  // Info/Meta (NEWS pill removed; show only 🕐 time)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              // 🕐 exact emoji for time
                              Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.13),
                                  shape: BoxShape.circle,
                                ),
                                child: const _Emoji(emoji: '🕐', size: 14),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  metaText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: Colors.grey[400], fontSize: 13.5),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),

                          // Title (2–3 lines depending on space)
                          Text(
                            widget.story.title,
                            maxLines: h.isFinite && h < 360 ? 2 : 3,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              height: 1.32,
                              fontWeight: FontWeight.w800,
                              color: isDark ? Colors.white.withOpacity(0.96) : scheme.onSurface,
                            ),
                          ),
                          const Spacer(),

                          // CTA row: full-width primary + compact secondary actions
                          Row(
                            children: [
                              Expanded(
                                child: Semantics(
                                  button: true,
                                  label: '${_ctaLabel} ${widget.story.title}',
                                  child: SizedBox(
                                    height: 46,
                                    child: ElevatedButton.icon(
                                      icon: _ctaLeading(),
                                      onPressed: hasUrl ? () => _openLink(context) : null,
                                      style: ElevatedButton.styleFrom(
                                        foregroundColor: Colors.white,
                                        backgroundColor: const Color(0xFFdc2626),
                                        elevation: 0,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                                      ),
                                      label: Text(_ctaLabel),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              // 🔖 Save (placeholder action)
                              _ActionIconBox(
                                tooltip: 'Save',
                                onTap: () {}, // hook up to your save flow
                                icon: const _Emoji(emoji: '🔖', size: 18),
                              ),
                              const SizedBox(width: 8),
                              // 📤 Share
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
              borderRadius: BorderRadius.circular(22),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
                child: card,
              ),
            ),
    );
  }
}

// --------- Sample Card Icon (category-specific with fallback) ---------
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

    return Icon(iconData, size: 70, color: iconColor.withOpacity(0.85));
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
      style: TextStyle(fontSize: size, height: 1),
    );
  }
}

// --------- Compact secondary action icon (supports emoji widget) ---------
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
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(child: icon),
          ),
        ),
      ),
    );
  }
}
