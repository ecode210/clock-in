import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

final _timeFormat = DateFormat('h:mm a');
final _dayFormat = DateFormat('EEE d MMM yyyy');
final _shortDayFormat = DateFormat('EEE d MMM');
final _monthYearFormat = DateFormat('MMMM yyyy');
final _exportStampFormat = DateFormat('dd MMM yyyy HH:mm');
final _exportDayFormat = DateFormat('dd MMM yyyy');

bool _timezonesReady = false;

/// Loads IANA zone data once at app start.
void initOrgTimezones() {
  if (_timezonesReady) return;
  tzdata.initializeTimeZones();
  _timezonesReady = true;
}

tz.Location _location(String timezone) {
  initOrgTimezones();
  try {
    return tz.getLocation(timezone);
  } catch (_) {
    return tz.UTC;
  }
}

/// Instant [value] shown in the organisation's working timezone.
DateTime inOrgTimezone(DateTime value, String timezone) {
  return tz.TZDateTime.from(value.toUtc(), _location(timezone));
}

/// "Right now" in the organisation timezone.
DateTime orgNow(String timezone) {
  return tz.TZDateTime.now(_location(timezone));
}

String formatTime(DateTime? value, {String? timezone}) {
  if (value == null) return '-';
  final shown = timezone == null ? value.toLocal() : inOrgTimezone(value, timezone);
  return _timeFormat.format(shown);
}

String formatDay(DateTime value, {String? timezone}) {
  final shown = timezone == null ? value : inOrgTimezone(value, timezone);
  return _dayFormat.format(shown);
}

String formatShortDay(DateTime value, {String? timezone}) {
  final shown = timezone == null ? value : inOrgTimezone(value, timezone);
  return _shortDayFormat.format(shown);
}

String formatMonthYear(DateTime value) => _monthYearFormat.format(value);

/// Timestamps in exported spreadsheets and PDFs: `13 Sep 2026 08:04`.
String formatExportStamp(DateTime? value, {String? timezone}) {
  if (value == null) return '-';
  final shown = timezone == null ? value.toLocal() : inOrgTimezone(value, timezone);
  return _exportStampFormat.format(shown);
}

/// Calendar days in export filenames and titles: `13 Sep 2026`.
String formatExportDay(DateTime value) => _exportDayFormat.format(value);

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
