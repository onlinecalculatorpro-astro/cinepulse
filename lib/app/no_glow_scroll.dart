import 'package:flutter/material.dart';

class NoGlowScroll extends MaterialScrollBehavior {
  const NoGlowScroll();
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child;
}
