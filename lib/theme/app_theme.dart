// lib/theme/app_theme.dart
import 'package:flutter/material.dart';

/// ─────────────────────────── Brand tokens ───────────────────────────
class Brand {
  // Accent
  static const Color primary = Color(0xFF4DA8FF); // CinePulse blue
  static const Color freshRed = Color(0xFFFF4D6A); // “freshness +Xm” only

  // Dark surfaces
  static const Color darkBgStart = Color(0xFF0D1117);
  static const Color darkBgEnd = Color(0xFF111827);
  static const Color darkCardTop = Color(0xFF1A2333);
  static const Color darkCardBottom = Color(0xFF111927);
  static const Color ctaBgDark = Color(0xFF1F2A3B);
  static const Color outlineDark = Color(0x14FFFFFF); // ~8% white hairline

  // Light surfaces
  static const Color lightBg = Color(0xFFF7FAFC);
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color outlineLight = Color(0xFFE5E7EB);
}

/// Central theme builder for CinePulse.
/// Primary (blue) drives pills, chips, buttons, etc.
/// Freshness red is used only for the "+Xm" timestamp highlights.
class AppTheme {
  /* ───────────────────────────── DARK THEME ───────────────────────────── */
  static ThemeData get dark {
    final base = ColorScheme.dark(
      primary: Brand.primary,
      secondary: Brand.primary,
      surface: Brand.darkCardBottom,
      background: Brand.darkBgEnd,
      onPrimary: Colors.white,
      onSurface: Colors.white,
      onBackground: Colors.white,
      error: Brand.freshRed,
    ).copyWith(
      // Better hairlines + containers for cards
      outlineVariant: Brand.outlineDark,
      surfaceContainerHighest: Brand.darkCardTop,
      // Keep scrim/shadow predictable for overlays/gradients
      scrim: Colors.black,
    );

    final rounded10 = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: base,
      scaffoldBackgroundColor: Brand.darkBgEnd,
      cardColor: Brand.darkCardTop,
      shadowColor: Colors.black, // used by StoryCard glow
      dividerTheme: DividerThemeData(
        color: base.outlineVariant,
        thickness: 1,
        space: 0,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
      ),

      // Buttons (CTAs → blue)
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: base.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: rounded10,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: base.primary,
          foregroundColor: Colors.white,
          shape: rounded10,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: base.primary,
          side: BorderSide(color: base.primary),
          shape: rounded10,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: MaterialStatePropertyAll(base.onSurface),
          overlayColor:
              MaterialStatePropertyAll(base.primary.withOpacity(.08)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: base.primary,
        foregroundColor: Colors.white,
      ),

      // Toggles
      switchTheme: SwitchThemeData(
        thumbColor: MaterialStatePropertyAll(base.primary),
        trackColor: MaterialStateProperty.resolveWith(
          (s) => s.contains(MaterialState.selected)
              ? base.primary.withOpacity(.35)
              : Colors.white24,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: MaterialStatePropertyAll(base.primary),
      ),
      radioTheme: RadioThemeData(
        fillColor: MaterialStatePropertyAll(base.primary),
      ),

      // Chips & Segmented
      chipTheme: ChipThemeData(
        backgroundColor: Brand.darkCardBottom,
        selectedColor: base.primary.withOpacity(.18),
        side: BorderSide(color: base.primary.withOpacity(.45)),
        labelStyle: const TextStyle(color: Colors.white),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          side: MaterialStatePropertyAll(
            BorderSide(color: base.primary.withOpacity(.45)),
          ),
          backgroundColor: MaterialStateProperty.resolveWith(
            (s) => s.contains(MaterialState.selected)
                ? base.primary.withOpacity(.18)
                : Colors.transparent,
          ),
          foregroundColor: const MaterialStatePropertyAll(Colors.white),
          shape: MaterialStatePropertyAll(rounded10),
        ),
      ),

      progressIndicatorTheme:
          ProgressIndicatorThemeData(color: base.primary),

      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Colors.transparent,
        selectedItemColor: base.primary,
        unselectedItemColor: Colors.white.withOpacity(0.75),
        type: BottomNavigationBarType.fixed,
      ),

      dividerColor: base.outlineVariant,
    );
  }

  /* ───────────────────────────── LIGHT THEME ──────────────────────────── */
  static ThemeData get light {
    final base = ColorScheme.light(
      primary: Brand.primary,
      secondary: Brand.primary,
      surface: Brand.lightCard,
      background: Brand.lightBg,
      onPrimary: Colors.white,
      onSurface: const Color(0xFF111827),
      onBackground: const Color(0xFF111827),
      error: Brand.freshRed,
    ).copyWith(
      outlineVariant: Brand.outlineLight,
      scrim: Colors.black,
    );

    final rounded10 = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: base,
      scaffoldBackgroundColor: Brand.lightBg,
      cardColor: Brand.lightCard,
      shadowColor: Colors.black,
      dividerTheme: DividerThemeData(
        color: base.outlineVariant,
        thickness: 1,
        space: 0,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: base.onSurface,
        elevation: 0,
        centerTitle: false,
      ),

      // Buttons (CTAs → blue)
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: base.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: rounded10,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: base.primary,
          foregroundColor: Colors.white,
          shape: rounded10,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: base.primary,
          side: BorderSide(color: base.primary),
          shape: rounded10,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: MaterialStatePropertyAll(base.onSurface),
          overlayColor:
              MaterialStatePropertyAll(base.primary.withOpacity(.08)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: base.primary,
        foregroundColor: Colors.white,
      ),

      // Toggles
      switchTheme: SwitchThemeData(
        thumbColor: MaterialStatePropertyAll(base.primary),
        trackColor: MaterialStateProperty.resolveWith(
          (s) => s.contains(MaterialState.selected)
              ? base.primary.withOpacity(.25)
              : Colors.black12,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: MaterialStatePropertyAll(base.primary),
      ),
      radioTheme: RadioThemeData(
        fillColor: MaterialStatePropertyAll(base.primary),
      ),

      // Chips & Segmented
      chipTheme: ChipThemeData(
        backgroundColor: base.surface,
        selectedColor: base.primary.withOpacity(.12),
        side: BorderSide(color: base.primary.withOpacity(.35)),
        labelStyle: TextStyle(color: base.onSurface),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          side: MaterialStatePropertyAll(
            BorderSide(color: base.primary.withOpacity(.35)),
          ),
          backgroundColor: MaterialStateProperty.resolveWith(
            (s) => s.contains(MaterialState.selected)
                ? base.primary.withOpacity(.12)
                : Colors.transparent,
          ),
          foregroundColor: MaterialStatePropertyAll(base.onSurface),
          shape: MaterialStatePropertyAll(rounded10),
        ),
      ),

      progressIndicatorTheme:
          ProgressIndicatorThemeData(color: base.primary),

      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Colors.transparent,
        selectedItemColor: base.primary,
        unselectedItemColor: base.onSurface.withOpacity(0.65),
        type: BottomNavigationBarType.fixed,
      ),

      dividerColor: base.outlineVariant,
    );
  }
}
