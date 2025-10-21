// lib/widgets/smart_video_player.dart
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

/// Smart inline player:
/// - YouTube links play with youtube_player_iframe
/// - MP4/HLS (m3u8) play with video_player + Chewie
/// - Non-playable/unknown links show a helpful fallback
/// 
/// New callbacks:
/// - [onEnded]  : called when playback naturally finishes (MP4/HLS).
///                (YouTube end detection varies across embeds; we always show a Close button)
/// - [onClose]  : called when user taps Close
/// - [onError]  : called when init/playback fails (with the error object)
class SmartVideoPlayer extends StatefulWidget {
  const SmartVideoPlayer({
    super.key,
    required this.url,
    this.autoPlay = true,
    this.looping = false,
    this.onEnded,
    this.onClose,
    this.onError,
  });

  final String url;
  final bool autoPlay;
  final bool looping;

  final VoidCallback? onEnded;
  final VoidCallback? onClose;
  final ValueChanged<Object>? onError;

  @override
  State<SmartVideoPlayer> createState() => _SmartVideoPlayerState();
}

class _SmartVideoPlayerState extends State<SmartVideoPlayer> {
  YoutubePlayerController? _yt;
  StreamSubscription? _ytStateSub;

  VideoPlayerController? _vp;
  ChewieController? _chewie;
  VoidCallback? _vpListener;

  Object? _initError;

  static bool _isYouTube(Uri u) =>
      u.host.contains('youtube.com') || u.host.contains('youtu.be');

  static String? _ytIdFrom(Uri u) {
    // https://youtu.be/<ID>
    if (u.host.contains('youtu.be')) {
      return u.pathSegments.isNotEmpty ? u.pathSegments.last : null;
    }
    // https://www.youtube.com/watch?v=<ID> or /shorts/<ID> or /embed/<ID>
    if (u.host.contains('youtube.com')) {
      final v = u.queryParameters['v'];
      if (v != null && v.isNotEmpty) return v;
      if (u.pathSegments.isNotEmpty &&
          (u.pathSegments.first == 'shorts' || u.pathSegments.first == 'embed')) {
        return u.pathSegments.length >= 2 ? u.pathSegments[1] : null;
      }
    }
    return null;
  }

  Future<void> _init() async {
    try {
      final uri = Uri.parse(widget.url);

      if (_isYouTube(uri)) {
        final id = _ytIdFrom(uri);
        if (id == null) throw 'Could not extract YouTube video id';

        _yt = YoutubePlayerController.fromVideoId(
          videoId: id,
          autoPlay: widget.autoPlay,
          params: YoutubePlayerParams(
            // Muting helps autoplay on web due to browser policies
            mute: kIsWeb && widget.autoPlay,
            showFullscreenButton: true,
            playsInline: true,
            enableCaption: true,
            loop: widget.looping,
            strictRelatedVideos: false,
          ),
        );

        // Best-effort: try to detect "ended" by observing current time near duration.
        // The 5.x API doesn't expose a stable ended callback in all contexts,
        // so we keep this conservative and always show a Close button.
        _ytStateSub?.cancel();
        _ytStateSub = _yt!.videoStateStream.listen((state) {
          // Some builds expose a position/duration pair; when both present and at end, notify.
          final pos = state.position;
          final dur = state.duration;
          if (pos != null && dur != null) {
            final remaining = dur - pos;
            if (remaining.inMilliseconds.abs() <= 500 && !widget.looping) {
              widget.onEnded?.call();
            }
          }
        }, onError: (e, __) {
          widget.onError?.call(e);
        });

        if (mounted) setState(() {});
        return;
      }

      // Generic MP4/HLS (m3u8)
      _vp = VideoPlayerController.networkUrl(uri);
      await _vp!.initialize();
      _vp!.setLooping(widget.looping);

      // Detect natural end (non-looping)
      _vpListener = () {
        final v = _vp!.value;
        if (!widget.looping &&
            v.isInitialized &&
            !v.isPlaying &&
            v.position >= v.duration &&
            v.duration != Duration.zero) {
          widget.onEnded?.call();
        }
      };
      _vp!.addListener(_vpListener!);

      _chewie = ChewieController(
        videoPlayerController: _vp!,
        autoPlay: widget.autoPlay,
        looping: widget.looping,
        allowFullScreen: true,
        allowMuting: true,
        showControls: true,
      );

      if (mounted) setState(() {});
    } catch (e) {
      _initError = e;
      widget.onError?.call(e);
      if (mounted) setState(() {});
    }
  }

  Future<void> _retry() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null) return;

    _disposePlayers();

    _initError = null;
    if (mounted) setState(() {});
    await _init();
  }

  Future<void> _openExternally() async {
    final uri = Uri.tryParse(widget.url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _close() {
    widget.onClose?.call();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  @override
  void dispose() {
    _disposePlayers();
    super.dispose();
  }

  void _disposePlayers() {
    _ytStateSub?.cancel();
    _ytStateSub = null;
    _yt?.close();
    _yt = null;

    if (_vpListener != null && _vp != null) {
      _vp!.removeListener(_vpListener!);
    }
    _vpListener = null;

    _chewie?.dispose();
    _chewie = null;

    _vp?.dispose();
    _vp = null;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget actions({bool showOpen = true}) {
      return Align(
        alignment: Alignment.centerRight,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton.icon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
            if (showOpen)
              TextButton.icon(
                onPressed: _openExternally,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open externally'),
              ),
            TextButton.icon(
              onPressed: _close,
              icon: const Icon(Icons.close_rounded),
              label: const Text('Close'),
            ),
          ],
        ),
      );
    }

    if (_initError != null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withOpacity(0.18),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Can’t play this video inside the app.\n($_initError)",
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            actions(),
          ],
        ),
      );
    }

    if (_yt != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: YoutubePlayer(
              controller: _yt!,
              aspectRatio: 16 / 9,
              keepAlive: true,
            ),
          ),
          const SizedBox(height: 8),
          // Some YouTube videos block/embed or don’t reliably surface "ended" on web.
          // We always show controls including Close.
          actions(showOpen: true),
        ],
      );
    }

    if (_chewie != null && _vp != null) {
      final ar = _vp!.value.aspectRatio == 0 ? 16 / 9 : _vp!.value.aspectRatio;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: ar,
            child: Chewie(controller: _chewie!),
          ),
          const SizedBox(height: 8),
          actions(showOpen: true),
        ],
      );
    }

    // Loading
    return const AspectRatio(
      aspectRatio: 16 / 9,
      child: Center(child: CircularProgressIndicator()),
    );
  }
}
