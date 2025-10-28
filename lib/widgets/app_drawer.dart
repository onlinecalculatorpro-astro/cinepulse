// lib/widgets/app_drawer.dart
//
// Right-side drawer (endDrawer) for CinePulse.
// This is the slide-out menu opened from the header "menu" icon.
//
// GOALS (aligned with app tone and Story screen style):
// - Strong CinePulse identity at the top (logo + tagline).
// - Show what the user is currently seeing: e.g. "Entertainment · Mixed language".
//   → passed in via feedStatusLine
// - Mark build status: "Version 0.1.0 · Early access".
//   → passed in via versionLabel
// - Plain-language sections:
//     CONTENT & FILTERS
//        - "Show stories in" (language pills English / Hindi / Mixed)
//        - "What to show" (tappable row that opens category picker sheet)
//     FEED RULES
//        - bullet list explaining "No gossip, no fake outrage" etc.
//     APPEARANCE
//        - Theme picker row
//     SHARE & SUPPORT
//        - Share CinePulse
//        - Report an issue (we remove broken / fake / old links)
//     ABOUT & LEGAL
//        - About CinePulse (uses versionLabel)
//        - Privacy Policy
//        - Terms of Use
//
// VISUAL LANGUAGE:
// - Dark drawer background (#0f172a in dark mode).
// - Accent red (#dc2626).
// - Pills: active = red fill w/ glow; inactive = transparent w/ red border.
// - Rows have 1px low-opacity separators, same as bottom nav styling.
// - All icons are white/gray-ish to match the Story page header, no random colors.
//
// STATE:
// - Language preference is persisted in SharedPreferences under 'cp.lang'.
//   Values: 'english' | 'hindi' | 'mixed'
// - CategoryPrefs (from root_shell.dart) drives the summary chip in "What to show".
//   The actual picker sheet is opened by widget.onCategoryTap().
//
// DEPENDENCIES:
// - share_plus for Share.share on device
// - url_launcher for email / external links
// - google_fonts for Inter
// - shared_preferences for local persistence
// - root_shell.dart for CategoryPrefs
//
// This file must stay in sync with RootShell: RootShell passes
//   feedStatusLine: "Entertainment · Mixed language"
//   versionLabel:   "Version 0.1.0 · Early access"
//
// If you change params here, update RootShell accordingly.

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
    this.onFiltersChanged, // tell shell/HomeScreen to refresh after changes
    this.onThemeTap,       // open Theme picker bottom sheet
    this.onCategoryTap,    // open Category picker bottom sheet
    this.appShareUrl,
    this.privacyUrl,
    this.termsUrl,
  });

  final VoidCallback onClose;
  final VoidCallback? onFiltersChanged;
  final VoidCallback? onThemeTap;
  final VoidCallback? onCategoryTap;

  // e.g. "Entertainment · Mixed language"
  final String feedStatusLine;

  // e.g. "Version 0.1.0 · Early access"
  final String versionLabel;

  // links
  final String? appShareUrl;
  final String? privacyUrl;
  final String? termsUrl;

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  // SharedPreferences key for user-chosen language.
  static const _kLang = 'cp.lang'; // 'english' | 'hindi' | 'mixed'
  static const _accent = Color(0xFFdc2626);

  String _lang = 'mixed';
  late Future<void> _loader;

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

  // ────────────────────── tiny helpers ──────────────────────

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

  // Pills for language preference: English / Hindi / Mixed.
  // Active = red fill + glow like active chips on Home.
  // Inactive = transparent bg, red border, red text.
  Widget _langChip(String label, String value) {
    final bool active = (_lang == value);

    if (active) {
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

  // Generic clickable row:
  // [leading icon]  Title
  //                 Subtitle
  //                                   >
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

  // Special row for "What to show" (categories).
  // Shows a summary pill instead of subtitle, to mirror our chips.
  Widget _categoryRow() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dividerColor = cs.onSurface.withOpacity(0.06);

    return AnimatedBuilder(
      animation: CategoryPrefs.instance,
      builder: (context, _) {
        final summary = CategoryPrefs.instance.summary(); // e.g. "All" / "Entertainment"
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
                        'What to show',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // read-only summary pill
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

  // The header at the very top of the drawer:
  //  - CinePulse badge
  //  - Title "CinePulse"
  //  - Tagline
  //  - feedStatusLine (e.g. "Entertainment · Mixed language")
  //  - Close button
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
          // Branded red badge
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

          // Brand block (CinePulse / tagline / status line)
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

  // FEED RULES section:
  // This clearly states what we DON'T show.
  // Helps build trust and matches CinePulse positioning.
  Widget _feedRulesSection() {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = cs.onSurface.withOpacity(0.06);

    Widget bullet(String emoji, String text) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              emoji,
              style: const TextStyle(fontSize: 14, height: 1.3),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  height: 1.4,
                  color: cs.onSurface.withOpacity(0.8),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            width: 1,
            color: dividerColor,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _emoji('🛡️'),
              const SizedBox(width: 16),
              Text(
                'Feed rules',
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
          bullet('❌', 'No gossip or off-camera drama'),
          bullet('🚫', 'No “fans troll” outrage spam'),
          bullet('🎯', 'We keep box office, OTT drops, on-air moments'),
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

  // Generic external link opener.
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

    final drawerBg = isDark ? const Color(0xFF0f172a) : cs.surface;

    return Drawer(
      backgroundColor: drawerBg,
      child: SafeArea(
        child: FutureBuilder<void>(
          future: _loader,
          builder: (context, _) {
            return ListView(
              padding: EdgeInsets.zero,
              children: [
                // HEADER (brand + tagline + feed status)
                _drawerHeader(isDark),

                // CONTENT & FILTERS
                _sectionHeader(context, 'Content & filters'),

                // Language preference ("Show stories in")
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
                            'Show stories in',
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

                // "What to show" (categories, opens bottom sheet)
                _categoryRow(),

                // FEED RULES
                _sectionHeader(context, 'Feed rules');
                _feedRulesSection(),

                // APPEARANCE
                _sectionHeader(context, 'Appearance'),
                _settingsRow(
                  leading: const Icon(Icons.palette_outlined, size: 20),
                  title: 'Theme',
                  subtitle: 'System / Light / Dark · Affects Home & stories',
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
                  subtitle:
                      'Tell us if something is broken or fake. We’ll remove it.',
                  onTap: _reportIssue,
                ),

                // ABOUT & LEGAL
                _sectionHeader(context, 'About & legal'),
                _settingsRow(
                  leading: const Icon(Icons.info_outline_rounded, size: 20),
                  title: 'About CinePulse',
                  subtitle: widget.versionLabel,
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
