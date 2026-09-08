enum UserRole {
  staff,
  admin;

  static UserRole fromName(String? value) =>
      value == 'admin' ? UserRole.admin : UserRole.staff;

  String get label => this == UserRole.admin ? 'Administrator' : 'Staff';
}

class Profile {
  const Profile({
    required this.id,
    required this.fullName,
    required this.role,
    required this.isActive,
    this.mustChangePassword = false,
    this.email,
    this.staffId,
  });

  factory Profile.fromMap(Map<String, dynamic> map) => Profile(
    id: map['id'] as String,
    fullName: (map['full_name'] as String?) ?? '',
    role: UserRole.fromName(map['role'] as String?),
    isActive: (map['is_active'] as bool?) ?? true,
    mustChangePassword: (map['must_change_password'] as bool?) ?? false,
    email: map['email'] as String?,
    staffId: map['staff_id'] as String?,
  );

  final String id;
  final String fullName;
  final UserRole role;
  final bool isActive;

  /// Set whenever an administrator issues a temporary password. Until the
  /// staff member replaces it the administrator knows their password, so the
  /// app lets them do nothing else.
  final bool mustChangePassword;

  final String? email;
  final String? staffId;

  bool get isAdmin => role == UserRole.admin;

  /// Something human to greet the user with when the name is not filled in.
  String get displayName {
    if (fullName.trim().isNotEmpty) return fullName.trim();
    return email ?? 'Staff member';
  }

  String get initials {
    final parts = displayName
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }
}
