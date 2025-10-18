// lib/app/no_glow_scroll.dart
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

/// Global scroll behavior that:
/// - removes the overscroll glow
/// - allows drag scrolling with mouse/stylus (web/desktop)
class NoGlowScroll extends MaterialScrollBehavior {
  const NoGlowScroll();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    // No glow / stretch indicators.
    return child;
  }

  /// Allow mouse/stylus drag to scroll on web/desktop in addition to touch.
  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
      };
}
