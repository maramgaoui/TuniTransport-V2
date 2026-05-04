class User {
  final String uid;
  final String email;
  final String? username;
  final String? firstName;
  final String? lastName;
  final String? avatarId;
  final String? customAvatarUrl;
  final String? city;
  final String status;
  final DateTime? banUntil;
  // Role: 'user' | 'admin' | 'super_admin'
  final String role;
  // Admin sub-type: 'metro_train' | 'bus' | 'taxicollectifs' | 'louage'
  final String? adminType;
  final String? matricule;
  final List<String> permissions;

  User({
    required this.uid,
    required this.email,
    this.username,
    this.firstName,
    this.lastName,
    this.avatarId,
    this.customAvatarUrl,
    this.city,
    this.status = 'active',
    this.banUntil,
    this.role = 'user',
    this.adminType,
    this.matricule,
    this.permissions = const [],
  });

  // Convert User to JSON for Firestore
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'uid': uid,
      'email': email,
      'role': role,
    };
    if (username != null) map['username'] = username;
    if (firstName != null) map['firstName'] = firstName;
    if (lastName != null) map['lastName'] = lastName;
    if (avatarId != null) map['avatarId'] = avatarId;
    if (customAvatarUrl != null) map['customAvatarUrl'] = customAvatarUrl;
    if (city != null) map['city'] = city;
    map['status'] = status;
    if (banUntil != null) map['banUntil'] = banUntil!.toIso8601String();
    if (adminType != null) map['adminType'] = adminType;
    if (matricule != null) map['matricule'] = matricule;
    if (permissions.isNotEmpty) map['permissions'] = permissions;
    return map;
  }

  // Create User from Firestore document
  factory User.fromMap(Map<String, dynamic> map) {
    DateTime? parsedBanUntil;
    final banRaw = map['banUntil'];
    if (banRaw is DateTime) {
      parsedBanUntil = banRaw;
    } else if (banRaw is String && banRaw.isNotEmpty) {
      parsedBanUntil = DateTime.tryParse(banRaw);
    }
    // Firestore Timestamp support (imported as dynamic from cloud_firestore)
    if (banRaw != null && parsedBanUntil == null) {
      try {
        parsedBanUntil = (banRaw as dynamic).toDate() as DateTime;
      } catch (_) {}
    }

    return User(
      uid: map['uid'] ?? '',
      email: map['email'] ?? '',
      username: map['username'],
      firstName: map['firstName'],
      lastName: map['lastName'],
      avatarId: map['avatarId'],
      customAvatarUrl: map['customAvatarUrl'],
      city: map['city'],
      status: (map['status'] ?? 'active').toString(),
      banUntil: parsedBanUntil,
      role: (map['role'] ?? 'user').toString(),
      adminType: map['adminType'] as String?,
      matricule: map['matricule'] as String?,
      permissions: List<String>.from(map['permissions'] ?? const <String>[]),
    );
  }

  // Copy with method for updates
  User copyWith({
    String? uid,
    String? email,
    String? username,
    String? firstName,
    String? lastName,
    String? avatarId,
    String? customAvatarUrl,
    String? city,
    String? status,
    DateTime? banUntil,
    bool clearBanUntil = false,
    String? role,
    String? adminType,
    String? matricule,
    List<String>? permissions,
  }) {
    return User(
      uid: uid ?? this.uid,
      email: email ?? this.email,
      username: username ?? this.username,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      avatarId: avatarId ?? this.avatarId,
      customAvatarUrl: customAvatarUrl ?? this.customAvatarUrl,
      city: city ?? this.city,
      status: status ?? this.status,
      banUntil: clearBanUntil ? null : (banUntil ?? this.banUntil),
      role: role ?? this.role,
      adminType: adminType ?? this.adminType,
      matricule: matricule ?? this.matricule,
      permissions: permissions ?? this.permissions,
    );
  }

  // Get full name
  String get fullName {
    if (firstName != null && lastName != null) {
      return '$firstName $lastName';
    } else if (firstName != null) {
      return firstName!;
    } else if (lastName != null) {
      return lastName!;
    }
    return email;
  }

  @override
  String toString() =>
      'User(uid: $uid, email: $email, name: $fullName)';
}
