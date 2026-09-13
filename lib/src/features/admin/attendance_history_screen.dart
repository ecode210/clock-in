import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../../routing/router.dart';
import '../../services/attendance_repository.dart';
import '../../services/staff_repository.dart';
import '../shared/widgets.dart';

/// Staff filter for the attendance calendar. Null means every staff member.
class AttendanceStaffFilter extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? userId) => state = userId;
}

final attendanceStaffFilterProvider =
    NotifierProvider<AttendanceStaffFilter, String?>(AttendanceStaffFilter.new);

/// Visit counts for one organisation month, keyed by year, month, and optional
/// staff id. Changing month is a new page of data rather than a date range.
final monthVisitCountsProvider =
    FutureProvider.family<Map<String, int>, (int, int, String?)>((ref, key) {
      final (year, month, userId) = key;
      return ref
          .watch(attendanceRepositoryProvider)
          .monthVisitCounts(year: year, month: month, userId: userId);
    });

class AttendanceHistoryScreen extends ConsumerWidget {
  const AttendanceHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(orgTodayProvider);

    return AppScaffold(
      childPad: false,
      header: FHeader(
        title: const Text('Attendance'),
        suffixes: [
          HeaderAction(
            icon: FLucideIcons.refreshCw,
            semanticsLabel: 'Refresh',
            onPress: () => ref.invalidate(monthVisitCountsProvider),
          ),
        ],
      ),
      child: AsyncSection(
        value: today,
        onRetry: () => ref.invalidate(orgTodayProvider),
        builder: (orgToday) => _MonthBody(today: orgToday),
      ),
    );
  }
}

class _MonthBody extends ConsumerStatefulWidget {
  const _MonthBody({required this.today});

  final DateTime today;

  @override
  ConsumerState<_MonthBody> createState() => _MonthBodyState();
}

class _MonthBodyState extends ConsumerState<_MonthBody> {
  late DateTime _month = DateTime(widget.today.year, widget.today.month);

  bool get _atCurrentMonth =>
      _month.year == widget.today.year && _month.month == widget.today.month;

  void _shiftMonth(int delta) {
    final next = DateTime(_month.year, _month.month + delta);
    final current = DateTime(widget.today.year, widget.today.month);
    if (next.isAfter(current)) return;
    setState(() => _month = next);
  }

  @override
  Widget build(BuildContext context) {
    final userId = ref.watch(attendanceStaffFilterProvider);
    final counts = ref.watch(
      monthVisitCountsProvider((_month.year, _month.month, userId)),
    );

    return PagePadding(
      maxWidth: 700,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StaffFilter(month: _month, today: widget.today),
          const SizedBox(height: gutter),
          AsyncSection(
            value: counts,
            onRetry: () => ref.invalidate(
              monthVisitCountsProvider((_month.year, _month.month, userId)),
            ),
            builder: (dayCounts) => _MonthCalendar(
              month: _month,
              today: widget.today,
              counts: dayCounts,
              atCurrentMonth: _atCurrentMonth,
              onPrev: () => _shiftMonth(-1),
              onNext: _atCurrentMonth ? null : () => _shiftMonth(1),
              onSelect: (day) =>
                  context.go(AppRoutes.adminAttendanceDay(dateKey(day))),
              onSelectOverflow: (day) {
                final current = DateTime(
                  widget.today.year,
                  widget.today.month,
                );
                final target = DateTime(day.year, day.month);
                if (target.isAfter(current)) return;
                setState(() => _month = target);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StaffFilter extends ConsumerWidget {
  const _StaffFilter({required this.month, required this.today});

  final DateTime month;
  final DateTime today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userId = ref.watch(attendanceStaffFilterProvider);
    final staff = ref.watch(staffListProvider).value ?? const [];

    final from = DateTime(month.year, month.month, 1);
    final monthEnd = DateTime(month.year, month.month + 1, 0);
    final to = monthEnd.isAfter(today) ? today : monthEnd;

    return SectionCard(
      title: 'Filter',
      trailing: FButton(
        variant: FButtonVariant.primary,
        size: FButtonSizeVariant.sm,
        prefix: const Icon(FLucideIcons.download),
        onPress: () => context.go(
          '${AppRoutes.adminAttendanceExport}'
          '?from=${dateKey(from)}&to=${dateKey(to)}',
        ),
        child: const Text('Export'),
      ),
      children: [
        FSelect<String>(
          items: {
            'Everyone': _everyone,
            for (final person in staff) person.displayName: person.id,
          },
          control: FSelectControl.lifted(
            value: userId ?? _everyone,
            onChange: (value) => ref
                .read(attendanceStaffFilterProvider.notifier)
                .set(value == null || value == _everyone ? null : value),
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

class _MonthCalendar extends StatelessWidget {
  const _MonthCalendar({
    required this.month,
    required this.today,
    required this.counts,
    required this.atCurrentMonth,
    required this.onPrev,
    required this.onNext,
    required this.onSelect,
    required this.onSelectOverflow,
  });

  final DateTime month;
  final DateTime today;
  final Map<String, int> counts;
  final bool atCurrentMonth;
  final VoidCallback onPrev;
  final VoidCallback? onNext;
  final ValueChanged<DateTime> onSelect;
  final ValueChanged<DateTime> onSelectOverflow;

  static const _weekdays = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final days = _gridDays(month);
    final todayKey = dateKey(today);

    return ContentCard(
      child: Column(
        children: [
          Row(
            children: [
              FButton.icon(
                variant: FButtonVariant.outline,
                size: FButtonSizeVariant.sm,
                semanticsLabel: 'Previous month',
                onPress: onPrev,
                child: const Icon(FLucideIcons.chevronLeft),
              ),
              Expanded(
                child: Text(
                  formatMonthYear(month),
                  textAlign: TextAlign.center,
                  style: theme.titleStyle,
                ),
              ),
              FButton.icon(
                variant: FButtonVariant.outline,
                size: FButtonSizeVariant.sm,
                semanticsLabel: 'Next month',
                onPress: onNext,
                child: const Icon(FLucideIcons.chevronRight),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (var i = 0; i < _weekdays.length; i++)
                Expanded(
                  child: Text(
                    _weekdays[i],
                    textAlign: TextAlign.center,
                    style: theme.captionStyle.copyWith(
                      fontWeight: FontWeight.w600,
                      color: i == 0
                          ? theme.colors.destructive
                          : theme.colors.mutedForeground,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          for (var week = 0; week < 6; week++) ...[
            if (week > 0) const SizedBox(height: 4),
            Row(
              children: [
                for (var dow = 0; dow < 7; dow++)
                  Expanded(
                    child: _DayCell(
                      day: days[week * 7 + dow],
                      month: month,
                      todayKey: todayKey,
                      count: counts[dateKey(days[week * 7 + dow])] ?? 0,
                      onSelect: onSelect,
                      onSelectOverflow: onSelectOverflow,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Six Sunday-first weeks covering [month], including greyed overflow days
  /// from the months on either side so the grid stays a stable height.
  static List<DateTime> _gridDays(DateTime month) {
    final first = DateTime(month.year, month.month, 1);
    final start = first.subtract(Duration(days: first.weekday % 7));
    return [
      for (var i = 0; i < 42; i++)
        DateTime(start.year, start.month, start.day + i),
    ];
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.month,
    required this.todayKey,
    required this.count,
    required this.onSelect,
    required this.onSelectOverflow,
  });

  final DateTime day;
  final DateTime month;
  final String todayKey;
  final int count;
  final ValueChanged<DateTime> onSelect;
  final ValueChanged<DateTime> onSelectOverflow;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final inMonth = day.month == month.month && day.year == month.year;
    final isToday = dateKey(day) == todayKey;
    final isSunday = day.weekday == DateTime.sunday;
    final dateColor = isSunday
        ? (inMonth
              ? theme.colors.destructive
              : theme.colors.disable(theme.colors.destructive))
        : (inMonth ? theme.colors.foreground : theme.colors.mutedForeground);

    final dateNumber = Text(
      '${day.day}',
      style: theme.bodyStyle.copyWith(
        fontWeight: FontWeight.w700,
        fontSize: 16,
        height: 1,
        color: dateColor,
      ),
    );

    return Semantics(
      button: true,
      label: _label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: inMonth ? () => onSelect(day) : () => onSelectOverflow(day),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Column(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: isToday && inMonth
                    ? BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: theme.colors.foreground,
                          width: 1.5,
                        ),
                      )
                    : null,
                child: dateNumber,
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 24,
                child: inMonth && count > 0
                    ? FittedBox(
                        fit: BoxFit.scaleDown,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.colors.foreground,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(6, 3, 6, 3),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '$count',
                                  style: theme.bodyStyle.copyWith(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 18,
                                    height: 1,
                                    color: theme.colors.background,
                                  ),
                                ),
                                const SizedBox(width: 3),
                                Icon(
                                  FLucideIcons.clock,
                                  size: 18,
                                  color: theme.colors.background,
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _label {
    final stamp = formatDay(day);
    if (count == 0) return stamp;
    return '$stamp, $count clock-in${count == 1 ? '' : 's'}';
  }
}
