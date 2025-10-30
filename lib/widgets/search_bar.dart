// lib/widgets/search_bar.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, LogicalKeySet; // ESC key + keyset

/// CinePulse inline search field.
///
/// Used in Home / Discover / Saved / Alerts as the "Row 3" inline search bar.
///
/// Behavior
/// --------
/// - Leading 🔍 icon (static).
/// - Editable text bound to [controller].
/// - Trailing ✕ button:
///     • If [onExitSearch] is provided, tapping ✕ calls that callback
///       (tabs use this to hide the search row, clear input, and unfocus).
///     • Otherwise we just clear the text and unfocus.
/// - Border glows red when focused to match the global accent.
///
/// Visual
/// ------
/// - Frosted-ish pill look shared across the app:
///     • 8px radius
///     • subtle translucent background
///     • 1px outline (accent when focused)
/// - Height = 40px
///
/// Lifecycle
/// ---------
/// - Owns a FocusNode to:
///     • update the border color on focus
///     • close the keyboard on exit
/// - Listens to [controller] and rebuilds to keep UI in sync.
///
/// Extras
/// ------
/// - ESC closes/clears (desktop/web): if [onExitSearch] is set we call it,
///   else we just clear & unfocus.
class SearchBarInput extends StatefulWidget {
  const SearchBarInput({
    super.key,
    required this.controller,
    this.onExitSearch,
    this.hintText = 'Search…',
  });

  final TextEditingController controller;
  final VoidCallback? onExitSearch;
  final String hintText;

  @override
  State<SearchBarInput> createState() => _SearchBarInputState();
}

class _SearchBarInputState extends State<SearchBarInput> {
  static const _accent = Color(0xFFdc2626);

  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(_syncUI);
    widget.controller.addListener(_syncUI);
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
    _focusNode.dispose();
    widget.controller.removeListener(_syncUI);
    super.dispose();
  }

  void _syncUI() {
    if (mounted) setState(() {});
  }

  void _handleClearOrExit() {
    if (widget.onExitSearch != null) {
      widget.onExitSearch!.call();
    } else {
      widget.controller.clear();
    }
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Outline color = accent when focused, subtle hairline otherwise.
    final Color outlineColor = _focusNode.hasFocus
        ? _accent
        : (isDark ? Colors.white.withOpacity(0.15) : Colors.black.withOpacity(0.2));

    // Background matches the pill buttons in headers / bottom nav.
    final Color bgColor =
        isDark ? const Color(0xFF0f172a).withOpacity(0.7) : theme.colorScheme.surface.withOpacity(0.6);

    final Color textColor = isDark ? Colors.white : Colors.black87;
    final Color hintColor = isDark ? Colors.white.withOpacity(0.6) : Colors.black.withOpacity(0.5);

    // Keybindings: ESC to clear/exit (use const LogicalKeySet & const Intent in a const map).
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        LogicalKeySet(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              _handleClearOrExit();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _focusNode,
          child: AnimatedContainer(
            height: 40,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: outlineColor, width: 1),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.search_rounded,
                  size: 18,
                  color: _accent,
                ),
                const SizedBox(width: 8),

                // Editable text
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    focusNode: _focusNode,
                    textInputAction: TextInputAction.search,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLines: 1,
                    cursorColor: _accent,
                    onTapOutside: (_) => FocusScope.of(context).unfocus(),
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.3,
                      color: textColor,
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: widget.hintText,
                      hintStyle: TextStyle(
                        fontSize: 14,
                        height: 1.3,
                        color: hintColor,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 8),

                // ✕ button — always visible for quick exit.
                Tooltip(
                  message: 'Clear',
                  waitDuration: const Duration(milliseconds: 400),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: _handleClearOrExit,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: _accent.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: _accent.withOpacity(0.4), width: 1),
                        boxShadow: [
                          BoxShadow(
                            color: _accent.withOpacity(0.4),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: _accent,
                      ),
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

/// Intent used for ESC-to-dismiss behavior.
class DismissIntent extends Intent {
  const DismissIntent();
}
