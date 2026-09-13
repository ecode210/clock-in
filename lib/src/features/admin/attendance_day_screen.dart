import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_error.dart';
import '../../core/formatters.dart';
import '../../models/attendance_record.dart';
import '../../routing/router.dart';
import '../../services/attendance_repository.dart';
import '../../services/supabase_providers.dart';
import '../shared/widgets.dart';
import 'attendance_history_screen.dart';
import 'attendance_row_tile.dart';

/// Clock-ins for a single day, opened from the attendance calendar.
class AttendanceDayScreen extends ConsumerStatefulWidget {
  const AttendanceDayScreen({required this.date, super.key});

  /// `yyyy-mm-dd` from the route. Invalid values bounce back to the calendar.
  final String date;

  @override
  ConsumerState<AttendanceDayScreen> createState() =>
      _AttendanceDayScreenState();
}

class _AttendanceDayScreenState extends ConsumerState<AttendanceDayScreen> {
  static const _pageSize = 50;

  final List<AttendanceRecord> _rows = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;
  String? _loadedFor;

  @override
  Widget build(BuildContext context) {
    final parsed = DateTime.tryParse(widget.date);
    if (parsed == null || !_isDateOnly(widget.date)) {
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
    final timezone = ref.watch(orgSettingsProvider).value?.timezone;
    final cacheKey = '${widget.date}|${userId ?? ''}';

    if (_loadedFor != cacheKey) {
      _loadedFor = cacheKey;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reload();
      });
    }

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
            onPress: _reload,
          ),
        ],
      ),
      child: PagePadding(
        maxWidth: 700,
        child: _loading
            ? const Center(child: FCircularProgress())
            : _error != null
            ? ErrorNotice(
                error: AppError(_error!),
                onRetry: _reload,
              )
            : _DayResults(
                date: widget.date,
                userId: userId,
                rows: _rows,
                timezone: timezone,
                hasMore: _hasMore,
                loadingMore: _loadingMore,
                onLoadMore: _loadMore,
                onReviewed: () {
                  ref.invalidate(
                    monthVisitCountsProvider((day.year, day.month, userId)),
                  );
                  _reload();
                },
              ),
      ),
    );
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
      _rows.clear();
      _hasMore = false;
    });
    try {
      final page = await ref
          .read(attendanceRepositoryProvider)
          .allRecordsPage(
            from: DateTime.parse(widget.date),
            to: DateTime.parse(widget.date),
            userId: ref.read(attendanceStaffFilterProvider),
            limit: _pageSize,
          );
      if (!mounted) return;
      setState(() {
        _rows
          ..clear()
          ..addAll(page.records);
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = errorMessage(error);
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(attendanceRepositoryProvider)
          .allRecordsPage(
            from: DateTime.parse(widget.date),
            to: DateTime.parse(widget.date),
            userId: ref.read(attendanceStaffFilterProvider),
            limit: _pageSize,
            offset: _rows.length,
          );
      if (!mounted) return;
      setState(() {
        _rows.addAll(page.records);
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      showSnack(context, errorMessage(error), isError: true);
    }
  }

  static final _dateOnly = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  static bool _isDateOnly(String value) => _dateOnly.hasMatch(value);
}

class _DayResults extends StatelessWidget {
  const _DayResults({
    required this.date,
    required this.userId,
    required this.rows,
    required this.timezone,
    required this.hasMore,
    required this.loadingMore,
    required this.onLoadMore,
    required this.onReviewed,
  });

  final String date;
  final String? userId;
  final List<AttendanceRecord> rows;
  final String? timezone;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback onLoadMore;
  final VoidCallback onReviewed;

  @override
  Widget build(BuildContext context) {
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
              MetricFigure(
                label: 'Visits',
                value: '${rows.length}${hasMore ? '+' : ''}',
              ),
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
        else ...[
          FTileGroup(
            children: [
              for (final row in rows)
                AttendanceRowTile(
                  record: row,
                  timezone: timezone,
                  onReviewed: onReviewed,
                ),
            ],
          ),
          if (hasMore) ...[
            const SizedBox(height: 12),
            FButton(
              variant: FButtonVariant.outline,
              onPress: loadingMore ? null : onLoadMore,
              prefix: loadingMore ? const FCircularProgress() : null,
              child: ButtonLabel(loadingMore ? 'Loading…' : 'Load more'),
            ),
          ],
        ],
      ],
    );
  }
}
