// lib/app/app.dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../root_shell.dart';
import 'app_settings.dart';
import 'no_glow_scroll.dart';

class CinePulseApp extends StatelessWidget {
  const CinePulseApp({super.key});

  // Approved Nutshell palette (kept minimal glow)
  static const _accentRed = Color(0xFFD12C3B);

  // DARK
  static const _darkBg = Color(0xFF0C0F14);      // page background
  static const _darkSurface = Color(0xFF151B28); // card/base surface
  static const _darkSurfaceLow = Color(0xFF0F1522); // lower container layer
  static const _darkOn = Color(0xFFFFFFFF);
  static const _darkOnAlt = Color(0xFFA7B3C7);   // secondary text

  // LIGHT
  static const _lightBg = Color(0xFFF7F9FC);
  static const _lightSurface = Color(0xFFFFFFFF);
  static const _lightOn = Color(0xFF1A1A1A);
  static const _lightOnAlt = Color(0xFF4B5563);

  @override
  Widget build(BuildContext context) {
    // Start with seeded schemes (for good container/variant ramps), then
    // pin our exact backgrounds/surfaces/primary so the UI matches the mock.
    final light = ColorScheme.fromSeed(
      seedColor: _accentRed,
      brightness: Brightness.light,
    ).copyWith(
      primary: _accentRed,
      onPrimary: Colors.white,
      background: _lightBg,
      onBackground: _lightOn,
      surface: _lightSurface,
      onSurface: _lightOn,
      surfaceContainerLowest: const Color(0xFFF1F4F8),
      surfaceContainerLow: const Color(0xFFE9EEF6),
      onSurfaceVariant: _lightOnAlt,
      secondary: _lightOnAlt,
      onSecondary: _lightOn,
      outline: const Color(0xFFCBD5E1),
      outlineVariant: const Color(0xFFE2E8F0),
      error: const Color(0xFFFF4D6A),
      onError: Colors.white,
      scrim: Colors.black.withOpacity(0.6),
    );

    final dark = ColorScheme.fromSeed(
      seedColor: _accentRed,
      brightness: Brightness.dark,
    ).copyWith(
      primary: _accentRed,
      onPrimary: Colors.white,
      background: _darkBg,
      onBackground: _darkOn,
      surface: _darkSurface,
      onSurface: _darkOn,
      surfaceContainerLowest: _darkSurfaceLow,
      surfaceContainerLow: const Color(0xFF131A27),
      onSurfaceVariant: _darkOnAlt,
      secondary: _darkOnAlt,
      onSecondary: _darkOn,
      outline: Colors.white.withOpacity(0.08),
      outlineVariant: Colors.white.withOpacity(0.06),
      error: const Color(0xFFFF4D6A),
      onError: Colors.white,
      scrim: Colors.black.withOpacity(0.6),
    );

    ThemeData themed(ColorScheme scheme) {
      final isDark = scheme.brightness == Brightness.dark;
      final baseText =
          (isDark ? ThemeData.dark() : ThemeData.light()).textTheme;

      return ThemeData(
        useMaterial3: true,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        colorScheme: scheme,
        textTheme: GoogleFonts.interTextTheme(baseText),

        // Pages
        scaffoldBackgroundColor: scheme.background,
        canvasColor: scheme.background,

        // AppBar (keeps frosted/header look consistent)
        appBarTheme: AppBarTheme(
          elevation: 0,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          foregroundColor: scheme.onSurface,
          centerTitle: false,
        ),

        // Cards: rounded, low-elevation, match your tiles
        cardTheme: CardThemeData(
          elevation: 0,
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(
              color: isDark
                  ? Colors.white.withOpacity(0.08)
                  : Colors.black.withOpacity(0.06),
              width: 1,
            ),
          ),
          color: scheme.surface,
        ),

        // Bottom nav (compact) background is toned down (less glow)
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: isDark
              ? scheme.surface.withOpacity(0.92)
              : scheme.surface.withOpacity(0.96),
          indicatorColor: scheme.primary.withOpacity(0.20),
          iconTheme: MaterialStatePropertyAll(
            IconThemeData(color: scheme.primary),
          ),
          labelTextStyle: MaterialStatePropertyAll(
            GoogleFonts.inter(fontWeight: FontWeight.w600),
          ),
        ),

        chipTheme: ChipThemeData(
          side: BorderSide.none,
          backgroundColor: scheme.surfaceContainerLow,
          labelStyle: TextStyle(color: scheme.onSurfaceVariant),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),

        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: scheme.surface.withOpacity(isDark ? 0.72 : 0.86),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: scheme.primary, width: 2),
          ),
        ),
      );
    }

    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (_, __) {
        return MaterialApp(
          title: 'CinePulse',
          debugShowCheckedModeBanner: false,
          scrollBehavior: const NoGlowScroll(),
          themeMode: AppSettings.instance.themeMode,
          theme: themed(light),
          darkTheme: themed(dark),
          home: const RootShell(),
        );
      },
    );
    }
}
