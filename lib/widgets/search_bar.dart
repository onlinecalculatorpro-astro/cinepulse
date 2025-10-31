// lib/widgets/search_bar.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, LogicalKeySet;
import '../theme/theme_colors.dart'; // neutralPillBg, outlineHairline, primaryTextColor

// Tweaks: slimmer bar but still cross-platform safe
const double _kSearchBarHeight = 44; // was 48
const double _kIconSize = 18;        // was 20
const double _kCornerRadius = 8;

/// Inline search field used in Row 3 of tabs.
/// Layout: [ 🔍 ][ expanding text field ][ ✕ ]
class SearchBarInput extends StatefulWidget {
  const SearchBarInput({
    super.key,
    required this.controller,
    this.onExitSearch,
    this.hintText = 'Search…',
    this.autofocus = false,
  });

  final TextEditingController controller;
  /// If provided, called when user clicks ✕ or presses ESC (so the row can close).
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
    _focusNode = FocusNode()..addListener(_refresh);
    widget.controller.addListener(_refresh);

    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant SearchBarInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_refresh);
    widget.controller.removeListener(_refresh);
    _focusNode.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _exit() {
    if (widget.onExitSearch != null) {
      widget.onExitSearch!();        // lets parent close the row
    } else {
      widget.controller.clear();     // fallback: just clear
    }
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final textCol   = primaryTextColor(context);
    final hintCol   = textCol.withOpacity(0.60);
    final outline   = _focusNode.hasFocus ? cs.primary : outlineHairline(context);

    // ESC closes the bar
    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.escape): const _DismissIntent(),
      },
      child: Actions(
        actions: {
          _DismissIntent: CallbackAction<_DismissIntent>(onInvoke: (_) {
            _exit();
            return null;
          }),
        },
        child: Material(
          type: MaterialType.transparency,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            height: _kSearchBarHeight,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: neutralPillBg(context),
              borderRadius: BorderRadius.circular(_kCornerRadius),
              border: Border.all(color: outline, width: 1),
            ),
            child: Row(
              children: [
                // 🔍 left
                Icon(Icons.search_rounded, size: _kIconSize, color: cs.primary),
                const SizedBox(width: 8),

                // expanding text field
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    focusNode: _focusNode,
                    autofocus: widget.autofocus,
                    textInputAction: TextInputAction.search,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLines: 1,
                    cursorColor: cs.primary,
                    textAlignVertical: TextAlignVertical.center,
                    // lock line metrics to avoid clipping at this thinner height
                    strutStyle: const StrutStyle(height: 1.35, forceStrutHeight: true),
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
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),

                const SizedBox(width: 8),

                // ✕ right — compact IconButton for better a11y & focus
                Tooltip(
                  message: 'Close search',
                  waitDuration: const Duration(milliseconds: 400),
                  child: IconButton(
                    onPressed: _exit,
                    splashRadius: 18,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                    icon: Icon(Icons.close_rounded, size: 18, color: cs.primary),
                    style: ButtonStyle(
                      backgroundColor: WidgetStatePropertyAll(cs.primary.withOpacity(0.12)),
                      shape: WidgetStatePropertyAll(
                        RoundedRectangleBorder(borderRadius: BorderRadius.circular(_kCornerRadius)),
                      ),
                      side: WidgetStatePropertyAll(
                        BorderSide(color: cs.primary.withOpacity(0.40), width: 1),
                      ),
                      elevation: const WidgetStatePropertyAll(0),
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
