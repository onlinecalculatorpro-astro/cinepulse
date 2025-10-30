// lib/theme/app_theme.dart
import 'package:flutter/material.dart';

/// Brand tokens (kept minimal; expand if needed)
class Brand {
  // Shared
  static const Color primary = Color(0xFF4DA8FF); // accent blue
  static const Color freshRed = Color(0xFFFF4D6A);

  // Dark
  static const Color darkBgStart   = Color(0xFF0D1117);
  static const Color darkBgEnd     = Color(0xFF111827);
  static const Color darkCardTop   = Color(0xFF1A2333);
  static const Color darkCardBottom= Color(0xFF111927);
  static const Color darkCta       = Color(0xFF1F2A3B);
  static const Color outlineDark   = Color(0x14FFFFFF); // ~8% white

  // Light (complementary, subdued)
  static const Color lightBg       = Color(0xFFF7FAFC);
  static const Color lightCard     = Color(0xFFFFFFFF);
  static const Color outlineLight  = Color(0xFFE5E7EB);
}

class AppTheme {
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
      surfaceContainerHighest: Brand.darkCardTop, // used by some M3 widgets
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
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: Brand.darkCta,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Colors.transparent,
        selectedItemColor: scheme.primary,
        unselectedItemColor: Colors.white.withOpacity(0.75),
        type: BottomNavigationBarType.fixed,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Brand.darkCardBottom,
        selectedColor: scheme.primary.withOpacity(0.18),
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: const TextStyle(color: Colors.white),
      ),
      dividerColor: scheme.outlineVariant,
    );
  }

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
    ).copyWith(
      outlineVariant: Brand.outlineLight,
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
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Colors.transparent,
        selectedItemColor: scheme.primary,
        unselectedItemColor: scheme.onSurface.withOpacity(0.65),
        type: BottomNavigationBarType.fixed,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surface,
        selectedColor: scheme.primary.withOpacity(0.12),
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: TextStyle(color: scheme.onSurface),
      ),
      dividerColor: scheme.outlineVariant,
    );
  }
}
