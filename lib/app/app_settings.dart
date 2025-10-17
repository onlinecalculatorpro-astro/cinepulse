// lib/app/app_settings.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide user settings (singleton).
///
/// Currently stores the preferred [ThemeMode] and persists it with
/// `SharedPreferences` (Web: localStorage).
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  static const _kTheme = 'theme_mode';

  late SharedPreferences _prefs;
  bool _ready = false;
  bool get isReady => _ready;

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  /// Load settings from storage. Call this once at app start.
  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final saved = _prefs.getString(_kTheme);
      if (saved != null) {
        _themeMode = _fromString(saved);
      }
    } catch (_) {
      // On any failure, fall back to defaults.
      _themeMode = ThemeMode.system;
    } finally {
      _ready = true;
      notifyListeners(); // allow listeners to react once ready
    }
  }

  /// Update and persist the theme mode.
  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    try {
      // Persist best-effort; UI already updated.
      await _prefs.setString(_kTheme, _asString(mode));
    } catch (_) {
      // Ignore storage errors.
    }
  }

  /// Convenience: cycle System → Light → Dark → System…
  Future<void> cycleThemeMode() {
    final next = switch (_themeMode) {
      ThemeMode.system => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
    };
    return setThemeMode(next);
  }

  // ---- helpers ----

  String _asString(ThemeMode mode) => switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        _ => 'system',
      };

  ThemeMode _fromString(String raw) => switch (raw) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
}
