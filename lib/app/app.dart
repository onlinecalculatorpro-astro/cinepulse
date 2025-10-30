// lib/app/app.dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../root_shell.dart';
import 'app_settings.dart';
import 'no_glow_scroll.dart';
import '../theme/app_theme.dart'; // <-- single source of truth for colors

class CinePulseApp extends StatelessWidget {
  const CinePulseApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Apply Inter on top of our centralized themes.
    final ThemeData lightTheme =
        AppTheme.light.copyWith(textTheme: GoogleFonts.interTextTheme(AppTheme.light.textTheme));
    final ThemeData darkTheme =
        AppTheme.dark.copyWith(textTheme: GoogleFonts.interTextTheme(AppTheme.dark.textTheme));

    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (_, __) {
        return MaterialApp(
          title: 'CinePulse',
          debugShowCheckedModeBanner: false,
          scrollBehavior: const NoGlowScroll(),
          themeMode: AppSettings.instance.themeMode,
          theme: lightTheme,
          darkTheme: darkTheme,
          home: const RootShell(),
        );
      },
    );
  }
}
