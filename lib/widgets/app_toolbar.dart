// lib/widgets/app_toolbar.dart
//
// Reusable second-row toolbar used under page headers.
// Provides:
//  • A horizontally scrollable chip row (via ToolbarChip from theme/toolbar.dart)
//  • An optional trailing area (e.g., Sort pill) with correct dark/light contrast.
//
// Use it across Home / Saved / Alerts / Discover by supplying the tabs,
// which tab is active, and either a trailing widget OR (sortLabel, sortIcon, onSortTap).
//
// Example (Home):
// AppToolbar(
//   tabs: const ['All','Entertainment','Sports'],
//   activeIndex: _tab.index,
//   onSelect: _onTabTap,
//   chipKeys: _chipKeys,
//   sortLabel: _sortModeLabel(_sortMode),
//   sortIcon: _iconForSort(_sortMode),
//   onSortTap: () => _showSortSheet(context),
// );

import 'package:flutter/material.dart';
import '../theme/toolbar.dart';         // ToolbarChip, toolbarSortPill
import '../theme/theme_colors.dart';   // outlineHairline

class AppToolbar extends StatelessWidget {
  const AppToolbar({
    super.key,
    required this.tabs,
    required this.activeIndex,
    required this.onSelect,
    this.chipKeys,
    this.trailing,
    this.sortLabel,
    this.sortIcon,
    this.onSortTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    this.showBottomBorder = true,
  });

  /// Labels for the chip row, e.g. ["All","Entertainment","Sports"].
  final List<String> tabs;

  /// The currently-selected chip index.
  final int activeIndex;

  /// Called when a chip is tapped with the chip index.
  final ValueChanged<int> onSelect;

  /// Optional keys (same length as [tabs]) so callers can ensure-visible.
  final List<GlobalKey>? chipKeys;

  /// Optional custom trailing widget (e.g., action buttons).
  /// If provided, it overrides [sortLabel]/[sortIcon]/[onSortTap].
  final Widget? trailing;

  /// Optional standard trailing "Sort" pill bits.
  final String? sortLabel;
  final IconData? sortIcon;
  final VoidCallback? onSortTap;

  /// Container padding.
  final EdgeInsetsGeometry padding;

  /// Adds a 1px bottom hairline if true.
  final bool showBottomBorder;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget buildTrailing() {
      if (trailing != null) return trailing!;
      if (sortLabel != null && onSortTap != null) {
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
      return const SizedBox.shrink();
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // LEFT: scrollable chip row
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: List.generate(tabs.length, (i) {
                  final key = (chipKeys != null && i < chipKeys!.length) ? chipKeys![i] : null;
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
          // RIGHT: trailing (sort or custom)
          buildTrailing(),
        ],
      ),
    );
  }
}
