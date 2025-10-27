// lib/widgets/app_drawer.dart
//
// Right-side settings panel (endDrawer).
// Updated header branding to match the CinePulse app bar brand block
//   - red badge with 🎬
//   - "CinePulse" gradient text
//   - tagline below
//
// Public API stays the same so RootShell does not need changes.

import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class AppDrawer extends StatefulWidget {
  const AppDrawer({
    super.key,
    required this.onClose,
    this.onFiltersChanged, // callback to refresh feeds immediately
    this.onThemeTap,       // open Theme picker in RootShell
    this.appShareUrl,      // e.g. https://cinepulse.netlify.app
    this.privacyUrl,       // e.g. https://.../privacy
    this.termsUrl,         // e.g. https://.../terms
  });

  final VoidCallback onClose;
  final VoidCallback? onFiltersChanged;
  final VoidCallback? onThemeTap;
  final String? appShareUrl;
  final String? privacyUrl;
  final String? termsUrl;

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  // Pref keys
  static const _kLang = 'cp.lang';           // 'english' | 'hindi' | 'mixed'
  static const _kCats = 'cp.categories';     // JSON list, e.g. ['entertainment']

  // Local state defaults
  String _lang = 'mixed';
  final Set<String> _cats = {'entertainment'};

  late Future<void> _loader;

  @override
  void initState() {
    super.initState();
    _loader = _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final sp = await SharedPreferences.getInstance();
    _lang = sp.getString(_kLang) ?? _lang;

    final raw = sp.getString(_kCats);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = (jsonDecode(raw) as List).map((e) => e.toString()).toList();
        if (list.isNotEmpty) {
          _cats
            ..clear()
            ..addAll(list);
        }
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Future<void> _persist() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kLang, _lang);
    await sp.setString(_kCats, jsonEncode(_cats.toList()));
    widget.onFiltersChanged?.call();
  }

  // ----- small helpers -----

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
                // ───────────────── HEADER (brand block + close) ─────────────────
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
                      // Brand avatar (red film badge with 🎬)
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

                      // Brand text + tagline
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // "CinePulse" in red gradient (same feel as header)
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

                      // Close icon
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

                // ───────────────── CONTENT & FILTERS ─────────────────
                _sectionTitle('Content & filters'),

                // Language preference
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
                              _persist();
                            },
                          ),
                          ChoiceChip(
                            label: const Text('Hindi'),
                            selected: _lang == 'hindi',
                            onSelected: (_) {
                              setState(() => _lang = 'hindi');
                              _persist();
                            },
                          ),
                          ChoiceChip(
                            label: const Text('Mixed'),
                            selected: _lang == 'mixed',
                            onSelected: (_) {
                              setState(() => _lang = 'mixed');
                              _persist();
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Categories
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
                          _emoji('🗂️'),
                          const SizedBox(width: 16),
                          Text(
                            'Categories',
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
                        runSpacing: 8,
                        children: [
                          _catChip('entertainment', 'Entertainment'),
                          // if more categories come later, add them here
                        ],
                      ),
                    ],
                  ),
                ),

                const Divider(height: 24),

                // ───────────────── APPEARANCE ─────────────────
                _sectionTitle('Appearance'),

                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Theme'),
                  subtitle: const Text('System / Light / Dark'),
                  onTap: widget.onThemeTap,
                ),

                const Divider(height: 24),

                // ───────────────── SHARE & SUPPORT ─────────────────
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

                // ───────────────── ABOUT & LEGAL ─────────────────
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

  Widget _catChip(String key, String label) {
    final selected = _cats.contains(key);
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (v) {
        setState(() {
          if (v) {
            _cats.add(key);
          } else {
            _cats.remove(key);
          }
        });
        _persist();
      },
    );
  }
}
