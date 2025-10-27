// lib/main.dart
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform, kReleaseMode;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'app/app.dart';
import 'app/app_settings.dart';
import 'core/api.dart'; // kApiBaseUrl, kDeepLinkBase
import 'core/cache.dart';
import 'core/fcm_bootstrap.dart'; // FCM init (Android only)

Future<void> main() async {
  // Make sure Flutter engine/services are ready before we do async work.
  WidgetsFlutterBinding.ensureInitialized();

  // Only set up Firebase/FCM on Android (not on web/iOS/etc.).
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await initCinepulseFcm();
  }

  // Default locale (can be overridden later by user/device).
  Intl.defaultLocale = 'en_US';

  // App-wide persisted stuff.
  await AppSettings.instance.init();
  await SavedStore.instance.init();

  // Log dart-define config so we know what the APK was built against.
  debugPrint('[CinePulse] API_BASE_URL = $kApiBaseUrl');
  debugPrint('[CinePulse] DEEP_LINK_BASE = $kDeepLinkBase');

  // ----- Global error handling -----

  // 1. Flutter framework build/layout errors.
  FlutterError.onError = (FlutterErrorDetails details) {
    // Still print the normal Flutter red screen in debug runs,
    // but also forward to the zone so we can catch it there.
    FlutterError.presentError(details);
    final stack = details.stack ?? StackTrace.current;
    Zone.current.handleUncaughtError(details.exception, stack);
  };

  // 2. Platform / plugin / engine errors.
  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('Unhandled platform error: $error\n$stack');
    // Return true = we handled it, so the engine won't double-log.
    return true;
  };

  // 3. Widget build failures.
  //    By default Flutter shows a red/yellow box with black text, which on our
  //    dark background can look basically "blank".
  //
  //    We override ErrorWidget.builder so that:
  //    - In debug / non-release: we render the actual exception string,
  //      in WHITE bold-ish text on our dark background.
  //      => You can screenshot this on the phone and send it to us.
  //
  //    - In release builds: we hide details and just say "Something went wrong."
  ErrorWidget.builder = (FlutterErrorDetails details) {
    final message = kReleaseMode
        ? 'Something went wrong.'
        : details.exceptionAsString();

    return Material(
      color: const Color(0xFF0b0f17), // our dark scaffold bg
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.white, // <-- high contrast so it's visible
            ),
          ),
        ),
      ),
    );
  };

  // 4. Run the whole app in a guarded zone to catch uncaught async errors.
  runZonedGuarded(
    () => runApp(const CinePulseApp()),
    (error, stack) {
      debugPrint('Uncaught zone error: $error\n$stack');
    },
  );
}
