// lib/theme/app_theme.dart
import 'package:flutter/material.dart';

/// Brand tokens
class Brand {
  // Shared
  static const Color primary  = Color(0xFF4DA8FF); // CinePulse blue
  static const Color freshRed = Color(0xFFFF4D6A); // freshness only

  // Dark surfaces
  static const Color darkBgStart    = Color(0xFF0D1117);
  static const Color darkBgEnd      = Color(0xFF111827);
  static const Color darkCardTop    = Color(0xFF1A2333);
  static const Color darkCardBottom = Color(0xFF111927);
  static const Color outlineDark    = Color(0x14FFFFFF); // ~8% white

  // Light surfaces
  static const Color lightBg      = Color(0xFFF7FAFC);
  static const Color lightCard    = Color(0xFFFFFFFF);
  static const Color outlineLight = Color(0xFFE5E7EB);
}

class AppTheme {
  /* ------------------------------- DARK THEME ------------------------------ */
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
    );

    final rounded10 = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: Brand.darkBgEnd,
      cardColor: Brand.darkCardTop,
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
      ),

      // CTAs → blue
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
          overlayColor: MaterialStatePropertyAll(scheme.primary.withOpacity(.08)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary, foregroundColor: Colors.white,
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
          foregroundColor: MaterialStatePropertyAll(Colors.white),
          shape: MaterialStatePropertyAll(rounded10),
        ),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),

      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Colors.transparent,
        selectedItemColor: scheme.primary,
        unselectedItemColor: Colors.white.withOpacity(0.75),
        type: BottomNavigationBarType.fixed,
      ),

      dividerColor: scheme.outlineVariant,
    );
  }

  /* ------------------------------- LIGHT THEME ----------------------------- */
  static ThemeData get light {
    final scheme = const ColorScheme.light(
      primary: Brand.primary,
      secondary: Brand.primary,
      surface: Brand.lightCard,
      background: Brand.lightBg,
      onPrimary: Colors.white,
      onSurface: Color(0xFF111827),
      onBackground: Color(0xFF111827),
      error: Brand.freshRed,
    ).copyWith(outlineVariant: Brand.outlineLight);

    final rounded10 = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: Brand.lightBg,
      cardColor: Brand.lightCard,
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        centerTitle: false,
      ),

      // CTAs → blue
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
          overlayColor: MaterialStatePropertyAll(scheme.primary.withOpacity(.08)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary, foregroundColor: Colors.white,
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

      // Chips & segmented
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surface,
        selectedColor: scheme.primary.withOpacity(.12),
        side: BorderSide(color: scheme.primary.withOpacity(.35)),
        labelStyle: TextStyle(color: scheme.onSurface),
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

      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),

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
