// lib/core/fcm_bootstrap.dart
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const _channelId = 'cinepulse_general';
const _channelName = 'CinePulse';
const _channelDesc = 'General updates';

final FlutterLocalNotificationsPlugin _fln = FlutterLocalNotificationsPlugin();

int _nextId() => DateTime.now().millisecondsSinceEpoch.remainder(1 << 31);

Future<void> _ensureFirebase() async {
  // On Android, google-services.json wires options automatically.
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp();
  }
}

Future<void> _ensureChannel() async {
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

/// Background handler (must be a top-level function).
@pragma('vm:entry-point')
Future<void> cinepulseFcmBg(RemoteMessage message) async {
  await _ensureFirebase();
  await _ensureChannel();

  const details = NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      _channelName,
      importance: Importance.high,
      priority: Priority.high,
    ),
  );

  await _fln.show(
    _nextId(),
    message.data['title'] ?? message.notification?.title ?? 'CinePulse',
    message.data['body'] ?? message.notification?.body ?? 'New update',
    details,
  );
}

/// Call once during app startup.
Future<void> initCinepulseFcm() async {
  await _ensureFirebase();

  // Local notifications init + channel
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _fln.initialize(const InitializationSettings(android: androidInit));
  await _ensureChannel();

  // Register background handler
  FirebaseMessaging.onBackgroundMessage(cinepulseFcmBg);

  // Android 13+ notification permission
  await FirebaseMessaging.instance
      .requestPermission(alert: true, badge: true, sound: true);

  // Foreground messages → show heads-up via local notifications
  FirebaseMessaging.onMessage.listen((msg) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    await _fln.show(
      _nextId(),
      msg.data['title'] ?? msg.notification?.title ?? 'CinePulse',
      msg.data['body'] ?? msg.notification?.body ?? 'New update',
      details,
    );
  });

  // App opened via notification (cold/warm start)
  final initial = await FirebaseMessaging.instance.getInitialMessage();
  if (initial != null) {
    // ignore: avoid_print
    print('FCM initial message: ${initial.messageId} data=${initial.data}');
  }
  FirebaseMessaging.onMessageOpenedApp.listen((msg) {
    // ignore: avoid_print
    print('FCM onMessageOpenedApp: ${msg.messageId} data=${msg.data}');
  });

  // Optional topic
  await FirebaseMessaging.instance.subscribeToTopic('global-feed');

  // Debug: print device token once
  final token = await FirebaseMessaging.instance.getToken();
  // ignore: avoid_print
  print('FCM TOKEN => $token');
}
