// lib/widgets/app_toolbar.dart
//
// Reusable second-row toolbar used under page headers.
//
// Supports the four main screens:
//
// • Home / Discover → chips + Sort pill
// • Saved           → chips + Sort pill + action squares (Export, Clear)
// • Alerts          → chips + action squares (e.g., Mark all read)
//                     (simply omit sort* params and pass actions)
//
// API
// ---
// AppToolbar(
//   tabs: const ['All','Entertainment','Sports'],
//   activeIndex: _tab.index,
//   onSelect: _onTabTap,
//   chipKeys: _chipKeys,                    // optional
//   // Option A: standard Sort pill
//   sortLabel: _sortModeLabel(_sortMode),   // optional
//   sortIcon:  _iconForSort(_sortMode),
//   onSortTap: () => _showSortSheet(context),
//
//   // Option B: extra actions rendered to the right of Sort (or alone)
//   actions: [
//     AppToolbarAction(icon: Icons.ios_share,      tooltip: 'Export',     onTap: _export),
//     AppToolbarAction(icon: Icons.delete_outline, tooltip: 'Clear all',  onTap: _clearAll),
//   ],
//
//   // Option C: provide your own trailing widget and take full control
//   // trailing: MyCustomTrailing(...),
// )
//
// Visuals are theme-driven (surface/onSurface) and safe in light/dark.

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

    // Trailing content
    this.trailing,                 // if provided, overrides sort/actions rendering
    this.sortLabel,                // if non-null + onSortTap non-null → show Sort pill
    this.sortIcon,
    this.onSortTap,
    this.actions,                  // optional list of square action buttons
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
      if (sortLabel == null || onSortTap == null) return const SizedBox.shrink();
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
      // Full override (alerts can pass a single custom pill, etc.)
      if (trailing != null) return trailing!;

      // Compose: [Sort pill?] [actions...]
      final List<Widget> right = [];
      final sort = buildSortPill();
      if (sort is! SizedBox) right.add(sort);

      if (actions != null && actions!.isNotEmpty) {
        if (right.isNotEmpty) right.add(const SizedBox(width: 8));
        right.addAll(actions!.map(buildSquareAction));
      }

      if (right.isEmpty) return const SizedBox.shrink();
      return Wrap(spacing: 8, runSpacing: 8, children: right);
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

          // RIGHT: sort / actions / custom trailing
          buildTrailing(),
        ],
      ),
    );
  }
}
