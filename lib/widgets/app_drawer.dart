// lib/widgets/app_drawer.dart
//
// Right-side settings / preferences drawer (endDrawer).
//
// Changes vs your previous version:
//  - Drawer no longer shows inline multi-select chips for Categories.
//    Instead it shows a single "Categories" row. Tapping that row calls
//    widget.onCategoryTap(), which RootShell handles by opening the
//    bottom-sheet category picker (_CategoryPicker).
//
//  - That row also live-updates a little pill like "All" or
//    "Entertainment +2" using CategoryPrefs.instance.summary().
//
//  - Language preference chips (English / Hindi / Mixed) still live here
//    and are persisted to SharedPreferences.
//
//  - Theme row still calls widget.onThemeTap(), which RootShell
//    handles by opening the theme bottom sheet.
//
// NOTE: CategoryPrefs is defined in root_shell.dart in this setup.
// You can move it to its own file (recommended long-term) and import
// from there. For now we import from root_shell.dart.

import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../root_shell.dart' show CategoryPrefs; // <-- uses the singleton

class AppDrawer extends StatefulWidget {
  const AppDrawer({
    super.key,
    required this.onClose,
    this.onFiltersChanged,       // tell Home to refresh after changes
    this.onThemeTap,             // open Theme bottom sheet
    this.onCategoryTap,          // open Category picker bottom sheet
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
  // SharedPreferences keys
  static const _kLang = 'cp.lang';           // 'english' | 'hindi' | 'mixed'
  // (previously we also persisted categories here as cp.categories. In the
  // new flow CategoryPrefs is global/in-memory + bottom sheet. You can
  // persist it later if you want, but for now we don't do it here.)

  // local state
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

  // small helpers

  Widget _emoji(String e, {double size = 16}) => Text(
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

  Widget _sectionTitle(String text) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: onSurface.withOpacity(0.72),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final borderColor = Colors.white.withOpacity(0.06);

    return Drawer(
      child: SafeArea(
        child: FutureBuilder<void>(
          future: _loader,
          builder: (context, _) {
            return ListView(
              padding: EdgeInsets.zero,
              children: [
                // HEADER (brand + close)
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                  decoration: BoxDecoration(
                    color: cs.surface.withOpacity(0.05),
                    border: Border(
                      bottom: BorderSide(color: borderColor, width: 1),
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

                      // CinePulse brand text + tagline
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ShaderMask(
                              shaderCallback: (bounds) =>
                                  const LinearGradient(
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
                ),

                // ────────────── CONTENT & FILTERS ──────────────
                _sectionTitle('Content & filters'),

                // Language preference block (English / Hindi / Mixed)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
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
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('English'),
                            selected: _lang == 'english',
                            onSelected: (_) {
                              setState(() => _lang = 'english');
                              _persistLanguage();
                            },
                          ),
                          ChoiceChip(
                            label: const Text('Hindi'),
                            selected: _lang == 'hindi',
                            onSelected: (_) {
                              setState(() => _lang = 'hindi');
                              _persistLanguage();
                            },
                          ),
                          ChoiceChip(
                            label: const Text('Mixed'),
                            selected: _lang == 'mixed',
                            onSelected: (_) {
                              setState(() => _lang = 'mixed');
                              _persistLanguage();
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Categories row:
                // - Tapping opens bottom-sheet category picker
                // - We show current selection summary in a pill
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: AnimatedBuilder(
                    animation: CategoryPrefs.instance,
                    builder: (context, __) {
                      final summary = CategoryPrefs.instance.summary();
                      return InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: widget.onCategoryTap,
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
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: cs.surfaceVariant
                                          .withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        width: 1,
                                        color: cs.onSurface.withOpacity(0.15),
                                      ),
                                    ),
                                    child: Text(
                                      summary,
                                      style: GoogleFonts.inter(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: cs.onSurface,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: cs.onSurface.withOpacity(0.6),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),

                const Divider(height: 24),

                // ────────────── APPEARANCE ──────────────
                _sectionTitle('Appearance'),

                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Theme'),
                  subtitle: const Text('System / Light / Dark'),
                  onTap: widget.onThemeTap,
                ),

                const Divider(height: 24),

                // ────────────── SHARE & SUPPORT ──────────────
                _sectionTitle('Share & support'),

                ListTile(
                  leading: _emoji('📣'),
                  title: const Text('Share CinePulse'),
                  onTap: () async {
                    final link =
                        widget.appShareUrl ?? 'https://cinepulse.netlify.app';
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
                  },
                ),
                ListTile(
                  leading: _emoji('🛠️'),
                  title: const Text('Report an issue'),
                  onTap: () async {
                    final uri = Uri.parse(
                      'mailto:feedback@cinepulse.app'
                      '?subject=CinePulse%20Feedback',
                    );
                    await launchUrl(
                      uri,
                      mode: LaunchMode.externalApplication,
                    );
                  },
                ),

                const Divider(height: 24),

                // ────────────── ABOUT & LEGAL ──────────────
                _sectionTitle('About & legal'),

                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('About CinePulse'),
                  subtitle: const Text('Version 0.1.0'),
                  onTap: widget.onClose,
                ),
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('Privacy Policy'),
                  onTap: () async {
                    final url = widget.privacyUrl ?? '';
                    if (url.isNotEmpty) {
                      await launchUrl(
                        Uri.parse(url),
                        mode: LaunchMode.platformDefault,
                      );
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.gavel_outlined),
                  title: const Text('Terms of Use'),
                  onTap: () async {
                    final url = widget.termsUrl ?? '';
                    if (url.isNotEmpty) {
                      await launchUrl(
                        Uri.parse(url),
                        mode: LaunchMode.platformDefault,
                      );
                    }
                  },
                ),

                const SizedBox(height: 18),
              ],
            );
          },
        ),
      ),
    );
  }
}
