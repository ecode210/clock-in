import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_error.dart';
import '../../core/dev_log.dart';
import '../../core/formatters.dart';
import '../../routing/router.dart';
import '../../services/attendance_export.dart';
import '../../services/attendance_repository.dart';
import '../../services/staff_repository.dart';
import '../../services/supabase_providers.dart';
import '../shared/widgets.dart';
import 'attendance_history_screen.dart';

/// Lets an administrator download a visit-level attendance report for a chosen
/// date range, staff member, and file type.
class AttendanceExportScreen extends ConsumerStatefulWidget {
  const AttendanceExportScreen({
    this.initialFrom,
    this.initialTo,
    super.key,
  });

  /// `yyyy-mm-dd` from the calendar route, optional.
  final String? initialFrom;
  final String? initialTo;

  @override
  ConsumerState<AttendanceExportScreen> createState() =>
      _AttendanceExportScreenState();
}

class _AttendanceExportScreenState
    extends ConsumerState<AttendanceExportScreen> {
  static const _everyone = '';

  DateTime? _from;
  DateTime? _to;
  String? _userId;
  AttendanceExportFormat _format = AttendanceExportFormat.excel;
  bool _busy = false;
  String? _error;
  bool _seeded = false;

  @override
  Widget build(BuildContext context) {
    final todayAsync = ref.watch(orgTodayProvider);

    return AppScaffold(
      childPad: false,
      header: FHeader.nested(
        title: const Text('Export attendance'),
        prefixes: [
          FHeaderAction.back(
            onPress: () => context.go(AppRoutes.adminAttendance),
          ),
        ],
      ),
      child: AsyncSection(
        value: todayAsync,
        onRetry: () => ref.invalidate(orgTodayProvider),
        builder: (today) {
          _seedOnce(today);
          return PagePadding(
            maxWidth: 700,
            child: _ExportForm(
              today: today,
              from: _from!,
              to: _to!,
              userId: _userId,
              format: _format,
              busy: _busy,
              error: _error,
              onFromChanged: (value) => setState(() {
                _from = _dateOnly(value);
                _error = null;
                if (_from!.isAfter(_to!)) _to = _from;
              }),
              onToChanged: (value) => setState(() {
                _to = _dateOnly(value);
                _error = null;
                if (_to!.isBefore(_from!)) _from = _to;
              }),
              onStaffChanged: (value) => setState(() {
                _userId = value == null || value == _everyone ? null : value;
                _error = null;
              }),
              onFormatChanged: (value) => setState(() {
                _format = value;
                _error = null;
              }),
              onDownload: () => _download(today),
            ),
          );
        },
      ),
    );
  }

  void _seedOnce(DateTime today) {
    if (_seeded) return;
    _seeded = true;

    final parsedFrom = _parseDate(widget.initialFrom);
    final parsedTo = _parseDate(widget.initialTo);
    final monthStart = DateTime(today.year, today.month, 1);

    var from = parsedFrom ?? monthStart;
    var to = parsedTo ?? today;
    if (from.isAfter(today)) from = today;
    if (to.isAfter(today)) to = today;
    if (from.isAfter(to)) from = to;

    _from = from;
    _to = to;
    _userId = ref.read(attendanceStaffFilterProvider);
  }

  Future<void> _download(DateTime today) async {
    final from = _from!;
    final to = _to!;

    if (from.isAfter(to)) {
      setState(() => _error = 'The start date cannot be after the end date.');
      return;
    }
    if (to.isAfter(today)) {
      setState(() => _error = 'You can only export up to today.');
      return;
    }

    try {
      AttendanceExportService.ensureSpanWithinLimit(from: from, to: to);
    } catch (error) {
      if (!mounted) return;
      final app = toAppError(error);
      setState(() => _error = null);
      showSnack(context, app.message, isError: true);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      logAction('attendance.export', {
        'from': dateKey(from),
        'to': dateKey(to),
        'staff': _userId ?? 'everyone',
        'format': _format.name,
      });

      // Fetch one past the cap so we can refuse an incomplete file.
      final records = await ref.read(attendanceRepositoryProvider).allRecords(
        from: from,
        to: to,
        userId: _userId,
        limit: _format.maxRows + 1,
      );

      if (records.isEmpty) {
        throw const AppError(
          'There are no visits in that date range for the staff you chose. '
          'Try a wider range or a different person.',
          code: 'export_empty',
        );
      }

      AttendanceExportService.ensureWithinLimit(
        format: _format,
        rowCount: records.length,
      );

      final staff = ref.read(staffListProvider).value ?? const [];
      final staffLabel = _userId == null
          ? 'Everyone'
          : staff
                    .where((p) => p.id == _userId)
                    .map((p) => p.displayName)
                    .firstOrNull ??
                'Selected staff';

      final orgSettings = ref.read(orgSettingsProvider).value;
      final orgName = orgSettings?.orgName ?? 'Organisation';
      final timezone = orgSettings?.timezone ?? 'UTC';

      await const AttendanceExportService().download(
        AttendanceExportRequest(
          orgName: orgName,
          from: from,
          to: to,
          staffLabel: staffLabel,
          records: records,
          format: _format,
          timezone: timezone,
        ),
      );

      logDone('attendance.export', {'rows': records.length});
      if (mounted) {
        showSnack(
          context,
          'Downloaded ${records.length} '
          '${records.length == 1 ? 'visit' : 'visits'}.',
        );
      }
    } catch (error, stack) {
      logFail('attendance.export', error, stack);
      if (!mounted) return;
      final app = toAppError(error);
      if (app.code == 'export_too_large' || app.code == 'export_span') {
        showSnack(context, app.message, isError: true);
      } else {
        setState(() => _error = app.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static DateTime? _parseDate(String? value) {
    if (value == null || value.isEmpty) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return null;
    return DateTime(parsed.year, parsed.month, parsed.day);
  }
}

class _ExportForm extends ConsumerWidget {
  const _ExportForm({
    required this.today,
    required this.from,
    required this.to,
    required this.userId,
    required this.format,
    required this.busy,
    required this.error,
    required this.onFromChanged,
    required this.onToChanged,
    required this.onStaffChanged,
    required this.onFormatChanged,
    required this.onDownload,
  });

  final DateTime today;
  final DateTime from;
  final DateTime to;
  final String? userId;
  final AttendanceExportFormat format;
  final bool busy;
  final String? error;
  final ValueChanged<DateTime> onFromChanged;
  final ValueChanged<DateTime> onToChanged;
  final ValueChanged<String?> onStaffChanged;
  final ValueChanged<AttendanceExportFormat> onFormatChanged;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final staff = ref.watch(staffListProvider).value ?? const [];
    final earliest = DateTime(today.year - 5, 1, 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: 'What to include',
          subtitle:
              'Each visit is one row: who, where, when they clocked in and '
              'out, and the checks they passed.',
          children: [
            FDateField.calendar(
              label: const Text('From'),
              selectionControl: FDateSelectionControl.liftedSingle(
                value: from,
                toggleable: false,
                onChange: (value) {
                  if (value != null) onFromChanged(value);
                },
              ),
              calendar: FDateFieldGridCalendarProperties(
                control: FGridCalendarControl(start: earliest, end: today),
              ),
            ),
            const SizedBox(height: 14),
            FDateField.calendar(
              label: const Text('To'),
              selectionControl: FDateSelectionControl.liftedSingle(
                value: to,
                toggleable: false,
                onChange: (value) {
                  if (value != null) onToChanged(value);
                },
              ),
              calendar: FDateFieldGridCalendarProperties(
                control: FGridCalendarControl(start: earliest, end: today),
              ),
            ),
            const SizedBox(height: 14),
            FSelect<String>(
              items: {
                'Everyone': _AttendanceExportScreenState._everyone,
                for (final person in staff) person.displayName: person.id,
              },
              control: FSelectControl.lifted(
                value: userId ?? _AttendanceExportScreenState._everyone,
                onChange: onStaffChanged,
              ),
              label: const Text('Staff member'),
              hint: 'Everyone',
            ),
            const SizedBox(height: 14),
            FSelect<String>(
              items: const {
                'Excel spreadsheet (.xlsx)': 'excel',
                'PDF document (.pdf)': 'pdf',
              },
              control: FSelectControl.lifted(
                value: format.name,
                onChange: (value) {
                  if (value == 'pdf') {
                    onFormatChanged(AttendanceExportFormat.pdf);
                  } else if (value == 'excel') {
                    onFormatChanged(AttendanceExportFormat.excel);
                  }
                },
              ),
              label: const Text('File type'),
            ),
          ],
        ),
        if (error != null) ...[
          const SizedBox(height: gutter),
          ErrorNotice(error: AppError(error!)),
        ],
        const SizedBox(height: 20),
        FButton(
          size: FButtonSizeVariant.lg,
          onPress: busy ? null : onDownload,
          prefix: busy
              ? const FCircularProgress()
              : const Icon(FLucideIcons.download),
          child: ButtonLabel(busy ? 'Preparing…' : 'Download'),
        ),
      ],
    );
  }
}
