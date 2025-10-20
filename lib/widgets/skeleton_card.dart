// lib/widgets/skeleton_card.dart
import 'package:flutter/material.dart';

class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1200),
      curve: Curves.easeInOut,
      builder: (context, t, _) {
        // Subtle pulse between base and highlight
        final base = cs.surfaceContainerHighest.withOpacity(0.28);
        final highlight = cs.surfaceContainerHighest.withOpacity(0.55);
        final fill = Color.lerp(base, highlight, 0.5 + 0.5 * t)!;

        return Container(
          decoration: BoxDecoration(
            color: cs.surface.withOpacity(0.60),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withOpacity(0.04), width: 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 16:9 thumbnail/poster
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: DecoratedBox(decoration: BoxDecoration(color: fill)),
                  ),
                ),
                const SizedBox(height: 12),

                // Kind badge + meta line
                Row(
                  children: [
                    // badge pill
                    Container(
                      height: 22,
                      width: 64,
                      decoration: BoxDecoration(
                        color: fill,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // meta text stub
                    Expanded(
                      child: Container(
                        height: 12,
                        decoration: BoxDecoration(
                          color: fill,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Title lines (2)
                Container(
                  height: 16,
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 8),
                FractionallySizedBox(
                  widthFactor: 0.6,
                  child: Container(
                    height: 16,
                    decoration: BoxDecoration(
                      color: fill,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Actions row: primary button + two circular icons
                Row(
                  children: [
                    // Primary CTA button
                    Container(
                      height: 36,
                      width: 110,
                      decoration: BoxDecoration(
                        color: fill,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    const Spacer(),
                    _circle(fill),
                    const SizedBox(width: 8),
                    _circle(fill),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static Widget _circle(Color fill) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
    );
  }
}
