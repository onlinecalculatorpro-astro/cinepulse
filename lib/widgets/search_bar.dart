import 'package:flutter/material.dart';

/// Reusable CinePulse search bar.
/// Used on Home (Search mode), and can be reused anywhere else that wants
/// the same "inline search field" look.
///
/// Behavior:
/// - Leading magnifying glass icon.
/// - Text field that updates the provided [controller].
/// - Trailing "X" button:
///    • If [onExitSearch] is provided, tapping the X calls that callback
///      (Home uses this to exit Search mode + clear text + unfocus).
///    • Otherwise, tapping the X just clears the text.
/// - Border goes red when focused to match the app accent.
///
/// Styling:
/// - Dark translucent background in dark mode, light translucent bg in light.
/// - 8px radius to match the rest of the UI (header pills, nav buttons).
///
class SearchBarInput extends StatefulWidget {
  const SearchBarInput({
    super.key,
    required this.controller,
    this.onExitSearch,
    this.hintText = 'Search…',
  });

  /// The text editing controller owned by the parent.
  final TextEditingController controller;

  /// Optional "close search mode" handler.
  /// If this is non-null, the trailing X will call this instead of just
  /// clearing the field.
  final VoidCallback? onExitSearch;

  /// Placeholder / hint.
  final String hintText;

  @override
  State<SearchBarInput> createState() => _SearchBarInputState();
}

class _SearchBarInputState extends State<SearchBarInput> {
  // Accent color we consistently use across the app.
  static const _accent = Color(0xFFdc2626);

  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _focus = FocusNode();
    _focus.addListener(_handleInternalChange);
    widget.controller.addListener(_handleInternalChange);
  }

  @override
  void didUpdateWidget(covariant SearchBarInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleInternalChange);
      widget.controller.addListener(_handleInternalChange);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_handleInternalChange);
    _focus.dispose();
    widget.controller.removeListener(_handleInternalChange);
    super.dispose();
  }

  void _handleInternalChange() {
    if (mounted) {
      setState(() {});
    }
  }

  void _handleClearOrExit() {
    if (widget.onExitSearch != null) {
      // Parent (ex: Home) decides how to exit search mode.
      widget.onExitSearch!.call();
    } else {
      // Default fallback: just clear the text.
      widget.controller.clear();
    }
    // Also hide keyboard.
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // When focused, border turns accent red.
    // Otherwise it's a subtle hairline.
    final Color borderColor = _focus.hasFocus
        ? _accent
        : (isDark
            ? Colors.white.withOpacity(0.15)
            : Colors.black.withOpacity(0.2));

    // Slight translucent bg, similar vibe to header pills / bottom nav bg.
    final Color bgColor = isDark
        ? const Color(0xFF0f172a).withOpacity(0.7)
        : theme.colorScheme.surface.withOpacity(0.6);

    final textColor = isDark ? Colors.white : Colors.black87;
    final hintColor = isDark
        ? Colors.white.withOpacity(0.6)
        : Colors.black.withOpacity(0.5);

    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: borderColor,
          width: 1,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(
            Icons.search_rounded,
            size: 18,
            color: _accent,
          ),
          const SizedBox(width: 8),

          // Text field grows
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              textInputAction: TextInputAction.search,
              style: TextStyle(
                fontSize: 14,
                height: 1.3,
                color: textColor,
                fontWeight: FontWeight.w500,
              ),
              cursorColor: _accent,
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

          // Trailing "X" button. We ALWAYS show it in this design
          // (so user can quickly back out of Search mode on Home),
          // but we could hide it if you want:
          // if (!widget.controller.text.isNotEmpty && !_focus.hasFocus) -> SizedBox.shrink()
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
