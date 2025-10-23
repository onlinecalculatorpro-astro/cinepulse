// lib/core/realtime.dart
import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;

class RealtimeClient {
  RealtimeClient(this.baseUrl);
  final String baseUrl;

  WebSocketChannel? _ws;
  StreamController<void>? _events;
  Timer? _sseTimer;
  bool _started = false;

  Stream<void> get onEvent {
    _events ??= StreamController<void>.broadcast();
    return _events!.stream;
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    // Try WS first
    try {
      final wsUrl = baseUrl.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://');
      _ws = WebSocketChannel.connect(Uri.parse('$wsUrl/v1/realtime/ws'));
      _ws!.stream.listen((msg) {
        // server already sends JSON strings; we only need a “something happened” signal
        _events?.add(null);
      }, onError: (_) {
        _fallbackToSse();
      }, onDone: _fallbackToSse);
    } catch (_) {
      _fallbackToSse();
    }
  }

  void _fallbackToSse() {
    _ws = null;
    _sseTimer?.cancel();
    // very light SSE poller using text/event-stream
    _sseTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      try {
        final req = await http.Client()
            .send(http.Request('GET', Uri.parse('$baseUrl/v1/realtime/stream'))
              ..headers['Accept'] = 'text/event-stream');
        // fire once on connect
        _events?.add(null);
        // we don’t keep the connection around in this minimal fallback
        req.stream.drain();
      } catch (_) {/* ignore */}
    });
  }

  Future<void> stop() async {
    _sseTimer?.cancel();
    _sseTimer = null;
    try { await _ws?.sink.close(); } catch (_) {}
    _ws = null;
    await _events?.close();
  }
}
