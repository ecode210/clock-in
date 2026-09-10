import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../../models/attendance_record.dart';
import '../../routing/router.dart';
import '../../services/attendance_repository.dart';
import '../shared/widgets.dart';
import 'attendance_history_screen.dart';
import 'attendance_row_tile.dart';

final attendanceDayProvider =
    FutureProvider.family<List<AttendanceRecord>, (String, String?)>((
      ref,
      key,
    ) {
      final (date, userId) = key;
      final day = DateTime.parse(date);
      return ref.watch(attendanceRepositoryProvider).allRecords(
        from: day,
        to: day,
        userId: userId,
      );
    });

/// Clock-ins for a single day, opened from the attendance calendar.
class AttendanceDayScreen extends ConsumerWidget {
  const AttendanceDayScreen({required this.date, super.key});

  /// `yyyy-mm-dd` from the route. Invalid values bounce back to the calendar.
  final String date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parsed = DateTime.tryParse(date);
    if (parsed == null || !_isDateOnly(date)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go(AppRoutes.adminAttendance);
      });
      return const AppScaffold(
        childPad: false,
        child: Center(child: FCircularProgress()),
      );
    }

    final day = DateTime(parsed.year, parsed.month, parsed.day);
    final userId = ref.watch(attendanceStaffFilterProvider);
    final records = ref.watch(attendanceDayProvider((date, userId)));

    return AppScaffold(
      childPad: false,
      header: FHeader.nested(
        title: Text(formatDay(day)),
        prefixes: [
          FHeaderAction.back(
            onPress: () => context.go(AppRoutes.adminAttendance),
          ),
        ],
        suffixes: [
          HeaderAction(
            icon: FLucideIcons.refreshCw,
            semanticsLabel: 'Refresh',
            onPress: () => ref.invalidate(attendanceDayProvider((date, userId))),
          ),
        ],
      ),
      child: AsyncSection(
        value: records,
        onRetry: () => ref.invalidate(attendanceDayProvider((date, userId))),
        builder: (rows) => PagePadding(
          maxWidth: 700,
          child: _DayResults(
            date: date,
            userId: userId,
            rows: rows,
          ),
        ),
      ),
    );
  }

  static final _dateOnly = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  static bool _isDateOnly(String value) => _dateOnly.hasMatch(value);
}

class _DayResults extends ConsumerWidget {
  const _DayResults({
    required this.date,
    required this.userId,
    required this.rows,
  });

  final String date;
  final String? userId;
  final List<AttendanceRecord> rows;

  void _invalidate(WidgetRef ref) {
    ref.invalidate(attendanceDayProvider((date, userId)));
    final parsed = DateTime.parse(date);
    ref.invalidate(
      monthAttendanceProvider((parsed.year, parsed.month, userId)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final worked = rows.fold(
      Duration.zero,
      (sum, r) => sum + (r.workedDuration ?? Duration.zero),
    );
    final flagged = rows
        .where((r) => r.reviewStatus == ReviewStatus.flagged)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ContentCard(
          child: MetricRow(
            figures: [
              MetricFigure(label: 'Clocked in', value: '${rows.length}'),
              MetricFigure(
                label: 'Total time',
                value: formatDuration(worked),
              ),
              MetricFigure(label: 'Flagged', value: '$flagged'),
            ],
          ),
        ),
        const SizedBox(height: gutter),
        if (rows.isEmpty)
          const FCard(
            child: EmptyState(
              icon: FLucideIcons.users,
              title: 'Nobody clocked in',
              message: 'There are no attendance records for this day.',
            ),
          )
        else
          FTileGroup(
            children: [
              for (final row in rows)
                AttendanceRowTile(
                  record: row,
                  onReviewed: () => _invalidate(ref),
                ),
            ],
          ),
      ],
    );
  }
}
