// lib/theme/theme_colors.dart
import 'package:flutter/material.dart';

/// CinePulse theme helpers — one source of truth for brand + readable colors.
/// Keep these names stable. Replace any hard-coded reds with these tokens.
///
/// Brand palette
/// ───────────────────────────────────────────────────────────────────────────
/// • kAccent        → primary CinePulse blue
/// • kAccentHi      → lighter blue (glow/gradients)
/// • kFreshnessRed  → “+8m” / freshness pips
///
/// Text helpers
/// ───────────────────────────────────────────────────────────────────────────
/// • primaryTextColor(context)    → main content text
/// • secondaryTextColor(context)  → metadata / subtext
/// • faintTextColor(context)      → extra subtle text
///
/// Extras
/// ───────────────────────────────────────────────────────────────────────────
/// • accentColor(context)         → returns kAccent
/// • freshnessColor(context)      → returns kFreshnessRed
/// • neutralPillBg(context)       → translucent pill bg (headers/search)
/// • outlineHairline(context)     → 1px outline on neutral surfaces
/// • subtleDivider(context)       → thin section dividers
/// • kAccentGradient              → const [kAccent, kAccentHi]
/// • accentGlow(context)          → soft brand-colored shadow

/* ───────────────────────── Brand palette ───────────────────────── */

const kAccent       = Color(0xFF4DA8FF); // CinePulse blue
const kAccentHi     = Color(0xFF82C4FF); // lighter blue for glow/gradients
const kFreshnessRed = Color(0xFFFF4D6A); // “freshness” timestamp color

// Optional surfaces (dark theme backgrounds/cards)
const kDarkBgStart = Color(0xFF0D1117);
const kDarkBgEnd   = Color(0xFF111827);
const kCardTop     = Color(0xFF1A2333);
const kCardBottom  = Color(0xFF111927);

// Ready-to-use const gradient (good for ShaderMask, LinearGradient, etc.)
const List<Color> kAccentGradient = <Color>[kAccent, kAccentHi];

/* ───────────────────── Convenience accessors ──────────────────── */

Color accentColor(BuildContext _) => kAccent;
Color freshnessColor(BuildContext _) => kFreshnessRed;

/// Neutral translucent pill background (header buttons, search bars, etc.)
Color neutralPillBg(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark
      ? const Color(0xFF0f172a).withOpacity(0.70)
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

/// Soft brand-colored shadow (use on active chips, buttons, badges).
List<BoxShadow> accentGlow(BuildContext context) => [
      BoxShadow(
        color: accentColor(context).withOpacity(0.35),
        blurRadius: 20,
        offset: const Offset(0, 10),
      ),
    ];

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

/* ───────────────────── Optional: context getters ───────────────── */

extension CinePulseThemeX on BuildContext {
  Color get cpAccent => kAccent;
  Color get cpAccentHi => kAccentHi;
  Color get cpFreshness => kFreshnessRed;

  Color get cpText => primaryTextColor(this);
  Color get cpTextDim => secondaryTextColor(this);
  Color get cpTextFaint => faintTextColor(this);

  Color get cpPillBg => neutralPillBg(this);
  Color get cpHairline => outlineHairline(this);
  Color get cpDivider => subtleDivider(this);
  List<BoxShadow> get cpGlow => accentGlow(this);
}
