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
import 'core/fcm_bootstrap.dart'; // initCinepulseFcm()

// ─────────────────────────────────────────────────────────────
// Simple in-app logger so we can see errors on the phone screen
// (no laptop / no logcat required).
// ─────────────────────────────────────────────────────────────

final ValueNotifier<List<String>> _errorLog =
    ValueNotifier<List<String>>(<String>[]);

void _logLine(String line) {
  final next = List<String>.from(_errorLog.value)..add(line);
  // keep last ~50 lines max so it doesn't explode
  if (next.length > 50) {
    next.removeRange(0, next.length - 50);
  }
  _errorLog.value = next;
}

/// A tiny always-on overlay that renders at the top of the app.
/// If no errors/logs yet, it stays hidden (SizedBox.shrink).
class _DebugOverlay extends StatelessWidget {
  const _DebugOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: true, // let touches pass through
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ValueListenableBuilder<List<String>>(
            valueListenable: _errorLog,
            builder: (context, lines, _) {
              if (lines.isEmpty) {
                return const SizedBox.shrink();
              }
              return Container(
                width: double.infinity,
                margin: const EdgeInsets.all(8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.redAccent,
                    width: 1,
                  ),
                ),
                child: Text(
                  lines.join('\n'),
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.3,
                    color: Colors.white,
                    fontFamily: 'monospace',
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// We mount the real app AND the overlay in a Stack so you always
/// see logs even if the main UI is blank.
class _RootWithOverlay extends StatelessWidget {
  const _RootWithOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: const [
        CinePulseApp(),
        _DebugOverlay(),
      ],
    );
  }
}

Future<void> main() async {
  // Needed before we do any async init.
  WidgetsFlutterBinding.ensureInitialized();

  // Region/locale default.
  Intl.defaultLocale = 'en_US';

  // Init app settings + saved stories store.
  await AppSettings.instance.init();
  await SavedStore.instance.init();

  // Try FCM only on Android real runtime.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    try {
      await initCinepulseFcm();
      _logLine('[main] FCM init OK');
    } catch (e, st) {
      _logLine('[main] FCM init FAILED: $e');
      _logLine(st.toString());
    }
  }

  // Print important compile-time values (from --dart-define in CI).
  _logLine('[main] kReleaseMode = $kReleaseMode');
  _logLine('[main] API_BASE_URL = $kApiBaseUrl');
  _logLine('[main] DEEP_LINK_BASE = $kDeepLinkBase');

  // ───────── Global error capture hooks ─────────

  // Any Flutter framework error (build/layout/paint, etc).
  FlutterError.onError = (FlutterErrorDetails details) {
    // still print red screen in debug internally
    FlutterError.presentError(details);

    final stack = details.stack ?? StackTrace.current;
    Zone.current.handleUncaughtError(details.exception, stack);

    _logLine('[FlutterError] ${details.exception}');
    _logLine(stack.toString());
  };

  // Uncaught platform / engine side errors (MethodChannel, plugins, etc).
  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    _logLine('[PlatformDispatcher] $error');
    _logLine(stack.toString());
    return true; // we handled it
  };

  // Replace Flutter's red/yellow error widget with a dark one
  // AND also push message into the overlay.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    final msg =
        kReleaseMode ? 'Something went wrong.' : details.exceptionAsString();

    _logLine('[ErrorWidget] $msg');

    return Material(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            msg,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  };

  // Guard all async zones. Anything that explodes later ends up in overlay.
  runZonedGuarded(
    () {
      runApp(const _RootWithOverlay());
    },
    (error, stack) {
      _logLine('[Zone] $error');
      _logLine(stack.toString());
    },
  );
}
