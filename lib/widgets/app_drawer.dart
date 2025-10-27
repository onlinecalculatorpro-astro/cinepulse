// lib/widgets/app_drawer.dart
//
// Right-side settings / preferences drawer (endDrawer).
//
// Changes in this version:
//
// - "Categories" no longer shows inline chips.
//   Instead it's a single row that opens the bottom-sheet category picker.
//   That sheet is owned by RootShell (RootShell calls showModalBottomSheet).
//   We trigger it using widget.onCategoryTap().
//
// - We still show a live summary pill next to "Categories", like:
//     "All"
//     "Entertainment"
//     "Entertainment +2"
//   We build that summary from AppSettings.instance.selectedCategories.
//
// - Language preference ("English" / "Hindi" / "Mixed") is still managed
//   here and persisted via SharedPreferences.
//
// - Theme row still calls widget.onThemeTap(), which RootShell handles by
//   opening the theme bottom sheet.
//
// NOTE: We assume AppSettings.instance exists, exposes:
//   - Set<String> get selectedCategories
//     (values like 'all', 'entertainment', 'sports', 'travel', 'fashion')
// and RootShell will call setSelectedCategories(...) + setState() so that
// when the drawer reopens, this summary is fresh.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/app_settings.dart';

class AppDrawer extends StatefulWidget {
  const AppDrawer({
    super.key,
    required this.onClose,
    this.onFiltersChanged,   // tell Home/root to refresh after changes (lang etc.)
    this.onThemeTap,         // open Theme bottom sheet
    this.onCategoryTap,      // open Categories bottom sheet
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
  static const _kLang = 'cp.lang'; // 'english' | 'hindi' | 'mixed'

  // Local state
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

  // Build a readable summary of the current category filter selection.
  // Rules:
  //  - if set contains 'all' OR is empty => "All"
  //  - otherwise pretty-print each category key into a name,
  //    sort, and do "First +N" if more than 1.
  String _categoriesSummary(Set<String> raw) {
    // Canonical keys we expect AppSettings to use.
    const kAll = 'all';
    const kEntertainment = 'entertainment';
    const kSports = 'sports';
    const kTravel = 'travel';
    const kFashion = 'fashion';

    if (raw.isEmpty || raw.contains(kAll)) {
      return 'All';
    }

    List<String> pretty = [];
    for (final key in raw) {
      switch (key) {
        case kEntertainment:
          pretty.add('Entertainment');
          break;
        case kSports:
          pretty.add('Sports');
          break;
        case kTravel:
          pretty.add('Travel');
          break;
        case kFashion:
          pretty.add('Fashion');
          break;
        default:
          pretty.add(key);
          break;
      }
    }

    pretty.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    if (pretty.isEmpty) return 'All';
    if (pretty.length == 1) return pretty.first;
    return '${pretty.first} +${pretty.length - 1}';
  }

  // small UI helpers

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
    // We were using a low-opacity white border in dark mode before.
    // Keep that same subtle divider feel.
    final borderColor = Colors.white.withOpacity(0.06);

    final Set<String> selectedCats =
        AppSettings.instance.selectedCategories; // read once per build
    final catSummary = _categoriesSummary(selectedCats);

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

                // Language preference (chips)
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

                // Categories row
                // Tapping opens bottom sheet (handled by RootShell via onCategoryTap)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: InkWell(
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
                                  color: cs.surfaceVariant.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    width: 1,
                                    color: cs.onSurface.withOpacity(0.15),
                                  ),
                                ),
                                child: Text(
                                  catSummary,
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
}
