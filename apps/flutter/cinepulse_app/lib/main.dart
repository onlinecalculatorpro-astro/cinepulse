// lib/main.dart
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// If you don't have intl in pubspec.yaml yet, either add it or
// delete these two intl lines.
import 'package:intl/intl.dart';

import 'app/app.dart';
import 'app/app_settings.dart';
import 'core/cache.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Optional, safe to remove if you don't want intl:
  Intl.defaultLocale = 'en_US';

  // Initialise app settings and any persistent stores.
  await AppSettings.instance.init();
  await SavedStore.instance.init();

  // ---------- Global error handling ----------
  FlutterError.onError = (FlutterErrorDetails details) {
    // Keep Flutter's red screen in debug.
    FlutterError.presentError(details);
    final stack = details.stack ?? StackTrace.current;
    Zone.current.handleUncaughtError(details.exception, stack);
  };

  // Plugin/engine errors
  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('Unhandled platform error: $error\n$stack');
    return true; // handled
  };

  // Friendly fallback widget if a build throws in release.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    final msg = kReleaseMode ? 'Something went wrong.' : details.exceptionAsString();
    return Material(color: Colors.transparent, child: Center(child: Text(msg)));
  };

  // Guard all async errors.
  runZonedGuarded(
    () => runApp(const CinePulseApp()),
    (error, stack) => debugPrint('Uncaught zone error: $error\n$stack'),
  );
}
