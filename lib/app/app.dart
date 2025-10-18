// lib/app/app.dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../root_shell.dart';
import 'app_settings.dart';
import 'no_glow_scroll.dart';

class CinePulseApp extends StatelessWidget {
  const CinePulseApp({super.key});

  static const _brandBlue = Color(0xFF2563EB);

  @override
  Widget build(BuildContext context) {
    final light = ColorScheme.fromSeed(
      seedColor: _brandBlue,
      brightness: Brightness.light,
    );
    final dark = ColorScheme.fromSeed(
      seedColor: _brandBlue,
      brightness: Brightness.dark,
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
        scaffoldBackgroundColor: scheme.surface,

        appBarTheme: AppBarTheme(
          elevation: 0,
          backgroundColor: scheme.surface,
          foregroundColor: scheme.onSurface,
          centerTitle: false,
        ),

        // Use CardThemeData to match your toolchain
        cardTheme: CardThemeData(
          elevation: 0,
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          color: scheme.surfaceContainerLowest,
        ),

        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: scheme.surface.withOpacity(0.96),
          indicatorColor: scheme.primaryContainer,
          iconTheme: MaterialStatePropertyAll(
            IconThemeData(color: scheme.primary),
          ),
          labelTextStyle: MaterialStatePropertyAll(
            GoogleFonts.inter(fontWeight: FontWeight.w600),
          ),
        ),

        chipTheme: ChipThemeData(
          side: BorderSide.none,
          backgroundColor: scheme.surfaceContainerHighest,
          labelStyle: TextStyle(color: scheme.onSurfaceVariant),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),

        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: scheme.surface.withOpacity(isDark ? 0.72 : 0.80),
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
