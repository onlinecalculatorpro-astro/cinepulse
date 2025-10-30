// lib/widgets/app_toolbar.dart
//
// Reusable second-row toolbar used under page headers.
//
// Left  : horizontally scrollable category chips
// Right : Sort pill (optional) + compact square actions (optional)
// Notes : The trailing area is a single Row so actions stay on the SAME line.
//
// API
// ---
// AppToolbar(
//   tabs: const ['All','Entertainment','Sports'],
//   activeIndex: _tab.index,
//   onSelect: _onTabTap,
//   chipKeys: _chipKeys,                    // optional
//   sortLabel: _sortModeLabel(_sortMode),   // optional (omit to hide)
//   sortIcon:  _iconForSort(_sortMode),
//   onSortTap: () => _showSortSheet(context),
//   actions: const [
//     AppToolbarAction(icon: Icons.ios_share,      tooltip: 'Export',    onTap: ...),
//     AppToolbarAction(icon: Icons.delete_outline, tooltip: 'Clear all', onTap: ...),
//   ],
//   // OR take full control of the right side with `trailing:`
// )

import 'package:flutter/material.dart';
import '../theme/toolbar.dart' show ToolbarChip, toolbarSortPill;
import '../theme/theme_colors.dart' show outlineHairline, neutralPillBg;

/// Declarative config for square action buttons on the right side.
class AppToolbarAction {
  const AppToolbarAction({
    required this.icon,
    required this.tooltip,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
}

class AppToolbar extends StatelessWidget {
  const AppToolbar({
    super.key,
    required this.tabs,
    required this.activeIndex,
    required this.onSelect,
    this.chipKeys,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    this.showBottomBorder = true,

    // Trailing controls (right side)
    this.trailing,                 // full override of the trailing area
    this.sortLabel,                // shown only if both label and onSortTap provided
    this.sortIcon,
    this.onSortTap,
    this.actions,                  // zero or more compact square actions
  });

  /// Labels for the chip row, e.g. ["All","Entertainment","Sports"].
  final List<String> tabs;

  /// The currently-selected chip index.
  final int activeIndex;

  /// Called when a chip is tapped with the chip index.
  final ValueChanged<int> onSelect;

  /// Optional keys (same length as [tabs]) so callers can ensure-visible.
  final List<GlobalKey>? chipKeys;

  /// Container padding.
  final EdgeInsetsGeometry padding;

  /// Adds a 1px bottom hairline if true.
  final bool showBottomBorder;

  // ---- Trailing controls ----
  final Widget? trailing;
  final String? sortLabel;
  final IconData? sortIcon;
  final VoidCallback? onSortTap;
  final List<AppToolbarAction>? actions;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget buildSortPill() {
      if (sortLabel == null || onSortTap == null) {
        return const SizedBox.shrink();
      }
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onSortTap,
        child: toolbarSortPill(
          context: context,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (sortIcon != null)
                Icon(sortIcon, size: 16, color: cs.onSurface),
              if (sortIcon != null) const SizedBox(width: 6),
              Flexible(
                child: Text(
                  sortLabel!,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.2,
                    fontWeight: FontWeight.w500,
                    color: cs.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.arrow_drop_down_rounded, size: 18, color: cs.onSurface),
            ],
          ),
        ),
      );
    }

    Widget buildSquareAction(AppToolbarAction a) {
      return Tooltip(
        message: a.tooltip,
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: a.onTap,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: neutralPillBg(context),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: outlineHairline(context), width: 1),
            ),
            child: Icon(a.icon, size: 16, color: cs.onSurface),
          ),
        ),
      );
    }

    Widget buildTrailing() {
      if (trailing != null) return trailing!;

      final List<Widget> right = [];
      final sort = buildSortPill();
      if (sort is! SizedBox) {
        right.add(sort);
      }

      final acts = actions ?? const <AppToolbarAction>[];
      if (acts.isNotEmpty) {
        if (right.isNotEmpty) right.add(const SizedBox(width: 8));
        for (int i = 0; i < acts.length; i++) {
          if (i > 0) right.add(const SizedBox(width: 8));
          right.add(buildSquareAction(acts[i]));
        }
      }

      if (right.isEmpty) return const SizedBox.shrink();

      // Single-line cluster pinned to the right
      return Row(mainAxisSize: MainAxisSize.min, children: right);
    }

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        border: showBottomBorder
            ? Border(bottom: BorderSide(width: 1, color: outlineHairline(context)))
            : null,
      ),
      padding: padding,
      child: Row(
        children: [
          // LEFT: scrollable chips (take remaining space)
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: List.generate(tabs.length, (i) {
                  final key = (chipKeys != null && i < chipKeys!.length)
                      ? chipKeys![i]
                      : null;
                  return Row(
                    key: ValueKey('toolbar-chip-wrap-$i'),
                    children: [
                      ToolbarChip(
                        key: key,
                        label: tabs[i],
                        active: i == activeIndex,
                        onTap: () => onSelect(i),
                      ),
                      if (i != tabs.length - 1) const SizedBox(width: 8),
                    ],
                  );
                }),
              ),
            ),
          ),

          const SizedBox(width: 12),

          // RIGHT: sort + actions
          buildTrailing(),
        ],
      ),
    );
  }
}
