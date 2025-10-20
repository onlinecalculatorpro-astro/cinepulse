// lib/features/home/widgets/search_bar.dart
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../../../core/cache.dart';

class SearchBarInput extends StatefulWidget {
  const SearchBarInput({
    super.key,
    this.controller,
    this.onChanged,
    this.onSubmitted,
    this.onMicTap,
    this.onRefresh,
    this.hintText = 'Search movies, shows, trailers…',
    this.enabled = true,
  });

  final TextEditingController? controller;

  /// Fires on user typing (for live filtering in Home).
  final ValueChanged<String>? onChanged;

  /// Fires on keyboard submit/Search.
  final ValueChanged<String>? onSubmitted;

  /// Mic action (tap). Will be disabled when offline or `enabled=false`.
  final VoidCallback? onMicTap;

  /// Refresh action (tap). Shown always; caller decides what to do.
  final VoidCallback? onRefresh;

  final String hintText;
  final bool enabled;

  @override
  State<SearchBarInput> createState() => _SearchBarInputState();
}

class _SearchBarInputState extends State<SearchBarInput> {
  final FocusNode _focus = FocusNode();
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlay;

  late final TextEditingController _c =
      widget.controller ?? TextEditingController();

  bool _offline = false;
  StreamSubscription? _connSub;

  List<String> _recents = const [];
  Timer? _recentDebounce;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    _c.addListener(_handleControllerChange);

    _loadRecents();

    // Connectivity
    _connSub = Connectivity().onConnectivityChanged.listen((event) {
      final hasNetwork = _hasNetworkFrom(event);
      if (mounted) setState(() => _offline = !hasNetwork);
    });
    () async {
      final initial = await Connectivity().checkConnectivity();
      final hasNetwork = _hasNetworkFrom(initial);
      if (mounted) setState(() => _offline = !hasNetwork);
    }();
  }

  @override
  void dispose() {
    _recentDebounce?.cancel();
    _hideOverlay();
    _connSub?.cancel();

    _focus.removeListener(_onFocus);
    _c.removeListener(_handleControllerChange);
    if (widget.controller == null) {
      _c.dispose();
    }
    _focus.dispose();
    super.dispose();
  }

  bool _hasNetworkFrom(dynamic event) {
    if (event is ConnectivityResult) return event != ConnectivityResult.none;
    if (event is List<ConnectivityResult>) {
      return event.any((r) => r != ConnectivityResult.none);
    }
    return true;
  }

  Future<void> _loadRecents() async {
    try {
      final list = await RecentQueriesStore.instance.list();
      if (mounted) setState(() => _recents = list);
    } catch (_) {
      // non-fatal
    }
  }

  // Keeps overlay state in sync with controller/focus.
  void _handleControllerChange() {
    if (_c.text.trim().isEmpty && _focus.hasFocus) {
      _showOverlay();
    } else {
      _hideOverlay();
    }
    widget.onChanged?.call(_c.text);
  }

  void _onFocus() {
    if (_focus.hasFocus && _c.text.trim().isEmpty) {
      _showOverlay();
    } else {
      _hideOverlay();
    }
  }

  void _showOverlay() {
    if (_overlay != null) return;
    _overlay = _buildOverlay();
    final overlay = Overlay.of(context);
    if (overlay != null && _overlay != null) {
      overlay.insert(_overlay!);
    }
  }

  void _hideOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  OverlayEntry _buildOverlay() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final items = _recents.take(8).toList(growable: false);

    return OverlayEntry(
      builder: (context) => CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        offset: const Offset(0, 56), // below the field
        child: Material(
          elevation: 8,
          color: cs.surface,
          surfaceTintColor: cs.surfaceTint,
          borderRadius: BorderRadius.circular(14),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720, maxHeight: 360),
            child: SizedBox(
              width: MediaQuery.of(context).size.width,
              child: items.isEmpty
                  ? _SuggestionsEmpty(onClearAll: () async {
                      await RecentQueriesStore.instance.clear();
                      if (mounted) setState(() => _recents = const []);
                      _hideOverlay();
                    })
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      shrinkWrap: true,
                      itemBuilder: (_, i) {
                        final q = items[i];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.history),
                          title: Text(
                            q,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: 'Remove',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () async {
                              await RecentQueriesStore.instance.remove(q);
                              await _loadRecents();
                              _hideOverlay();
                              if (_focus.hasFocus && _c.text.trim().isEmpty) {
                                _showOverlay();
                              }
                            },
                          ),
                          onTap: () {
                            _c.text = q;
                            _c.selection =
                                TextSelection.collapsed(offset: _c.text.length);
                            _hideOverlay();
                            widget.onSubmitted?.call(q);
                          },
                        );
                      },
                      separatorBuilder: (_, __) => Divider(
                        height: 1,
                        thickness: 0.5,
                        color: cs.outlineVariant.withOpacity(0.5),
                      ),
                      itemCount: items.length,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _saveRecent(String q) async {
    final query = q.trim();
    if (query.isEmpty) return;
    _recentDebounce?.cancel();
    _recentDebounce = Timer(const Duration(milliseconds: 150), () async {
      await RecentQueriesStore.instance.add(query);
      await _loadRecents();
    });
  }

  Future<void> _handleSubmit(String q) async {
    await _saveRecent(q);
    _hideOverlay();
    widget.onSubmitted?.call(q.trim());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final hasText = _c.text.trim().isNotEmpty;

    final micEnabled = widget.enabled && !_offline;

    return CompositedTransformTarget(
      link: _link,
      child: Container(
        decoration: BoxDecoration(
          color: isDark
              ? const Color(0xFF1e293b).withOpacity(0.6)
              : Colors.grey[200],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.white.withOpacity(0.08),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 8),
            // 🔍 exact emoji for search
            const Padding(
              padding: EdgeInsets.only(left: 4.0),
              child: _Emoji(emoji: '🔍', size: 18),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _c,
                focusNode: _focus,
                enabled: widget.enabled,
                textInputAction: TextInputAction.search,
                onChanged: widget.onChanged,
                onSubmitted: _handleSubmit,
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  hintStyle: TextStyle(
                    color: isDark ? const Color(0xFF64748b) : Colors.grey[600],
                    fontSize: 15,
                  ),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 0, vertical: 14),
                ),
              ),
            ),

            // Offline indicator (subtle)
            if (_offline)
              Tooltip(
                message: 'Offline',
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.cloud_off, color: cs.onSurfaceVariant),
                ),
              ),

            // Clear (when typing) or Mic (when empty) — 🎤 exact emoji
            if (hasText)
              IconButton(
                tooltip: 'Clear',
                onPressed: !widget.enabled
                    ? null
                    : () {
                        _c.clear();
                        widget.onChanged?.call('');
                        if (_focus.hasFocus) _showOverlay();
                      },
                icon: const Icon(Icons.close_rounded),
              )
            else
              IconButton(
                tooltip: micEnabled ? 'Voice' : 'Voice (offline)',
                onPressed: micEnabled ? widget.onMicTap : null,
                icon: const _Emoji(emoji: '🎤', size: 18),
              ),

            // Refresh (always shown) – keeping Material refresh icon
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: IconButton(
                tooltip: 'Refresh',
                onPressed: widget.enabled ? widget.onRefresh : null,
                icon: Icon(
                  Icons.refresh_rounded,
                  color: widget.enabled
                      ? (isDark ? const Color(0xFF94a3b8) : Colors.grey[700])
                      : cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* --------------------------- Suggestions Empty --------------------------- */

class _SuggestionsEmpty extends StatelessWidget {
  const _SuggestionsEmpty({required this.onClearAll});
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Row(
        children: [
          const _Emoji(emoji: '🔍', size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Type to search. Your recent queries will appear here.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onClearAll,
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
  }
}

/* --------------------------------- Utils -------------------------------- */

class _Emoji extends StatelessWidget {
  const _Emoji({required this.emoji, this.size = 18});
  final String emoji;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Text(
      emoji,
      // Use system emoji font; do not apply GoogleFonts or color.
      style: TextStyle(fontSize: size, height: 1),
    );
  }
}
