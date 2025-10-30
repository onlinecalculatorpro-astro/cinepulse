// lib/main.dart
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform, kReleaseMode;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'app/app.dart';                 // CinePulseApp
import 'app/app_settings.dart';        // AppSettings singleton
import 'core/api.dart';                // kApiBaseUrl, kDeepLinkBase
import 'core/cache.dart';              // SavedStore
import 'core/fcm_bootstrap.dart';      // FCM init (Android only)

Future<void> main() async {
  // Ensure bindings for async init (prefs, plugins, channels).
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase/FCM ONLY on Android (skip web/others).
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await initCinepulseFcm();
  }

  // Default locale (device/user settings can override later).
  Intl.defaultLocale = 'en_US';

  // App-wide settings & persistent stores.
  await AppSettings.instance.init();
  await SavedStore.instance.init();

  // Log compiled-in config (verifies --dart-define in CI).
  debugPrint('[CinePulse] API_BASE_URL = $kApiBaseUrl');
  debugPrint('[CinePulse] DEEP_LINK_BASE = $kDeepLinkBase');

  // ---------- Global error handling ----------
  // Framework errors
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details); // Keep red screen in debug.
    final stack = details.stack ?? StackTrace.current;
    Zone.current.handleUncaughtError(details.exception, stack);
  };

  // Platform / engine errors (e.g., from plugins).
  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('Unhandled platform error: $error\n$stack');
    return true; // We've handled it.
  };

  // Friendlier fallback widget when a build throws.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    final message =
        kReleaseMode ? 'Something went wrong.' : details.exceptionAsString();
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

  // Run inside a guarded zone to catch uncaught async errors.
  runZonedGuarded(
    () => runApp(const CinePulseApp()),
    (error, stack) => debugPrint('Uncaught zone error: $error\n$stack'),
  );
}
