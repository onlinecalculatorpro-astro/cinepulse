import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../root_shell.dart';
import 'app_settings.dart';
import 'no_glow_scroll.dart';

class CinePulseApp extends StatelessWidget {
  const CinePulseApp({super.key});

  @override
  Widget build(BuildContext context) {
    final light = ColorScheme.fromSeed(seedColor: const Color(0xFF6B4EFF));
    final dark = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6B4EFF),
      brightness: Brightness.dark,
    );

    TextTheme font(TextTheme base) => GoogleFonts.interTextTheme(base);

    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (_, __) {
        return MaterialApp(
          title: 'CinePulse',
          debugShowCheckedModeBanner: false,
          scrollBehavior: const NoGlowScroll(),
          themeMode: AppSettings.instance.themeMode,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: light,
            textTheme: font(ThemeData.light().textTheme),
            scaffoldBackgroundColor: light.surface,
            cardTheme: CardThemeData(
              elevation: 0,
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              color: light.surfaceContainerLowest,
            ),
            navigationBarTheme: NavigationBarThemeData(
              indicatorColor: light.primaryContainer,
              iconTheme: WidgetStatePropertyAll(
                IconThemeData(color: light.primary),
              ),
              labelTextStyle: WidgetStatePropertyAll(
                GoogleFonts.inter(fontWeight: FontWeight.w600),
              ),
              backgroundColor: light.surface.withOpacity(0.96),
            ),
            chipTheme: ChipThemeData(
              side: BorderSide.none,
              color: WidgetStatePropertyAll(light.surfaceContainerHighest),
              labelStyle: TextStyle(color: light.onSurfaceVariant),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: light.surface.withOpacity(0.8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: light.outlineVariant),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: light.outlineVariant),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: light.primary, width: 2),
              ),
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: dark,
            textTheme: font(ThemeData.dark().textTheme),
            scaffoldBackgroundColor: dark.surface,
            cardTheme: CardThemeData(
              elevation: 0,
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              color: dark.surfaceContainerLowest,
            ),
            chipTheme: ChipThemeData(
              side: BorderSide.none,
              color: WidgetStatePropertyAll(dark.surfaceContainerHighest),
              labelStyle: TextStyle(color: dark.onSurfaceVariant),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
          ),
          home: const RootShell(),
        );
      },
    );
  }
}
