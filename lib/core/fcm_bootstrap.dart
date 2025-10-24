import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// NOTE: this path is correct because this file lives in lib/core/
import '../firebase_options.dart';

final FlutterLocalNotificationsPlugin _fln = FlutterLocalNotificationsPlugin();

int _nextId() => DateTime.now().millisecondsSinceEpoch.remainder(1 << 31);

@pragma('vm:entry-point')
Future<void> cinepulseFcmBg(RemoteMessage msg) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  const details = NotificationDetails(
    android: AndroidNotificationDetails(
      'cinepulse_general',
      'CinePulse',
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
}

Future<void> initCinepulseFcm() async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Local notifications & channel
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _fln.initialize(const InitializationSettings(android: androidInit));
  const channel = AndroidNotificationChannel(
    'cinepulse_general',
    'CinePulse',
    description: 'General updates',
    importance: Importance.high,
  );
  await _fln
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  // Background + permission
  FirebaseMessaging.onBackgroundMessage(cinepulseFcmBg);
  await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);

  // Foreground handler (show heads-up)
  FirebaseMessaging.onMessage.listen((msg) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'cinepulse_general',
        'CinePulse',
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

  // Optional: subscribe to a global topic for broadcast pushes
  await FirebaseMessaging.instance.subscribeToTopic('global-feed');

  // Debug: print token once
  final token = await FirebaseMessaging.instance.getToken();
  // ignore: avoid_print
  print('FCM TOKEN => $token');
}
