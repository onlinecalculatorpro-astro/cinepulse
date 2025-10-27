// lib/features/story/story_pager.dart
//
// Full-screen horizontal pager for story details.
//
// Usage (from StoryCard):
//   Navigator.push(
//     context,
//     fadeRoute(
//       StoryPagerScreen(
//         stories: allStories,
//         initialIndex: index,
//         autoplayInitial: true/false,
//       ),
//     ),
//   );
//
// Behavior:
// - PageView.builder lets you swipe left/right between stories.
// - Each page is a full StoryDetailsScreen.
// - Only the initially opened page can autoplay video;
//   swiping to another page never auto-plays.
//
// NOTE:
// StoryDetailsScreen already builds its own Scaffold+SliverAppBar,
// so we just embed it directly in each PageView page. Nesting Scaffolds
// like this is fine for this use case.

import 'package:flutter/material.dart';

import '../../core/models.dart';
import 'story_details.dart';

class StoryPagerScreen extends StatefulWidget {
  const StoryPagerScreen({
    super.key,
    required this.stories,
    required this.initialIndex,
    this.autoplayInitial = false,
  });

  /// The slice of stories we're paging through
  final List<Story> stories;

  /// Which story to show first (index into `stories`)
  final int initialIndex;

  /// If true AND we're on [initialIndex], we ask StoryDetailsScreen
  /// to autoplay its inline video player (if any).
  final bool autoplayInitial;

  @override
  State<StoryPagerScreen> createState() => _StoryPagerScreenState();
}

class _StoryPagerScreenState extends State<StoryPagerScreen> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();

    // Clamp initial index just in case
    final maxIdx = widget.stories.isEmpty ? 0 : widget.stories.length - 1;
    _currentIndex = widget.initialIndex.clamp(0, maxIdx);
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  bool _shouldAutoplayFor(int pageIndex) {
    // Only let the first-opened page autoplay.
    return widget.autoplayInitial && pageIndex == _currentIndex;
  }

  @override
  Widget build(BuildContext context) {
    // If somehow we have no stories, just pop.
    if (widget.stories.isEmpty) {
      // Using a post-frame callback avoids setState during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      // Render an empty container for this one frame.
      return const SizedBox.shrink();
    }

    return PageView.builder(
      controller: _pageController,
      physics: const PageScrollPhysics(),
      onPageChanged: (newPage) {
        setState(() {
          _currentIndex = newPage;
        });
      },
      itemCount: widget.stories.length,
      itemBuilder: (context, pageIndex) {
        final story = widget.stories[pageIndex];

        return StoryDetailsScreen(
          story: story,
          autoplay: _shouldAutoplayFor(pageIndex),
        );
      },
    );
  }
}
