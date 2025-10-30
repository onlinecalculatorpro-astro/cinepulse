// lib/theme/toolbar.dart
import 'package:flutter/material.dart';
import 'theme_colors.dart'; // outlineHairline(), etc.

/// Brand-consistent toolbar chip:
/// • Inactive → neutral text (onSurface) + hairline border (no blue text)
/// • Active   → primary fill + onPrimary text (keeps accent only for active)
class ToolbarChip extends StatelessWidget {
  const ToolbarChip({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (active) {
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: cs.primary,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: cs.primary, width: 1),
            boxShadow: [
              BoxShadow(
                color: cs.primary.withOpacity(0.35),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.2,
              color: cs.onPrimary,
            ),
          ),
        ),
      );
    }

    // Inactive state: neutral text + subtle hairline border.
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: outlineHairline(context), width: 1),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            height: 1.2,
            color: cs.onSurface, // <- neutral, high-contrast in dark & light
          ),
        ),
      ),
    );
  }
}

/// Neutral container for "Recent ▼" / "Latest first ▼" sort controls.
/// Use neutral icon/text colors (cs.onSurface) inside.
Widget toolbarSortPill({
  required BuildContext context,
  required Widget child,
}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: outlineHairline(context), width: 1),
    ),
    child: child,
  );
}
