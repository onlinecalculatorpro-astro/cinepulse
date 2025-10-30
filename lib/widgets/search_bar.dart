// lib/widgets/search_bar.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, LogicalKeySet;
import '../theme/theme_colors.dart'; // neutralPillBg, outlineHairline, primaryTextColor

/// CinePulse inline search field (Row 3 in tabs).
/// Layout: [ 🔍 ][  text field (expands)  ][ ✕ ]
/// - ✕ always invokes [onExitSearch] if provided (so it closes the bar).
/// - ESC also triggers the same behavior.
/// - Colors are fully theme-driven (no hard-coded tints).
class SearchBarInput extends StatefulWidget {
  const SearchBarInput({
    super.key,
    required this.controller,
    this.onExitSearch,
    this.hintText = 'Search…',
    this.autofocus = false,
  });

  final TextEditingController controller;
  final VoidCallback? onExitSearch;
  final String hintText;
  final bool autofocus;

  @override
  State<SearchBarInput> createState() => _SearchBarInputState();
}

class _SearchBarInputState extends State<SearchBarInput> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(_syncUI);
    widget.controller.addListener(_syncUI);

    if (widget.autofocus) {
      // Let the frame build before requesting focus (avoids jumps).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant SearchBarInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncUI);
      widget.controller.addListener(_syncUI);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_syncUI);
    widget.controller.removeListener(_syncUI);
    _focusNode.dispose();
    super.dispose();
  }

  void _syncUI() {
    if (mounted) setState(() {});
  }

  void _exit() {
    if (widget.onExitSearch != null) {
      widget.onExitSearch!();
    } else {
      widget.controller.clear();
    }
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final accent = cs.primary;
    final textCol = primaryTextColor(context);
    final hintCol = textCol.withOpacity(0.6);

    final outlineCol = _focusNode.hasFocus ? accent : outlineHairline(context);

    // ESC closes the search bar.
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        LogicalKeySet(LogicalKeyboardKey.escape): const _DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _DismissIntent: CallbackAction<_DismissIntent>(onInvoke: (_) {
            _exit();
            return null;
          }),
        },
        child: Focus(
          focusNode: _focusNode,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: neutralPillBg(context),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: outlineCol, width: 1),
            ),
            child: Row(
              children: [
                // 🔍
                Icon(Icons.search_rounded, size: 18, color: cs.onSurfaceVariant),
                const SizedBox(width: 8),

                // Text field (expands)
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    focusNode: _focusNode,
                    autofocus: widget.autofocus,
                    textInputAction: TextInputAction.search,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLines: 1,
                    cursorColor: accent,
                    onTapOutside: (_) => FocusScope.of(context).unfocus(),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 14,
                      height: 1.35,
                      color: textCol,
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: widget.hintText,
                      hintStyle: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 14,
                        height: 1.35,
                        color: hintCol,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 8),

                // ✕ (close)
                Tooltip(message: 'Close search', waitDuration: const Duration(milliseconds: 400), child:
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: _exit,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: neutralPillBg(context),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: outlineHairline(context), width: 1),
                      ),
                      child: Icon(Icons.close_rounded, size: 16, color: cs.onSurfaceVariant),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DismissIntent extends Intent {
  const _DismissIntent();
}
