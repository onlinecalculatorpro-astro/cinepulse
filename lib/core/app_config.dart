// lib/core/app_config.dart
class AppConfig {
  static const apiBase = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api.onlinecalculatorpro.org', // not localhost
  );

  static const deepLinkBase = String.fromEnvironment(
    'DEEP_LINK_BASE',
    defaultValue: 'https://cinepulse.netlify.app/#/s',
  );
}
