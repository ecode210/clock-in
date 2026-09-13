import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_error.dart';
import '../core/dev_log.dart';
import '../models/org_settings.dart';
import 'supabase_providers.dart';

class SettingsRepository {
  const SettingsRepository(this._client);

  final SupabaseClient _client;

  /// Writes the whole settings row. RLS restricts this to admins and a
  /// database trigger validates the timezone.
  Future<OrgSettings> save(OrgSettings settings) async {
    logAction('settings.save', {'timezone': settings.timezone});
    try {
      final row = await _client
          .from('org_settings')
          .update(settings.toUpdateMap())
          .eq('id', true)
          .select()
          .single();
      logDone('settings.save');
      return OrgSettings.fromMap(row);
    } catch (error, stack) {
      logFail('settings.save', error, stack);
      throw toAppError(error);
    }
  }

  Future<OrgSettings> patch(Map<String, dynamic> changes) async {
    logAction('settings.patch', changes);
    try {
      final row = await _client
          .from('org_settings')
          .update(changes)
          .eq('id', true)
          .select()
          .single();
      logDone('settings.patch');
      return OrgSettings.fromMap(row);
    } catch (error, stack) {
      logFail('settings.patch', error, stack);
      throw toAppError(error);
    }
  }
}

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(supabaseClientProvider)),
);
