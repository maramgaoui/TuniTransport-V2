import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../constants/firestore_collections.dart';
import '../../utils/firebase_error_handler.dart';
import '../../utils/role_guard.dart';

class AdminAuthResult {
  final bool isAuthenticated;
  final String? role;
  final String? name;
  final String? matricule;
  final String? errorMessage;

  const AdminAuthResult({
    required this.isAuthenticated,
    this.role,
    this.name,
    this.matricule,
    this.errorMessage,
  });
}

class AdminAuthController {
  AdminAuthController({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    SharedPreferences? sharedPreferences,
  })
    : _firestore = firestore ?? FirebaseFirestore.instance,
      _auth = auth ?? FirebaseAuth.instance,
      _sharedPreferences = sharedPreferences;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final SharedPreferences? _sharedPreferences;

  // Client-side lockout: immediate feedback before Auth round-trip, 5 attempts then exponential back-off.
  static const int _kLockoutThreshold = 5;
  static const String _failedAttemptsKey = 'admin_auth.failed_attempts';
  static const String _lockedUntilEpochKey = 'admin_auth.locked_until_epoch';
  int _failedAttempts = 0;
  DateTime? _lockedUntil;
  bool _lockoutStateLoaded = false;

  Future<SharedPreferences> _prefs() async {
    return _sharedPreferences ?? await SharedPreferences.getInstance();
  }

  Future<void> _restoreLockoutStateIfNeeded() async {
    if (_lockoutStateLoaded) {
      return;
    }

    final prefs = await _prefs();
    _failedAttempts = prefs.getInt(_failedAttemptsKey) ?? 0;
    final lockedUntilEpoch = prefs.getInt(_lockedUntilEpochKey);
    _lockedUntil = lockedUntilEpoch == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(lockedUntilEpoch);
    _lockoutStateLoaded = true;
  }

  Future<void> _persistLockoutState() async {
    final prefs = await _prefs();
    await prefs.setInt(_failedAttemptsKey, _failedAttempts);
    final lockedUntil = _lockedUntil;
    if (lockedUntil == null) {
      await prefs.remove(_lockedUntilEpochKey);
    } else {
      await prefs.setInt(
        _lockedUntilEpochKey,
        lockedUntil.millisecondsSinceEpoch,
      );
    }
  }

  Future<void> _clearLockoutState() async {
    _failedAttempts = 0;
    _lockedUntil = null;
    await _persistLockoutState();
  }

  /// Exponential back-off: 30 s after the 5th failure, doubling every
  /// additional [_kLockoutThreshold] failures, capped at 15 minutes.
  Duration _nextLockoutDuration() {
    final tier = (_failedAttempts ~/ _kLockoutThreshold) - 1;
    var seconds = 30;
    for (var i = 0; i < tier.clamp(0, 5); i++) {
      seconds *= 2;
    }
    return Duration(seconds: seconds.clamp(30, 900));
  }

  Future<void> _recordFailure() async {
    _failedAttempts++;
    if (_failedAttempts % _kLockoutThreshold == 0) {
      _lockedUntil = DateTime.now().add(_nextLockoutDuration());
    }
    await _persistLockoutState();
  }

  Future<AdminAuthResult> login({
    required String emailOrMatricule,
    required String password,
  }) async {
    await _restoreLockoutStateIfNeeded();

    final sanitizedInput = emailOrMatricule.trim();
    final sanitizedPassword = password;

    if (sanitizedInput.isEmpty || sanitizedPassword.isEmpty) {
      return const AdminAuthResult(
        isAuthenticated: false,
        errorMessage: 'Email/matricule et mot de passe sont requis.',
      );
    }

    // Client-side lockout check — immediate rejection before any network call.
    if (_lockedUntil != null && DateTime.now().isBefore(_lockedUntil!)) {
      final remaining = _lockedUntil!.difference(DateTime.now());
      final secs = remaining.inSeconds + 1;
      return AdminAuthResult(
        isAuthenticated: false,
        errorMessage:
            'Too many failed attempts. Try again in $secs second${secs == 1 ? '' : 's'}.',
      );
    }

    try {
      // Cloud Function accounts use {matricule}@admin.local; promoted users keep
      // their real email — resolve via admin_login_lookup as a fallback.
      String email = sanitizedInput.contains('@')
          ? sanitizedInput
          : '${sanitizedInput.toLowerCase()}@admin.local';

      late UserCredential credential;
      try {
        credential = await _auth.signInWithEmailAndPassword(
          email: email,
          password: sanitizedPassword,
        );
      } on FirebaseAuthException catch (e) {
        // @admin.local failed → promoted admin using real email. Look up via
        // admin_login_lookup (public read) and retry with the resolved email.
        if ((e.code == 'user-not-found' || e.code == 'invalid-credential') &&
            !sanitizedInput.contains('@')) {
          final lookupDoc = await _firestore
              .collection(Col.adminLoginLookup)
              .doc(sanitizedInput.toLowerCase())
              .get();
          final resolvedEmail =
              (lookupDoc.data()?['email'] as String? ?? '').trim().toLowerCase();
          if (resolvedEmail.isNotEmpty) {
            email = resolvedEmail;
            // Retry with the real email. Any exception bubbles to the outer catch.
            credential = await _auth.signInWithEmailAndPassword(
              email: resolvedEmail,
              password: sanitizedPassword,
            );
          } else {
            rethrow;
          }
        } else {
          rethrow;
        }
      }

      final uid = credential.user?.uid;
      if (uid == null) {
        return const AdminAuthResult(
          isAuthenticated: false,
          errorMessage: 'Authentication failed: no user returned.',
        );
      }

      // Unified users collection first (new schema), legacy admins as fallback.
      Map<String, dynamic>? adminData;

      final userDoc = await _firestore.collection(Col.users).doc(uid).get();
      final userRole = userDoc.data()?['role']?.toString() ?? '';
      if (userDoc.exists && RoleGuard.isPrivileged(userRole)) {
        adminData = userDoc.data();
      } else {
        final adminDoc = await _firestore.collection(Col.admins).doc(uid).get();
        if (adminDoc.exists) {
          adminData = adminDoc.data();
        }
      }

      if (adminData == null) {
        await _auth.signOut();
        return const AdminAuthResult(
          isAuthenticated: false,
          errorMessage: 'Admin profile not found.',
        );
      }

      // Block deactivated/suspended admin accounts.
      final accountStatus = (adminData['status'] ?? 'active').toString();
      if (accountStatus == 'suspended' || accountStatus == 'inactive') {
        await _auth.signOut();
        return const AdminAuthResult(
          isAuthenticated: false,
          errorMessage: 'Ce compte administrateur a été désactivé. Contactez un super administrateur.',
        );
      }

      // Successful login — reset the failure counter.
      await _clearLockoutState();

      // Resolve display name — new schema uses firstName/lastName, old uses name.
      final firstName = (adminData['firstName'] as String?)?.trim() ?? '';
      final lastName = (adminData['lastName'] as String?)?.trim() ?? '';
      final legacyName = (adminData['name'] as String?)?.trim() ?? '';
      final resolvedName = firstName.isNotEmpty
          ? [firstName, lastName].where((s) => s.isNotEmpty).join(' ')
          : legacyName.isNotEmpty ? legacyName : null;

      // Resolve admin type — new schema uses adminType, old uses role.
      final resolvedType = (adminData['adminType'] as String?) ??
          (adminData['role'] as String?);

      return AdminAuthResult(
        isAuthenticated: true,
        role: resolvedType,
        name: resolvedName,
        matricule: (adminData['matricule'] ?? sanitizedInput).toString(),
      );
    } on FirebaseAuthException catch (e) {
      // Count credential errors toward the lockout threshold.
      // 'user-not-found' is treated identically to 'invalid-credential' so
      // that an attacker cannot enumerate valid matricules from the response.
      if (const {
        'user-not-found',
        'invalid-password',
        'wrong-password',
        'invalid-credential',
      }.contains(e.code)) {
        await _recordFailure();
      }
      return AdminAuthResult(
        isAuthenticated: false,
        errorMessage: FirebaseErrorHandler.getMessage(e),
      );
    } catch (e) {
      return AdminAuthResult(
        isAuthenticated: false,
        errorMessage: FirebaseErrorHandler.getMessage(e),
      );
    }
  }

  // Ensures any Firebase session is cleared before returning to login.
  Future<void> signOut() async {
    await _auth.signOut();
  }

  /// Requests a password reset for an admin account.
  /// Calls the `sendAdminPasswordReset` Cloud Function, which looks up the
  /// admin's real email by matricule and sends the Firebase reset link there
  /// (because admin Firebase Auth emails are non-deliverable @admin.local addresses).
  Future<void> sendPasswordResetRequest(String matricule) async {
    try {
      final callable = FirebaseFunctions.instance
          .httpsCallable('sendAdminPasswordReset');
      await callable.call<dynamic>(<String, dynamic>{
        'matricule': matricule.trim().toLowerCase(),
      });
    } on FirebaseFunctionsException catch (e) {
      throw Exception('Password reset failed: ${e.message}');
    } catch (_) {
      throw Exception('Password reset request failed. Check your connection.');
    }
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
    String? matricule,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const FormatException('No authenticated admin session found.');
    }

    final currentPwd = currentPassword;
    final newPwd = newPassword;

    if (currentPwd.trim().isEmpty || newPwd.trim().isEmpty) {
      throw const FormatException('Current password and new password are required.');
    }

    if (newPwd.length < 6) {
      throw const FormatException('New password must be at least 6 characters.');
    }

    if (currentPwd == newPwd) {
      throw const FormatException('New password must be different from the current one.');
    }

    final email = user.email ??
        ((matricule != null && matricule.trim().isNotEmpty)
            ? '${matricule.trim().toLowerCase()}@admin.local'
            : null);

    if (email == null || email.isEmpty) {
      throw const FormatException('Unable to determine admin account email.');
    }

    try {
      final credential = EmailAuthProvider.credential(
        email: email,
        password: currentPwd,
      );

      await user
          .reauthenticateWithCredential(credential)
          .timeout(const Duration(seconds: 10));

      await user
          .updatePassword(newPwd)
          .timeout(const Duration(seconds: 10));

      // Stamp audit field — non-blocking so a Firestore hiccup doesn't
      // fail the password change that already succeeded in Firebase Auth.
      _firestore
          .collection(Col.users)
          .doc(user.uid)
          .update({'passwordChangedAt': FieldValue.serverTimestamp()})
          .catchError((_) {});

      await user.reload();
    } on TimeoutException {
      throw Exception('Operation timeout. Please check your network and try again.');
    } on FirebaseAuthException catch (e) {
      final lowerMessage = (e.message ?? '').toLowerCase();
      final message = switch (e.code) {
        'wrong-password' ||
        'invalid-credential' ||
        'invalid-login-credentials' ||
        'user-mismatch' ||
        'user-not-found' =>
          'Le mot de passe actuel est incorrect.',
        'weak-password' => 'New password is too weak.',
        'network-request-failed' =>
          'Erreur reseau. Verifiez votre connexion Internet.',
        'requires-recent-login' =>
          'Please log in again before changing your password.',
        'too-many-requests' =>
          'Too many attempts. Please try again later.',
        _ => (lowerMessage.contains('credential') ||
                lowerMessage.contains('password') ||
                lowerMessage.contains('mot de passe'))
            ? 'Le mot de passe actuel est incorrect.'
            : (e.message ?? 'Authentication error while changing password.'),
      };
      throw Exception(message);
    }
  }
}
