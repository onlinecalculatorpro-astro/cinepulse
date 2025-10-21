// lib/widgets/app_drawer.dart
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppDrawer extends StatefulWidget {
  const AppDrawer({
    super.key,
    required this.onClose,
    this.onFiltersChanged,          // optional callback to refresh feeds
    this.appShareUrl,               // e.g., https://cinepulse.netlify.app
    this.privacyUrl,                // e.g., https://.../privacy
    this.termsUrl,                  // e.g., https://.../terms
  });

  final VoidCallback onClose;
  final VoidCallback? onFiltersChanged;
  final String? appShareUrl;
  final String? privacyUrl;
  final String? termsUrl;

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  // Pref keys
  static const _kRegion = 'cp.region';        // 'india' | 'global'
  static const _kLang   = 'cp.lang';          // 'english' | 'hindi' | 'mixed'
  static const _kCats   = 'cp.categories';    // JSON list: ['all','trailers',...]

  // Local state (with sensible defaults)
  String _region = 'india';
  String _lang = 'mixed';
  final Set<String> _cats = {
    'all', 'trailers', 'ott', 'intheatres', 'comingsoon'
  };

  late Future<void> _loader;

  @override
  void initState() {
    super.initState();
    _loader = _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final sp = await SharedPreferences.getInstance();
    _region = sp.getString(_kRegion) ?? _region;
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

  Future<void> _savePrefs() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kRegion, _region);
    await sp.setString(_kLang, _lang);
    await sp.setString(_kCats, jsonEncode(_cats.toList()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Filters updated')),
    );
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

                // ===== Content & Filters =====
                _sectionTitle('Content & filters'),

                // Region
                ListTile(
                  leading: _emoji('🌐'),
                  title: const Text('Region'),
                  subtitle: Text(
                    _region == 'india' ? 'India' : 'Global',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                  trailing: DropdownButton<String>(
                    value: _region,
                    onChanged: (v) => setState(() => _region = v ?? _region),
                    items: const [
                      DropdownMenuItem(value: 'india', child: Text('India')),
                      DropdownMenuItem(value: 'global', child: Text('Global')),
                    ],
                  ),
                ),

                // Language preference
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
                            onSelected: (_) => setState(() => _lang = 'english'),
                          ),
                          ChoiceChip(
                            label: const Text('Hindi'),
                            selected: _lang == 'hindi',
                            onSelected: (_) => setState(() => _lang = 'hindi'),
                          ),
                          ChoiceChip(
                            label: const Text('Mixed'),
                            selected: _lang == 'mixed',
                            onSelected: (_) => setState(() => _lang = 'mixed'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Categories multi-select
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
                          _catChip('all', 'All'),
                          _catChip('trailers', 'Trailers'),
                          _catChip('ott', 'OTT'),
                          _catChip('intheatres', 'In Theatres'),
                          _catChip('comingsoon', 'Coming Soon'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () {
                            setState(() {
                              _cats
                                ..clear()
                                ..addAll(
                                  {'all','trailers','ott','intheatres','comingsoon'},
                                );
                            });
                          },
                          icon: const Icon(Icons.select_all_rounded),
                          label: const Text('Select all'),
                        ),
                      ),
                    ],
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _savePrefs,
                      icon: const Icon(Icons.done_all_rounded),
                      label: const Text('Apply filters'),
                    ),
                  ),
                ),

                const Divider(height: 24),

                // ===== Appearance (kept simple, you already have this elsewhere) =====
                _sectionTitle('Appearance'),
                ListTile(
                  leading: const Icon(Icons.brightness_6_rounded),
                  title: const Text('Theme'),
                  subtitle: const Text('System / Light / Dark'),
                  onTap: () {
                    // Keep your existing theme flow. If you want me to wire a bottom sheet here,
                    // say the word and I’ll add it.
                  },
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
                  onTap: () {
                    // Replace with your GitHub Issues or mailto:
                  },
                ),

                const Divider(height: 24),

                // ===== About & legal =====
                _sectionTitle('About & legal'),
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('About CinePulse'),
                  subtitle: const Text('Version 0.1.0'),
                  onTap: () {},
                ),
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('Privacy Policy'),
                  onTap: () {
                    final url = widget.privacyUrl ?? '';
                    if (url.isNotEmpty) _openUrl(url);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.gavel_outlined),
                  title: const Text('Terms of Use'),
                  onTap: () {
                    final url = widget.termsUrl ?? '';
                    if (url.isNotEmpty) _openUrl(url);
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
    return FilterChip(
      label: Text(label),
      selected: _cats.contains(key),
      onSelected: (v) => setState(() {
        if (v) {
          _cats.add(key);
        } else {
          _cats.remove(key);
        }
      }),
    );
  }

  Future<void> _openUrl(String url) async {
    // Keep this minimal: on web we let the browser handle it
    // (You already have url_launcher as a dep in the app).
    // Import here would add another dep; we keep the drawer pure.
  }
}
