// lib/theme/app_theme.dart
import 'package:flutter/material.dart';

/// ─────────────────────────── Brand tokens (single source of truth) ───────────────────────────
/// Mirrors nutshell_mock_light_toned.html:
///   --ink:#0f2d49; --ink-600:#154066;
///   --bg:#f6f7fb; --panel:#ffffff; --panel-border:#e6e9ef;
///   --text:#0b1220; --text-muted:#5b6476; --faint:#9aa3b2;
///   --meta-red:#dc2626 (we keep Brand.freshRed = #FF4D6A per product spec)
class Brand {
  // Accent / CTA
  static const Color primary = Color(0xFF0F2D49);   // = --ink (dark naval blue)
  static const Color primary600 = Color(0xFF154066); // = --ink-600 (richer hover/border)
  static const Color freshRed = Color(0xFFFF4D6A);   // freshness “+Xm” only

  // Light surfaces & text (HTML mock)
  static const Color lightBg = Color(0xFFF6F7FB);        // --bg
  static const Color lightCard = Color(0xFFFFFFFF);      // --panel
  static const Color outlineLight = Color(0xFFE6E9EF);   // --panel-border
  static const Color textLight = Color(0xFF0B1220);      // --text
  static const Color textMutedLight = Color(0xFF5B6476); // --text-muted
  static const Color faintLight = Color(0xFF9AA3B2);     // --faint

  // Dark surfaces (kept from your approved palette)
  static const Color darkBgStart = Color(0xFF0D1117);
  static const Color darkBgEnd = Color(0xFF111827);
  static const Color darkCardTop = Color(0xFF1A2333);
  static const Color darkCardBottom = Color(0xFF111927);
  static const Color outlineDark = Color(0x14FFFFFF); // ~8% white hairline
}

/// Central theme builder for CinePulse.
class AppTheme {
  /* ───────────────────────────── DARK THEME ───────────────────────────── */
  static ThemeData get dark {
    final scheme = const ColorScheme.dark(
      primary: Brand.primary,
      secondary: Brand.primary,
      surface: Brand.darkCardBottom,
      background: Brand.darkBgEnd,
      onPrimary: Colors.white,
      onSurface: Colors.white,
      onBackground: Colors.white,
      error: Brand.freshRed,
    ).copyWith(
      outlineVariant: Brand.outlineDark,
      surfaceContainerHighest: Brand.darkCardTop,
      scrim: Colors.black,
    );

    final rounded10 = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: Brand.darkBgEnd,
      cardColor: Brand.darkCardTop,
      shadowColor: Colors.black,
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 0,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
      ),

      // CTAs → primary ink
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: rounded10,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: Colors.white,
          shape: rounded10,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.primary),
          shape: rounded10,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: MaterialStatePropertyAll(scheme.onSurface),
          overlayColor:
              MaterialStatePropertyAll(scheme.primary.withOpacity(.08)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: Colors.white,
      ),

      // Selection controls
      switchTheme: SwitchThemeData(
        thumbColor: MaterialStatePropertyAll(scheme.primary),
        trackColor: MaterialStateProperty.resolveWith(
          (s) => s.contains(MaterialState.selected)
              ? scheme.primary.withOpacity(.35)
              : Colors.white24,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: MaterialStatePropertyAll(scheme.primary),
      ),
      radioTheme: RadioThemeData(
        fillColor: MaterialStatePropertyAll(scheme.primary),
      ),

      // Chips & segmented
      chipTheme: ChipThemeData(
        backgroundColor: Brand.darkCardBottom,
        selectedColor: scheme.primary.withOpacity(.18),
        side: BorderSide(color: scheme.primary.withOpacity(.45)),
        labelStyle: const TextStyle(color: Colors.white),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          side: MaterialStatePropertyAll(
            BorderSide(color: scheme.primary.withOpacity(.45)),
          ),
          backgroundColor: MaterialStateProperty.resolveWith(
            (s) => s.contains(MaterialState.selected)
                ? scheme.primary.withOpacity(.18)
                : Colors.transparent,
          ),
          foregroundColor: const MaterialStatePropertyAll(Colors.white),
          shape: MaterialStatePropertyAll(rounded10),
        ),
      ),

      progressIndicatorTheme:
          ProgressIndicatorThemeData(color: scheme.primary),

      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Colors.transparent,
        selectedItemColor: scheme.primary,
        unselectedItemColor: Colors.white.withOpacity(0.75),
        type: BottomNavigationBarType.fixed,
      ),

      dividerColor: scheme.outlineVariant,
    );
  }

  /* ───────────────────────────── LIGHT THEME ──────────────────────────── */
  static ThemeData get light {
    final scheme = const ColorScheme.light(
      primary: Brand.primary, // dark ink
      secondary: Brand.primary,
      surface: Brand.lightCard,
      background: Brand.lightBg,
      onPrimary: Colors.white,
      onSurface: Brand.textLight,       // main text
      onBackground: Brand.textLight,    // page text
      error: Brand.freshRed,
    ).copyWith(
      // carry the HTML mock neutrals into the scheme
      outlineVariant: Brand.outlineLight,
      onSurfaceVariant: Brand.textMutedLight, // “secondary” text
      // keep scrims consistent (thumb gradient overlays etc.)
      scrim: Colors.black,
    );

    final rounded10 = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: Brand.lightBg,
      cardColor: Brand.lightCard,
      shadowColor: Colors.black,
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 0,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        centerTitle: false,
      ),

      // CTAs → primary ink
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: rounded10,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: Colors.white,
          shape: rounded10,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.primary),
          shape: rounded10,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: MaterialStatePropertyAll(scheme.onSurface),
          overlayColor:
              MaterialStatePropertyAll(scheme.primary.withOpacity(.08)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: Colors.white,
      ),

      // Selection controls
      switchTheme: SwitchThemeData(
        thumbColor: MaterialStatePropertyAll(scheme.primary),
        trackColor: MaterialStateProperty.resolveWith(
          (s) => s.contains(MaterialState.selected)
              ? scheme.primary.withOpacity(.25)
              : Colors.black12,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: MaterialStatePropertyAll(scheme.primary),
      ),
      radioTheme: RadioThemeData(
        fillColor: MaterialStatePropertyAll(scheme.primary),
      ),

      // Chips & segmented (use mock’s soft chip bg/border via opacities)
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surface.withOpacity(0.92), // ~ --chip-bg
        side: BorderSide(color: scheme.outlineVariant),     // --chip-border
        selectedColor: scheme.primary.withOpacity(.12),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          side: MaterialStatePropertyAll(
            BorderSide(color: scheme.primary.withOpacity(.35)),
          ),
          backgroundColor: MaterialStateProperty.resolveWith(
            (s) => s.contains(MaterialState.selected)
                ? scheme.primary.withOpacity(.12)
                : Colors.transparent,
          ),
          foregroundColor: MaterialStatePropertyAll(scheme.onSurface),
          shape: MaterialStatePropertyAll(rounded10),
        ),
      ),

      progressIndicatorTheme:
          ProgressIndicatorThemeData(color: scheme.primary),

      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Colors.transparent,
        selectedItemColor: scheme.primary,
        unselectedItemColor: scheme.onSurface.withOpacity(0.65),
        type: BottomNavigationBarType.fixed,
      ),

      dividerColor: scheme.outlineVariant,
    );
  }
}
