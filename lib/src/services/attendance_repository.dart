import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_error.dart';
import '../core/dev_log.dart';
import '../models/attendance_record.dart';
import 'supabase_providers.dart';

/// Named after the foreign key rather than the table: `attendance` points at
/// `profiles` twice, through `user_id` and through `reviewed_by`, and without
/// the constraint name PostgREST refuses to guess which one to embed.
const _staffEmbed =
    'profiles!attendance_user_id_fkey!inner'
    '(full_name, email, staff_id, role, is_active)';

class AttendanceRepository {
  const AttendanceRepository(this._client);

  final SupabaseClient _client;

  /// The organisation's current date, which may differ from the browser's.
  Future<DateTime> orgToday() async {
    final value = await withClockSkewRetry(() => _client.rpc('org_today'));
    return DateTime.parse(value as String);
  }

  Future<AttendanceRecord?> myTodayRecord() async {
    final result = await _client.rpc('my_today_attendance');
    // With no row for today the function yields null, an empty list, or a
    // composite whose fields are all null, depending on how PostgREST frames
    // it. Treat all three as "not clocked in yet".
    final row = switch (result) {
      null => null,
      final List<dynamic> list => list.isEmpty
          ? null
          : list.first as Map<String, dynamic>?,
      final Map<String, dynamic> map => map,
      _ => null,
    };

    if (row == null || row['id'] == null) return null;
    return AttendanceRecord.fromMap(row);
  }

  Future<AttendanceRecord> clockIn({
    required double latitude,
    required double longitude,
    double? accuracyMeters,
    String? selfiePath,
  }) async {
    logAction('clock_in', {
      'lat': latitude.toStringAsFixed(6),
      'lng': longitude.toStringAsFixed(6),
      'accuracy': accuracyMeters?.round(),
      'selfie': selfiePath == null ? 'none' : 'attached',
    });
    try {
      final row = await _client.rpc(
        'clock_in',
        params: {
          'p_lat': latitude,
          'p_lng': longitude,
          'p_accuracy_meters': accuracyMeters,
          'p_selfie_path': selfiePath,
        },
      );
      final record = AttendanceRecord.fromMap(row as Map<String, dynamic>);
      logDone('clock_in', {'distance': record.clockInDistanceMeters.round()});
      return record;
    } catch (error, stack) {
      logFail('clock_in', error, stack);
      throw toAppError(error);
    }
  }

  Future<AttendanceRecord> clockOut({
    double? latitude,
    double? longitude,
    double? accuracyMeters,
  }) async {
    logAction('clock_out', {
      'lat': latitude?.toStringAsFixed(6),
      'lng': longitude?.toStringAsFixed(6),
      'accuracy': accuracyMeters?.round(),
    });
    try {
      final row = await _client.rpc(
        'clock_out',
        params: {
          'p_lat': latitude,
          'p_lng': longitude,
          'p_accuracy_meters': accuracyMeters,
        },
      );
      final record = AttendanceRecord.fromMap(row as Map<String, dynamic>);
      logDone('clock_out', {
        'distance': record.clockOutDistanceMeters?.round(),
      });
      return record;
    } catch (error, stack) {
      logFail('clock_out', error, stack);
      throw toAppError(error);
    }
  }

  Future<List<AttendanceRecord>> myHistory({int limit = 60}) async {
    final rows = await _client
        .from('attendance')
        .select()
        .order('work_date', ascending: false)
        .limit(limit);
    return rows.map(AttendanceRecord.fromMap).toList();
  }

  /// Admin view: every staff member's rows, with their profile embedded.
  Future<List<AttendanceRecord>> allRecords({
    DateTime? from,
    DateTime? to,
    String? userId,
    int limit = 500,
  }) async {
    var query = _client.from('attendance').select('*, $_staffEmbed');

    if (from != null) {
      query = query.gte('work_date', _dateOnly(from));
    }
    if (to != null) {
      query = query.lte('work_date', _dateOnly(to));
    }
    if (userId != null) {
      query = query.eq('user_id', userId);
    }

    final rows = await query
        .order('work_date', ascending: false)
        .order('clock_in_at', ascending: false)
        .limit(limit);

    return rows.map(AttendanceRecord.fromMap).toList();
  }

  /// Records what an administrator made of a clock-in photo. Attendance rows
  /// are revoked for update from the client, so this goes through an RPC in
  /// the same way clocking in and out does.
  Future<AttendanceRecord> review(String id, ReviewStatus status) async {
    logAction('attendance.review', {'id': id, 'status': status.name});
    try {
      final row = await _client.rpc(
        'review_attendance',
        params: {'p_id': id, 'p_status': status.name},
      );
      logDone('attendance.review');
      return AttendanceRecord.fromMap(row as Map<String, dynamic>);
    } catch (error, stack) {
      logFail('attendance.review', error, stack);
      throw toAppError(error);
    }
  }

  /// Short-lived link so admins can view a private selfie for verification.
  Future<String> selfieUrl(String path) => _client.storage
      .from('selfies')
      .createSignedUrl(path, 60 * 10);

  static String _dateOnly(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

final attendanceRepositoryProvider = Provider<AttendanceRepository>(
  (ref) => AttendanceRepository(ref.watch(supabaseClientProvider)),
);

final orgTodayProvider = FutureProvider<DateTime>(
  (ref) => ref.watch(attendanceRepositoryProvider).orgToday(),
);

final myTodayRecordProvider = FutureProvider<AttendanceRecord?>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(attendanceRepositoryProvider).myTodayRecord();
});

final myHistoryProvider = FutureProvider<List<AttendanceRecord>>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(attendanceRepositoryProvider).myHistory();
});

/// Today's attendance across the whole organisation, for the admin dashboard.
final todayAttendanceProvider = FutureProvider<List<AttendanceRecord>>((
  ref,
) async {
  final today = await ref.watch(orgTodayProvider.future);
  return ref
      .watch(attendanceRepositoryProvider)
      .allRecords(from: today, to: today);
});
