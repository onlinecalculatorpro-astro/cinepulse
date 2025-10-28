// lib/widgets/app_drawer.dart
//
// CinePulse right-side drawer (endDrawer).
//
// This is the slide-out panel you get when you tap the Menu button in the header.
//
// UPDATED TO MATCH THE FINAL APPROVED MOCK:
//
// ───────────────── LAYOUT ─────────────────
//
// HEADER
//   [ 🎬 red gradient square ]
//   CinePulse
//   "Movies & OTT, in a minute."
//   "<CategorySummary> · <LanguageSummary>"   (feedStatusLine)
//   [ ✕ ]
//
// SECTION: CONTENT & FILTERS
//   ROW 1:
//     [square icon button 🌐]   Show stories in
//                               English
//                               (> opens language picker)
//   ROW 2:
//     [square icon button 📺]   What to show
//                               (no second line)
//                               (> opens category picker)
//
// SECTION: APPEARANCE
//   ROW:
//     [square icon button 🎨]   Theme
//                               System / Light / Dark · Affects Home & stories
//                               (> opens theme picker)
//
// SECTION: SHARE & SUPPORT
//   ROW:
//     [square icon button 📣]   Share CinePulse
//                               Send the app link
//                               (> share / copy link)
//   ROW:
//     [square icon button 🛠️]  Report an issue
//                               Tell us if something is broken or fake. We’ll remove it.
//                               (> email feedback)
//
// SECTION: ABOUT & LEGAL
//   ROW:
//     [square icon button ℹ️]   About CinePulse
//                               Version 0.1.0 · Early access   (versionLabel)
//                               (> close drawer or open About later)
//   ROW:
//     [square icon button 🔒]   Privacy Policy
//                               (> opens privacyUrl)
//   ROW:
//     [square icon button 📜]   Terms of Use
//                               (> opens termsUrl)
//
// ───────────────── VISUAL RULES ─────────────────
//
// • Row format EXACTLY matches your approved mock:
//     [ small rounded square icon button ]  [ title + optional subline ]
//                                           [ chevron on far right ]
//
// • The square button style matches the header action buttons from Home:
//     - dark/navy background block
//     - subtle red border (#dc2626)
//     - 8px radius
//     - 36x36
//     - emoji/icon centered
//
// • Title ("Show stories in") is bold-ish 14px Inter.
// • The second line, when it's showing a SELECTION (like "English"), is 13px,
//   semibold, near-primary text.
// • The second line, when it's just helper copy ("Send the app link"), is
//   13px normal weight, slightly dimmed (onSurface.withOpacity(0.7)).
//
// • Chevron on the right.
//
// • Section headers are quiet, all-caps-ish labels at 12px,
//   color onSurface.withOpacity(0.6).
//
// • Drawer bg is dark navy (#0f172a) in dark mode, and surface in light.
// • 1px separators use onSurface.withOpacity(0.06).
//
// ───────────────── STATE / DATA FLOW ─────────────────
//
// • We read current language from SharedPreferences('cp.lang').
//   Values: 'english' | 'hindi' | 'mixed' | (later: 'bengali','telugu','marathi','tamil', etc.)
//   That is shown as the second line in "Show stories in".
//
// • We do NOT show the category summary text under "What to show"
//   (you asked for no subline there — only the title).
//
// • feedStatusLine (e.g. "Entertainment · English") and versionLabel
//   (e.g. "Version 0.1.0 · Early access") both come from RootShell.
//
// • onLanguageTap / onCategoryTap / onThemeTap are callbacks to RootShell,
//   which closes the drawer and opens the correct bottom sheet.
//
// • Share / Report / Privacy / Terms rows call native actions / launch URLs.
//
// DEPENDENCIES:
//
// - google_fonts for Inter
// - shared_preferences for language persistence
// - share_plus for Share.share
// - url_launcher for mailto / external links
// - CategoryPrefs lives in root_shell.dart
//
// Make sure RootShell is passing:
//   feedStatusLine: "..."
//   versionLabel:   "..."
//   onLanguageTap: _openLanguagePicker()
//   onCategoryTap: _openCategoryPicker()
//   onThemeTap:    _openThemePicker()
//   etc.
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
    this.onFiltersChanged, // still here for compatibility
    this.onLanguageTap,    // opens Language picker sheet
    this.onCategoryTap,    // opens Category picker sheet
    this.onThemeTap,       // opens Theme picker sheet
    this.appShareUrl,
    this.privacyUrl,
    this.termsUrl,
  });

  final VoidCallback onClose;

  // e.g. "Entertainment · English"
  final String feedStatusLine;

  // e.g. "Version 0.1.0 · Early access"
  final String versionLabel;

  final VoidCallback? onFiltersChanged;
  final VoidCallback? onLanguageTap;
  final VoidCallback? onCategoryTap;
  final VoidCallback? onThemeTap;

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

  // Turn stored language code into display label.
  // We'll expand this list as we add more languages.
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

  // ───────────────────── text style helpers ─────────────────────

  TextStyle _rowTitleStyle(ColorScheme cs) {
    return GoogleFonts.inter(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: cs.onSurface,
      height: 1.3,
    );
  }

  // Subtitle for helper copy ("Send the app link", "Affects Home & stories").
  TextStyle _rowSubStyle(ColorScheme cs) {
    return GoogleFonts.inter(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      height: 1.3,
      color: cs.onSurface.withOpacity(0.7),
    );
  }

  // Subtitle for selected value ("English").
  TextStyle _valueLineStyle(ColorScheme cs) {
    return GoogleFonts.inter(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1.3,
      color: cs.onSurface,
    );
  }

  // Small "🌐" etc with emoji fallback.
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

  // The small square action button on the left of each row.
  // Matches the header action buttons feel:
  // dark/navy bg block, red border, 8px radius, subtle glow.
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

  // Section header label ("CONTENT & FILTERS", etc.).
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

  // ───────────────────── reusable row builder ─────────────────────
  //
  // This builds a single row of the drawer sections in the new style:
  //
  // [square icon]  Title
  //                Subtitle (optional, either "English" or helper text)
  //                                           >
  //
  // isValueLine:
  //   true  -> subtitle styled bold/primary (ex: "English")
  //   false -> subtitle styled as helper/dimmed
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
              style:
                  isValueLine ? _valueLineStyle(cs) : _rowSubStyle(cs),
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
            // Text block
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
            // Chevron
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

  // ───────────────────── specific rows using _drawerRow ─────────────────────

  Widget _langRow() {
    final label = _langLabel(_lang);
    return _drawerRow(
      emoji: '🌐',
      title: 'Show stories in',
      subtitle: label,        // just "English", etc.
      isValueLine: true,      // bold/primary subtitle
      onTap: widget.onLanguageTap,
    );
  }

  Widget _whatToShowRow() {
    // Per your request:
    // "What to show" row has NO second line.
    // We do NOT display CategoryPrefs.instance.summary() here anymore.
    return _drawerRow(
      emoji: '📺',
      title: 'What to show',
      subtitle: null,         // no subline
      isValueLine: false,
      onTap: widget.onCategoryTap,
    );
  }

  Widget _themeRow() {
    return _drawerRow(
      emoji: '🎨',
      title: 'Theme',
      subtitle: 'System / Light / Dark · Affects Home & stories',
      isValueLine: false,
      onTap: widget.onThemeTap,
    );
  }

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

  // ───────────────────── header block ─────────────────────
  //
  // Top branding section exactly like before:
  //   🎬 red square
  //   CinePulse (red gradient text)
  //   tagline
  //   feedStatusLine ("Entertainment · English")
  //   Close button
  Widget _drawerHeader(bool isDark) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor =
        isDark ? Colors.white.withOpacity(0.06)
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

          // Brand + tagline + feed status
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

  // ───────────────────── actions ─────────────────────

  // Share CinePulse link.
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

  // "Report an issue"
  Future<void> _reportIssue() async {
    final uri = Uri.parse(
      'mailto:feedback@cinepulse.app?subject=CinePulse%20Feedback',
    );
    await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
  }

  // Open privacy / terms external URLs.
  Future<void> _openExternal(String? url) async {
    if (url == null || url.isEmpty) return;
    await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.platformDefault,
    );
  }

  // ───────────────────── build ─────────────────────

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
