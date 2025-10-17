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
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  List<String> _recents = const [];
  Timer? _recentDebounce;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    _c.addListener(_onChanged);

    _loadRecents();

    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNetwork = results.any((r) => r != ConnectivityResult.none);
      if (mounted) setState(() => _offline = !hasNetwork);
    });
    () async {
      final results = await Connectivity().checkConnectivity();
      final hasNetwork = results.any((r) => r != ConnectivityResult.none);
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

  Future<void> _loadRecents() async {
    try {
      final list = await RecentQueriesStore.instance.list();
      if (mounted) setState(() => _recents = list);
    } catch (_) {
      // ignore silently; suggestions are optional
    }
  }

  void _onChanged() {
    // Hide suggestions when typing; show when empty & focused.
    if (_c.text.trim().isEmpty && _focus.hasFocus) {
      _showOverlay();
    } else {
      _hideOverlay();
    }
    // No network calls here: HomeScreen already listens & debounces the controller.
  }

  void _onFocus() {
    if (_focus.hasFocus && _c.text.trim().isEmpty) {
      _showOverlay();
    } else {
      _hideOverlay();
    }
  }

  void _showOverlay() {
    _overlay ??= _buildOverlay();
    Overlay.of(context, debugRequiredFor: widget)?.insert(_overlay!);
  }

  void _hideOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  OverlayEntry _buildOverlay() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // Cap the list to ~8 items for sanity
    final items = _recents.take(8).toList(growable: false);

    return OverlayEntry(
      builder: (context) => Positioned.fill(
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          offset: const Offset(0, 52), // just below the field
          child: Align(
            alignment: Alignment.topCenter,
            child: FractionallySizedBox(
              widthFactor: 1.0,
              child: Material(
                elevation: 6,
                color: cs.surface,
                surfaceTintColor: cs.surfaceTint,
                borderRadius: BorderRadius.circular(14),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
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
                              title: Text(q, maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing: IconButton(
                                tooltip: 'Remove',
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () async {
                                  await RecentQueriesStore.instance.remove(q);
                                  await _loadRecents();
                                  // Rebuild overlay smoothly
                                  _hideOverlay();
                                  if (_focus.hasFocus && _c.text.trim().isEmpty) {
                                    _showOverlay();
                                  }
                                },
                              ),
                              onTap: () {
                                _c.text = q;
                                _c.selection = TextSelection.collapsed(offset: _c.text.length);
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
    // HomeScreen is already listening to controller changes; nothing else to do.
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final hasText = _c.text.trim().isNotEmpty;

    return CompositedTransformTarget(
      link: _link,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface.withOpacity(0.92),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: scheme.primary.withOpacity(0.08),
              blurRadius: 12,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Row(
          children: [
            const SizedBox(width: 8),
            const Padding(
              padding: EdgeInsets.only(left: 4.0),
              child: Icon(Icons.search),
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
                  contentPadding: EdgeInsets.symmetric(horizontal: 0, vertical: 14),
                ),
              ),
            ),
            if (_offline)
              Tooltip(
                message: 'Offline',
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.cloud_off, color: scheme.onSurfaceVariant),
                ),
              ),
            if (hasText)
              IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close_rounded),
                onPressed: () {
                  _c.clear();
                  _showOverlay(); // show recents again
                },
              )
            else
              IconButton(
                tooltip: 'Voice (coming soon)',
                onPressed: () {},
                icon: const Icon(Icons.mic_none_rounded),
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
          Icon(Icons.search, color: cs.onSurfaceVariant),
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
