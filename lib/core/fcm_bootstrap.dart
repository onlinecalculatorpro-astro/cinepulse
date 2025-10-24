// lib/core/fcm_bootstrap.dart
import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const _channelId = 'cinepulse_general';
const _channelName = 'CinePulse';
const _channelDesc = 'General updates';

final FlutterLocalNotificationsPlugin _fln = FlutterLocalNotificationsPlugin();

bool get _isAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

int _nextId() => DateTime.now().millisecondsSinceEpoch.remainder(1 << 31);

Future<void> _ensureFirebase() async {
  if (!_isAndroid) return;
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp();
  }
}

Future<void> _ensureChannel() async {
  if (!_isAndroid) return;
  const channel = AndroidNotificationChannel(
    _channelId,
    _channelName,
    description: _channelDesc,
    importance: Importance.high,
  );
  await _fln
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);
}

NotificationDetails _headsUpDetails() => const NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        importance: Importance.high,
        priority: Priority.high,
        // icon: '@mipmap/ic_notification', // (optional) if you add one
      ),
    );

({String title, String body}) _titleBody(RemoteMessage msg) {
  final title =
      msg.data['title'] ?? msg.notification?.title ?? 'CinePulse';
  final body =
      msg.data['body'] ?? msg.notification?.body ?? 'New update';
  return (title: title, body: body);
}

/// Background handler (must be top-level).
@pragma('vm:entry-point')
Future<void> cinepulseFcmBg(RemoteMessage message) async {
  await _ensureFirebase();
  await _ensureChannel();

  final tb = _titleBody(message);
  await _fln.show(_nextId(), tb.title, tb.body, _headsUpDetails());
}

bool _didInit = false;

/// Call once during app startup (Android only).
Future<void> initCinepulseFcm() async {
  if (!_isAndroid || _didInit) return;
  _didInit = true;

  await _ensureFirebase();

  // Local notifications init + channel
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _fln.initialize(const InitializationSettings(android: androidInit));
  await _ensureChannel();

  // Make sure FCM is on
  await FirebaseMessaging.instance.setAutoInitEnabled(true);

  // Background handler
  FirebaseMessaging.onBackgroundMessage(cinepulseFcmBg);

  // Android 13+ runtime permission
  await FirebaseMessaging.instance
      .requestPermission(alert: true, badge: true, sound: true);

  // Foreground messages → local heads-up
  FirebaseMessaging.onMessage.listen((msg) async {
    final tb = _titleBody(msg);
    await _fln.show(_nextId(), tb.title, tb.body, _headsUpDetails());
  });

  // Notification taps
  final initial = await FirebaseMessaging.instance.getInitialMessage();
  if (initial != null) {
    // ignore: avoid_print
    print('FCM initial message: ${initial.messageId} data=${initial.data}');
  }
  FirebaseMessaging.onMessageOpenedApp.listen((msg) {
    // ignore: avoid_print
    print('FCM onMessageOpenedApp: ${msg.messageId} data=${msg.data}');
  });

  // Subscribe everyone to broadcast topic and keep it on token refresh
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
