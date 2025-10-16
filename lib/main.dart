import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'app/app.dart';
import 'app/app_settings.dart';
import 'core/cache.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Intl.defaultLocale = 'en_US';

  await AppSettings.instance.init();
  await SavedStore.instance.init();

  runApp(const CinePulseApp());
}
