import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_error.dart';
import '../core/dev_log.dart';
import '../models/org_settings.dart';
import '../models/profile.dart';

final supabaseClientProvider = Provider<SupabaseClient>(
  (ref) => Supabase.instance.client,
);

/// Holds the current session, seeded with whatever was restored from storage
/// and then kept in step with Supabase's auth events.
class SessionController extends Notifier<Session?> {
  @override
  Session? build() {
    final auth = ref.watch(supabaseClientProvider).auth;
    final subscription = auth.onAuthStateChange.listen((event) {
      logNote('auth ${event.event.name}', {
        'user': event.session?.user.email,
      });
      state = event.session;
    });
    ref.onDispose(subscription.cancel);
    return auth.currentSession;
  }
}

final sessionProvider = NotifierProvider<SessionController, Session?>(
  SessionController.new,
);

/// The signed-in user's id, or null. Watching this instead of the whole
/// session avoids refetching everything on every silent token refresh.
final currentUserIdProvider = Provider<String?>(
  (ref) => ref.watch(sessionProvider.select((s) => s?.user.id)),
);

final myProfileProvider = FutureProvider<Profile?>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return null;

  final client = ref.watch(supabaseClientProvider);
  final row = await withClockSkewRetry(
    () => client.from('profiles').select().eq('id', userId).maybeSingle(),
  );

  return row == null ? null : Profile.fromMap(row);
});

final orgSettingsProvider = FutureProvider<OrgSettings>((ref) async {
  // Settings are readable by any signed-in user because staff need the
  // geofence to show their live distance.
  ref.watch(currentUserIdProvider);

  final client = ref.watch(supabaseClientProvider);
  final row = await withClockSkewRetry(
    () => client.from('org_settings').select().limit(1).single(),
  );

  return OrgSettings.fromMap(row);
});

/// Drives the first-run screen that lets the very first account become admin.
final adminExistsProvider = FutureProvider<bool>((ref) async {
  ref.watch(currentUserIdProvider);
  final client = ref.watch(supabaseClientProvider);
  final result = await withClockSkewRetry(() => client.rpc('admin_exists'));
  return result == true;
});
