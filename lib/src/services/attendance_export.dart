import 'package:excel/excel.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/app_error.dart';
import '../core/download_bytes.dart';
import '../core/formatters.dart';
import '../models/attendance_record.dart';

/// Inclusive calendar-day cap for one export. Stops a 5-year "everyone"
/// download from scanning the table only to trip the row limit.
const attendanceExportMaxSpanDays = 366;

/// Client-side generation limits for Flutter web. PDF layout is much heavier
/// than a spreadsheet, so its cap is lower.
enum AttendanceExportFormat {
  excel(maxRows: 5000),
  pdf(maxRows: 1000);

  const AttendanceExportFormat({required this.maxRows});

  /// Soft ceiling: fetch one extra row; if we hit it, refuse rather than
  /// silently truncate.
  final int maxRows;

  String get fileLabel => switch (this) {
    AttendanceExportFormat.excel => 'spreadsheet',
    AttendanceExportFormat.pdf => 'PDF',
  };
}

/// Friendly column layout shared by Excel and PDF. No UUIDs, no raw GPS.
class AttendanceExportRow {
  const AttendanceExportRow({
    required this.name,
    required this.staffId,
    required this.email,
    required this.location,
    required this.clockIn,
    required this.clockOut,
    required this.worked,
    required this.distance,
    required this.passkey,
    required this.livePhoto,
    required this.review,
  });

  factory AttendanceExportRow.fromRecord(
    AttendanceRecord record, {
    required String timezone,
  }) {
    final staff = record.staff;
    return AttendanceExportRow(
      name: staff?.displayName ?? 'Unknown staff member',
      staffId: (staff?.staffId?.trim().isNotEmpty ?? false)
          ? staff!.staffId!.trim()
          : '-',
      email: (staff?.email?.trim().isNotEmpty ?? false)
          ? staff!.email!.trim()
          : '-',
      location: record.displayLocationName,
      clockIn: formatExportStamp(record.clockInAt, timezone: timezone),
      clockOut: formatExportStamp(record.clockOutAt, timezone: timezone),
      worked: record.isOpen
          ? 'On shift'
          : formatDuration(record.workedDuration),
      distance: formatDistance(record.clockInDistanceMeters),
      passkey: record.verifiedWithPasskey ? 'Yes' : 'No',
      livePhoto: record.verifiedWithSelfie ? 'Yes' : 'No',
      review: switch (record.reviewStatus) {
        ReviewStatus.unreviewed => 'Unreviewed',
        ReviewStatus.reviewed => 'Reviewed',
        ReviewStatus.flagged => 'Flagged',
      },
    );
  }

  final String name;
  final String staffId;
  final String email;
  final String location;
  final String clockIn;
  final String clockOut;
  final String worked;
  final String distance;
  final String passkey;
  final String livePhoto;
  final String review;

  List<String> get cells => [
    name,
    staffId,
    email,
    location,
    clockIn,
    clockOut,
    worked,
    distance,
    passkey,
    livePhoto,
    review,
  ];
}

const attendanceExportHeaders = <String>[
  'Name',
  'Staff ID',
  'Email',
  'Location',
  'Clock in',
  'Clock out',
  'Time worked',
  'Distance from site',
  'Passkey',
  'Live photo',
  'Photo review',
];

class AttendanceExportRequest {
  const AttendanceExportRequest({
    required this.orgName,
    required this.from,
    required this.to,
    required this.staffLabel,
    required this.records,
    required this.format,
    required this.timezone,
  });

  final String orgName;
  final DateTime from;
  final DateTime to;
  final String staffLabel;
  final List<AttendanceRecord> records;
  final AttendanceExportFormat format;
  final String timezone;

  String get filenameBase {
    final range = '${formatExportDay(from)} to ${formatExportDay(to)}';
    final staff = staffLabel == 'Everyone' ? '' : ' - $staffLabel';
    return 'Attendance $range$staff';
  }
}

class AttendanceExportService {
  const AttendanceExportService();

  /// Throws [AppError] with code `export_span` when the inclusive date range
  /// is longer than [attendanceExportMaxSpanDays].
  static void ensureSpanWithinLimit({
    required DateTime from,
    required DateTime to,
  }) {
    final days = to.difference(from).inDays + 1;
    if (days <= attendanceExportMaxSpanDays) return;
    throw const AppError(
      'You can export at most 12 months at a time. '
      'Shorten the date range and try again.',
      code: 'export_span',
    );
  }

  /// Throws [AppError] with code `export_too_large` when [records] exceeds the
  /// format's [AttendanceExportFormat.maxRows].
  static void ensureWithinLimit({
    required AttendanceExportFormat format,
    required int rowCount,
  }) {
    if (rowCount <= format.maxRows) return;
    throw AppError(
      'That export has too many visits for a ${format.fileLabel}. '
      'Narrow the date range or choose one staff member, then try again.',
      code: 'export_too_large',
      technical: 'rows=$rowCount max=${format.maxRows} format=${format.name}',
    );
  }

  Future<void> download(AttendanceExportRequest request) async {
    ensureWithinLimit(
      format: request.format,
      rowCount: request.records.length,
    );
    switch (request.format) {
      case AttendanceExportFormat.excel:
        await _downloadExcel(request);
      case AttendanceExportFormat.pdf:
        await _downloadPdf(request);
    }
  }

  Future<void> _downloadExcel(AttendanceExportRequest request) async {
    final excel = Excel.createExcel();
    final defaultName = excel.getDefaultSheet();
    if (defaultName != null) {
      excel.rename(defaultName, 'Attendance');
    }
    final sheet = excel['Attendance'];

    sheet.appendRow(
      attendanceExportHeaders.map((h) => TextCellValue(h)).toList(),
    );

    for (final record in request.records) {
      final row = AttendanceExportRow.fromRecord(
        record,
        timezone: request.timezone,
      );
      sheet.appendRow(row.cells.map((c) => TextCellValue(c)).toList());
    }

    // Freeze the header so scrolling keeps the column names visible.
    sheet.setColumnAutoFit(0);
    for (var i = 0; i < attendanceExportHeaders.length; i++) {
      sheet.setColumnWidth(i, _excelWidths[i]);
    }

    excel.save(fileName: '${request.filenameBase}.xlsx');
  }

  Future<void> _downloadPdf(AttendanceExportRequest request) async {
    final rows = request.records
        .map(
          (record) => AttendanceExportRow.fromRecord(
            record,
            timezone: request.timezone,
          ),
        )
        .toList(growable: false);
    final generatedAt = formatExportStamp(
      DateTime.now().toUtc(),
      timezone: request.timezone,
    );

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(28),
        header: (context) {
          if (context.pageNumber > 1) {
            return pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 10),
              child: pw.Text(
                '${request.orgName} - Attendance - page ${context.pageNumber}',
                style: pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
              ),
            );
          }
          return pw.SizedBox();
        },
        build: (context) => [
          pw.Text(
            request.orgName,
            style: pw.TextStyle(fontSize: 11, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'Attendance',
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            'From ${formatExportDay(request.from)} to '
            '${formatExportDay(request.to)}',
            style: const pw.TextStyle(fontSize: 11),
          ),
          pw.Text(
            'Staff: ${request.staffLabel}',
            style: const pw.TextStyle(fontSize: 11),
          ),
          pw.Text(
            'Generated $generatedAt - ${rows.length} '
            '${rows.length == 1 ? 'visit' : 'visits'}',
            style: pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 16),
          pw.TableHelper.fromTextArray(
            headers: attendanceExportHeaders,
            data: [for (final row in rows) row.cells],
            headerStyle: pw.TextStyle(
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey800),
            cellStyle: const pw.TextStyle(fontSize: 7.5),
            cellAlignment: pw.Alignment.centerLeft,
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 3,
            ),
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.4),
            headerCount: 1,
          ),
        ],
      ),
    );

    final bytes = await doc.save();
    downloadBytes(
      bytes: bytes,
      filename: '${request.filenameBase}.pdf',
      mimeType: 'application/pdf',
    );
  }

  static const _excelWidths = <double>[
    22, // Name
    12, // Staff ID
    28, // Email
    18, // Location
    18, // Clock in
    18, // Clock out
    12, // Time worked
    16, // Distance
    10, // Passkey
    10, // Live photo
    14, // Photo review
  ];
}
