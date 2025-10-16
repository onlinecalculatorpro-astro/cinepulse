import 'package:flutter/material.dart';

PageRouteBuilder<T> fadeRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: animation.drive(CurveTween(curve: Curves.easeInOut)),
        child: child,
      );
    },
  );
}
