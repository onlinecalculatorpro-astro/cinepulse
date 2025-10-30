// lib/theme/theme_colors.dart
import 'package:flutter/material.dart';

/// CinePulse theme helpers — single source of truth for brand colors
/// and readable text colors across light/dark.
///
/// ─ Brand palette (use these instead of hard-coded reds) ─
///   • kAccent        → primary CinePulse blue
///   • kAccentHi      → lighter blue for glow/gradients
///   • kFreshnessRed  → timestamp “+8m” / freshness pips
///
/// ─ Text helpers (keep names stable) ─
///   • primaryTextColor(context)    → main content text
///   • secondaryTextColor(context)  → metadata / subtext
///   • faintTextColor(context)      → extra subtle text
///
/// ─ Extra helpers ─
///   • accentColor(context)         → returns kAccent
///   • freshnessColor(context)      → returns kFreshnessRed
///   • neutralPillBg(context)       → translucent pill bg (headers/search)
///   • outlineHairline(context)     → 1px outline on neutral surfaces
///   • subtleDivider(context)       → thin section dividers

/* ───────────────────────── Brand palette ───────────────────────── */

const kAccent       = Color(0xFF4DA8FF); // CinePulse blue
const kAccentHi     = Color(0xFF82C4FF); // lighter blue for glow/gradients
const kFreshnessRed = Color(0xFFFF4D6A); // “freshness” timestamp color

// Optional surface colors (useful for themed backgrounds/cards if needed)
const kDarkBgStart = Color(0xFF0D1117);
const kDarkBgEnd   = Color(0xFF111827);
const kCardTop     = Color(0xFF1A2333);
const kCardBottom  = Color(0xFF111927);

/* ───────────────────── Convenience accessors ──────────────────── */

Color accentColor(BuildContext _) => kAccent;
Color freshnessColor(BuildContext _) => kFreshnessRed;

/// Neutral translucent pill background (header buttons, search bars, etc.)
Color neutralPillBg(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark
      ? const Color(0xFF0f172a).withOpacity(0.7)
      : Colors.black.withOpacity(0.06);
}

/// Hairline/outline for subtle 1px borders on neutral surfaces.
Color outlineHairline(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark
      ? Colors.white.withOpacity(0.12)
      : Colors.black.withOpacity(0.12);
}

/// Very subtle divider line between rows/sections.
Color subtleDivider(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark
      ? Colors.white.withOpacity(0.06)
      : Colors.black.withOpacity(0.06);
}

/* ───────────────────── Readable text colors ───────────────────── */

/// Main body text / titles / headlines inside cards or header.
Color primaryTextColor(BuildContext context) {
  final brightness = Theme.of(context).brightness;
  return brightness == Brightness.dark
      ? Colors.white
      : const Color(0xFF1A1A1A); // strong contrast on light bg
}

/// Metadata like timestamp, “Source:”, subtle labels.
Color secondaryTextColor(BuildContext context) {
  final brightness = Theme.of(context).brightness;
  return brightness == Brightness.dark
      ? Colors.white70
      : const Color(0xFF4B5563); // gray-600 style
}

/// Extra low emphasis (used previously as white30/38).
Color faintTextColor(BuildContext context) {
  final brightness = Theme.of(context).brightness;
  return brightness == Brightness.dark
      ? Colors.white38
      : const Color(0xFF9CA3AF); // gray-400 style
}
