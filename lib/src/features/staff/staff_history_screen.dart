import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../core/formatters.dart';
import '../../models/attendance_record.dart';
import '../../services/attendance_repository.dart';
import '../shared/widgets.dart';

class StaffHistoryScreen extends ConsumerWidget {
  const StaffHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(myHistoryProvider);

    return FScaffold(
      childPad: false,
      header: FHeader(
        title: const Text('History'),
        suffixes: [
          HeaderAction(
            icon: FLucideIcons.refreshCw,
            semanticsLabel: 'Refresh',
            onPress: () => ref.invalidate(myHistoryProvider),
          ),
        ],
      ),
      child: AsyncSection(
        value: history,
        onRetry: () => ref.invalidate(myHistoryProvider),
        builder: (records) {
          if (records.isEmpty) {
            return const PagePadding(
              child: FCard(
                child: EmptyState(
                  icon: FLucideIcons.calendarDays,
                  title: 'No attendance yet',
                  message:
                      'Your clock-ins will appear here once you start marking '
                      'attendance.',
                ),
              ),
            );
          }

          return PagePadding(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _MonthSummary(records: records),
                const SizedBox(height: gutter),
                FTileGroup(
                  label: const Text('All shifts'),
                  children: [
                    for (final record in records) _HistoryTile(record: record),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A quick "how am I doing this month" read, computed from the rows already
/// loaded rather than a second query.
class _MonthSummary extends StatelessWidget {
  const _MonthSummary({required this.records});

  final List<AttendanceRecord> records;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final thisMonth = records.where(
      (r) => r.workDate.year == now.year && r.workDate.month == now.month,
    );

    final total = thisMonth.fold(
      Duration.zero,
      (sum, r) => sum + (r.workedDuration ?? Duration.zero),
    );

    return SectionCard(
      title: 'This month',
      children: [
        MetricRow(
          figures: [
            MetricFigure(label: 'Days', value: '${thisMonth.length}'),
            MetricFigure(label: 'Hours', value: formatDuration(total)),
            MetricFigure(
              label: 'Open',
              value: '${thisMonth.where((r) => r.isOpen).length}',
            ),
          ],
        ),
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget with FTileMixin {
  const _HistoryTile({required this.record});

  final AttendanceRecord record;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    return FTile(
      prefix: TileIcon(
        record.isOpen ? FLucideIcons.hourglass : FLucideIcons.circleCheck,
      ),
      title: Text(formatShortDay(record.workDate)),
      subtitle: Text(
        '${formatTime(record.clockInAt)} → ${formatTime(record.clockOutAt)}'
        ' · ${formatDistance(record.clockInDistanceMeters)} out',
      ),
      details: Text(
        record.isOpen ? 'Open' : formatDuration(record.workedDuration),
        style: theme.bodyStyle.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}
