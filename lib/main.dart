import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app.dart';
import 'src/config/supabase_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Clean paths such as /admin/attendance instead of /#/admin/attendance. The
  // server must answer every one of those paths with index.html, which the
  // nginx config in this repo does; a host without that fallback 404s on
  // refresh.
  usePathUrlStrategy();

  await Supabase.initialize(
    url: SupabaseConfig.url,
    publishableKey: SupabaseConfig.publishableKey,
  );

  runApp(const ProviderScope(child: ClockInApp()));
}
