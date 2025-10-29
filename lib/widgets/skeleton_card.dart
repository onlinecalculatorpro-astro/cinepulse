// lib/widgets/skeleton_card.dart
//
// Loading placeholder for StoryCard tiles.
// Used in Home / Discover / Saved / Alerts while content is fetching.
//
// Visual goals:
// - Same general shape and spacing as a real StoryCard
//   (media on top, body content, CTA row at the bottom).
// - Pulsing fill so the card feels alive but not distracting.
// - Matches our card chrome: 22px radius, subtle border, drop shadow.
//
// Layout notes:
// - The top "media" box uses a responsive height that mirrors StoryCard's
//   aspect logic so grids don't jump when real data arrives.
// - Body stub has:
//     • Row with a "badge", avatar circle, and short meta bar
//     • 2–3 title lines depending on available height
//     • Bottom row with primary CTA pill and two square icon buttons
//
// Animation:
// - A single AnimationController loops 0→1→0 with easeInOut.
// - We lerp between two opacities of surfaceContainerHighest to get a soft
//   breathing effect, then tint the skeleton chunks with that.
//
import 'dart:math' as math;
import 'package:flutter/material.dart';

class SkeletonCard extends StatefulWidget {
  const SkeletonCard({super.key});

  @override
  State<SkeletonCard> createState() => _SkeletonCardState();
}

class _SkeletonCardState extends State<SkeletonCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        // Ease curve so the glow slows in/out
        final t = Curves.easeInOut.transform(_pulse.value);

        // Base + hi are both derived from surfaceContainerHighest, just with
        // different opacities. We lerp them so the "fill" breathes.
        final base =
            cs.surfaceContainerHighest.withOpacity(isDark ? 0.28 : 0.24);
        final hi =
            cs.surfaceContainerHighest.withOpacity(isDark ? 0.55 : 0.44);
        final fill = Color.lerp(base, hi, 0.5 + 0.5 * t)!;

        return LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            final h = box.maxHeight;

            // Match StoryCard's media height rules:
            // - wider screens lean more cinematic (16:7, 16:9)
            // - medium / tablet-ish (3:2)
            // - phone-ish (4:3)
            final aspectGuess = w >= 1200
                ? (16 / 7)
                : w >= 900
                    ? (16 / 9)
                    : w >= 600
                        ? (3 / 2)
                        : (4 / 3);

            // clamp so tiny tiles don't get absurdly short
            final mediaHeight = (w / aspectGuess)
                .clamp(120.0, math.max(140.0, h.isFinite ? h * 0.45 : 220.0));

            return Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: cs.surface.withOpacity(isDark ? 0.92 : 0.97),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: Colors.white.withOpacity(0.08),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.18),
                    blurRadius: 22,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Media placeholder (poster / thumbnail / still)
                  Container(
                    height: mediaHeight.toDouble(),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: isDark
                            ? [
                                const Color(0xFF101626),
                                const Color(0xFF232941),
                              ]
                            : [
                                const Color(0xFFE7EBF2),
                                const Color(0xFFD1D5DC),
                              ],
                      ),
                    ),
                    // Sub-layer fill adds the pulsing "shimmer" wash
                    child: Container(
                      color: fill.withOpacity(0.25),
                    ),
                  ),

                  // ── Body stub
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 18,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Top meta row: kind pill, avatar, timestamp-ish bar
                          Row(
                            children: [
                              _pill(
                                fill,
                                width: 68,
                                height: 22,
                                radius: 6,
                              ),
                              const SizedBox(width: 10),
                              _circle(fill, 24),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _bar(
                                  fill,
                                  height: 10,
                                  opacity: 0.7,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),

                          // Headline lines (2-3 depending on card height)
                          _bar(fill, height: 14),
                          const SizedBox(height: 8),
                          _bar(
                            fill,
                            height: 14,
                            widthFactor: 0.85,
                          ),
                          if (!h.isFinite || h >= 360) ...[
                            const SizedBox(height: 8),
                            _bar(
                              fill,
                              height: 14,
                              widthFactor: 0.55,
                            ),
                          ],

                          const Spacer(),

                          // Bottom action row:
                          // big CTA pill + two square icon buttons
                          Row(
                            children: [
                              Expanded(
                                child: _pill(
                                  fill,
                                  height: 46,
                                  radius: 10,
                                ),
                              ),
                              const SizedBox(width: 12),
                              _square(
                                fill,
                                44,
                                radius: 10,
                              ),
                              const SizedBox(width: 8),
                              _square(
                                fill,
                                44,
                                radius: 10,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // Horizontal bar (used for title lines, timestamp line, etc.)
  Widget _bar(
    Color fill, {
    double height = 12,
    double widthFactor = 1,
    double opacity = 1,
  }) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: fill.withOpacity(opacity),
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
  }

  // Rounded rect (badge, CTA button placeholder, etc.)
  Widget _pill(
    Color fill, {
    double width = double.infinity,
    double height = 28,
    double radius = 8,
  }) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: Colors.white.withOpacity(0.04),
          width: 1,
        ),
      ),
    );
  }

  // Square / circle button placeholders
  Widget _square(
    Color fill,
    double size, {
    double radius = 8,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: Colors.white.withOpacity(0.04),
          width: 1,
        ),
      ),
    );
  }

  Widget _circle(Color fill, double size) =>
      _square(fill, size, radius: size / 2);
}
