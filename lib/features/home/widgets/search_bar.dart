// lib/features/home/widgets/search_bar.dart
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../../../core/cache.dart';

class SearchBarInput extends StatefulWidget {
  const SearchBarInput({super.key, this.controller});
  final TextEditingController? controller;

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
    _c.addListener(_onChanged);

    _loadRecents();

    // Connectivity (robust to plugin API differences)
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
    _c.removeListener(_onChanged);
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
      // suggestions are optional; ignore errors
    }
  }

  void _onChanged() {
    // Show recents when empty & focused; hide when typing
    if (_c.text.trim().isEmpty && _focus.hasFocus) {
      _showOverlay();
    } else {
      _hideOverlay();
    }
    // Home screen listens to the controller for filtering; no extra calls here.
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
              width: MediaQuery.of(context).size.width, // expand; container clamps
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
                              // Recreate overlay to reflect the list smoothly
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

  Future<void> _onSubmitted(String q) async {
    final query = q.trim();
    if (query.isEmpty) return;
    // Save to recents (debounced to avoid rapid dupes)
    _recentDebounce?.cancel();
    _recentDebounce = Timer(const Duration(milliseconds: 150), () async {
      await RecentQueriesStore.instance.add(query);
      await _loadRecents();
    });
    _hideOverlay();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasText = _c.text.trim().isNotEmpty;

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
            const Padding(
              padding: EdgeInsets.only(left: 4.0),
              child: Icon(Icons.search_rounded),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _c,
                focusNode: _focus,
                textInputAction: TextInputAction.search,
                onSubmitted: _onSubmitted,
                decoration: const InputDecoration(
                  hintText: 'Search movies, shows, trailers…',
                  border: InputBorder.none,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 0, vertical: 14),
                ),
              ),
            ),
            if (_offline)
              Tooltip(
                message: 'Offline',
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child:
                      Icon(Icons.cloud_off, color: scheme.onSurfaceVariant),
                ),
              ),
            if (hasText)
              IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close_rounded),
                onPressed: () {
                  _c.clear();
                  if (_focus.hasFocus) {
                    _showOverlay(); // show recents again
                  }
                },
              )
            else
              IconButton(
                tooltip: 'Voice (coming soon)',
                onPressed: () {},
                icon: const Icon(Icons.mic_rounded),
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
          Icon(Icons.search_rounded, color: cs.onSurfaceVariant),
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
