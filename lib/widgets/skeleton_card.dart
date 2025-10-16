import 'package:flutter/material.dart';

class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1200),
      curve: Curves.easeInOut,
      builder: (context, t, child) {
        final base = scheme.surfaceContainerHighest.withOpacity(0.3);
        final highlight = scheme.surfaceContainerHighest.withOpacity(0.6);
        final color =
            Color.lerp(base, highlight, (0.5 + 0.5 * (t)).clamp(0, 1));

        return Card(
          color: scheme.surface.withOpacity(0.6),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 120,
                  height: 72,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        height: 16,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 16,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: List.generate(
                          3,
                          (i) => Expanded(
                            child: Container(
                              height: 28,
                              margin: EdgeInsets.only(right: i == 2 ? 0 : 8),
                              decoration: BoxDecoration(
                                color: color,
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
