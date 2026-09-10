import 'package:intl/intl.dart';

final _timeFormat = DateFormat('h:mm a');
final _dayFormat = DateFormat('EEE d MMM yyyy');
final _shortDayFormat = DateFormat('EEE d MMM');
final _monthYearFormat = DateFormat('MMMM yyyy');

String formatTime(DateTime? value) =>
    value == null ? '-' : _timeFormat.format(value);

String formatDay(DateTime value) => _dayFormat.format(value);

String formatShortDay(DateTime value) => _shortDayFormat.format(value);

String formatMonthYear(DateTime value) => _monthYearFormat.format(value);

/// Calendar and query key for a date-only value: `2026-09-10`.
///
/// Uses the [DateTime]'s own calendar fields, so a Postgres `date` parsed as
/// UTC midnight and a local `DateTime(y, m, d)` cell still share a key.
String dateKey(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

/// Distances are read at a glance, so keep them short: "42 m", "1.3 km".
String formatDistance(double? meters) {
  if (meters == null) return '-';
  if (meters < 1000) return '${meters.round()} m';
  return '${(meters / 1000).toStringAsFixed(meters < 10000 ? 1 : 0)} km';
}

String formatDuration(Duration? duration) {
  if (duration == null) return '-';
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours == 0) return '${minutes}m';
  return '${hours}h ${minutes}m';
}

/// Used for the live counter while a shift is open.
String formatElapsed(Duration duration) {
  final hours = duration.inHours.toString().padLeft(2, '0');
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}
