// lib/app/app.dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../root_shell.dart';
import 'app_settings.dart';
import 'no_glow_scroll.dart';
import '../theme/app_theme.dart'; // <-- single source of truth

class CinePulseApp extends StatelessWidget {
  const CinePulseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (_, __) {
        final light = AppTheme.light.copyWith(
          textTheme: GoogleFonts.interTextTheme(AppTheme.light.textTheme),
        );
        final dark = AppTheme.dark.copyWith(
          textTheme: GoogleFonts.interTextTheme(AppTheme.dark.textTheme),
        );

        return MaterialApp(
          title: 'CinePulse',
          debugShowCheckedModeBanner: false,
          scrollBehavior: const NoGlowScroll(),
          themeMode: AppSettings.instance.themeMode,
          theme: light,
          darkTheme: dark,
          home: const RootShell(),
        );
      },
    );
  }
}
