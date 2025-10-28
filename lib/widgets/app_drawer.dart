// lib/widgets/app_drawer.dart
//
// CinePulse right-side drawer (endDrawer).
//
// This is the slide-out panel you get when you tap the Menu button in the header.
//
// UPDATED TO MATCH NEW SPEC:
//
// ───────── LAYOUT (NOW) ─────────
//
// HEADER
//   [ 🎬 red gradient square ]
//   CinePulse
//   "Movies & OTT, in a minute."
//   "<CategorySummary> · <LanguageSummary>"   (feedStatusLine)
//   [ ✕ ]
//
// CONTENT & FILTERS
//   [square icon 🏷️]  Categories
//                      (no subtitle)
//   [square icon 🎞️]  Content type
//                      All / Read / Video / Audio   (shows current selection)
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
// SETTINGS
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
// ───────── CALLBACK API (UPDATED) ─────────
//
// Required from RootShell:
//   feedStatusLine        e.g. "All · Hindi"
//   versionLabel          e.g. "Version 0.1.0 · Early access"
//   contentTypeLabel      e.g. "All" / "Read" / "Video" / "Audio"
//
// Callbacks provided by RootShell:
//   onCategoryTap         → open Categories picker sheet
//                            (multi-select: All / Entertainment / Sports / ...)
//   onContentTypeTap      → open Content type picker sheet
//                            (single-select: All / Read / Video / Audio)
//   onThemeTap            → open Theme picker
//
//   onAppLanguageTap      → open App language settings (UI language drawer/sheet)
//   onSubscriptionTap     → open Subscription paywall
//   onLoginTap            → open Sign in / Account
//
// Other:
//   onClose               → close drawer
//   onFiltersChanged      → legacy hook (kept, still optional)
//
// External links for share / policy / terms:
//   appShareUrl, privacyUrl, termsUrl
//
// ───────── STYLE RULES ─────────
//
// • Each row uses the same pill-style square icon container (36x36, 8px radius,
//   subtle red border, dark translucent bg in dark mode), matching header icons.
// • We changed the row emojis to match the new meaning:
//     - Categories       → 🏷️
//     - Content type     → 🎞️
//     - Theme            → 🎨
//     - etc.
// • "Content type" row shows the selected value in bold as the subtitle.
// • "Categories" row has no subtitle now.
//
// NOTE: We removed all the old "Show stories in" language picker UI from this file.
// That logic is now replaced by "Content type".
//
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class AppDrawer extends StatefulWidget {
  const AppDrawer({
    super.key,
    required this.onClose,
    required this.feedStatusLine,
    required this.versionLabel,
    required this.contentTypeLabel, // "All" / "Read" / "Video" / "Audio"

    this.onFiltersChanged, // legacy hook if we need to trigger a rebuild

    // CONTENT & FILTERS callbacks
    this.onCategoryTap, // opens Categories sheet
    this.onContentTypeTap, // opens Content type sheet

    // APPEARANCE
    this.onThemeTap,

    // SETTINGS
    this.onAppLanguageTap,
    this.onSubscriptionTap,
    this.onLoginTap,

    // external / share links
    this.appShareUrl,
    this.privacyUrl,
    this.termsUrl,
  });

  final VoidCallback onClose;

  // e.g. "All · Hindi"
  final String feedStatusLine;

  // e.g. "Version 0.1.0 · Early access"
  final String versionLabel;

  // e.g. "All" / "Read" / "Video" / "Audio"
  final String contentTypeLabel;

  final VoidCallback? onFiltersChanged;

  // CONTENT & FILTERS
  final VoidCallback? onCategoryTap;
  final VoidCallback? onContentTypeTap;

  // APPEARANCE
  final VoidCallback? onThemeTap;

  // SETTINGS
  final VoidCallback? onAppLanguageTap;
  final VoidCallback? onSubscriptionTap;
  final VoidCallback? onLoginTap;

  // external links
  final String? appShareUrl;
  final String? privacyUrl;
  final String? termsUrl;

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  static const _accent = Color(0xFFdc2626);

  // ───────────────── text styles ─────────────────

  TextStyle _rowTitleStyle(ColorScheme cs) {
    return GoogleFonts.inter(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: cs.onSurface,
      height: 1.3,
    );
  }

  // helper / descriptive subline
  TextStyle _rowSubStyle(ColorScheme cs) {
    return GoogleFonts.inter(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      height: 1.3,
      color: cs.onSurface.withOpacity(0.7),
    );
  }

  // selected value subline (bold-ish / primary)
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

  // 36x36 rounded square icon container with subtle border/glow.
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

  // Section header like "CONTENT & FILTERS"
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

  // Generic row renderer:
  //
  // [square icon]  Title
  //                Subtitle (optional)
  //                                    >
  //
  // If isValueLine = true, subtitle uses _valueLineStyle (bold / primary).
  // Otherwise subtitle uses _rowSubStyle (dim helper text).
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

  // "Categories" row (used to be "What to show")
  // - No subtitle, tap opens Categories picker sheet.
  Widget _categoriesRow() {
    return _drawerRow(
      emoji: '🏷️',
      title: 'Categories',
      subtitle: null,
      isValueLine: false,
      onTap: widget.onCategoryTap,
    );
  }

  // "Content type" row (used to be "Show stories in")
  // - Shows current selection ("All" / "Read" / "Video" / "Audio")
  // - Tap opens Content type picker sheet.
  Widget _contentTypeRow() {
    return _drawerRow(
      emoji: '🎞️',
      title: 'Content type',
      subtitle: widget.contentTypeLabel,
      isValueLine: true,
      onTap: widget.onContentTypeTap,
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

  // SETTINGS
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

  // ───────── HEADER ─────────
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
            _categoriesRow(),
            _contentTypeRow(),

            // APPEARANCE
            _sectionHeader(context, 'Appearance'),
            _themeRow(),

            // SHARE & SUPPORT
            _sectionHeader(context, 'Share & support'),
            _shareRow(),
            _reportRow(),

            // SETTINGS
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
