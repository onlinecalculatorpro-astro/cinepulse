// lib/widgets/app_drawer.dart
//
// CinePulse endDrawer (right-side slide-out menu).
//
// PRESENTATION-ONLY drawer. RootShell owns prefs/state and passes summaries.
// Uses theme helpers from theme/theme_colors.dart so no hard-coded reds.
//
// Sections:
//   • Content & filters  → Categories, Content type
//   • Appearance         → Theme
//   • Share & support    → Share, Report
//   • Settings           → App language, Subscription, Sign in
//   • About & legal      → About (version), Privacy, Terms
//
// Props from RootShell:
//   - onClose (required)
//   - feedStatusLine, versionLabel, contentTypeLabel
//   - onFiltersChanged? (optional legacy hook)
//   - onCategoriesTap?, onContentTypeTap?, onThemeTap?
//   - onAppLanguageTap?, onSubscriptionTap?, onLoginTap?
//   - appShareUrl?, privacyUrl?, termsUrl?
//
// Dependencies: google_fonts, share_plus, url_launcher

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/theme_colors.dart'; // accent + text + hairlines

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
  /* ───────────────────── Typography helpers (theme-aware) ───────────────────── */

  TextStyle _titleStyle(BuildContext ctx) {
    final cs = Theme.of(ctx).colorScheme;
    return GoogleFonts.inter(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.3,
      color: cs.onSurface,
    );
  }

  TextStyle _subStyle(BuildContext ctx) {
    return GoogleFonts.inter(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      height: 1.3,
      color: secondaryTextColor(ctx),
    );
  }

  TextStyle _valueStyle(BuildContext ctx) {
    final cs = Theme.of(ctx).colorScheme;
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

  /// 36x36 rounded square badge (theme-aware).
  Widget _badge(String emojiChar) {
    final ctx = context;
    final cs = Theme.of(ctx).colorScheme;

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: neutralPillBg(ctx),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: cs.primary.withOpacity(0.35),
          width: 1,
        ),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        text.toUpperCase(),
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: secondaryTextColor(context),
        ),
      ),
    );
  }

  /// Reusable tap row:
  /// [ badge ][ Title + (subtitle?) ]        [chevron]
  /// If `isValueLine` true → subtitle rendered with stronger value style.
  Widget _drawerRow({
    required String emoji,
    required String title,
    String? subtitle,
    required bool isValueLine,
    required VoidCallback? onTap,
  }) {
    final ctx = context;
    final divider = subtleDivider(ctx);

    final subWidget = (subtitle != null && subtitle.isNotEmpty)
        ? Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              subtitle,
              style: isValueLine ? _valueStyle(ctx) : _subStyle(ctx),
            ),
          )
        : const SizedBox.shrink();

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(width: 1, color: divider),
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
                  Text(title, style: _titleStyle(ctx)),
                  subWidget,
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: secondaryTextColor(ctx),
            ),
          ],
        ),
      ),
    );
  }

  /* ────────────────────────── row builders ────────────────────────── */

  // CONTENT & FILTERS
  Widget _rowCategories() => _drawerRow(
        emoji: '🏷️',
        title: 'Categories',
        subtitle: null,
        isValueLine: false,
        onTap: widget.onCategoriesTap,
      );

  Widget _rowContentType() => _drawerRow(
        emoji: '🎞️',
        title: 'Content type',
        subtitle: widget.contentTypeLabel,
        isValueLine: true,
        onTap: widget.onContentTypeTap,
      );

  // APPEARANCE
  Widget _rowTheme() => _drawerRow(
        emoji: '🎨',
        title: 'Theme',
        subtitle: 'System / Light / Dark · Affects Home & stories',
        isValueLine: false,
        onTap: widget.onThemeTap,
      );

  // SHARE & SUPPORT
  Widget _rowShare() => _drawerRow(
        emoji: '📣',
        title: 'Share CinePulse',
        subtitle: 'Send the app link',
        isValueLine: false,
        onTap: _shareApp,
      );

  Widget _rowReport() => _drawerRow(
        emoji: '🛠️',
        title: 'Report an issue',
        subtitle: 'Tell us if something is broken or fake. We’ll remove it.',
        isValueLine: false,
        onTap: _reportIssue,
      );

  // SETTINGS
  Widget _rowAppLanguage() => _drawerRow(
        emoji: '🌍',
        title: 'App language',
        subtitle: 'Change the CinePulse UI language',
        isValueLine: false,
        onTap: widget.onAppLanguageTap,
      );

  Widget _rowSubscription() => _drawerRow(
        emoji: '💎',
        title: 'Subscription',
        subtitle: 'Remove ads & unlock extras',
        isValueLine: false,
        onTap: widget.onSubscriptionTap,
      );

  Widget _rowLogin() => _drawerRow(
        emoji: '👤',
        title: 'Sign in',
        subtitle: 'Sync saved stories across devices',
        isValueLine: false,
        onTap: widget.onLoginTap,
      );

  // ABOUT & LEGAL
  Widget _rowAbout() => _drawerRow(
        emoji: 'ℹ️',
        title: 'About CinePulse',
        subtitle: widget.versionLabel,
        isValueLine: false,
        onTap: widget.onClose, // placeholder for a future About screen
      );

  Widget _rowPrivacy() => _drawerRow(
        emoji: '🔒',
        title: 'Privacy Policy',
        subtitle: null,
        isValueLine: false,
        onTap: () => _openExternal(widget.privacyUrl),
      );

  Widget _rowTerms() => _drawerRow(
        emoji: '📜',
        title: 'Terms of Use',
        subtitle: null,
        isValueLine: false,
        onTap: () => _openExternal(widget.termsUrl),
      );

  /* ────────────────────────── drawer header ────────────────────────── */

  Widget _header() {
    final ctx = context;
    final cs = Theme.of(ctx).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: neutralPillBg(ctx).withOpacity(0.4),
        border: Border(
          bottom: BorderSide(color: outlineHairline(ctx), width: 1),
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
                    color: secondaryTextColor(ctx),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.feedStatusLine,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    height: 1.3,
                    fontWeight: FontWeight.w500,
                    color: secondaryTextColor(ctx),
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
              color: primaryTextColor(ctx),
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
        await Clipboard.setData(ClipboardData(text: link));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copied to clipboard')),
        );
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: link));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link copied to clipboard')),
      );
    }
  }

  Future<void> _reportIssue() async {
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0f172a) : Theme.of(context).colorScheme.surface;

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
