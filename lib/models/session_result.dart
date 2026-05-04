enum SessionRole { guest, user, admin, superAdmin }

class SessionResult {
  const SessionResult({
    required this.role,
    this.adminRole,
    this.adminMatricule,
    this.adminName,
    this.adminType,
  });

  final SessionRole role;
  /// Admin sub-type: 'metro_train' | 'bus' | 'taxicollectifs' | 'louage'
  final String? adminType;
  /// Legacy alias kept for existing callers (equals adminType for new accounts)
  final String? adminRole;
  final String? adminMatricule;
  final String? adminName;

  bool get isAdmin => role == SessionRole.admin;
  bool get isSuperAdmin => role == SessionRole.superAdmin;
  bool get isGuest => role == SessionRole.guest;
  bool get isUser => role == SessionRole.user;
  bool get isPrivileged => isAdmin || isSuperAdmin;
}
