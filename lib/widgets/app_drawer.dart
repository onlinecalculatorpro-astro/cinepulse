// lib/widgets/app_drawer.dart
//
// CinePulse right-side drawer (endDrawer).
//
// This is the slide-out panel you get when you tap the Menu button in the header.
//
// UPDATED: same UI/UX as your approved mock + **new SETTINGS block**.
//
// ───────── LAYOUT (FINAL) ─────────
//
// HEADER
//   [ 🎬 red gradient square ]
//   CinePulse
//   "Movies & OTT, in a minute."
//   "<CategorySummary> · <LanguageSummary>"   (feedStatusLine)
//   [ ✕ ]
//
// CONTENT & FILTERS
//   [square icon 🌐]  Show stories in
//                     Hindi
//   [square icon 📺]  What to show
//
// APPEARANCE
//   [square icon 🎨]  Theme
//                     System / Light / Dark · Affects Home & stories
//
// SHARE & SUPPORT
//   [square icon 📣]  Share CinePulse
//                     Send the app link
//   [square icon 🛠️] Report an issue
//                     Tell us if something is broken or fake. We’ll remove it.
//
// SETTINGS (NEW BLOCK)
//   [square icon 🌍]  App language
//                     Change the CinePulse UI language
//   [square icon 💎]  Subscription
//                     Remove ads & unlock extras
//   [square icon 👤]  Sign in
//                     Sync saved stories across devices
//
// ABOUT & LEGAL
//   [square icon ℹ️]  About CinePulse
//                     Version 0.1.0 · Early access
//   [square icon 🔒]  Privacy Policy
//   [square icon 📜]  Terms of Use
//
// ───────── STYLE RULES ─────────
//
// • EXACT SAME row visual as your screenshot:
//     [ small rounded square icon button ]  [ title + subline ]
//                                           [ chevron on far right ]
//
// • The square icon button:
//     - 36x36
//     - 8px radius
//     - subtle red border (#dc2626 with opacity)
//     - dark/navy bg in dark mode
//     - emoji centered
//     This matches the header action buttons you already ship.
//
// • Section headers are the same quiet caps style.
// • Dividers: 1px line using onSurface.withOpacity(0.06).
// • Drawer bg: #0f172a in dark mode, normal surface in light.
//
// ───────── DATA / CALLBACKS ─────────
//
// Required from RootShell:
//   feedStatusLine   e.g. "All · Hindi"
//   versionLabel     e.g. "Version 0.1.0 · Early access"
//
// Also from RootShell (callbacks):
//   onLanguageTap        → open "Show stories in" picker
//   onCategoryTap        → open "What to show" picker
//   onThemeTap           → open Theme picker
//
//   onAppLanguageTap     → open APP language (UI language for full app)
//   onSubscriptionTap    → open paywall / subscription
//   onLoginTap           → open sign-in / account
//
// Plus:
//   appShareUrl          → for Share CinePulse
//   privacyUrl / termsUrl
//
// We also read SharedPreferences('cp.lang') to render the current feed language
// under "Show stories in".
//
// DEPENDENCIES: google_fonts, shared_preferences, share_plus, url_launcher
//
// NOTE: CategoryPrefs import is kept for consistency even though we don't show
//       the category summary subtitle in this UI (row is single-line).
//

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../root_shell.dart' show CategoryPrefs;

class AppDrawer extends StatefulWidget {
  const AppDrawer({
    super.key,
    required this.onClose,
    required this.feedStatusLine,
    required this.versionLabel,
    this.onFiltersChanged,   // legacy hook
    this.onLanguageTap,      // feed language picker
    this.onCategoryTap,      // category picker
    this.onThemeTap,         // theme picker

    // NEW for SETTINGS section:
    this.onAppLanguageTap,   // app-wide UI language picker
    this.onSubscriptionTap,  // subscription / paywall
    this.onLoginTap,         // sign in / account

    this.appShareUrl,
    this.privacyUrl,
    this.termsUrl,
  });

  final VoidCallback onClose;

  // "All · Hindi"
  final String feedStatusLine;

  // "Version 0.1.0 · Early access"
  final String versionLabel;

  final VoidCallback? onFiltersChanged;
  final VoidCallback? onLanguageTap;
  final VoidCallback? onCategoryTap;
  final VoidCallback? onThemeTap;

  // SETTINGS callbacks
  final VoidCallback? onAppLanguageTap;
  final VoidCallback? onSubscriptionTap;
  final VoidCallback? onLoginTap;

  // external / share links
  final String? appShareUrl;
  final String? privacyUrl;
  final String? termsUrl;

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  static const _accent = Color(0xFFdc2626);
  static const _kLangPrefKey = 'cp.lang'; // 'english' | 'hindi' | 'mixed' | etc.

  String _lang = 'mixed';

  @override
  void initState() {
    super.initState();
    _loadLangPref();
  }

  Future<void> _loadLangPref() async {
    final sp = await SharedPreferences.getInstance();
    final stored = sp.getString(_kLangPrefKey);
    if (mounted && stored != null && stored.isNotEmpty) {
      setState(() {
        _lang = stored;
      });
    }
  }

  // Convert saved feed language code to display text.
  String _langLabel(String code) {
    switch (code) {
      case 'english':
        return 'English';
      case 'hindi':
        return 'Hindi';
      case 'bengali':
        return 'Bengali';
      case 'telugu':
        return 'Telugu';
      case 'marathi':
        return 'Marathi';
      case 'tamil':
        return 'Tamil';
      case 'gujarati':
        return 'Gujarati';
      default:
        return 'Mixed';
    }
  }

  // ───────────────── text styles ─────────────────

  TextStyle _rowTitleStyle(ColorScheme cs) {
    return GoogleFonts.inter(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: cs.onSurface,
      height: 1.3,
    );
  }

  // helper copy / descriptive subline
  TextStyle _rowSubStyle(ColorScheme cs) {
    return GoogleFonts.inter(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      height: 1.3,
      color: cs.onSurface.withOpacity(0.7),
    );
  }

  // selected value subline (bold-ish)
  TextStyle _valueLineStyle(ColorScheme cs) {
    return GoogleFonts.inter(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1.3,
      color: cs.onSurface,
    );
  }

  Widget _emoji(String e, {double size = 18}) {
    return Text(
      e,
      style: TextStyle(
        fontSize: size,
        height: 1,
        fontFamily: null,
        fontFamilyFallback: const [
          'Apple Color Emoji',
          'Segoe UI Emoji',
          'Noto Color Emoji',
          'EmojiOne Color',
        ],
      ),
    );
  }

  // 36x36 rounded square icon button at the start of each row.
  Widget _squareIconButton(String emojiChar) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color bgColor = isDark
        ? const Color(0xFF0f172a).withOpacity(0.7)
        : Colors.black.withOpacity(0.06);

    final Color borderColor = _accent.withOpacity(0.4);

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: borderColor,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: _accent.withOpacity(0.4),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: _emoji(emojiChar),
    );
  }

  // Section label like "CONTENT & FILTERS"
  Widget _sectionHeader(BuildContext context, String text) {
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

  // Generic row builder that matches your screenshot:
  //
  // [square icon]  Title
  //                Subtitle (optional)
  //                                    >
  //
  // If isValueLine = true, subtitle is rendered bold/primary (for "Hindi", etc.)
  // Otherwise subtitle is rendered dimmer helper text.
  Widget _drawerRow({
    required String emoji,
    required String title,
    String? subtitle,
    required bool isValueLine,
    required VoidCallback? onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = cs.onSurface.withOpacity(0.06);

    final subtitleWidget = (subtitle != null && subtitle.isNotEmpty)
        ? Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              subtitle,
              style: isValueLine ? _valueLineStyle(cs) : _rowSubStyle(cs),
            ),
          )
        : const SizedBox.shrink();

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(width: 1, color: dividerColor),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _squareIconButton(emoji),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: _rowTitleStyle(cs)),
                  subtitleWidget,
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

  // ───────── ROW COMPOSERS (PER SECTION) ─────────

  // CONTENT & FILTERS
  Widget _langRow() {
    final label = _langLabel(_lang);
    return _drawerRow(
      emoji: '🌐',
      title: 'Show stories in',
      subtitle: label,
      isValueLine: true,
      onTap: widget.onLanguageTap,
    );
  }

  Widget _whatToShowRow() {
    // Design: NO subtitle here.
    return _drawerRow(
      emoji: '📺',
      title: 'What to show',
      subtitle: null,
      isValueLine: false,
      onTap: widget.onCategoryTap,
    );
  }

  // APPEARANCE
  Widget _themeRow() {
    return _drawerRow(
      emoji: '🎨',
      title: 'Theme',
      subtitle: 'System / Light / Dark · Affects Home & stories',
      isValueLine: false,
      onTap: widget.onThemeTap,
    );
  }

  // SHARE & SUPPORT
  Widget _shareRow() {
    return _drawerRow(
      emoji: '📣',
      title: 'Share CinePulse',
      subtitle: 'Send the app link',
      isValueLine: false,
      onTap: () => _shareApp(context),
    );
  }

  Widget _reportRow() {
    return _drawerRow(
      emoji: '🛠️',
      title: 'Report an issue',
      subtitle:
          'Tell us if something is broken or fake. We’ll remove it.',
      isValueLine: false,
      onTap: _reportIssue,
    );
  }

  // SETTINGS (NEW BLOCK)
  Widget _appLanguageRow() {
    return _drawerRow(
      emoji: '🌍',
      title: 'App language',
      subtitle: 'Change the CinePulse UI language',
      isValueLine: false,
      onTap: widget.onAppLanguageTap,
    );
  }

  Widget _subscriptionRow() {
    return _drawerRow(
      emoji: '💎',
      title: 'Subscription',
      subtitle: 'Remove ads & unlock extras',
      isValueLine: false,
      onTap: widget.onSubscriptionTap,
    );
  }

  Widget _loginRow() {
    return _drawerRow(
      emoji: '👤',
      title: 'Sign in',
      subtitle: 'Sync saved stories across devices',
      isValueLine: false,
      onTap: widget.onLoginTap,
    );
  }

  // ABOUT & LEGAL
  Widget _aboutRow() {
    return _drawerRow(
      emoji: 'ℹ️',
      title: 'About CinePulse',
      subtitle: widget.versionLabel,
      isValueLine: false,
      onTap: widget.onClose,
    );
  }

  Widget _privacyRow() {
    return _drawerRow(
      emoji: '🔒',
      title: 'Privacy Policy',
      subtitle: null,
      isValueLine: false,
      onTap: () => _openExternal(widget.privacyUrl),
    );
  }

  Widget _termsRow() {
    return _drawerRow(
      emoji: '📜',
      title: 'Terms of Use',
      subtitle: null,
      isValueLine: false,
      onTap: () => _openExternal(widget.termsUrl),
    );
  }

  // ───────── HEADER (unchanged look) ─────────
  Widget _drawerHeader(bool isDark) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = isDark
        ? Colors.white.withOpacity(0.06)
        : cs.onSurface.withOpacity(0.06);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF1e2537).withOpacity(0.15)
            : cs.surface.withOpacity(0.05),
        border: Border(
          bottom: BorderSide(color: dividerColor, width: 1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // red gradient square with 🎬
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFdc2626),
                  Color(0xFFef4444),
                ],
              ),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFdc2626).withOpacity(0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: const Text(
              '🎬',
              style: TextStyle(fontSize: 20, height: 1),
            ),
          ),

          const SizedBox(width: 12),

          // CinePulse + tagline + feed status
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShaderMask(
                  shaderCallback: (bounds) => const LinearGradient(
                    colors: [
                      Color(0xFFdc2626),
                      Color(0xFFef4444),
                    ],
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
            icon: Icon(
              Icons.close_rounded,
              color: cs.onSurface,
            ),
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  // ───────── actions for share/report/external links ─────────

  Future<void> _shareApp(BuildContext context) async {
    final link = widget.appShareUrl ?? 'https://cinepulse.netlify.app';
    if (!kIsWeb) {
      await Share.share(link);
    } else {
      await Clipboard.setData(ClipboardData(text: link));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Link copied to clipboard'),
        ),
      );
    }
  }

  Future<void> _reportIssue() async {
    final uri = Uri.parse(
      'mailto:feedback@cinepulse.app?subject=CinePulse%20Feedback',
    );
    await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _openExternal(String? url) async {
    if (url == null || url.isEmpty) return;
    await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.platformDefault,
    );
  }

  // ───────── build ─────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final drawerBg = isDark ? const Color(0xFF0f172a) : cs.surface;

    return Drawer(
      backgroundColor: drawerBg,
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            // HEADER
            _drawerHeader(isDark),

            // CONTENT & FILTERS
            _sectionHeader(context, 'Content & filters'),
            _langRow(),
            _whatToShowRow(),

            // APPEARANCE
            _sectionHeader(context, 'Appearance'),
            _themeRow(),

            // SHARE & SUPPORT
            _sectionHeader(context, 'Share & support'),
            _shareRow(),
            _reportRow(),

            // SETTINGS (NEW BLOCK)
            _sectionHeader(context, 'Settings'),
            _appLanguageRow(),
            _subscriptionRow(),
            _loginRow(),

            // ABOUT & LEGAL
            _sectionHeader(context, 'About & legal'),
            _aboutRow(),
            _privacyRow(),
            _termsRow(),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
