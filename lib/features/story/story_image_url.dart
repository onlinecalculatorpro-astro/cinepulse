// lib/features/story/story_image_url.dart
//
// Shared logic to choose a safe hero image URL for a Story.
// - prefer posterUrl, fallback to thumbUrl
// - drop obvious junk (demo.tagdiv.com etc.)
// - avoid /v1/img proxy URLs on web (CORS / broken thumbs)
// - if the URL is relative, prefix API_BASE_URL from --dart-define
//
// Usage:
//   final imgUrl = resolveStoryImageUrl(story);
//   if (imgUrl.isNotEmpty) ... CachedNetworkImage(imageUrl: imgUrl, ...);

import '../../core/models.dart';

// This reads the value you pass in CI with
//   --dart-define=API_BASE_URL=https://api.whatever.com
// IMPORTANT: no trailing slash in that secret (your workflow already trims it)
const String _API_BASE = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: '',
);

String resolveStoryImageUrl(Story story) {
  // 1. pick candidate from story
  final cand = (story.posterUrl?.isNotEmpty == true)
      ? story.posterUrl!
      : (story.thumbUrl ?? '');

  if (cand.isEmpty) return '';

  // 2. reject obvious garbage domains
  if (cand.contains('demo.tagdiv.com')) return '';

  final uri = Uri.tryParse(cand);
  if (uri == null) return '';

  // Inner candidate if this was some proxy like /v1/img?u=<real-url>
  final innerParam =
      uri.queryParameters['u'] ?? uri.queryParameters['url'] ?? '';

  // If that innerParam points to demo.tagdiv.com, nuke it too
  if (innerParam.contains('demo.tagdiv.com')) {
    return '';
  }

  final pathLower = uri.path.toLowerCase();

  // 3. We generally do NOT want to use `/v1/img?...` thumbnails in web,
  //    because they'll 404/CORS on Netlify. Try to fall back to the inner real URL.
  if (pathLower.contains('/v1/img')) {
    final innerUri = Uri.tryParse(innerParam);
    if (innerUri != null &&
        innerUri.hasScheme &&
        (innerUri.scheme == 'http' || innerUri.scheme == 'https')) {
      return innerParam;
    }
    // couldn't salvage -> give up
    return '';
  }

  // 4. If it's already absolute http/https, just use it as-is.
  if (uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https')) {
    return cand;
  }

  // 5. Otherwise it's probably a relative path like "/images/foo.jpg".
  //    Prefix API_BASE_URL (which your GitHub Action passes via --dart-define).
  if (_API_BASE.isNotEmpty) {
    if (cand.startsWith('/')) {
      return '$_API_BASE$cand';
    } else {
      return '$_API_BASE/$cand';
    }
  }

  // 6. Last resort: return whatever we had.
  return cand;
}
