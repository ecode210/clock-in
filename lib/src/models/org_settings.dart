import 'package:latlong2/latlong.dart';

/// The single row of `org_settings`: where staff may clock in from and which
/// fraud-prevention checks are switched on.
class OrgSettings {
  const OrgSettings({
    required this.orgName,
    required this.locationName,
    required this.timezone,
    required this.radiusMeters,
    required this.requireSelfie,
    required this.requirePasskey,
    required this.passkeyFreshnessSeconds,
    required this.allowClockOutOutsideGeofence,
    this.geofenceLat,
    this.geofenceLng,
    this.maxAccuracyMeters,
  });

  factory OrgSettings.fromMap(Map<String, dynamic> map) => OrgSettings(
    orgName: (map['org_name'] as String?) ?? 'My Organisation',
    locationName: (map['location_name'] as String?) ?? 'Main Site',
    timezone: (map['timezone'] as String?) ?? 'UTC',
    radiusMeters: (map['radius_meters'] as num?)?.toInt() ?? 100,
    requireSelfie: (map['require_selfie'] as bool?) ?? false,
    requirePasskey: (map['require_passkey'] as bool?) ?? false,
    passkeyFreshnessSeconds:
        (map['passkey_freshness_seconds'] as num?)?.toInt() ?? 300,
    allowClockOutOutsideGeofence:
        (map['allow_clock_out_outside_geofence'] as bool?) ?? false,
    geofenceLat: (map['geofence_lat'] as num?)?.toDouble(),
    geofenceLng: (map['geofence_lng'] as num?)?.toDouble(),
    maxAccuracyMeters: (map['max_accuracy_meters'] as num?)?.toInt(),
  );

  final String orgName;
  final String locationName;
  final String timezone;
  final int radiusMeters;
  final bool requireSelfie;
  final bool requirePasskey;
  final int passkeyFreshnessSeconds;
  final bool allowClockOutOutsideGeofence;
  final double? geofenceLat;
  final double? geofenceLng;
  final int? maxAccuracyMeters;

  bool get isGeofenceConfigured => geofenceLat != null && geofenceLng != null;

  LatLng? get center => isGeofenceConfigured
      ? LatLng(geofenceLat!, geofenceLng!)
      : null;

  OrgSettings copyWith({
    String? orgName,
    String? locationName,
    String? timezone,
    int? radiusMeters,
    bool? requireSelfie,
    bool? requirePasskey,
    int? passkeyFreshnessSeconds,
    bool? allowClockOutOutsideGeofence,
    double? geofenceLat,
    double? geofenceLng,
    int? maxAccuracyMeters,
    bool clearMaxAccuracy = false,
  }) => OrgSettings(
    orgName: orgName ?? this.orgName,
    locationName: locationName ?? this.locationName,
    timezone: timezone ?? this.timezone,
    radiusMeters: radiusMeters ?? this.radiusMeters,
    requireSelfie: requireSelfie ?? this.requireSelfie,
    requirePasskey: requirePasskey ?? this.requirePasskey,
    passkeyFreshnessSeconds:
        passkeyFreshnessSeconds ?? this.passkeyFreshnessSeconds,
    allowClockOutOutsideGeofence:
        allowClockOutOutsideGeofence ?? this.allowClockOutOutsideGeofence,
    geofenceLat: geofenceLat ?? this.geofenceLat,
    geofenceLng: geofenceLng ?? this.geofenceLng,
    maxAccuracyMeters: clearMaxAccuracy
        ? null
        : (maxAccuracyMeters ?? this.maxAccuracyMeters),
  );

  Map<String, dynamic> toUpdateMap() => {
    'org_name': orgName,
    'location_name': locationName,
    'timezone': timezone,
    'radius_meters': radiusMeters,
    'require_selfie': requireSelfie,
    'require_passkey': requirePasskey,
    'passkey_freshness_seconds': passkeyFreshnessSeconds,
    'allow_clock_out_outside_geofence': allowClockOutOutsideGeofence,
    'geofence_lat': geofenceLat,
    'geofence_lng': geofenceLng,
    'max_accuracy_meters': maxAccuracyMeters,
  };
}
