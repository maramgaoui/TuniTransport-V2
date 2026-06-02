import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:developer' as developer;
import '../models/user_model.dart';
import '../models/session_result.dart';
import '../utils/role_guard.dart';
import '../utils/validation_utils.dart';
import '../constants/firestore_collections.dart';
import '../services/active_journey_service.dart';
import 'notification_controller.dart';
import '../services/notification_service.dart';

class AuthController {
  AuthController({
    firebase_auth.FirebaseAuth? firebaseAuth,
    FirebaseFirestore? firestore,
    GoogleSignIn? googleSignIn,
  }) : _firebaseAuth = firebaseAuth ?? firebase_auth.FirebaseAuth.instance,
       _firestore = firestore ?? FirebaseFirestore.instance,
       _googleSignIn = googleSignIn;

  /// The shared app-wide instance.  Defaults to a production controller.
  /// Call [AuthController.resetInstance] in tests to inject a fake.
  static AuthController instance = AuthController();

  /// Replace the global instance (for tests only).
  @visibleForTesting
  static void resetInstance(AuthController controller) {
    instance = controller;
  }
  static const Duration _authStreamTtl = Duration(seconds: 60);
  static const Duration _sessionTtl = Duration(minutes: 5);
  static const String _sessionCachePrefix = 'auth.session.';

  final firebase_auth.FirebaseAuth _firebaseAuth;
  final FirebaseFirestore _firestore;
  GoogleSignIn? _googleSignIn;
  SessionResult? _cachedSession;
  DateTime? _sessionCachedAt;
  String? _cachedSessionUid;
  User? _cachedAuthStreamUser;
  DateTime? _authStreamCachedAt;
  String? _cachedAuthStreamUid;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _userStatusSubscription;
  String? _userStatusListenerUid;
  String? _lastObservedUserStatus;
  String? _lastObservedUserRole;
  String? _lastObservedAdminType;

  // Admins browsing as regular users: gates router redirect and feature visibility.
  bool _actingAsUser = false;
  bool get isActingAsUser => _actingAsUser;
  SessionResult? get cachedSession => _cachedSession;

  void switchToUserMode() => _actingAsUser = true;
  void switchToAdminMode() => _actingAsUser = false;

  GoogleSignIn get _googleSignInClient => _googleSignIn ??= GoogleSignIn();

  static const String _blockedMessage = 'auth.error.account_blocked';

  String _normalizeEmail(String email) => email.trim().toLowerCase();

  bool _isTransientFirestoreError(Object error) {
    if (error is! FirebaseException) return false;
    return error.code == 'unavailable' ||
        error.code == 'deadline-exceeded' ||
        error.code == 'aborted';
  }

  void _invalidateAuthStreamCache() {
    _cachedAuthStreamUser = null;
    _authStreamCachedAt = null;
    _cachedAuthStreamUid = null;
  }

  void _cacheAuthStreamUser(String uid, User resolvedUser) {
    _cachedAuthStreamUser = resolvedUser;
    _authStreamCachedAt = DateTime.now();
    _cachedAuthStreamUid = uid;
  }

  void _invalidateSessionCache({String? uid, bool clearPersistent = true}) {
    final targetUid = uid ?? _cachedSessionUid;
    _cachedSession = null;
    _sessionCachedAt = null;
    _cachedSessionUid = null;
    if (clearPersistent && targetUid != null && targetUid.isNotEmpty) {
      unawaited(_clearPersistedSession(targetUid));
    }
  }

  void _cacheSession(
    String uid,
    SessionResult session, {
    String accountStatus = 'active',
  }) {
    _cachedSession = session;
    _sessionCachedAt = DateTime.now();
    _cachedSessionUid = uid;
    unawaited(
      _persistSession(
        uid,
        session,
        accountStatus: accountStatus,
      ),
    );
  }

  String _sessionCacheKey(String uid) => '$_sessionCachePrefix$uid';

  Future<void> _persistSession(
    String uid,
    SessionResult session, {
    required String accountStatus,
  }) async {
    if (uid.isEmpty) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = <String, dynamic>{
        'role': session.role.name,
        'adminRole': session.adminRole,
        'adminType': session.adminType,
        'adminMatricule': session.adminMatricule,
        'adminName': session.adminName,
        'accountStatus': accountStatus,
        'cachedAt': DateTime.now().toIso8601String(),
      };
      await prefs.setString(_sessionCacheKey(uid), jsonEncode(payload));
    } catch (e) {
      developer.log(
        'Failed to persist session cache: $e',
        name: 'AuthController',
      );
    }
  }

  Future<void> _clearPersistedSession(String uid) async {
    if (uid.isEmpty) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sessionCacheKey(uid));
      await prefs.remove('pending_profile_$uid');
    } catch (e) {
      developer.log(
        'Failed to clear persisted session cache: $e',
        name: 'AuthController',
      );
    }
  }

  Future<SessionResult?> _loadPersistedSession(String uid) async {
    if (uid.isEmpty) return null;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_sessionCacheKey(uid));
      if (raw == null || raw.isEmpty) return null;

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final roleName = (decoded['role'] ?? '').toString();
      final role = SessionRole.values.firstWhere(
        (candidate) => candidate.name == roleName,
        orElse: () => SessionRole.guest,
      );

      return SessionResult(
        role: role,
        adminRole: decoded['adminRole'] as String?,
        adminType: decoded['adminType'] as String?,
        adminMatricule: decoded['adminMatricule'] as String?,
        adminName: decoded['adminName'] as String?,
      );
    } catch (e) {
      developer.log(
        'Failed to load persisted session cache: $e',
        name: 'AuthController',
      );
      return null;
    }
  }

  bool _isDefinitiveSessionFailure(Object error) {
    if (error is FirebaseException) {
      return error.code == 'permission-denied' ||
          error.code == 'unauthenticated';
    }

    if (error is firebase_auth.FirebaseAuthException) {
      return error.code == 'user-disabled' ||
          error.code == 'invalid-user-token' ||
          error.code == 'user-token-expired';
    }

    return false;
  }

  Future<void> _cancelUserStatusListener() async {
    await _userStatusSubscription?.cancel();
    _userStatusSubscription = null;
    _userStatusListenerUid = null;
    _lastObservedUserStatus = null;
    _lastObservedUserRole = null;
    _lastObservedAdminType = null;
  }

  Future<void> _setUserStatusListener(String uid) async {
    if (_userStatusSubscription != null && _userStatusListenerUid == uid) {
      return;
    }

    await _cancelUserStatusListener();

    _userStatusListenerUid = uid;
    _userStatusSubscription = _firestore
        .collection(Col.users)
        .doc(uid)
        .snapshots()
        .listen(
          (snapshot) {
            final data = snapshot.data();
            final currentStatus    = (data?['status']    ?? 'active').toString();
            final currentRole      = (data?['role']      ?? 'user').toString();
            final currentAdminType = (data?['adminType'] ?? '').toString();

            if (_lastObservedUserStatus == null && _lastObservedUserRole == null) {
              _lastObservedUserStatus  = currentStatus;
              _lastObservedUserRole    = currentRole;
              _lastObservedAdminType   = currentAdminType;
              return;
            }

            if (_lastObservedUserStatus  != currentStatus  ||
                _lastObservedUserRole    != currentRole     ||
                _lastObservedAdminType   != currentAdminType) {
              _lastObservedUserStatus  = currentStatus;
              _lastObservedUserRole    = currentRole;
              _lastObservedAdminType   = currentAdminType;
              _invalidateSessionCache(uid: uid);
            }
          },
          onError: (Object error) {
            developer.log(
              'User status listener error: $error',
              name: 'AuthController',
            );
          },
        );
  }

  Future<void> _safeSignOut({bool clearSessionCache = true}) async {
    final currentUid = _firebaseAuth.currentUser?.uid;
    _actingAsUser = false;
    _invalidateAuthStreamCache();
    _invalidateSessionCache(uid: currentUid, clearPersistent: clearSessionCache);
    await _cancelUserStatusListener();

    // Remove FCM token before signing out so stale tokens don't accumulate
    // across multiple accounts used on the same device.
    if (currentUid != null) {
      try {
        await _firestore.collection(Col.users).doc(currentUid).update({
          'fcmToken': FieldValue.delete(),
        });
      } catch (_) {}
    }

    // Clear user-specific data that must not survive an account switch on a
    // shared device.
    await ActiveJourneyService.instance.clearActiveJourney();
    await NotificationController.instance.resetForSignOut();

    try {
      await _firebaseAuth.signOut();
    } catch (e) {
      developer.log('Safe sign out error: $e', name: 'AuthController');
    }
  }

  Stream<User?> get authStateChanges {
    return _firebaseAuth.authStateChanges().asyncMap((
      firebase_auth.User? user,
    ) async {
      if (user == null) {
        _invalidateAuthStreamCache();
        await _cancelUserStatusListener();
        return null;
      }

      // Block unverified email/password accounts — but exempt admin accounts
      // ({matricule}@admin.local) which are created by the super admin and
      // never go through the user-facing email verification flow.
      final isEmailPasswordUser = user.providerData
          .any((p) => p.providerId == 'password');
      final isAdminAccount = user.email?.endsWith('@admin.local') ?? false;
      if (isEmailPasswordUser && !user.emailVerified && !isAdminAccount) {
        _invalidateAuthStreamCache();
        return null;
      }

      if (_cachedAuthStreamUser != null &&
          _cachedAuthStreamUid == user.uid &&
          _authStreamCachedAt != null &&
          DateTime.now().difference(_authStreamCachedAt!) < _authStreamTtl) {
        return _cachedAuthStreamUser;
      }

      // Ban logic on app open: if banUntil has expired, automatically reactivate user.
      // If user is still blocked/banned, sign out to prevent app access.
      try {
        final accessError = await _validateAndNormalizeUserAccess(
          uid: user.uid,
          enforceRestriction: true,
        );
        if (accessError != null) {
          await _safeSignOut();
          return null;
        }
      } catch (e) {
        // Offline/temporary Firestore failures should not break auth stream
        // delivery or leave the app in a blank routing state.
        developer.log(
          'Skipping access normalization due to transient error: $e',
          name: 'AuthController',
        );
      }

      // Guard: another auth event (e.g. sign-out) may have fired while we were
      // awaiting Firestore above. If the current user changed, bail out to
      // prevent creating an orphaned status listener for a stale UID.
      if (_firebaseAuth.currentUser?.uid != user.uid) {
        await _cancelUserStatusListener();
        return null;
      }

      try {
        final userDoc = await _firestore
            .collection(Col.users)
            .doc(user.uid)
            .get();
        // Guard again after the second Firestore round-trip.
        if (_firebaseAuth.currentUser?.uid != user.uid) {
          await _cancelUserStatusListener();
          return null;
        }
        await _setUserStatusListener(user.uid);
        if (userDoc.exists) {
          final resolvedUser = User.fromMap(userDoc.data() ?? {});
          _cacheAuthStreamUser(user.uid, resolvedUser);
          unawaited(NotificationService.instance.onUserLoggedIn());
          return resolvedUser;
        } else {
          // No Firestore doc yet — first login before the profile write lands.
          final resolvedUser = User(uid: user.uid, email: user.email ?? '');
          _cacheAuthStreamUser(user.uid, resolvedUser);
          return resolvedUser;
        }
      } catch (e) {
        developer.log('Error fetching user data: $e', name: 'AuthController');
        final resolvedUser = User(uid: user.uid, email: user.email ?? '');
        _cacheAuthStreamUser(user.uid, resolvedUser);
        return resolvedUser;
      }
    });
  }

  /// Last status value observed by the real-time Firestore listener.
  /// Null until the first snapshot arrives. Stays current across ban/unban events.
  String? get currentUserStatus => _lastObservedUserStatus;

  // uid + email only — use fetchCurrentUser() when profile fields are needed
  User? get currentUser {
    final firebaseUser = _firebaseAuth.currentUser;
    if (firebaseUser == null) return null;

    final isEmailPasswordUser = firebaseUser.providerData
        .any((p) => p.providerId == 'password');
    final isAdminAccount = firebaseUser.email?.endsWith('@admin.local') ?? false;
    if (isEmailPasswordUser && !firebaseUser.emailVerified && !isAdminAccount) return null;

    return User(uid: firebaseUser.uid, email: firebaseUser.email ?? '');
  }

  // Returns a minimal User on Firestore errors so callers are never blocked.
  Future<User?> fetchCurrentUser() async {
    final firebaseUser = _firebaseAuth.currentUser;
    if (firebaseUser == null) return null;

    try {
      final userDoc = await _firestore
          .collection(Col.users)
          .doc(firebaseUser.uid)
          .get();
      if (userDoc.exists) {
        return User.fromMap(userDoc.data() ?? {});
      }
    } catch (e) {
      developer.log('Error fetching current user: $e', name: 'AuthController');
    }
    return User(uid: firebaseUser.uid, email: firebaseUser.email ?? '');
  }

  // Creates the Firestore user doc at signup, not after verification, so
  // profile data lands even if the user verifies from a different device.
  Future<User?> signUpWithEmail({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
    String? username,
    String? avatarId,
  }) async {
    try {
      final normalizedEmail = _normalizeEmail(email);

      final emailValidation = ValidationUtils.validateEmail(normalizedEmail);
      if (emailValidation != null) throw Exception(emailValidation);

      final firstNameValidation = ValidationUtils.validateName(firstName, 'Prénom');
      if (firstNameValidation != null) throw Exception(firstNameValidation);

      final lastNameValidation = ValidationUtils.validateName(lastName, 'Nom');
      if (lastNameValidation != null) throw Exception(lastNameValidation);

      final passwordValidation = ValidationUtils.validatePassword(password);
      if (passwordValidation != null) throw Exception(passwordValidation);

      final effectiveUsername = (username != null && username.isNotEmpty) ? username : null;
      if (effectiveUsername != null) {
        final usernameValidation = ValidationUtils.validateUsername(effectiveUsername);
        if (usernameValidation != null) throw Exception(usernameValidation);
        // Uniqueness is checked AFTER auth creation because the users
        // collection query requires an authenticated caller.
      }

      // Auth account must exist before the username uniqueness query: the
      // users collection requires an authenticated caller per Firestore rules.
      final userCredential = await _firebaseAuth.createUserWithEmailAndPassword(
        email: normalizedEmail,
        password: password,
      );

      final firebaseUser = userCredential.user;
      if (firebaseUser == null) {
        throw Exception('auth.error.account_creation_failed');
      }

      if (effectiveUsername != null) {
        late final bool taken;
        try {
          taken = await _isUsernameTakenByOtherUser(effectiveUsername);
        } catch (e) {
          await firebaseUser.delete().catchError((_) {});
          if (_isTransientFirestoreError(e)) {
            throw Exception('auth.error.firestore_unavailable');
          }
          rethrow;
        }
        if (taken) {
          await firebaseUser.delete().catchError((_) {});
          throw Exception('auth.error.username_taken');
        }
      }

      final firestoreProfile = {
        'uid': firebaseUser.uid,
        'email': normalizedEmail,
        'username': effectiveUsername ?? '',
        'firstName': firstName,
        'lastName': lastName,
        'avatarId': avatarId ?? 'avatar-01',
        'role': 'user',
        'status': 'active',
        'banUntil': null,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // JSON-safe local cache used by legacy post-verification restore path.
      final pendingProfile = {
        'uid': firebaseUser.uid,
        'email': normalizedEmail,
        'username': effectiveUsername ?? '',
        'firstName': firstName,
        'lastName': lastName,
        'avatarId': avatarId ?? 'avatar-01',
        'role': 'user',
        'status': 'active',
        'banUntil': null,
      };

      try {
        await _firestore
            .collection(Col.users)
            .doc(firebaseUser.uid)
            .set(firestoreProfile, SetOptions(merge: true));
      } catch (e) {
        developer.log('Failed to create user profile at signup: $e', name: 'AuthController');
        await firebaseUser.delete().catchError((_) {});
        if (_isTransientFirestoreError(e)) {
          throw Exception('auth.error.firestore_unavailable');
        }
        throw Exception('auth.error.account_creation_failed');
      }

      // Backward-compat: older sessions may still restore profile from this cache key.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'pending_profile_${firebaseUser.uid}',
        jsonEncode(pendingProfile),
      );
      developer.log('Pending profile saved for ${firebaseUser.uid}', name: 'AuthController');

      developer.log('Sending verification email to ${firebaseUser.email}', name: 'AuthController');
      try {
        await firebaseUser.sendEmailVerification();
        developer.log('Verification email sent successfully', name: 'AuthController');
      } on firebase_auth.FirebaseAuthException catch (e) {
        developer.log('sendEmailVerification failed: ${e.code} ${e.message}', name: 'AuthController');
      }
      await _firebaseAuth.signOut();
      _invalidateSessionCache();

      return User(
        uid: firebaseUser.uid,
        email: normalizedEmail,
        username: effectiveUsername,
        firstName: firstName,
        lastName: lastName,
        avatarId: avatarId,
      );
    } on firebase_auth.FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    } catch (e) {
      developer.log('Sign up error: $e', name: 'AuthController');
      throw Exception(e.toString());
    }
  }

  /// Returns true if [username] is already used by any user other than
  /// [excludeUid] (pass the caller's own UID when updating an existing profile).
  Future<bool> _isUsernameTakenByOtherUser(
    String username, {
    String? excludeUid,
  }) async {
    final snapshot = await _firestore
        .collection(Col.users)
        .where('username', isEqualTo: username)
        .limit(1)
        .get();
    if (snapshot.docs.isEmpty) return false;
    if (excludeUid != null && snapshot.docs.first.id == excludeUid) return false;
    return true;
  }

  Future<User?> signInWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      final normalizedEmail = _normalizeEmail(email);
      final userCredential = await _firebaseAuth.signInWithEmailAndPassword(
        email: normalizedEmail,
        password: password,
      );

      final firebaseUser = userCredential.user;
      if (firebaseUser == null) {
        throw Exception('Failed to sign in');
      }

      if (!firebaseUser.emailVerified) {
        await _firebaseAuth.signOut();
        throw Exception('email_not_verified:${firebaseUser.email ?? ''}');
      }

      final accessError = await _validateAndNormalizeUserAccess(
        uid: firebaseUser.uid,
        enforceRestriction: true,
      );
      if (accessError != null) {
        await _firebaseAuth.signOut();
        throw Exception(accessError);
      }

      // First login after email verification: Firestore doc may not exist yet.
      // Restore from the pending profile saved during signup.
      final userDocRef = _firestore.collection(Col.users).doc(firebaseUser.uid);
      final userDoc = await userDocRef.get();

      if (userDoc.exists) {
        _invalidateSessionCache(uid: firebaseUser.uid);
        unawaited(NotificationService.instance.onUserLoggedIn());
        return User.fromMap(userDoc.data() ?? {});
      }

      final prefs = await SharedPreferences.getInstance();
      final pendingJson = prefs.getString('pending_profile_${firebaseUser.uid}');
      if (pendingJson != null) {
        try {
          final pendingData = jsonDecode(pendingJson) as Map<String, dynamic>;
          pendingData['status'] = 'active';
          pendingData['banUntil'] = null;
          developer.log('Creating Firestore doc from pending profile for ${firebaseUser.uid}', name: 'AuthController');
          await userDocRef.set(pendingData);
          await prefs.remove('pending_profile_${firebaseUser.uid}');
          _invalidateSessionCache(uid: firebaseUser.uid);
          unawaited(NotificationService.instance.onUserLoggedIn());
          return User.fromMap(pendingData);
        } catch (e) {
          developer.log('Failed to restore pending profile: $e', name: 'AuthController');
        }
      }

      _invalidateSessionCache(uid: firebaseUser.uid);
      unawaited(NotificationService.instance.onUserLoggedIn());
      return User(uid: firebaseUser.uid, email: firebaseUser.email ?? '');
    } on firebase_auth.FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    } on Exception {
      // Re-throw ban/block messages and other known exceptions as-is.
      rethrow;
    } catch (e) {
      developer.log('Sign in error: $e', name: 'AuthController');
      throw Exception('An error occurred during sign in. Please try again.');
    }
  }

  /// Sends a new verification email. Signs in temporarily with [email] and
  /// [password] to obtain a Firebase user with a fresh token, then immediately
  /// signs out again.
  Future<void> resendVerificationEmail({
    required String email,
    required String password,
  }) async {
    try {
      final normalizedEmail = _normalizeEmail(email);
      final userCredential = await _firebaseAuth.signInWithEmailAndPassword(
        email: normalizedEmail,
        password: password,
      );
      final firebaseUser = userCredential.user;
      if (firebaseUser != null && !firebaseUser.emailVerified) {
        await firebaseUser.sendEmailVerification();
      }
      await _firebaseAuth.signOut();
    } on firebase_auth.FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    } catch (e) {
      throw Exception(e.toString());
    }
  }

  /// Signs in temporarily to check whether [email] has been verified, then
  /// signs out again immediately. Returns `true` if verified.
  Future<bool> isEmailVerified({
    required String email,
    required String password,
  }) async {
    try {
      final normalizedEmail = _normalizeEmail(email);
      final userCredential = await _firebaseAuth.signInWithEmailAndPassword(
        email: normalizedEmail,
        password: password,
      );
      final firebaseUser = userCredential.user;
      if (firebaseUser != null) {
        await firebaseUser.reload();
        final verified = firebaseUser.emailVerified;
        await _firebaseAuth.signOut();
        return verified;
      }
      await _firebaseAuth.signOut();
      return false;
    } catch (_) {
      try { await _firebaseAuth.signOut(); } catch (_) {}
      return false;
    }
  }

  Future<User?> signInWithGoogle({bool isSignUp = false}) async {
    try {
      // Clear cached Google account so Android always shows the chooser.
      // Without this, GoogleSignIn may silently reuse the previous account.
      try {
        await _googleSignInClient.signOut();
      } catch (_) {}

      final googleUser = await _googleSignInClient.signIn();
      if (googleUser == null) {
        throw Exception('Google sign-in cancelled');
      }

      final googleAuth = await googleUser.authentication;

      // NOTE: Do not query Firestore before authentication. Firestore rules
      // for `users` require an authenticated caller, so pre-auth reads trigger
      // `cloud_firestore/permission-denied`. Access checks run right after
      // Firebase sign-in via `_validateAndNormalizeUserAccess`.

      final credential = firebase_auth.GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final userCredential = await _firebaseAuth.signInWithCredential(
        credential,
      );
      final firebaseUser = userCredential.user;

      if (firebaseUser == null) {
        throw Exception('Failed to create Firebase user');
      }

      final userDoc = await _firestore
          .collection(Col.users)
          .doc(firebaseUser.uid)
          .get();

      if (userDoc.exists) {
        if (isSignUp) {
          await _firebaseAuth.signOut();
          throw Exception('auth.error.google_account_already_exists');
        }
        final accessError = await _validateAndNormalizeUserAccess(
          uid: firebaseUser.uid,
          enforceRestriction: true,
        );
        if (accessError != null) {
          await _firebaseAuth.signOut();
          throw Exception(accessError);
        }
        _invalidateSessionCache(uid: firebaseUser.uid);
        final existingData = Map<String, dynamic>.from(userDoc.data() ?? {});
        // Backfill username for existing Google users who never had one set.
        if ((existingData['username'] ?? '').toString().isEmpty) {
          var generated = _generateUsername(
            displayName: googleUser.displayName,
            email: firebaseUser.email ?? '',
          );
          if (await _isUsernameTakenByOtherUser(generated, excludeUid: firebaseUser.uid)) {
            generated = '${generated}_${firebaseUser.uid.substring(0, 4)}';
          }
          await _firestore
              .collection(Col.users)
              .doc(firebaseUser.uid)
              .update({'username': generated});
          existingData['username'] = generated;
        }
        unawaited(NotificationService.instance.onUserLoggedIn());
        return User.fromMap(existingData);
      } else {
        var generatedUsername = _generateUsername(
          displayName: googleUser.displayName,
          email: firebaseUser.email ?? '',
        );
        if (await _isUsernameTakenByOtherUser(generatedUsername)) {
          generatedUsername = '${generatedUsername}_${firebaseUser.uid.substring(0, 4)}';
        }
        final user = User(
          uid: firebaseUser.uid,
          email: firebaseUser.email ?? '',
          username: generatedUsername,
          firstName: googleUser.displayName?.split(' ').first ?? '',
          lastName: googleUser.displayName?.split(' ').skip(1).join(' ') ?? '',
          avatarId: 'avatar-01',
        );

        final userData = user.toMap();
        userData['status'] = 'active';
        userData['banUntil'] = null;
        try {
          await _firestore
              .collection(Col.users)
              .doc(firebaseUser.uid)
              .set(userData);
        } catch (e) {
          // Roll back the Firebase Auth account so the user can retry cleanly
          // rather than being left with an orphaned Auth entry and no profile.
          await firebaseUser.delete().catchError((_) {});
          developer.log(
            'Google sign-in Firestore write failed, Auth account rolled back: $e',
            name: 'AuthController',
          );
          if (_isTransientFirestoreError(e)) {
            throw Exception('auth.error.firestore_unavailable');
          }
          throw Exception('auth.error.account_creation_failed');
        }

        _invalidateSessionCache(uid: firebaseUser.uid);
        unawaited(NotificationService.instance.onUserLoggedIn());
        return user;
      }
    } on firebase_auth.FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    } on Exception {
      rethrow;
    } catch (e) {
      developer.log('Google sign in error: $e', name: 'AuthController');
      throw Exception(
        'An error occurred during Google sign in. Please try again.',
      );
    }
  }

  String _generateUsername({String? displayName, required String email}) {
    if (displayName != null && displayName.isNotEmpty) {
      final cleaned = displayName
          .toLowerCase()
          .replaceAll(RegExp(r'\s+'), '_')
          .replaceAll(RegExp(r'[^a-z0-9_]'), '');
      if (cleaned.isNotEmpty) return cleaned;
    }
    final prefix = email.split('@').first
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '');
    return prefix.isNotEmpty ? prefix : 'user';
  }

  /// Resolves the role of the currently signed-in user from the unified
  /// `users` collection.  Falls back to the legacy `admins` collection for
  /// accounts created before the data-model migration and auto-migrates them.
  Future<SessionResult> resolveSession(User current) async {
    if (current.uid.isEmpty) {
      _invalidateSessionCache();
      return const SessionResult(role: SessionRole.guest);
    }

    if (_cachedSession != null &&
        _sessionCachedAt != null &&
        _cachedSessionUid == current.uid &&
        DateTime.now().difference(_sessionCachedAt!) < _sessionTtl) {
      return _cachedSession!;
    }

    try {
      final userDoc = await _firestore
          .collection(Col.users)
          .doc(current.uid)
          .get();

      if (userDoc.exists) {
        final data = userDoc.data() ?? {};
        final role = (data['role'] ?? 'user').toString();

        if (RoleGuard.isSuperAdmin(role)) {
          final result = SessionResult(
            role: SessionRole.superAdmin,
            adminType: data['adminType'] as String?,
            adminRole: data['adminType'] as String?,
            adminMatricule: (data['matricule'] ?? '').toString(),
            adminName: (data['firstName'] ?? data['name'] ?? '').toString(),
          );
          _cacheSession(current.uid, result);
          return result;
        }

        if (RoleGuard.isAdmin(role)) {
          final result = SessionResult(
            role: SessionRole.admin,
            adminType: data['adminType'] as String?,
            adminRole: data['adminType'] as String?,
            adminMatricule: (data['matricule'] ?? '').toString(),
            adminName: (data['firstName'] ?? data['name'] ?? '').toString(),
          );
          _cacheSession(current.uid, result);
          return result;
        }

        // Handle sub-admin roles stored directly on the users doc by older
        // versions of createAdminAccount (e.g. 'admin_taxi_collectifs').
        const subAdminRoleMap = {
          'admin_bus': 'bus',
          'admin_metro': 'metro_train',
          'admin_taxi_collectifs': 'taxicollectifs',
          'admin_louage_train': 'louage',
        };
        if (subAdminRoleMap.containsKey(role)) {
          final resolvedType = (data['adminType'] as String?)
              ?? subAdminRoleMap[role];
          final result = SessionResult(
            role: SessionRole.admin,
            adminType: resolvedType,
            adminRole: resolvedType,
            adminMatricule: (data['matricule'] ?? '').toString(),
            adminName: (data['firstName'] ?? data['name'] ?? '').toString(),
          );
          _cacheSession(current.uid, result);
          return result;
        }

        final status = (data['status'] ?? 'active').toString();
        final banUntilRaw = data['banUntil'];
        DateTime? banUntil;
        if (banUntilRaw is Timestamp) {
          banUntil = banUntilRaw.toDate();
        }

        if (status == 'banned' &&
            banUntil != null &&
            DateTime.now().isAfter(banUntil)) {
          unawaited(
            _firestore.collection(Col.users).doc(current.uid).update({
              'status': 'active',
              'banUntil': null,
            }).catchError((Object error) {
              developer.log(
                'Failed to auto-reactivate expired ban: $error',
                name: 'AuthController',
              );
            }),
          );
        } else if (status == 'banned' || status == 'blocked' ||
                   status == 'suspended' || status == 'inactive') {
          const restrictedResult = SessionResult(role: SessionRole.guest);
          _cacheSession(current.uid, restrictedResult, accountStatus: status);
          await _safeSignOut(clearSessionCache: false);
          return restrictedResult;
        }

        const result = SessionResult(role: SessionRole.user);
        _cacheSession(current.uid, result);
        return result;
      }

      // Legacy admins collection — pre-migration accounts only. Auto-migrates to users/{uid}.
      final adminDoc = await _firestore
          .collection(Col.admins)
          .doc(current.uid)
          .get();

      if (adminDoc.exists) {
        final adminData = adminDoc.data() ?? {};
        // Auto-migrate: stamp role='admin' onto the users document so future
        // lookups hit the fast path above.
        await _firestore.collection(Col.users).doc(current.uid).set(
          {
            'uid': current.uid,
            'email': current.email,
            'role': 'admin',
            'adminType': adminData['role'] as String?,
            'matricule': (adminData['matricule'] ?? '').toString(),
            'firstName': adminData['name'] as String?,
            'status': 'active',
            'permissions': adminData['permissions'] ?? <String>[],
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        ).catchError((Object e) {
          developer.log(
            'Failed to auto-migrate admin to users collection: $e',
            name: 'AuthController',
          );
        });

        final result = SessionResult(
          role: SessionRole.admin,
          adminType: adminData['role'] as String?,
          adminRole: adminData['role'] as String?,
          adminMatricule: (adminData['matricule'] ?? '').toString(),
          adminName: adminData['name'] as String?,
        );
        _cacheSession(current.uid, result);
        return result;
      }

      // Race between auth and Firestore write (new signup) — default to user role.
      const result = SessionResult(role: SessionRole.user);
      _cacheSession(current.uid, result);
      return result;
    } catch (e) {
      if (_isDefinitiveSessionFailure(e)) {
        developer.log(
          'resolveSession forcing sign-out after definitive failure: $e',
          name: 'AuthController',
        );
        await _safeSignOut();
        return const SessionResult(role: SessionRole.guest);
      }

      final persisted = await _loadPersistedSession(current.uid);
      if (persisted != null) {
        _cacheSession(current.uid, persisted);
        developer.log(
          'resolveSession restored cached role after transient failure: $e',
          name: 'AuthController',
        );
        return persisted;
      }

      developer.log(
        'resolveSession transient failure with no cache, defaulting to guest: $e',
        name: 'AuthController',
      );
      return const SessionResult(role: SessionRole.guest);
    }
  }

  Future<void> signOut() async {
    try {
      await _safeSignOut();
    } catch (e) {
      developer.log('Sign out error: $e', name: 'AuthController');
      throw Exception('Failed to sign out');
    }
  }

  Future<void> updateUserProfile({
    required String uid,
    String? username,
    String? firstName,
    String? lastName,
    String? avatarId,
    String? city,
  }) async {
    try {
      final updateData = <String, dynamic>{};
      if (username != null) updateData['username'] = username;
      if (firstName != null) updateData['firstName'] = firstName;
      if (lastName != null) updateData['lastName'] = lastName;
      if (avatarId != null) updateData['avatarId'] = avatarId;
      if (city != null) updateData['city'] = city;
      if (updateData.isEmpty) return;
      updateData['updatedAt'] = FieldValue.serverTimestamp();

      await _firestore.collection(Col.users).doc(uid).update(updateData);
    } catch (e) {
      developer.log('Update profile error: $e', name: 'AuthController');
      throw Exception('Failed to update profile');
    }
  }

  Future<void> sendPasswordResetEmail(String email) async {
    try {
      final normalizedEmail = _normalizeEmail(email);
      developer.log(
        'Sending password reset email to: $normalizedEmail',
        name: 'AuthController',
      );
      await _firebaseAuth.sendPasswordResetEmail(email: normalizedEmail);
      developer.log(
        'Password reset email sent successfully to: $normalizedEmail',
        name: 'AuthController',
      );
    } on firebase_auth.FirebaseAuthException catch (e) {
      developer.log(
        'Firebase Auth Exception - Code: ${e.code}, Message: ${e.message}',
        name: 'AuthController',
        error: e,
      );
      throw _handleAuthException(e);
    } catch (e) {
      developer.log(
        'Send password reset email error: $e',
        name: 'AuthController',
        error: e,
      );
      throw Exception(
        'auth.error.password_reset_failed',
      );
    }
  }

  // Maps Firebase error codes to l10n keys; callers translate via AppLocalizations.
  Exception _handleAuthException(firebase_auth.FirebaseAuthException e) {
    return Exception(switch (e.code) {
      'weak-password' => 'auth.error.weak_password',
      'email-already-in-use' => 'auth.error.email_already_in_use',
      'invalid-email' => 'auth.error.invalid_email',
      'user-disabled' => 'auth.error.user_disabled',
      'user-not-found' => 'auth.error.user_not_found',
      'wrong-password' || 'invalid-credential' => 'auth.error.wrong_password',
      'too-many-requests' => 'auth.error.too_many_requests',
      _ => 'auth.error.generic',
    });
  }

  Future<String?> _validateAndNormalizeUserAccess({
    required String uid,
    required bool enforceRestriction,
  }) async {
    final userDoc = await _firestore.collection(Col.users).doc(uid).get();
    if (!userDoc.exists) {
      return null;
    }

    final data = userDoc.data() ?? <String, dynamic>{};
    final status = (data['status'] ?? 'active').toString();
    final banUntilValue = data['banUntil'];

    DateTime? banUntil;
    if (banUntilValue is Timestamp) {
      banUntil = banUntilValue.toDate();
    } else if (banUntilValue is String) {
      banUntil = DateTime.tryParse(banUntilValue);
    }

    if (status == 'banned' &&
        banUntil != null &&
        DateTime.now().isAfter(banUntil)) {
      await _firestore.collection(Col.users).doc(uid).update({
        'status': 'active',
        'banUntil': null,
      });
      return null;
    }

    if (!enforceRestriction) {
      return null;
    }

    if (status == 'blocked') {
      return _blockedMessage;
    }

    if (status == 'suspended' || status == 'inactive') {
      return 'auth.error.account_deactivated';
    }

    if (status == 'banned') {
      if (banUntil == null) {
        return 'auth.error.account_banned_indefinite';
      }
      return 'auth.error.account_banned_until:${_formatBanDate(banUntil)}';
    }

    return null;
  }

  String _formatBanDate(DateTime date) {
    final yyyy = date.year.toString().padLeft(4, '0');
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    final hh = date.hour.toString().padLeft(2, '0');
    final min = date.minute.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd $hh:$min';
  }
}
