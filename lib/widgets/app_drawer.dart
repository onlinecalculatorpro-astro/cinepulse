// lib/widgets/app_drawer.dart
//
// Right-side settings / preferences drawer (endDrawer).
//
// UPDATED TO MATCH THE APPROVED CINEPULSE POLISH:
//
// - Dark, glassy / nav-style surface (0xFF0f172a) with subtle 1px separators.
// - Strong CinePulse branding header with red badge, gradient text, and Close.
// - Section headers are quiet, all-caps-ish labels at 12px, semi-transparent.
// - Language chips now match our pill system:
//     • Selected  = red fill (#dc2626), white text
//     • Unselected = transparent bg, red border/text
//   This keeps visual consistency with the header chips in HomeScreen.
// - Categories row: shows a tappable row with a read-only summary pill
//   (outline pill using accent border) instead of inline FilterChips.
//   Tapping it triggers widget.onCategoryTap(), which pops a bottom sheet.
// - Theme row: triggers widget.onThemeTap() -> Theme bottom sheet.
// - Share / Report issue / About & legal rows styled like interactive rows.
//
// Behavior:
// - We persist language preference (cp.lang) to SharedPreferences.
// - We read CategoryPrefs.instance.summary() to render the pill that says
//   "All", "Entertainment", or "Entertainment +2".
// - We don't expose category chips here anymore. Category selection lives
//   in the bottom sheet (_CategoryPicker) owned by RootShell.
//
// NOTE: CategoryPrefs currently lives in root_shell.dart.

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
    this.onFiltersChanged, // let HomeScreen refresh if prefs change
    this.onThemeTap,       // open Theme picker sheet
    this.onCategoryTap,    // open Category picker sheet
    this.appShareUrl,
    this.privacyUrl,
    this.termsUrl,
  });

  final VoidCallback onClose;
  final VoidCallback? onFiltersChanged;
  final VoidCallback? onThemeTap;
  final VoidCallback? onCategoryTap;
  final String? appShareUrl;
  final String? privacyUrl;
  final String? termsUrl;

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  // SharedPreferences key for language.
  static const _kLang = 'cp.lang'; // 'english' | 'hindi' | 'mixed'

  String _lang = 'mixed';
  late Future<void> _loader;

  static const _accent = Color(0xFFdc2626);

  @override
  void initState() {
    super.initState();
    _loader = _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final sp = await SharedPreferences.getInstance();
    _lang = sp.getString(_kLang) ?? _lang;
    if (mounted) setState(() {});
  }

  Future<void> _persistLanguage() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kLang, _lang);
    widget.onFiltersChanged?.call();
  }

  // ───────────────────── Small helpers ─────────────────────

  Widget _emoji(String e, {double size = 16}) {
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

  Widget _langChip(String label, String value) {
    final bool active = (_lang == value);

    if (active) {
      // FILLED red pill (matches active category chip in header)
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () {
          setState(() => _lang = value);
          _persistLanguage();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ),
      );
    }

    // OUTLINE pill
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () {
        setState(() => _lang = value);
        _persistLanguage();
      },
      child: Container(
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
          label,
          style: TextStyle(
            color: _accent,
            fontSize: 13,
            fontWeight: FontWeight.w500,
            height: 1.2,
          ),
        ),
      ),
    );
  }

  // A generic tappable row with leading widget, title/subtitle and trailing chevron.
  Widget _settingsRow({
    required Widget leading,
    required String title,
    String? subtitle,
    required VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
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
            leading,
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                      height: 1.3,
                    ),
                  ),
                  if (subtitle != null && subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        height: 1.3,
                        color: cs.onSurface.withOpacity(0.7),
                      ),
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

  // Row for Categories specifically because we show the summary pill.
  Widget _categoryRow() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dividerColor = cs.onSurface.withOpacity(0.06);

    return AnimatedBuilder(
      animation: CategoryPrefs.instance,
      builder: (context, _) {
        final summary = CategoryPrefs.instance.summary();
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
                _emoji('🗂️'),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Categories',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // read-only pill mirroring inactive chip style
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            width: 1,
                            color: _accent.withOpacity(0.4),
                          ),
                        ),
                        child: Text(
                          summary,
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: _accent,
                            height: 1.2,
                          ),
                        ),
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
      },
    );
  }

  // The header at the very top of the drawer.
  Widget _drawerHeader(bool isDark) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
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
          // red badge with 🎬
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

          // CinePulse + tagline
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

  // "Share CinePulse"
  Future<void> _shareApp(BuildContext context) async {
    final link = widget.appShareUrl ?? 'https://cinepulse.netlify.app';
    if (!kIsWeb) {
      await Share.share(link);
    } else {
      await Clipboard.setData(ClipboardData(text: link));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Link copied to clipboard'),
          ),
        );
      }
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

  // Launch simple external URL
  Future<void> _openExternal(String? url) async {
    if (url == null || url.isEmpty) return;
    await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.platformDefault,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final drawerBg = isDark
        ? const Color(0xFF0f172a)
        : cs.surface;

    return Drawer(
      backgroundColor: drawerBg,
      child: SafeArea(
        child: FutureBuilder<void>(
          future: _loader,
          builder: (context, _) {
            return ListView(
              padding: EdgeInsets.zero,
              children: [
                // HEADER
                _drawerHeader(isDark),

                // CONTENT & FILTERS
                _sectionHeader(context, 'Content & filters'),

                // Language preference
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        width: 1,
                        color: cs.onSurface.withOpacity(0.06),
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _emoji('🗣️'),
                          const SizedBox(width: 16),
                          Text(
                            'Language preference',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _langChip('English', 'english'),
                          _langChip('Hindi', 'hindi'),
                          _langChip('Mixed', 'mixed'),
                        ],
                      ),
                    ],
                  ),
                ),

                // Categories row (opens bottom sheet picker)
                _categoryRow(),

                // APPEARANCE
                _sectionHeader(context, 'Appearance'),
                _settingsRow(
                  leading: const Icon(Icons.palette_outlined, size: 20),
                  title: 'Theme',
                  subtitle: 'System / Light / Dark',
                  onTap: widget.onThemeTap,
                ),

                // SHARE & SUPPORT
                _sectionHeader(context, 'Share & support'),
                _settingsRow(
                  leading: _emoji('📣'),
                  title: 'Share CinePulse',
                  subtitle: 'Send the app link',
                  onTap: () => _shareApp(context),
                ),
                _settingsRow(
                  leading: _emoji('🛠️'),
                  title: 'Report an issue',
                  subtitle: 'Send us feedback',
                  onTap: _reportIssue,
                ),

                // ABOUT & LEGAL
                _sectionHeader(context, 'About & legal'),
                _settingsRow(
                  leading: const Icon(Icons.info_outline_rounded, size: 20),
                  title: 'About CinePulse',
                  subtitle: 'Version 0.1.0',
                  onTap: widget.onClose,
                ),
                _settingsRow(
                  leading: const Icon(Icons.privacy_tip_outlined, size: 20),
                  title: 'Privacy Policy',
                  subtitle: null,
                  onTap: () => _openExternal(widget.privacyUrl),
                ),
                _settingsRow(
                  leading: const Icon(Icons.gavel_outlined, size: 20),
                  title: 'Terms of Use',
                  subtitle: null,
                  onTap: () => _openExternal(widget.termsUrl),
                ),

                const SizedBox(height: 24),
              ],
            );
          },
        ),
      ),
    );
  }
}
