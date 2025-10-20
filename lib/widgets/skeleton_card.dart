// lib/widgets/skeleton_card.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';

class SkeletonCard extends StatefulWidget {
  const SkeletonCard({super.key});

  @override
  State<SkeletonCard> createState() => _SkeletonCardState();
}

class _SkeletonCardState extends State<SkeletonCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: _ac,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_ac.value);
        final base = cs.surfaceContainerHighest.withOpacity(isDark ? 0.28 : 0.24);
        final hi = cs.surfaceContainerHighest.withOpacity(isDark ? 0.55 : 0.44);
        final fill = Color.lerp(base, hi, 0.5 + 0.5 * t)!;

        return LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            final h = box.maxHeight;

            // Match StoryCard’s responsive media height
            final targetAspect = w >= 1200
                ? (16 / 7)
                : w >= 900
                    ? (16 / 9)
                    : w >= 600
                        ? (3 / 2)
                        : (4 / 3);
            final mediaH = (w / targetAspect)
                .clamp(120.0, math.max(140.0, h.isFinite ? h * 0.45 : 220.0));

            return Container(
              decoration: BoxDecoration(
                color: cs.surface.withOpacity(isDark ? 0.92 : 0.97),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Colors.white.withOpacity(0.08), width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.18),
                    blurRadius: 22,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Media placeholder (responsive height)
                  Container(
                    height: mediaH.toDouble(),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: isDark
                            ? [const Color(0xFF101626), const Color(0xFF232941)]
                            : [const Color(0xFFE7EBF2), const Color(0xFFD1D5DC)],
                      ),
                    ),
                    child: Container(color: fill.withOpacity(0.25)),
                  ),

                  // Body
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Kind badge + meta line
                          Row(
                            children: [
                              _pill(fill, width: 68, height: 22, radius: 6),
                              const SizedBox(width: 10),
                              _circle(fill, 24),
                              const SizedBox(width: 8),
                              Expanded(child: _bar(fill, height: 10, opacity: 0.7)),
                            ],
                          ),
                          const SizedBox(height: 14),

                          // Title lines (2–3 based on height)
                          _bar(fill, height: 14),
                          const SizedBox(height: 8),
                          _bar(fill, height: 14, widthFactor: 0.85),
                          if (!h.isFinite || h >= 360) ...[
                            const SizedBox(height: 8),
                            _bar(fill, height: 14, widthFactor: 0.55),
                          ],
                          const Spacer(),

                          // CTA + secondary actions
                          Row(
                            children: [
                              Expanded(child: _pill(fill, height: 46, radius: 10)),
                              const SizedBox(width: 12),
                              _square(fill, 44, radius: 10),
                              const SizedBox(width: 8),
                              _square(fill, 44, radius: 10),
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

  Widget _bar(Color fill, {double height = 12, double widthFactor = 1, double opacity = 1}) {
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

  Widget _pill(Color fill, {double width = double.infinity, double height = 28, double radius = 8}) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withOpacity(0.04), width: 1),
      ),
    );
  }

  Widget _square(Color fill, double size, {double radius = 8}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withOpacity(0.04), width: 1),
      ),
    );
  }

  Widget _circle(Color fill, double size) => _square(fill, size, radius: size / 2);
}
