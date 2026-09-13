import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_error.dart';
import '../core/dev_log.dart';
import '../models/attendance_record.dart';
import '../models/profile.dart';
import 'supabase_providers.dart';

/// Named after the foreign key rather than the table: `attendance` points at
/// `profiles` twice, through `user_id` and through `reviewed_by`, and without
/// the constraint name PostgREST refuses to guess which one to embed.
const _staffEmbed =
    'profiles!attendance_user_id_fkey!inner'
    '(full_name, email, staff_id, role, is_active)';

/// One page of attendance rows, with an explicit signal when more exist.
class AttendancePage {
  const AttendancePage({
    required this.records,
    required this.hasMore,
  });

  final List<AttendanceRecord> records;
  final bool hasMore;
}

/// Admin "Today" snapshot: accurate counts even when the visit list is bounded.
class AdminTodaySnapshot {
  const AdminTodaySnapshot({
    required this.workDate,
    required this.people,
    required this.onShift,
    required this.completed,
    required this.absent,
    required this.recent,
  });

  factory AdminTodaySnapshot.fromMap(Map<String, dynamic> map) {
    final absentRaw = map['absent'];
    final recentRaw = map['recent'];
    return AdminTodaySnapshot(
      workDate: DateTime.parse(map['work_date'] as String),
      people: (map['people'] as num?)?.toInt() ?? 0,
      onShift: (map['on_shift'] as num?)?.toInt() ?? 0,
      completed: (map['completed'] as num?)?.toInt() ?? 0,
      absent: absentRaw is List
          ? absentRaw
                .whereType<Map>()
                .map((row) => Profile.fromMap(Map<String, dynamic>.from(row)))
                .toList(growable: false)
          : const [],
      recent: recentRaw is List
          ? recentRaw
                .whereType<Map>()
                .map(
                  (row) =>
                      AttendanceRecord.fromMap(Map<String, dynamic>.from(row)),
                )
                .toList(growable: false)
          : const [],
    );
  }

  final DateTime workDate;
  final int people;
  final int onShift;
  final int completed;
  final List<Profile> absent;
  final List<AttendanceRecord> recent;
}

class AttendanceRepository {
  const AttendanceRepository(this._client);

  final SupabaseClient _client;

  /// The organisation's current date, which may differ from the browser's.
  Future<DateTime> orgToday() async {
    final value = await withClockSkewRetry(() => _client.rpc('org_today'));
    return DateTime.parse(value as String);
  }

  /// Every visit today for the caller, newest first.
  Future<List<AttendanceRecord>> myTodayRecords() async {
    final result = await _client.rpc('my_today_attendance');
    final rows = switch (result) {
      null => const <dynamic>[],
      final List<dynamic> list => list,
      final Map<String, dynamic> map => [map],
      _ => const <dynamic>[],
    };

    return rows
        .whereType<Map<String, dynamic>>()
        .where((row) => row['id'] != null)
        .map(AttendanceRecord.fromMap)
        .toList();
  }

  /// The open shift, if any. Drives the clock-out button.
  Future<AttendanceRecord?> myOpenRecord() async {
    final result = await _client.rpc('my_open_attendance');
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
    required String locationId,
    double? accuracyMeters,
    String? selfiePath,
  }) async {
    logAction('clock_in', {
      'lat': latitude.toStringAsFixed(6),
      'lng': longitude.toStringAsFixed(6),
      'location_id': locationId,
      'accuracy': accuracyMeters?.round(),
      'selfie': selfiePath == null ? 'none' : 'attached',
    });
    try {
      final row = await _client.rpc(
        'clock_in',
        params: {
          'p_lat': latitude,
          'p_lng': longitude,
          'p_location_id': locationId,
          'p_accuracy_meters': accuracyMeters,
          'p_selfie_path': selfiePath,
        },
      );
      final record = AttendanceRecord.fromMap(row as Map<String, dynamic>);
      logDone('clock_in', {
        'distance': record.clockInDistanceMeters.round(),
        'location': record.locationName,
      });
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

  /// Staff history, newest first. Fetches one past [limit] so callers can show
  /// a clear "load more" affordance instead of silent truncation.
  Future<AttendancePage> myHistoryPage({
    int limit = 30,
    int offset = 0,
  }) async {
    final rows = await _client
        .from('attendance')
        .select()
        .order('work_date', ascending: false)
        .order('clock_in_at', ascending: false)
        .range(offset, offset + limit);
    final records = rows.map(AttendanceRecord.fromMap).toList();
    final hasMore = records.length > limit;
    return AttendancePage(
      records: hasMore ? records.sublist(0, limit) : records,
      hasMore: hasMore,
    );
  }

  /// Admin view: every staff member's rows, with their profile embedded.
  Future<List<AttendanceRecord>> allRecords({
    DateTime? from,
    DateTime? to,
    String? userId,
    int limit = 500,
    int offset = 0,
  }) async {
    final page = await allRecordsPage(
      from: from,
      to: to,
      userId: userId,
      limit: limit,
      offset: offset,
    );
    return page.records;
  }

  /// Same as [allRecords], but reports whether another page exists.
  Future<AttendancePage> allRecordsPage({
    DateTime? from,
    DateTime? to,
    String? userId,
    int limit = 50,
    int offset = 0,
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
        .range(offset, offset + limit);
    final records = rows.map(AttendanceRecord.fromMap).toList();
    final hasMore = records.length > limit;
    return AttendancePage(
      records: hasMore ? records.sublist(0, limit) : records,
      hasMore: hasMore,
    );
  }

  /// Calendar badges without loading every visit row.
  Future<Map<String, int>> monthVisitCounts({
    required int year,
    required int month,
    String? userId,
  }) async {
    final rows = await _client.rpc(
      'admin_month_visit_counts',
      params: {
        'p_year': year,
        'p_month': month,
        'p_user_id': userId,
      },
    );
    final counts = <String, int>{};
    if (rows is! List) return counts;
    for (final row in rows.whereType<Map>()) {
      final map = Map<String, dynamic>.from(row);
      final date = map['work_date'] as String?;
      final count = (map['visit_count'] as num?)?.toInt() ?? 0;
      if (date != null) counts[date] = count;
    }
    return counts;
  }

  /// Accurate Today stats plus a bounded recent-visits list.
  Future<AdminTodaySnapshot> todaySnapshot({int recentLimit = 50}) async {
    final result = await _client.rpc(
      'admin_today_snapshot',
      params: {'p_recent_limit': recentLimit},
    );
    return AdminTodaySnapshot.fromMap(
      Map<String, dynamic>.from(result as Map),
    );
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

final myTodayRecordsProvider = FutureProvider<List<AttendanceRecord>>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(attendanceRepositoryProvider).myTodayRecords();
});

final myOpenRecordProvider = FutureProvider<AttendanceRecord?>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(attendanceRepositoryProvider).myOpenRecord();
});

/// Accurate Today dashboard data, including overnight open shifts.
final todaySnapshotProvider = FutureProvider<AdminTodaySnapshot>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(attendanceRepositoryProvider).todaySnapshot();
});
