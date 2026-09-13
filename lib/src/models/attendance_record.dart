import 'profile.dart';

/// How far an administrator has got with a clock-in's photo. Records start
/// unreviewed; flagging one is how a photo that does not look like the staff
/// member gets marked for follow-up.
enum ReviewStatus {
  unreviewed,
  reviewed,
  flagged;

  static ReviewStatus fromName(String? value) => switch (value) {
    'reviewed' => ReviewStatus.reviewed,
    'flagged' => ReviewStatus.flagged,
    _ => ReviewStatus.unreviewed,
  };
}

class AttendanceRecord {
  const AttendanceRecord({
    required this.id,
    required this.userId,
    required this.workDate,
    required this.clockInAt,
    required this.clockInDistanceMeters,
    required this.verifiedWithSelfie,
    required this.verifiedWithPasskey,
    this.reviewStatus = ReviewStatus.unreviewed,
    this.locationId,
    this.locationName,
    this.clockOutAt,
    this.clockOutDistanceMeters,
    this.clockInAccuracyMeters,
    this.clockOutAccuracyMeters,
    this.selfiePath,
    this.staff,
  });

  factory AttendanceRecord.fromMap(Map<String, dynamic> map) {
    final joined = map['profiles'];
    return AttendanceRecord(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      workDate: DateTime.parse(map['work_date'] as String),
      clockInAt: DateTime.parse(map['clock_in_at'] as String).toUtc(),
      clockInDistanceMeters:
          (map['clock_in_distance_meters'] as num?)?.toDouble() ?? 0,
      verifiedWithSelfie: (map['verified_with_selfie'] as bool?) ?? false,
      verifiedWithPasskey: (map['verified_with_passkey'] as bool?) ?? false,
      reviewStatus: ReviewStatus.fromName(map['review_status'] as String?),
      locationId: map['location_id'] as String?,
      locationName: map['location_name'] as String?,
      clockOutAt: map['clock_out_at'] == null
          ? null
          : DateTime.parse(map['clock_out_at'] as String).toUtc(),
      clockOutDistanceMeters: (map['clock_out_distance_meters'] as num?)
          ?.toDouble(),
      clockInAccuracyMeters: (map['clock_in_accuracy_meters'] as num?)
          ?.toDouble(),
      clockOutAccuracyMeters: (map['clock_out_accuracy_meters'] as num?)
          ?.toDouble(),
      selfiePath: map['selfie_path'] as String?,
      staff: joined is Map<String, dynamic>
          ? Profile.fromMap({'id': map['user_id'], ...joined})
          : null,
    );
  }

  final String id;
  final String userId;
  final DateTime workDate;
  final DateTime clockInAt;
  final double clockInDistanceMeters;
  final bool verifiedWithSelfie;
  final bool verifiedWithPasskey;
  final ReviewStatus reviewStatus;
  final String? locationId;

  /// Snapshot of the site name at clock-in, so renames and archives stay
  /// readable on history.
  final String? locationName;
  final DateTime? clockOutAt;
  final double? clockOutDistanceMeters;
  final double? clockInAccuracyMeters;
  final double? clockOutAccuracyMeters;
  final String? selfiePath;

  /// Populated when the row was fetched with the staff profile embedded.
  final Profile? staff;

  bool get isOpen => clockOutAt == null;

  Duration? get workedDuration => clockOutAt?.difference(clockInAt);

  String get displayLocationName => locationName ?? 'Unknown location';
}
