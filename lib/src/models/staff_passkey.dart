/// A staff member's registered passkey as an administrator sees it. The
/// credential itself stays in the database and never reaches the client; only
/// the label and the dates do.
class StaffPasskey {
  const StaffPasskey({
    required this.friendlyName,
    required this.createdAt,
    required this.backedUp,
    this.lastUsedAt,
  });

  factory StaffPasskey.fromMap(Map<String, dynamic> map) => StaffPasskey(
    friendlyName: switch (map['friendly_name']) {
      final String name when name.trim().isNotEmpty => name.trim(),
      _ => 'Passkey',
    },
    createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
    backedUp: (map['backed_up'] as bool?) ?? false,
    lastUsedAt: map['last_used_at'] == null
        ? null
        : DateTime.parse(map['last_used_at'] as String).toLocal(),
  );

  final String friendlyName;
  final DateTime createdAt;

  /// The authenticator syncs this credential to the staff member's other
  /// devices, so "one passkey" does not necessarily mean "one phone".
  final bool backedUp;

  final DateTime? lastUsedAt;
}

enum PasskeyEventAction {
  enrolled,
  deleted,
  reset;

  static PasskeyEventAction fromName(String? value) => switch (value) {
    'deleted' => PasskeyEventAction.deleted,
    'reset' => PasskeyEventAction.reset,
    _ => PasskeyEventAction.enrolled,
  };

  String get label => switch (this) {
    PasskeyEventAction.enrolled => 'Device enrolled',
    PasskeyEventAction.deleted => 'Passkey removed',
    PasskeyEventAction.reset => 'Reset by administrator',
  };
}

/// One entry in the passkey audit trail. Enrolments carry no actor because
/// they happen on a GoTrue connection with no session attached; a reset
/// carries the administrator who performed it.
class PasskeyEvent {
  const PasskeyEvent({
    required this.id,
    required this.action,
    required this.createdAt,
    this.friendlyName,
    this.actorName,
  });

  factory PasskeyEvent.fromMap(Map<String, dynamic> map) {
    final actor = map['actor'];
    return PasskeyEvent(
      id: map['id'] as String,
      action: PasskeyEventAction.fromName(map['action'] as String?),
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
      friendlyName: map['friendly_name'] as String?,
      actorName: actor is Map<String, dynamic>
          ? actor['full_name'] as String?
          : null,
    );
  }

  final String id;
  final PasskeyEventAction action;
  final DateTime createdAt;
  final String? friendlyName;
  final String? actorName;
}
