import 'package:flutter/material.dart';

class SearchBarInput extends StatelessWidget {
  const SearchBarInput({super.key, this.controller});
  final TextEditingController? controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface.withOpacity(0.85),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withOpacity(0.08),
            blurRadius: 12,
            spreadRadius: 2,
          )
        ],
      ),
      child: TextField(
        controller: controller,
        textInputAction: TextInputAction.search,
        decoration: const InputDecoration(
          hintText: 'Search movies, shows, trailers…',
          prefixIcon: Icon(Icons.search),
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),
    );
  }
}
