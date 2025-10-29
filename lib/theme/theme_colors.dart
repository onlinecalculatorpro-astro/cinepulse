import 'package:flutter/material.dart';

/// Centralized dynamic text colors for light vs dark.
/// Call these instead of hardcoding Colors.white / Colors.white70 / etc.
///
/// Usage:
///   color: primaryTextColor(context)      // main content text
///   color: secondaryTextColor(context)    // metadata / subtext
///   color: faintTextColor(context)        // extra subtle text
///
/// Dark mode → keep current white-on-dark look
/// Light mode → switch to dark grays so it's readable on pale cards
Color primaryTextColor(BuildContext context) {
  final brightness = Theme.of(context).brightness;
  // main body text / titles / headlines inside cards or header
  return brightness == Brightness.dark
      ? Colors.white
      : const Color(0xFF1A1A1A); // near-black, strong contrast on light bg
}

Color secondaryTextColor(BuildContext context) {
  final brightness = Theme.of(context).brightness;
  // metadata text like timestamp, "Source:", subtle labels
  return brightness == Brightness.dark
      ? Colors.white70
      : const Color(0xFF4B5563); // gray-600 style
}

Color faintTextColor(BuildContext context) {
  final brightness = Theme.of(context).brightness;
  // super low emphasis (you previously used Colors.white30/38)
  return brightness == Brightness.dark
      ? Colors.white38
      : const Color(0xFF9CA3AF); // gray-400 style
}
