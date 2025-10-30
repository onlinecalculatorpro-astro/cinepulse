// lib/widgets/app_drawer.dart
//
// CinePulse endDrawer (right-side slide-out menu).
//
// WHAT LIVES HERE
// -----------------------------------------------------------------------------
// • Branding header (CinePulse badge, tagline, feed summary, Close button)
// • User-facing controls surfaced in sections:
//
//   CONTENT & FILTERS
//     - Categories
//     - Content type  (All / Read / Video / Audio)
//
//   APPEARANCE
//     - Theme         (System / Light / Dark)
//
//   SHARE & SUPPORT
//     - Share CinePulse
//     - Report an issue
//
//   SETTINGS
//     - App language
//     - Subscription
//     - Sign in
//
//   ABOUT & LEGAL
//     - About CinePulse (shows version label)
//     - Privacy Policy
//     - Terms of Use
//
// VISUAL LANGUAGE
// -----------------------------------------------------------------------------
// • Each row =
//      [36x36 rounded square badge w/ emoji]
//      [Title + optional subline]
//      [chevron]
//   - Badge is 8px radius, subtle primary border, very soft glow.
//   - Use theme colors (ColorScheme.primary / onSurface / outlineVariant).
// • Section headers are all-caps, 12px, ~60% opacity.
// • Each row has a 1px divider at the bottom (onSurface @6%).
//
// PROPS (provided by RootShell)
// -----------------------------------------------------------------------------
// feedStatusLine      e.g. "Entertainment +2 · English"
// versionLabel        e.g. "Version 0.1.0 · Early access"
// contentTypeLabel    e.g. "All" / "Read" / "Video" / "Audio"
//
// onClose             required; close the drawer
//
// onFiltersChanged    optional legacy hook (RootShell may .setState() after
//                     the user changes categories / type). Safe to ignore.
//
// onCategoriesTap     open Categories bottom sheet
// onContentTypeTap    open Content Type bottom sheet
// onThemeTap          open Theme picker
//
// onAppLanguageTap    open App language picker
// onSubscriptionTap   open subscription/paywall sheet
// onLoginTap          open sign-in flow
//
// appShareUrl         link we want users to share
// privacyUrl          external Privacy Policy
// termsUrl            external Terms of Use
//
// NOTE
// -----------------------------------------------------------------------------
// This widget is PRESENTATION ONLY. It doesn't read SharedPreferences, etc.
// RootShell already computed summaries and handles actual sheets.
//
// Dependencies: google_fonts, share_plus, url_launcher
// -----------------------------------------------------------------------------

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class AppDrawer extends StatefulWidget {
  const AppDrawer({
    super.key,
    // header
    required this.onClose,
    required this.feedStatusLine,
    required this.versionLabel,
    required this.contentTypeLabel,

    // optional callback RootShell can use to rebuild feeds after edits
    this.onFiltersChanged,

    // CONTENT & FILTERS
    this.onCategoriesTap,
    this.onContentTypeTap,

    // APPEARANCE
    this.onThemeTap,

    // SETTINGS
    this.onAppLanguageTap,
    this.onSubscriptionTap,
    this.onLoginTap,

    // external links
    this.appShareUrl,
    this.privacyUrl,
    this.termsUrl,
  });

  final VoidCallback onClose;

  final String feedStatusLine;
  final String versionLabel;
  final String contentTypeLabel;

  final VoidCallback? onFiltersChanged;

  final VoidCallback? onCategoriesTap;
  final VoidCallback? onContentTypeTap;

  final VoidCallback? onThemeTap;

  final VoidCallback? onAppLanguageTap;
  final VoidCallback? onSubscriptionTap;
  final VoidCallback? onLoginTap;

  final String? appShareUrl;
  final String? privacyUrl;
  final String? termsUrl;

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  /* ────────────────────────── tiny text helpers ────────────────────────── */

  TextStyle _titleStyle(ColorScheme cs) {
    return GoogleFonts.inter(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.3,
      color: cs.onSurface,
    );
  }

  TextStyle _subStyle(ColorScheme cs) {
    return GoogleFonts.inter(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      height: 1.3,
      color: cs.onSurface.withOpacity(0.7),
    );
  }

  TextStyle _valueStyle(ColorScheme cs) {
    return GoogleFonts.inter(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1.3,
      color: cs.onSurface,
    );
  }

  Widget _emoji(String char, {double size = 18}) {
    return Text(
      char,
      style: TextStyle(
        fontSize: size,
        height: 1,
        fontFamilyFallback: const [
          'Apple Color Emoji',
          'Segoe UI Emoji',
          'Noto Color Emoji',
          'EmojiOne Color',
        ],
      ),
    );
  }

  /// 36x36 rounded square icon badge (theme-aware).
  Widget _badge(String emojiChar) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final bg = isDark
        ? const Color(0xFF0f172a).withOpacity(0.7)
        : cs.surfaceVariant.withOpacity(0.5);

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: cs.primary.withOpacity(0.35),
          width: 1,
        ),
        // Softer, less "glowy"
        boxShadow: [
          BoxShadow(
            color: cs.primary.withOpacity(0.18),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: _emoji(emojiChar),
    );
  }

  /// Section label like "CONTENT & FILTERS".
  Widget _sectionHeader(String text) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        text.toUpperCase(),
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: onSurface.withOpacity(0.6),
        ),
      ),
    );
  }

  /// Reusable tap row:
  /// [ badge ][ Title + (subtitle?) ]        [chevron]
  ///
  /// If `isValueLine` is true, subtitle is "value style" (bold-ish),
  /// otherwise we use the dimmer helper style.
  Widget _drawerRow({
    required String emoji,
    required String title,
    String? subtitle,
    required bool isValueLine,
    required VoidCallback? onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = cs.onSurface.withOpacity(0.06);

    final subWidget = (subtitle != null && subtitle.isNotEmpty)
        ? Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              subtitle,
              style: isValueLine ? _valueStyle(cs) : _subStyle(cs),
            ),
          )
        : const SizedBox.shrink();

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              width: 1,
              color: dividerColor,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _badge(emoji),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: _titleStyle(cs)),
                  subWidget,
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: cs.onSurface.withOpacity(0.6),
            ),
          ],
        ),
      ),
    );
  }

  /* ────────────────────────── row builders ────────────────────────── */

  // CONTENT & FILTERS
  Widget _rowCategories() {
    return _drawerRow(
      emoji: '🏷️',
      title: 'Categories',
      subtitle: null,
      isValueLine: false,
      onTap: widget.onCategoriesTap,
    );
  }

  Widget _rowContentType() {
    return _drawerRow(
      emoji: '🎞️',
      title: 'Content type',
      subtitle: widget.contentTypeLabel,
      isValueLine: true,
      onTap: widget.onContentTypeTap,
    );
  }

  // APPEARANCE
  Widget _rowTheme() {
    return _drawerRow(
      emoji: '🎨',
      title: 'Theme',
      subtitle: 'System / Light / Dark · Affects Home & stories',
      isValueLine: false,
      onTap: widget.onThemeTap,
    );
  }

  // SHARE & SUPPORT
  Widget _rowShare() {
    return _drawerRow(
      emoji: '📣',
      title: 'Share CinePulse',
      subtitle: 'Send the app link',
      isValueLine: false,
      onTap: () => _shareApp(),
    );
  }

  Widget _rowReport() {
    return _drawerRow(
      emoji: '🛠️',
      title: 'Report an issue',
      subtitle: 'Tell us if something is broken or fake. We’ll remove it.',
      isValueLine: false,
      onTap: _reportIssue,
    );
  }

  // SETTINGS
  Widget _rowAppLanguage() {
    return _drawerRow(
      emoji: '🌍',
      title: 'App language',
      subtitle: 'Change the CinePulse UI language',
      isValueLine: false,
      onTap: widget.onAppLanguageTap,
    );
  }

  Widget _rowSubscription() {
    return _drawerRow(
      emoji: '💎',
      title: 'Subscription',
      subtitle: 'Remove ads & unlock extras',
      isValueLine: false,
      onTap: widget.onSubscriptionTap,
    );
  }

  Widget _rowLogin() {
    return _drawerRow(
      emoji: '👤',
      title: 'Sign in',
      subtitle: 'Sync saved stories across devices',
      isValueLine: false,
      onTap: widget.onLoginTap,
    );
  }

  // ABOUT & LEGAL
  Widget _rowAbout() {
    return _drawerRow(
      emoji: 'ℹ️',
      title: 'About CinePulse',
      subtitle: widget.versionLabel,
      isValueLine: false,
      onTap: widget.onClose, // placeholder for future About screen
    );
  }

  Widget _rowPrivacy() {
    return _drawerRow(
      emoji: '🔒',
      title: 'Privacy Policy',
      subtitle: null,
      isValueLine: false,
      onTap: () => _openExternal(widget.privacyUrl),
    );
  }

  Widget _rowTerms() {
    return _drawerRow(
      emoji: '📜',
      title: 'Terms of Use',
      subtitle: null,
      isValueLine: false,
      onTap: () => _openExternal(widget.termsUrl),
    );
  }

  /* ────────────────────────── drawer header ────────────────────────── */

  Widget _header() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final borderColor = cs.onSurface.withOpacity(0.06);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF1e2537).withOpacity(0.12)
            : cs.surface.withOpacity(0.05),
        border: Border(
          bottom: BorderSide(color: borderColor, width: 1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // CinePulse badge (subtle, theme-primary accent)
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: cs.primary.withOpacity(0.16),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: cs.primary.withOpacity(0.45),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: cs.primary.withOpacity(0.18),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: const Text('🎬', style: TextStyle(fontSize: 20, height: 1)),
          ),

          const SizedBox(width: 12),

          // App name, tagline, feed summary
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShaderMask(
                  shaderCallback: (bounds) => LinearGradient(
                    colors: [cs.primary, cs.primary.withOpacity(0.8)],
                  ).createShader(bounds),
                  child: Text(
                    'CinePulse',
                    style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                      color: Colors.white,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Movies & OTT, in a minute.',
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    height: 1.2,
                    color: cs.onSurface.withOpacity(0.72),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.feedStatusLine,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    height: 1.3,
                    fontWeight: FontWeight.w500,
                    color: cs.onSurface.withOpacity(0.72),
                  ),
                ),
              ],
            ),
          ),

          IconButton(
            tooltip: 'Close',
            onPressed: widget.onClose,
            icon: Icon(
              Icons.close_rounded,
              color: cs.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  /* ────────────────────────── actions / helpers ────────────────────────── */

  Future<void> _shareApp() async {
    final link = widget.appShareUrl ?? 'https://cinepulse.netlify.app';

    try {
      if (!kIsWeb) {
        await Share.share(link);
      } else {
        // Web fallback: copy link + toast.
        await Clipboard.setData(ClipboardData(text: link));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copied to clipboard')),
        );
      }
    } catch (_) {
      // If share fails, fallback to copy.
      await Clipboard.setData(ClipboardData(text: link));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link copied to clipboard')),
      );
    }
  }

  Future<void> _reportIssue() async {
    // For now we just surface a "mailto:" link.
    final uri = Uri.parse(
      'mailto:feedback@cinepulse.app?subject=CinePulse%20Feedback',
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _openExternal(String? url) async {
    if (url == null || url.isEmpty) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.platformDefault);
  }

  /* ────────────────────────── build ────────────────────────── */

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0f172a) : cs.surface;

    return Drawer(
      backgroundColor: bgColor,
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            // HEADER
            _header(),

            // CONTENT & FILTERS
            _sectionHeader('Content & filters'),
            _rowCategories(),
            _rowContentType(),

            // APPEARANCE
            _sectionHeader('Appearance'),
            _rowTheme(),

            // SHARE & SUPPORT
            _sectionHeader('Share & support'),
            _rowShare(),
            _rowReport(),

            // SETTINGS
            _sectionHeader('Settings'),
            _rowAppLanguage(),
            _rowSubscription(),
            _rowLogin(),

            // ABOUT & LEGAL
            _sectionHeader('About & legal'),
            _rowAbout(),
            _rowPrivacy(),
            _rowTerms(),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
