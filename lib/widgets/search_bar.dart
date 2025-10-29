import 'package:flutter/material.dart';

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
/// - We own a FocusNode so we can:
///     • update the border color on focus
///     • close the keyboard on exit
/// - We listen to [controller] and rebuild so we can react to text changes
///   if you ever want to hide ✕ when empty. (Right now ✕ always shows.)
class SearchBarInput extends StatefulWidget {
  const SearchBarInput({
    super.key,
    required this.controller,
    this.onExitSearch,
    this.hintText = 'Search…',
  });

  /// Parent-owned text controller.
  final TextEditingController controller;

  /// Optional "close search mode" handler.
  ///
  /// If non-null, tapping ✕ will call this instead of just clearing [controller].
  /// Each tab uses this to both hide the row and clear the text.
  final VoidCallback? onExitSearch;

  /// Placeholder string.
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

    // If the parent swapped controllers, detach from the old one and attach to the new one.
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
    if (mounted) {
      setState(() {});
    }
  }

  void _handleClearOrExit() {
    if (widget.onExitSearch != null) {
      // Tab-level handler: hide search row and reset state.
      widget.onExitSearch!.call();
    } else {
      // Default fallback: just clear.
      widget.controller.clear();
    }

    // Always drop keyboard focus.
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Outline color = accent when focused, subtle hairline otherwise.
    final Color outlineColor = _focusNode.hasFocus
        ? _accent
        : (isDark
            ? Colors.white.withOpacity(0.15)
            : Colors.black.withOpacity(0.2));

    // Background matches the pill buttons in headers / bottom nav.
    final Color bgColor = isDark
        ? const Color(0xFF0f172a).withOpacity(0.7)
        : theme.colorScheme.surface.withOpacity(0.6);

    final Color textColor = isDark ? Colors.white : Colors.black87;
    final Color hintColor = isDark
        ? Colors.white.withOpacity(0.6)
        : Colors.black.withOpacity(0.5);

    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: outlineColor, width: 1),
      ),
      child: Row(
        children: [
          Icon(
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
              cursorColor: _accent,
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

          // ✕ button.
          // We always render it so you can instantly bail out of search mode.
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: _handleClearOrExit,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: _accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _accent.withOpacity(0.4),
                  width: 1,
                ),
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
        ],
      ),
    );
  }
}
