/// The single row of `org_settings`: organisation identity, timezone, and
/// which fraud-prevention checks are switched on. Clock-in sites live in
/// `locations`, not here.
class OrgSettings {
  const OrgSettings({
    required this.orgName,
    required this.timezone,
    required this.requireSelfie,
    required this.requirePasskey,
    required this.passkeyFreshnessSeconds,
    this.maxAccuracyMeters,
  });

  factory OrgSettings.fromMap(Map<String, dynamic> map) => OrgSettings(
    orgName: (map['org_name'] as String?) ?? 'My Organisation',
    timezone: (map['timezone'] as String?) ?? 'UTC',
    requireSelfie: (map['require_selfie'] as bool?) ?? false,
    requirePasskey: (map['require_passkey'] as bool?) ?? false,
    passkeyFreshnessSeconds:
        (map['passkey_freshness_seconds'] as num?)?.toInt() ?? 300,
    maxAccuracyMeters: (map['max_accuracy_meters'] as num?)?.toInt(),
  );

  final String orgName;
  final String timezone;
  final bool requireSelfie;
  final bool requirePasskey;
  final int passkeyFreshnessSeconds;
  final int? maxAccuracyMeters;

  OrgSettings copyWith({
    String? orgName,
    String? timezone,
    bool? requireSelfie,
    bool? requirePasskey,
    int? passkeyFreshnessSeconds,
    int? maxAccuracyMeters,
    bool clearMaxAccuracy = false,
  }) => OrgSettings(
    orgName: orgName ?? this.orgName,
    timezone: timezone ?? this.timezone,
    requireSelfie: requireSelfie ?? this.requireSelfie,
    requirePasskey: requirePasskey ?? this.requirePasskey,
    passkeyFreshnessSeconds:
        passkeyFreshnessSeconds ?? this.passkeyFreshnessSeconds,
    maxAccuracyMeters: clearMaxAccuracy
        ? null
        : (maxAccuracyMeters ?? this.maxAccuracyMeters),
  );

  Map<String, dynamic> toUpdateMap() => {
    'org_name': orgName,
    'timezone': timezone,
    'require_selfie': requireSelfie,
    'require_passkey': requirePasskey,
    'passkey_freshness_seconds': passkeyFreshnessSeconds,
    'max_accuracy_meters': maxAccuracyMeters,
  };
}
