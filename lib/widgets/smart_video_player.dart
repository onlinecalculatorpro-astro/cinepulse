// lib/widgets/smart_video_player.dart
import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

class SmartVideoPlayer extends StatefulWidget {
  const SmartVideoPlayer({
    super.key,
    required this.url,
    this.autoPlay = true,
    this.looping = false,
  });

  final String url;
  final bool autoPlay;
  final bool looping;

  @override
  State<SmartVideoPlayer> createState() => _SmartVideoPlayerState();
}

class _SmartVideoPlayerState extends State<SmartVideoPlayer> {
  YoutubePlayerController? _yt;
  VideoPlayerController? _vp;
  ChewieController? _chewie;
  Object? _initError;

  String? _ytId;

  static bool _isYouTube(Uri u) =>
      u.host.contains('youtube.com') || u.host.contains('youtu.be');

  static String? _ytIdFrom(Uri u) {
    // https://youtu.be/ID or https://www.youtube.com/watch?v=ID
    if (u.host.contains('youtu.be')) {
      return u.pathSegments.isNotEmpty ? u.pathSegments.last : null;
    }
    if (u.host.contains('youtube.com')) {
      final v = u.queryParameters['v'];
      if (v != null && v.isNotEmpty) return v;
      if (u.pathSegments.contains('shorts') || u.pathSegments.contains('embed')) {
        return u.pathSegments.isNotEmpty ? u.pathSegments.last : null;
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
        _ytId = id;

        _yt = YoutubePlayerController.fromVideoId(
          videoId: id,
          autoPlay: widget.autoPlay,
          params: YoutubePlayerParams(
            mute: kIsWeb && widget.autoPlay, // helps autoplay on web
            showFullscreenButton: true,
            playsInline: true,
            enableCaption: true,
            loop: widget.looping,
            strictRelatedVideos: false,
          ),
        );
        setState(() {});
        return;
      }

      // Generic MP4/HLS (m3u8)
      _vp = VideoPlayerController.networkUrl(uri);
      await _vp!.initialize();
      _vp!.setLooping(widget.looping);
      _chewie = ChewieController(
        videoPlayerController: _vp!,
        autoPlay: widget.autoPlay,
        looping: widget.looping,
        allowFullScreen: true,
        allowMuting: true,
        showControls: true,
      );
      setState(() {});
    } catch (e) {
      _initError = e;
      if (mounted) setState(() {});
    }
  }

  Future<void> _retry() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null) return;

    // Dispose old controllers
    _chewie?.dispose();
    _vp?.dispose();
    _yt?.close();
    _chewie = null;
    _vp = null;
    _yt = null;
    _initError = null;
    setState(() {});

    // Re-init
    await _init();
  }

  Future<void> _openExternally() async {
    final uri = Uri.tryParse(widget.url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _vp?.dispose();
    _yt?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget _actions({bool showOpen = true}) {
      return Align(
        alignment: Alignment.centerRight,
        child: Wrap(
          spacing: 8,
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
                label: const Text('Open Externally'),
              ),
          ],
        ),
      );
    }

    if (_initError != null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withOpacity(0.18),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Can’t play this video inside the app.\n($_initError)",
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            _actions(),
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
          // Show actions always for YouTube: some videos block embedding intermittently.
          _actions(showOpen: true),
        ],
      );
    }

    if (_chewie != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio:
                _vp!.value.aspectRatio == 0 ? 16 / 9 : _vp!.value.aspectRatio,
            child: Chewie(controller: _chewie!),
          ),
          const SizedBox(height: 8),
          _actions(showOpen: true),
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
