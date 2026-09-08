import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../core/formatters.dart';
import '../../models/attendance_record.dart';
import '../../services/attendance_repository.dart';
import '../../services/staff_repository.dart';
import '../shared/widgets.dart';
import 'attendance_row_tile.dart';

/// Filter state for the admin's attendance browser.
class AttendanceFilter {
  const AttendanceFilter({required this.from, required this.to, this.userId});

  final DateTime from;
  final DateTime to;
  final String? userId;

  AttendanceFilter copyWith({
    DateTime? from,
    DateTime? to,
    String? userId,
    bool clearUser = false,
  }) => AttendanceFilter(
    from: from ?? this.from,
    to: to ?? this.to,
    userId: clearUser ? null : (userId ?? this.userId),
  );
}

AttendanceFilter _defaultFilter() => AttendanceFilter(
  from: DateTime.now().subtract(const Duration(days: 29)),
  to: DateTime.now(),
);

class AttendanceFilterController extends Notifier<AttendanceFilter> {
  @override
  AttendanceFilter build() => _defaultFilter();

  void update(AttendanceFilter filter) => state = filter;

  void reset() => state = _defaultFilter();
}

final attendanceFilterProvider =
    NotifierProvider<AttendanceFilterController, AttendanceFilter>(
      AttendanceFilterController.new,
    );

final filteredAttendanceProvider = FutureProvider<List<AttendanceRecord>>((
  ref,
) {
  final filter = ref.watch(attendanceFilterProvider);
  return ref.watch(attendanceRepositoryProvider).allRecords(
    from: filter.from,
    to: filter.to,
    userId: filter.userId,
  );
});

class AttendanceHistoryScreen extends ConsumerWidget {
  const AttendanceHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(filteredAttendanceProvider);

    return FScaffold(
      childPad: false,
      header: FHeader(
        title: const Text('Attendance'),
        suffixes: [
          HeaderAction(
            icon: FLucideIcons.refreshCw,
            semanticsLabel: 'Refresh',
            onPress: () => ref.invalidate(filteredAttendanceProvider),
          ),
        ],
      ),
      child: PagePadding(
        maxWidth: 700,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _FilterCard(),
            const SizedBox(height: gutter),
            AsyncSection(
              value: records,
              onRetry: () => ref.invalidate(filteredAttendanceProvider),
              builder: (rows) => _Results(rows: rows),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterCard extends ConsumerWidget {
  const _FilterCard();

  /// The calendar comes up from the bottom rather than in a dialog: it is a
  /// tall control and a sheet is what a phone user expects for one.
  Future<void> _pickRange(
    BuildContext context,
    WidgetRef ref,
    AttendanceFilter filter,
  ) async {
    final picked = await showFSheet<(DateTime, DateTime)>(
      context: context,
      side: FLayout.btt,
      mainAxisMaxRatio: null,
      useSafeArea: true,
      builder: (sheetContext) =>
          _RangeSheet(initial: (filter.from, filter.to)),
    );

    if (picked != null) {
      ref
          .read(attendanceFilterProvider.notifier)
          .update(filter.copyWith(from: picked.$1, to: picked.$2));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(attendanceFilterProvider);
    final staff = ref.watch(staffListProvider).value ?? const [];

    return SectionCard(
      title: 'Filter',
      trailing: FButton(
        variant: FButtonVariant.primary,
        size: FButtonSizeVariant.sm,
        prefix: const Icon(FLucideIcons.rotateCcw),
        onPress: () => ref.read(attendanceFilterProvider.notifier).reset(),
        child: const Text('Reset'),
      ),
      children: [
        FButton(
          variant: FButtonVariant.outline,
          onPress: () => _pickRange(context, ref, filter),
          prefix: const Icon(FLucideIcons.calendarDays),
          child: ButtonLabel(
            '${formatShortDay(filter.from)} to ${formatShortDay(filter.to)}',
          ),
        ),
        const SizedBox(height: 12),
        FSelect<String>(
          items: {
            'Everyone': _everyone,
            for (final person in staff) person.displayName: person.id,
          },
          // Lifted, so the filter provider stays the single source of truth
          // and the Reset button above is reflected in the field.
          control: FSelectControl.lifted(
            value: filter.userId ?? _everyone,
            onChange: (value) =>
                ref.read(attendanceFilterProvider.notifier).update(
                  filter.copyWith(
                    userId: value,
                    clearUser: value == null || value == _everyone,
                  ),
                ),
          ),
          label: const Text('Staff member'),
          hint: 'Everyone',
        ),
      ],
    );
  }

  /// Sentinel for "no staff filter". `FSelect` keys items by value, so the
  /// unfiltered choice needs a value of its own rather than null.
  static const _everyone = '';
}

class _RangeSheet extends StatefulWidget {
  const _RangeSheet({required this.initial});

  final (DateTime, DateTime) initial;

  @override
  State<_RangeSheet> createState() => _RangeSheetState();
}

class _RangeSheetState extends State<_RangeSheet> {
  late (DateTime, DateTime)? _range = widget.initial;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final now = DateTime.now();

    return Padding(
      padding: const EdgeInsets.fromLTRB(gutter, 8, gutter, gutter),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Pick a date range', style: theme.titleStyle),
          const SizedBox(height: 4),
          Text(
            _range == null
                ? 'Tap a start date, then an end date.'
                : '${formatShortDay(_range!.$1)} to '
                      '${formatShortDay(_range!.$2)}',
            style: theme.mutedStyle,
          ),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              child: FCalendar.grid(
                control: FGridCalendarControl(
                  start: DateTime(2024),
                  end: now.add(const Duration(days: 1)),
                ),
                selectionControl: FDateSelectionControl.liftedRange(
                  value: _range,
                  onChange: (value) => setState(() => _range = value),
                ),
              ),
            ),
          ),
          const SizedBox(height: gutter),
          FButton(
            onPress: _range == null
                ? null
                : () => Navigator.of(context).pop(_range),
            child: const ButtonLabel('Apply'),
          ),
          const SizedBox(height: 8),
          FButton(
            variant: FButtonVariant.outline,
            onPress: () => Navigator.of(context).pop(),
            child: const ButtonLabel('Cancel'),
          ),
        ],
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({required this.rows});

  final List<AttendanceRecord> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (rows.isEmpty) {
      return const FCard(
        child: EmptyState(
          icon: FLucideIcons.search,
          title: 'No attendance in this range',
          message: 'Try widening the dates or clearing the staff filter.',
        ),
      );
    }

    final worked = rows.fold(
      Duration.zero,
      (sum, r) => sum + (r.workedDuration ?? Duration.zero),
    );

    return FTileGroup(
      label: Text(
        '${rows.length} record${rows.length == 1 ? '' : 's'}',
      ),
      description: Text('Total recorded time: ${formatDuration(worked)}'),
      children: [
        for (final row in rows)
          AttendanceRowTile(
            record: row,
            showDate: true,
            onReviewed: () => ref.invalidate(filteredAttendanceProvider),
          ),
      ],
    );
  }
}
