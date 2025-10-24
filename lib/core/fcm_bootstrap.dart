import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'firebase_options.dart';

final FlutterLocalNotificationsPlugin _fln = FlutterLocalNotificationsPlugin();

@pragma('vm:entry-point')
Future<void> cinepulseFcmBg(RemoteMessage m) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  const n = NotificationDetails(
    android: AndroidNotificationDetails('cinepulse_general','CinePulse',
      importance: Importance.high, priority: Priority.high),
  );
  await _fln.show(DateTime.now().millisecondsSinceEpoch.remainder(1<<31),
      m.data['title'] ?? 'CinePulse', m.data['body'] ?? 'New update', n);
}

Future<void> initCinepulseFcm() async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  const init = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _fln.initialize(const InitializationSettings(android: init));
  const ch = AndroidNotificationChannel('cinepulse_general','CinePulse',
      importance: Importance.high, description: 'General updates');
  await _fln.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(ch);

  FirebaseMessaging.onBackgroundMessage(cinepulseFcmBg);
  await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);

  FirebaseMessaging.onMessage.listen((m) async {
    const n = NotificationDetails(
      android: AndroidNotificationDetails('cinepulse_general','CinePulse',
          importance: Importance.high, priority: Priority.high),
    );
    await _fln.show(DateTime.now().millisecondsSinceEpoch.remainder(1<<31),
        m.data['title'] ?? m.notification?.title ?? 'CinePulse',
        m.data['body'] ?? m.notification?.body ?? 'New update', n);
  });

  await FirebaseMessaging.instance.subscribeToTopic('global-feed');
  final t = await FirebaseMessaging.instance.getToken();
  // ignore: avoid_print
  print('FCM TOKEN => $t');
}
