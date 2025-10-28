// lib/widgets/app_drawer.dart
//
// Right-side drawer (endDrawer) for CinePulse.
//
// This panel slides in from the right when you tap the menu icon in the header.
// It matches the wide-screen CinePulse UI (your screenshot):
//
// ───────────────── UI STRUCTURE ─────────────────
//
// HEADER
//   [ 🎬 red gradient square ]
//   CinePulse
//   "Movies & OTT, in a minute."
//   "<CategorySummary> · <LanguageSummary>"   (feedStatusLine from RootShell)
//   [ ✕ close ]
//
// CONTENT & FILTERS
//   Row: "Show stories in"
//        [red badge]  English                        (> opens language picker)
//   Row: "What to show"
//        [outline badge]  Entertainment / All / ... (> opens category picker)
//
// APPEARANCE
//   Row: "Theme"
//        "System / Light / Dark · Affects Home & stories"
//        (> opens theme picker)
//
// SHARE & SUPPORT
//   Row:
//        [outline pill: "Share"]
//        "Send the app link"
//        (> share or copy link)
//   Row:
//        [outline pill: "Report"]
//        "Tell us if something is broken or fake. We’ll remove it."
//        (> email feedback)
//
// ABOUT & LEGAL
//   Row: "About CinePulse"
//        "Version 0.1.0 · Early access" (versionLabel from RootShell)
//   Row: "Privacy Policy"
//   Row: "Terms of Use"
//
// ───────────────── KEY STYLE DECISIONS ─────────────────
//
// 1. CONTENT & FILTERS rows now match what you asked for:
//    - NOT a full chip/pill with text inside.
//    - Instead we show a small CinePulse "badge" shape first,
//      and then the text label next to it.
//
//    Example:
//      Show stories in
//      [red badge]  English
//
//      What to show
//      [outline badge]  Entertainment
//
//    The badge = visual dot/lozenge that uses CinePulse red.
//    The label text sits to the right.
//
// 2. The rest of the drawer still uses:
//    - Dark navy/black surfaces (#0f172a in dark mode).
//    - 1px low-opacity separators (0.06 alpha).
//    - Inter typography at 14/13px.
//    - Accent red #dc2626.
//
// 3. Language preference is read from SharedPreferences ('cp.lang')
//    and turned into a label ("English", "Hindi", "Mixed").
//
// 4. CategoryPrefs.instance.summary() returns "All", "Entertainment",
//    "Entertainment +2", etc. We show that after an outline badge.
//
// 5. Tapping:
//    - "Show stories in" row    → widget.onLanguageTap()
//    - "What to show" row       → widget.onCategoryTap()
//    - "Theme" row              → widget.onThemeTap()
//    - "Share" row              → share/copy
//    - "Report" row             → mailto feedback
//
// RootShell must pass:
//   feedStatusLine: "Entertainment · English"
//   versionLabel:   "Version 0.1.0 · Early access"
//
// NOTE: This file depends on google_fonts, share_plus, url_launcher,
//       shared_preferences. CategoryPrefs is defined in root_shell.dart.
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
    this.onFiltersChanged, // kept for compatibility
    this.onLanguageTap,    // open Language picker bottom sheet
    this.onCategoryTap,    // open Category picker bottom sheet
    this.onThemeTap,       // open Theme picker bottom sheet
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
  static const _kLangPrefKey = 'cp.lang'; // 'english' | 'hindi' | 'mixed'

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

  // Map 'english' / 'hindi' / 'mixed' -> label text
  String _langLabel(String code) {
    switch (code) {
      case 'english':
        return 'English';
      case 'hindi':
        return 'Hindi';
      default:
        return 'Mixed';
    }
  }

  // ────────────────────────── shared text styles ──────────────────────────

  TextStyle _rowTitleStyle(ColorScheme cs) {
    return GoogleFonts.inter(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: cs.onSurface,
      height: 1.3,
    );
  }

  TextStyle _rowSubStyle(ColorScheme cs) {
    return GoogleFonts.inter(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      height: 1.3,
      color: cs.onSurface.withOpacity(0.7),
    );
  }

  TextStyle _valueTextStyle(ColorScheme cs) {
    // the "English", "Entertainment" text after the badge
    return GoogleFonts.inter(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1.3,
      color: cs.onSurface, // in dark mode this will be near-white
    );
  }

  // ────────────────────────── badge primitives ──────────────────────────
  //
  // Tiny CinePulse visual dot/lozenge.
  // We show this next to the text in Content & Filters so it reads like:
  // [badge]  English
  //
  // Filled badge = solid red with glow.
  // Outline badge = transparent bg with red border.

  Widget _badgeFilled() {
    return Container(
      height: 14,
      width: 18,
      decoration: BoxDecoration(
        color: _accent,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _accent, width: 1),
        boxShadow: [
          BoxShadow(
            color: _accent.withOpacity(0.4),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
    );
  }

  Widget _badgeOutline() {
    return Container(
      height: 14,
      width: 18,
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: _accent.withOpacity(0.4),
          width: 1,
        ),
      ),
    );
  }

  // We still keep pillOutline/pillFilled for Share / Report rows.
  Widget _pillOutline(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: _accent.withOpacity(0.4),
          width: 1,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: _accent,
          fontSize: 13,
          fontWeight: FontWeight.w500,
          height: 1.2,
        ),
      ),
    );
  }

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

  // ────────────────────────── row builders ──────────────────────────
  //
  // Each row:
  //   - 16px horizontal padding
  //   - 14px vertical padding
  //   - bottom 1px divider
  //   - left side is Column(title + value line)
  //   - right side chevron

  Widget _langRow() {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = cs.onSurface.withOpacity(0.06);
    final label = _langLabel(_lang);

    return InkWell(
      onTap: widget.onLanguageTap,
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
            // Left side content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Show stories in',
                    style: _rowTitleStyle(cs),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _badgeFilled(),
                      const SizedBox(width: 8),
                      Text(label, style: _valueTextStyle(cs)),
                    ],
                  ),
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

  Widget _whatToShowRow() {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = cs.onSurface.withOpacity(0.06);

    return AnimatedBuilder(
      animation: CategoryPrefs.instance,
      builder: (context, _) {
        final summary = CategoryPrefs.instance.summary(); // e.g. "All", "Entertainment"
        return InkWell(
          onTap: widget.onCategoryTap,
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
                // Left side content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'What to show',
                        style: _rowTitleStyle(cs),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _badgeOutline(),
                          const SizedBox(width: 8),
                          Text(summary, style: _valueTextStyle(cs)),
                        ],
                      ),
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
      },
    );
  }

  Widget _themeRow() {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = cs.onSurface.withOpacity(0.06);

    return InkWell(
      onTap: widget.onThemeTap,
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Theme',
                    style: _rowTitleStyle(cs),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'System / Light / Dark · Affects Home & stories',
                    style: _rowSubStyle(cs),
                  ),
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

  Widget _shareSupportRow({
    required String pillText,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = cs.onSurface.withOpacity(0.06);

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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _pillOutline(pillText),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: _rowSubStyle(cs),
                  ),
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

  Widget _infoRow({
    required String title,
    String? subtitle,
    required VoidCallback? onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = cs.onSurface.withOpacity(0.06);

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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: _rowTitleStyle(cs),
                  ),
                  if (subtitle != null && subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: _rowSubStyle(cs),
                    ),
                  ],
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

  // ────────────────────────── header block ──────────────────────────
  //
  //  🎬 badge
  //  CinePulse (red gradient text)
  //  Movies & OTT, in a minute.
  //  feedStatusLine (ex: "Entertainment · English")
  //  [✕]
  Widget _drawerHeader(bool isDark) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor =
        isDark ? Colors.white.withOpacity(0.06) : cs.onSurface.withOpacity(0.06);

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
          // Branded red square with 🎬
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
            child: const Center(
              child: Text(
                '🎬',
                style: TextStyle(fontSize: 20, height: 1),
              ),
            ),
          ),

          const SizedBox(width: 12),

          // Brand block
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

  // ────────────────────────── actions ──────────────────────────

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

  // ────────────────────────── build ──────────────────────────

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
            _shareSupportRow(
              pillText: 'Share',
              subtitle: 'Send the app link',
              onTap: () => _shareApp(context),
            ),
            _shareSupportRow(
              pillText: 'Report',
              subtitle:
                  'Tell us if something is broken or fake. We’ll remove it.',
              onTap: _reportIssue,
            ),

            // ABOUT & LEGAL
            _sectionHeader(context, 'About & legal'),
            _infoRow(
              title: 'About CinePulse',
              subtitle: widget.versionLabel,
              onTap: widget.onClose,
            ),
            _infoRow(
              title: 'Privacy Policy',
              subtitle: null,
              onTap: () => _openExternal(widget.privacyUrl),
            ),
            _infoRow(
              title: 'Terms of Use',
              subtitle: null,
              onTap: () => _openExternal(widget.termsUrl),
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
