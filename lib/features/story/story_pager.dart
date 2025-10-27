// lib/features/story/story_pager.dart
//
// StoryDetailsPager
// -----------------
// This wraps the existing StoryDetailsScreen in a horizontal PageView,
// so the user can swipe left/right to see previous / next stories
// without going back to the grid.
//
// How it's meant to be used from StoryCard:
//
//   Navigator.of(context).push(
//     fadeRoute(
//       StoryDetailsPager(
//         stories: feedStories,        // the visible list in the grid
//         initialIndex: storyIndex,    // the tapped card's index in that list
//         autoplayInitial: autoplay,   // true if we should auto-play video on the first page
//       ),
//     ),
//   );
//
// Behavior:
// - We show each story using the existing StoryDetailsScreen.
// - Only the initially opened page gets `autoplayInitial == true`.
//   All other pages get autoplay = false so we don't auto-play
//   when you swipe.
// - Back button inside StoryDetailsScreen still just pops the route,
//   which will close the pager and drop you back to the grid.
//

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/utils.dart'; // (for fadeRoute type hints etc., not strictly required here)
import 'story_details.dart';

class StoryDetailsPager extends StatefulWidget {
  const StoryDetailsPager({
    super.key,
    required this.stories,
    required this.initialIndex,
    this.autoplayInitial = false,
  });

  /// Ordered list of stories from the feed / grid that the user was looking at.
  final List<Story> stories;

  /// Index in [stories] that was originally tapped.
  final int initialIndex;

  /// Whether we should autoplay inline video for the initially opened story.
  /// (Subsequent pages will not autoplay on swipe.)
  final bool autoplayInitial;

  @override
  State<StoryDetailsPager> createState() => _StoryDetailsPagerState();
}

class _StoryDetailsPagerState extends State<StoryDetailsPager> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();

    // Clamp the initial index just in case we're handed something out of range.
    final safeIndex = widget.initialIndex.clamp(0, widget.stories.length - 1);
    _currentIndex = safeIndex;
    _pageController = PageController(initialPage: safeIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // If we somehow have no stories at all, fall back to an empty scaffold.
    if (widget.stories.isEmpty) {
      return const Scaffold(
        body: Center(child: Text('No story')),
      );
    }

    return PageView.builder(
      controller: _pageController,
      onPageChanged: (i) {
        setState(() {
          _currentIndex = i;
        });
      },
      itemCount: widget.stories.length,
      itemBuilder: (context, index) {
        final story = widget.stories[index];

        // We ONLY autoplay for the initially opened story,
        // and ONLY on that first build of that page.
        final shouldAutoplay =
            (index == widget.initialIndex) && widget.autoplayInitial;

        return StoryDetailsScreen(
          key: ValueKey('details-${story.id}-$index'),
          story: story,
          autoplay: shouldAutoplay,
        );
      },
    );
  }
}
