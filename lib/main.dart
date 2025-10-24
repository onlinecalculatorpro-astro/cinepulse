// lib/main.dart
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'app/app.dart';
import 'app/app_settings.dart';
import 'core/api.dart';   // for kApiBaseUrl, kDeepLinkBase
import 'core/cache.dart';
import 'core/fcm_bootstrap.dart'; // <-- FCM init

Future<void> main() async {
  // Ensure bindings for async init (prefs, caches, plugins, etc.)
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase/FCM (channel, permissions, handlers, topic, token log)
  await initCinepulseFcm();

  // Default locale (can be overridden by device/user settings later).
  Intl.defaultLocale = 'en_US';

  // App-wide settings & persistent stores.
  await AppSettings.instance.init();
  await SavedStore.instance.init();

  // Log compiled-in config once (helps verify --dart-define on CI).
  debugPrint('[CinePulse] API_BASE_URL = $kApiBaseUrl');
  debugPrint('[CinePulse] DEEP_LINK_BASE = $kDeepLinkBase');

  // ---------- Global error handling ----------
  // Framework errors
  FlutterError.onError = (FlutterErrorDetails details) {
    // Keep Flutter's default red-screen in debug.
    FlutterError.presentError(details);
    final stack = details.stack ?? StackTrace.current;
    Zone.current.handleUncaughtError(details.exception, stack);
  };

  // Platform / engine errors (e.g., from plugins)
  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('Unhandled platform error: $error\n$stack');
    // Return true to indicate we've handled it.
    return true;
  };

  // Friendlier fallback widget when a build throws.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    final message = kReleaseMode ? 'Something went wrong.' : details.exceptionAsString();
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
