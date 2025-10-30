// lib/widgets/search_bar.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show LogicalKeyboardKey, LogicalKeySet; // ESC key + keyset
import '../theme/theme_colors.dart'; // neutralPillBg, outlineHairline, primaryTextColor

/// CinePulse inline search field (Row 3 in tabs).
///
/// • Leading 🔍 icon
/// • Editable text bound to [controller]
/// • Trailing ✕ that clears or calls [onExitSearch]
/// • Focus/ink colors come from Theme.colorScheme.primary (no hard-coded colors)
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
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // Accent = brand primary; everything derives from ColorScheme.
    final accent = cs.primary;

    // Outline: accent when focused, subtle hairline otherwise.
    final Color outlineColor =
        _focusNode.hasFocus ? accent : outlineHairline(context);

    // Shared pill background for neutral surfaces.
    final Color bgColor = neutralPillBg(context);

    final Color textColor = primaryTextColor(context);
    final Color hintColor = textColor.withOpacity(isDark ? 0.6 : 0.55);

    // ESC to clear/exit.
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        LogicalKeySet(LogicalKeyboardKey.escape): const DismissIntent(),
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
                Icon(Icons.search_rounded, size: 18, color: accent),
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
                    cursorColor: accent,
                    onTapOutside: (_) => FocusScope.of(context).unfocus(),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 14,
                      height: 1.3,
                      color: textColor,
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: widget.hintText,
                      hintStyle: theme.textTheme.bodyMedium?.copyWith(
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
                        color: accent.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: accent.withOpacity(0.4), width: 1),
                        boxShadow: [
                          BoxShadow(
                            color: accent.withOpacity(0.35),
                            blurRadius: 18,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Icon(Icons.close_rounded, size: 16, color: accent),
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
