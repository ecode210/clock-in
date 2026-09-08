import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';
import '../core/app_error.dart';
import '../core/dev_log.dart';
import '../models/profile.dart';
import '../models/staff_passkey.dart';
import 'supabase_providers.dart';

/// Result of creating an account or resetting a password: the admin has to
/// hand the temporary password to the staff member out of band.
class StaffCredentials {
  const StaffCredentials({
    required this.userId,
    required this.temporaryPassword,
    this.email,
  });

  final String userId;
  final String temporaryPassword;
  final String? email;
}

class StaffRepository {
  const StaffRepository(this._client);

  final SupabaseClient _client;

  Future<List<Profile>> list() async {
    final rows = await _client
        .from('profiles')
        .select()
        .order('role')
        .order('full_name');
    return rows.map(Profile.fromMap).toList();
  }

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) async {
    final action = 'staff.${body['action']}';
    logAction(action, {'email': body['email'], 'user_id': body['user_id']});
    try {
      final response = await _client.functions.invoke(
        SupabaseConfig.staffFunction,
        body: body,
      );
      final data = response.data;
      if (data is Map<String, dynamic>) {
        if (data['error'] is String) {
          throw AppError(data['error'] as String);
        }
        logDone(action);
        return data;
      }
      throw const AppError('The server returned an unexpected response.');
    } catch (error, stack) {
      logFail(action, error, stack);
      throw toAppError(error);
    }
  }

  Future<StaffCredentials> create({
    required String fullName,
    required String email,
    String? staffId,
    UserRole role = UserRole.staff,
    String? password,
  }) async {
    final data = await _invoke({
      'action': 'create',
      'full_name': fullName,
      'email': email,
      'staff_id': staffId ?? '',
      'role': role.name,
      if (password != null && password.isNotEmpty) 'password': password,
    });

    return StaffCredentials(
      userId: data['user_id'] as String,
      temporaryPassword: data['temporary_password'] as String,
      email: data['email'] as String?,
    );
  }

  Future<StaffCredentials> resetPassword({
    required String userId,
    String? password,
  }) async {
    final data = await _invoke({
      'action': 'reset_password',
      'user_id': userId,
      if (password != null && password.isNotEmpty) 'password': password,
    });

    return StaffCredentials(
      userId: data['user_id'] as String,
      temporaryPassword: data['temporary_password'] as String,
    );
  }

  Future<void> delete(String userId) =>
      _invoke({'action': 'delete', 'user_id': userId});

  /// Deactivating is preferred over deleting: it blocks clock-ins while
  /// keeping the person's attendance history intact.
  Future<void> setActive(String userId, {required bool isActive}) async {
    logAction('staff.set_active', {'user_id': userId, 'active': isActive});
    try {
      await _client
          .from('profiles')
          .update({'is_active': isActive})
          .eq('id', userId);
      logDone('staff.set_active');
    } catch (error, stack) {
      logFail('staff.set_active', error, stack);
      throw toAppError(error);
    }
  }

  Future<void> updateDetails({
    required String userId,
    required String fullName,
    String? staffId,
    required UserRole role,
  }) async {
    logAction('staff.update_details', {'user_id': userId, 'role': role.name});
    try {
      await _client
          .from('profiles')
          .update({
            'full_name': fullName,
            'staff_id': (staffId ?? '').isEmpty ? null : staffId,
            'role': role.name,
          })
          .eq('id', userId);
      logDone('staff.update_details');
    } catch (error, stack) {
      logFail('staff.update_details', error, stack);
      throw toAppError(error);
    }
  }

  /// Replaces the caller's own password and clears the flag that was forcing
  /// them here. Goes through the Edge Function rather than `updateUser` so the
  /// flag can only be cleared by a password that actually changed.
  Future<void> changeOwnPassword(String password) async {
    await _invoke({'action': 'change_own_password', 'password': password});
  }

  Future<List<StaffPasskey>> passkeysFor(String userId) async {
    try {
      final rows = await _client.rpc(
        'list_staff_passkeys',
        params: {'p_user_id': userId},
      );
      return (rows as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(StaffPasskey.fromMap)
          .toList();
    } catch (error, stack) {
      logFail('staff.passkeys', error, stack);
      throw toAppError(error);
    }
  }

  Future<List<PasskeyEvent>> passkeyEventsFor(String userId, {int limit = 20}) async {
    try {
      final rows = await _client
          .from('passkey_events')
          .select('id, action, friendly_name, created_at, actor:actor_id(full_name)')
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .limit(limit);
      return rows.map(PasskeyEvent.fromMap).toList();
    } catch (error, stack) {
      logFail('staff.passkey_events', error, stack);
      throw toAppError(error);
    }
  }

  /// Clears the staff member's passkey so they can enrol a new device. The
  /// delete has to happen inside the RPC: the guard trigger on the credential
  /// table stands down for nothing else.
  Future<int> resetPasskey(String userId) async {
    logAction('staff.reset_passkey', {'user_id': userId});
    try {
      final removed = await _client.rpc(
        'reset_staff_passkey',
        params: {'p_user_id': userId},
      );
      logDone('staff.reset_passkey', {'removed': removed});
      return (removed as int?) ?? 0;
    } catch (error, stack) {
      logFail('staff.reset_passkey', error, stack);
      throw toAppError(error);
    }
  }
}

final staffRepositoryProvider = Provider<StaffRepository>(
  (ref) => StaffRepository(ref.watch(supabaseClientProvider)),
);

final staffListProvider = FutureProvider<List<Profile>>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(staffRepositoryProvider).list();
});

/// What an administrator sees on a staff member's passkey sheet: the
/// credential currently registered, if any, and how it got there.
typedef PasskeyOverview = ({
  List<StaffPasskey> passkeys,
  List<PasskeyEvent> events,
});

final staffPasskeysProvider = FutureProvider.family<PasskeyOverview, String>((
  ref,
  userId,
) async {
  final repository = ref.watch(staffRepositoryProvider);
  final passkeys = await repository.passkeysFor(userId);
  final events = await repository.passkeyEventsFor(userId);
  return (passkeys: passkeys, events: events);
});
