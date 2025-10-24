// lib/core/fcm_bootstrap.dart
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const _channelId = 'cinepulse_general';
const _channelName = 'CinePulse';

final FlutterLocalNotificationsPlugin _fln = FlutterLocalNotificationsPlugin();

int _nextId() => DateTime.now().millisecondsSinceEpoch.remainder(1 << 31);

Future<void> _ensureFirebase() async {
  // On Android, google-services.json wires up options automatically.
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp();
  }
}

/// Background handler (must be a top-level/tear-off function)
@pragma('vm:entry-point')
Future<void> cinepulseFcmBg(RemoteMessage message) async {
  await _ensureFirebase();

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

/// Call this once during app startup.
Future<void> initCinepulseFcm() async {
  await _ensureFirebase();

  // Local notifications init + channel
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _fln.initialize(
    const InitializationSettings(android: androidInit),
  );

  const channel = AndroidNotificationChannel(
    _channelId,
    _channelName,
    description: 'General updates',
    importance: Importance.high,
  );

  await _fln
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  // Background handling
  FirebaseMessaging.onBackgroundMessage(cinepulseFcmBg);

  // Android 13+ runtime permission (no-op on older)
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

  // App opened from a notification (terminated/background → foreground)
  // Useful for routing later if you want.
  final initial = await FirebaseMessaging.instance.getInitialMessage();
  if (initial != null) {
    // ignore: avoid_print
    print('FCM initial message: ${initial.messageId} data=${initial.data}');
  }
  FirebaseMessaging.onMessageOpenedApp.listen((msg) {
    // ignore: avoid_print
    print('FCM onMessageOpenedApp: ${msg.messageId} data=${msg.data}');
  });

  // Optional: subscribe to a global topic for broadcast pushes
  await FirebaseMessaging.instance.subscribeToTopic('global-feed');

  // Debug: print the device token once (useful to paste into Firebase console “Send test message”)
  final token = await FirebaseMessaging.instance.getToken();
  // ignore: avoid_print
  print('FCM TOKEN => $token');
}
