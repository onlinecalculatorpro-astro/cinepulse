// lib/core/fcm_bootstrap.dart
import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const _channelId   = 'cinepulse_general';
const _channelName = 'CinePulse';
const _channelDesc = 'General updates';

final FlutterLocalNotificationsPlugin _fln = FlutterLocalNotificationsPlugin();

bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

int _nextId() => DateTime.now().millisecondsSinceEpoch.remainder(1 << 31);

Future<void> _ensureFirebase() async {
  if (!_isAndroid) return;
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp();
  }
}

Future<void> _ensureChannel() async {
  if (!_isAndroid) return;
  const ch = AndroidNotificationChannel(
    _channelId,
    _channelName,
    description: _channelDesc,
    importance: Importance.high,
  );
  await _fln
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(ch);
}

NotificationDetails _headsUpDetails() => const NotificationDetails(
  android: AndroidNotificationDetails(
    _channelId,
    _channelName,
    importance: Importance.high,
    priority: Priority.high,
    // icon: '@mipmap/ic_notification', // optional custom small icon
  ),
);

String _extractTitle(RemoteMessage msg) {
  final t = (msg.data['title'] ?? msg.notification?.title ?? 'CinePulse').toString().trim();
  return t.isEmpty ? 'CinePulse' : t;
}

/// Background handler (must be top-level).
/// Show ONLY for data-only messages to avoid duplicates with system notifications.
@pragma('vm:entry-point')
Future<void> cinepulseFcmBg(RemoteMessage message) async {
  if (message.notification != null) return; // system will handle those
  final title = _extractTitle(message);
  await _ensureFirebase();
  await _ensureChannel();
  await _fln.show(_nextId(), title, null, _headsUpDetails());
}

bool _didInit = false;

/// Call once during app startup (Android only).
Future<void> initCinepulseFcm() async {
  if (!_isAndroid || _didInit) return;
  _didInit = true;

  await _ensureFirebase();

  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _fln.initialize(const InitializationSettings(android: androidInit));
  await _ensureChannel();

  // Ensure FCM auto-init and background handler
  await FirebaseMessaging.instance.setAutoInitEnabled(true);
  FirebaseMessaging.onBackgroundMessage(cinepulseFcmBg);

  // Android 13+ permission
  await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);

  // Foreground messages → show ONLY for data-only to prevent doubles
  FirebaseMessaging.onMessage.listen((msg) async {
    if (msg.notification != null) return; // ignore notification payloads
    final title = _extractTitle(msg);
    await _fln.show(_nextId(), title, null, _headsUpDetails());
  });

  // Debug hooks (taps)
  final initial = await FirebaseMessaging.instance.getInitialMessage();
  if (initial != null) {
    // ignore: avoid_print
    print('FCM initial message: ${initial.messageId} data=${initial.data}');
  }
  FirebaseMessaging.onMessageOpenedApp.listen((m) {
    // ignore: avoid_print
    print('FCM onMessageOpenedApp: ${m.messageId} data=${m.data}');
  });

  // Subscribe everyone to the broadcast topic and keep it across token refreshes
  await FirebaseMessaging.instance.subscribeToTopic('global-feed');
  FirebaseMessaging.instance.onTokenRefresh.listen((_) {
    FirebaseMessaging.instance.subscribeToTopic('global-feed');
  });

  // Debug: token now + on refresh
  final token = await FirebaseMessaging.instance.getToken();
  // ignore: avoid_print
  print('FCM TOKEN => $token');
  FirebaseMessaging.instance.onTokenRefresh.listen((t) {
    // ignore: avoid_print
    print('FCM TOKEN (refreshed) => $t');
  });
}
