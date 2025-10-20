// lib/widgets/kind_badge.dart
import 'package:flutter/material.dart';

class KindBadge extends StatelessWidget {
  const KindBadge(
    this.text, {
    super.key,
    this.compact = false,
    this.background,
    this.foreground = Colors.white,
  });

  final String text;
  final bool compact;
  final Color? background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color bg = background ?? const Color(0xFFdc2626); // brand red

    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: bg.withOpacity(0.24),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(
          color: isDark ? Colors.white.withOpacity(0.06) : Colors.transparent,
          width: 1,
        ),
      ),
      child: Text(
        (text.isEmpty ? 'NEWS' : text).toUpperCase(),
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: foreground,
        ),
      ),
    );
  }
}
