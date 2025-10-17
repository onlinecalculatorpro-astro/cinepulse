// lib/main.dart
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'app/app.dart';
import 'app/app_settings.dart';
import 'core/cache.dart';

Future<void> main() async {
  // Ensure bindings for async init (prefs, licenses, etc.)
  WidgetsFlutterBinding.ensureInitialized();

  // Locale defaults (override per user/device later if needed)
  Intl.defaultLocale = 'en_US';

  // Initialize app-level settings and saved/bookmarks store
  await AppSettings.instance.init();
  await SavedStore.instance.init();

  // Global error handling
  FlutterError.onError = (FlutterErrorDetails details) {
    // Show default red error in debug; still forward to zone.
    FlutterError.presentError(details);
    if (details.stack != null) {
      Zone.current.handleUncaughtError(details.exception, details.stack!);
    } else {
      Zone.current.handleUncaughtError(details.exception, StackTrace.current);
    }
  };

  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('Unhandled platform error: $error\n$stack');
    // Return true to signal we've handled it (prevents duplicate crash).
    return true;
  };

  // Friendlier fallback widget when a build throws.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    final message = kReleaseMode
        ? 'Something went wrong.'
        : details.exceptionAsString();
    return Material(
      color: Colors.transparent,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14),
          ),
        ),
      ),
    );
  };

  // Run the app inside a zone to catch uncaught async errors.
  runZonedGuarded(
    () => runApp(const CinePulseApp()),
    (error, stack) {
      debugPrint('Uncaught zone error: $error\n$stack');
    },
  );
}
