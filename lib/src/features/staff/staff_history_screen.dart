import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../core/app_error.dart';
import '../../core/formatters.dart';
import '../../models/attendance_record.dart';
import '../../services/attendance_repository.dart';
import '../../services/supabase_providers.dart';
import '../shared/widgets.dart';

class StaffHistoryScreen extends ConsumerStatefulWidget {
  const StaffHistoryScreen({super.key});

  @override
  ConsumerState<StaffHistoryScreen> createState() => _StaffHistoryScreenState();
}

class _StaffHistoryScreenState extends ConsumerState<StaffHistoryScreen> {
  static const _pageSize = 30;

  final List<AttendanceRecord> _rows = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  Widget build(BuildContext context) {
    final timezone = ref.watch(orgSettingsProvider).value?.timezone;
    final today = ref.watch(orgTodayProvider).value;

    return AppScaffold(
      childPad: false,
      header: FHeader(
        title: const Text('History'),
        suffixes: [
          HeaderAction(
            icon: FLucideIcons.refreshCw,
            semanticsLabel: 'Refresh',
            onPress: _reload,
          ),
        ],
      ),
      child: PagePadding(
        child: _loading
            ? const Center(child: FCircularProgress())
            : _error != null
            ? ErrorNotice(
                error: AppError(_error!),
                onRetry: _reload,
              )
            : _rows.isEmpty
            ? const FCard(
                child: EmptyState(
                  icon: FLucideIcons.calendarDays,
                  title: 'No attendance yet',
                  message:
                      'Your clock-ins will appear here once you start marking '
                      'attendance.',
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _MonthSummary(
                    records: _rows,
                    today: today,
                  ),
                  const SizedBox(height: gutter),
                  FTileGroup(
                    label: const Text('All shifts'),
                    children: [
                      for (final record in _rows)
                        _HistoryTile(
                          record: record,
                          timezone: timezone,
                        ),
                    ],
                  ),
                  if (_hasMore) ...[
                    const SizedBox(height: 12),
                    FButton(
                      variant: FButtonVariant.outline,
                      onPress: _loadingMore ? null : _loadMore,
                      prefix: _loadingMore
                          ? const FCircularProgress()
                          : null,
                      child: ButtonLabel(
                        _loadingMore ? 'Loading…' : 'Load more',
                      ),
                    ),
                  ],
                ],
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
          .myHistoryPage(limit: _pageSize);
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
          .myHistoryPage(limit: _pageSize, offset: _rows.length);
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
}

/// A quick "how am I doing this month" read, computed from the rows already
/// loaded rather than a second query.
class _MonthSummary extends StatelessWidget {
  const _MonthSummary({required this.records, required this.today});

  final List<AttendanceRecord> records;
  final DateTime? today;

  @override
  Widget build(BuildContext context) {
    final anchor = today ?? DateTime.now();
    final thisMonth = records.where(
      (r) => r.workDate.year == anchor.year && r.workDate.month == anchor.month,
    );

    final total = thisMonth.fold(
      Duration.zero,
      (sum, r) => sum + (r.workedDuration ?? Duration.zero),
    );

    final uniqueDays = thisMonth.map((r) => r.workDate).toSet().length;

    return SectionCard(
      title: 'This month',
      children: [
        MetricRow(
          figures: [
            MetricFigure(label: 'Days', value: '$uniqueDays'),
            MetricFigure(label: 'Visits', value: '${thisMonth.length}'),
            MetricFigure(label: 'Hours', value: formatDuration(total)),
          ],
        ),
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget with FTileMixin {
  const _HistoryTile({required this.record, required this.timezone});

  final AttendanceRecord record;
  final String? timezone;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    return FTile(
      prefix: TileIcon(
        record.isOpen ? FLucideIcons.hourglass : FLucideIcons.circleCheck,
      ),
      title: Text(formatShortDay(record.workDate)),
      subtitle: Text(
        '${record.displayLocationName} · '
        '${formatTime(record.clockInAt, timezone: timezone)} → '
        '${formatTime(record.clockOutAt, timezone: timezone)}'
        ' · ${formatDistance(record.clockInDistanceMeters)} out',
      ),
      details: Text(
        record.isOpen ? 'Open' : formatDuration(record.workedDuration),
        style: theme.bodyStyle.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}
