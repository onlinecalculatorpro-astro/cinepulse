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

  static bool _isYouTube(Uri u) =>
      u.host.contains('youtube.com') || u.host.contains('youtu.be');

  static String? _ytIdFrom(Uri u) {
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
        _yt = YoutubePlayerController.fromVideoId(
          videoId: id,
          params: YoutubePlayerParams(
            autoPlay: widget.autoPlay,
            loop: widget.looping,
            showFullscreenButton: true,
            playsInline: true,
            enableCaption: true,
            mute: kIsWeb ? true : false, // autoplay policy on web
          ),
        );
        return;
      }

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
    } catch (e) {
      _initError = e;
    } finally {
      if (mounted) setState(() {});
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
    final uri = Uri.tryParse(widget.url);

    if (_initError != null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withOpacity(0.18),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text("Can’t play this video inside the app.\n($_initError)",
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () async {
              if (uri != null) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            child: const Text('Open Externally'),
          ),
        ]),
      );
    }

    if (_yt != null) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: YoutubePlayer(),
      );
    }

    if (_chewie != null) {
      return AspectRatio(
        aspectRatio:
            _vp!.value.aspectRatio == 0 ? 16 / 9 : _vp!.value.aspectRatio,
        child: Chewie(controller: _chewie!),
      );
    }

    return const AspectRatio(
      aspectRatio: 16 / 9,
      child: Center(child: CircularProgressIndicator()),
    );
  }
}
