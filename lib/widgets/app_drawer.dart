// lib/widgets/app_drawer.dart
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
    this.onFiltersChanged,          // callback to refresh feeds immediately
    this.onThemeTap,                // open Theme picker in RootShell
    this.appShareUrl,               // e.g., https://cinepulse.netlify.app
    this.privacyUrl,                // e.g., https://.../privacy
    this.termsUrl,                  // e.g., https://.../terms
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

  // Local state (defaults)
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

  // UI helpers
  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.72),
        ),
      ),
    );
  }

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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Drawer(
      child: SafeArea(
        child: FutureBuilder<void>(
          future: _loader,
          builder: (context, _) {
            return ListView(
              padding: EdgeInsets.zero,
              children: [
                // ----- Header (match AppBar style) -----
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        cs.surfaceContainerHighest.withOpacity(0.28),
                        cs.surface.withOpacity(0.18),
                      ],
                    ),
                    border: Border(
                      bottom: BorderSide(
                        color: Colors.white.withOpacity(0.06),
                        width: 1,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      // Use your app logo to mirror the AppBar
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.asset(
                          'assets/logo.png',
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'CinePulse',
                            style: GoogleFonts.inter(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: cs.onSurface,
                              height: 1.1,
                            ),
                          ),
                          Text(
                            'Movies & OTT, in a minute.',
                            style: GoogleFonts.inter(
                              fontSize: 12.5,
                              color: cs.onSurface.withOpacity(0.72),
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                ),

                // ===== Content & filters =====
                _sectionTitle('Content & filters'),

                // Language preference (app UI language)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _emoji('🗣️'),
                          const SizedBox(width: 16),
                          const Text('Language preference'),
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

                // Categories (for now: only "Entertainment")
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _emoji('🗂️'),
                          const SizedBox(width: 16),
                          const Text('Categories'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _catChip('entertainment', 'Entertainment'),
                        ],
                      ),
                    ],
                  ),
                ),

                const Divider(height: 24),

                // ===== Appearance =====
                _sectionTitle('Appearance'),
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Theme'),
                  subtitle: const Text('System / Light / Dark'),
                  onTap: widget.onThemeTap,
                ),

                const Divider(height: 24),

                // ===== Share & support =====
                _sectionTitle('Share & support'),
                ListTile(
                  leading: _emoji('📣'),
                  title: const Text('Share CinePulse'),
                  onTap: () async {
                    final link = widget.appShareUrl ?? 'https://cinepulse.netlify.app';
                    if (!kIsWeb) {
                      await Share.share(link);
                    } else {
                      await Clipboard.setData(ClipboardData(text: link));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Link copied to clipboard')),
                        );
                      }
                    }
                  },
                ),
                ListTile(
                  leading: _emoji('🛠️'),
                  title: const Text('Report an issue'),
                  onTap: () async {
                    final uri = Uri.parse('mailto:feedback@cinepulse.app?subject=CinePulse%20Feedback');
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  },
                ),

                const Divider(height: 24),

                // ===== About & legal =====
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
                      await launchUrl(Uri.parse(url), mode: LaunchMode.platformDefault);
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.gavel_outlined),
                  title: const Text('Terms of Use'),
                  onTap: () async {
                    final url = widget.termsUrl ?? '';
                    if (url.isNotEmpty) {
                      await launchUrl(Uri.parse(url), mode: LaunchMode.platformDefault);
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
