import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:developer' as developer;
import '../models/user_model.dart';
import '../models/session_result.dart';
import '../utils/firebase_error_handler.dart';
import '../utils/role_guard.dart';
import '../utils/validation_utils.dart';
import '../constants/firestore_collections.dart';
import '../services/active_journey_service.dart';
import 'notification_controller.dart';
import '../services/notification_service.dart';

/// Result returned by [AuthController.loginWithMatriculeOrEmail].
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

  // Fires whenever a privileged session is cached so the router can redirect
  // to the admin dashboard without waiting for a new auth-state event.
  final _sessionRefreshController = StreamController<void>.broadcast();
  Stream<void> get sessionChanges => _sessionRefreshController.stream;

  SessionResult? _cachedSession;
  DateTime? _sessionCachedAt;
  String? _cachedSessionUid;
  User? _cachedAuthStreamUser;
  DateTime? _authStreamCachedAt;
  String? _cachedAuthStreamUid;

  // Holds the Google credential that could not complete sign-in because the
  // email already belongs to an email/password account. The linking dialog
  // reads pendingLinkEmail and calls linkGoogleToPendingAccount(password).
  firebase_auth.AuthCredential? _pendingLinkCredential;
  String? _pendingLinkEmail;

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

  /// Reads a document FROM THE SERVER, retrying on transient Firestore errors
  /// (`unavailable` / `deadline-exceeded` / `aborted`).
  ///
  /// `Source.server` is critical. Right after a Google sign-in the auth token
  /// changes and Firestore's gRPC channel resets (the "SSL shutdown / connection
  /// abort" seen in logs). A default `.get()` would then fall back to the local
  /// cache — and with offline persistence disabled that cache only holds the
  /// in-flight `fcmToken` pending write, NOT the real server fields. The read
  /// comes back `exists=true` but `role=null`, so resolveSession defaults the
  /// user to `user` and caches that wrong role for 5 minutes, routing an
  /// admin/super-admin to the user home screen.
  ///
  /// Forcing `Source.server` makes an unreachable server throw `unavailable`
  /// instead of returning a partial cached doc; the retry loop then waits for
  /// the connection to recover and returns the COMPLETE document.
  Future<DocumentSnapshot<Map<String, dynamic>>> _getDocWithRetry(
    DocumentReference<Map<String, dynamic>> ref, {
    int maxAttempts = 6,
    String? requireField,
  }) async {
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        final snap = await ref.get(const GetOptions(source: Source.server));
        // An existing doc missing a field we know must always be present means
        // we read a partial/stale snapshot (e.g. only the in-flight `fcmToken`
        // pending write). Retry instead of trusting it — this is exactly what
        // poisoned an admin's session with role `user`.
        if (requireField != null &&
            snap.exists &&
            snap.data()?[requireField] == null &&
            attempt < maxAttempts) {
          developer.log(
            'Partial doc (missing "$requireField") on attempt $attempt; retrying',
            name: 'AuthController',
          );
          await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
          continue;
        }
        return snap;
      } on FirebaseException catch (e) {
        if (!_isTransientFirestoreError(e) || attempt >= maxAttempts) {
          rethrow;
        }
        developer.log(
          'Transient Firestore error (${e.code}) on attempt $attempt; retrying',
          name: 'AuthController',
        );
        await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
      }
    }
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
    unawaited(_persistSession(uid, session, accountStatus: accountStatus));
    // Notify the router immediately when a privileged session is cached so it
    // can redirect to /admin without waiting for the next auth-state event.
    if (session.isPrivileged && !_sessionRefreshController.isClosed) {
      _sessionRefreshController.add(null);
    }
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

              // Force sign-out immediately when the user is banned or blocked
              // so the session ends without waiting for the next auth event.
              if (currentStatus == 'blocked' || currentStatus == 'banned') {
                unawaited(_safeSignOut());
              }
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
        _actingAsUser = false;   // always exit user-mode when session ends
        _invalidateAuthStreamCache();
        await _cancelUserStatusListener();
        return null;
      }

      // Block unverified email/password accounts — exempt admins because
      // their accounts are created by a super-admin and may not go through
      // the self-service email verification flow.
      final isEmailPasswordUser = user.providerData
          .any((p) => p.providerId == 'password');
      if (isEmailPasswordUser && !user.emailVerified) {
        // Quick privilege check so admins with real (non-@admin.local) emails
        // are not blocked. Only reads Firestore when verification is missing.
        bool isPrivileged = false;
        try {
          final snap = await _firestore
              .collection(Col.users)
              .doc(user.uid)
              .get();
          isPrivileged = RoleGuard.isPrivileged(
              snap.data()?['role']?.toString() ?? '');
          if (!isPrivileged) {
            isPrivileged = (await _firestore
                    .collection(Col.admins)
                    .doc(user.uid)
                    .get())
                .exists;
          }
        } catch (_) {}
        if (!isPrivileged) {
          _invalidateAuthStreamCache();
          return null;
        }
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

  /// The email address that triggered the pending Google-link flow.
  /// Non-null only between the account-exists-with-different-credential error
  /// and a successful [linkGoogleToPendingAccount] or [clearPendingLink] call.
  String? get pendingLinkEmail => _pendingLinkEmail;

  /// Discards the stored Google credential and email without linking.
  /// Call this when the user cancels the link dialog.
  void clearPendingLink() {
    _pendingLinkCredential = null;
    _pendingLinkEmail = null;
  }

  // uid + email only — use fetchCurrentUser() when profile fields are needed
  User? get currentUser {
    final firebaseUser = _firebaseAuth.currentUser;
    if (firebaseUser == null) return null;

    final isEmailPasswordUser = firebaseUser.providerData
        .any((p) => p.providerId == 'password');
    if (isEmailPasswordUser && !firebaseUser.emailVerified) {
      // Admin accounts created by super-admin never go through email
      // verification. Allow them through if the session cache confirms
      // a privileged role for this UID.
      final isPrivilegedCached = _cachedSession != null &&
          _cachedSessionUid == firebaseUser.uid &&
          _cachedSession!.isPrivileged;
      if (!isPrivilegedCached) return null;
    }

    return User(uid: firebaseUser.uid, email: firebaseUser.email ?? '');
  }

  /// The account's creation time straight from Firebase Auth. Unlike the
  /// Firestore `createdAt` serverTimestamp (which is briefly null right after
  /// signup), this is available immediately and reliably — used to hide admin
  /// notifications that predate the account.
  DateTime? get accountCreationTime =>
      _firebaseAuth.currentUser?.metadata.creationTime;

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
        'authProvider': 'password',
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
        'authProvider': 'password',
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
    _actingAsUser = false; // clear any stale user-mode from a previous session
    // Eagerly wipe the persisted session so a stale 'user' cache in
    // SharedPreferences cannot be read by resolveSession's catch-block
    // fallback during the redirect that fires immediately after sign-in.
    final previousUid = _firebaseAuth.currentUser?.uid;
    if (previousUid != null) await _clearPersistedSession(previousUid);
    _invalidateSessionCache(); // prevent stale in-memory session from fast-pathing the router
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

      // Kick off resolveSession() immediately so the session cache is
      // populated before the router's redirect fires — same pattern as
      // loginWithMatriculeOrEmail(). Without this, an admin signing in via
      // email lands on the user home screen due to the async race.
      unawaited(resolveSession(
        User(uid: firebaseUser.uid, email: firebaseUser.email ?? ''),
      ));

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
          unawaited(NotificationService.instance.onUserLoggedIn());
          return User.fromMap(pendingData);
        } catch (e) {
          developer.log('Failed to restore pending profile: $e', name: 'AuthController');
        }
      }

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
    _actingAsUser = false; // clear any stale user-mode from a previous session
    final previousUid = _firebaseAuth.currentUser?.uid;
    if (previousUid != null) await _clearPersistedSession(previousUid);
    _invalidateSessionCache(); // prevent stale in-memory session from fast-pathing the router
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

      final uid = firebaseUser.uid;
      final email = (firebaseUser.email ?? '').trim().toLowerCase();

      // Run all three reads in parallel to minimise the window between
      // signInWithCredential() firing the auth stream and the router calling
      // resolveSession(). The faster we detect admin and set the cache, the
      // less chance there is of the router landing on the user home screen.
      // Email-based collection queries may fail with permission-denied for
      // non-privileged users (users limit>1, admins list query). Fall back to
      // reading only the UID-keyed doc so regular sign-ins are not blocked.
      late final DocumentSnapshot<Map<String, dynamic>> userDoc;
      QuerySnapshot<Map<String, dynamic>>? usersByEmail;
      QuerySnapshot<Map<String, dynamic>>? legacyAdmins;

      try {
        final results = await Future.wait([
          _firestore.collection(Col.users).doc(uid).get(),
          if (email.isNotEmpty)
            _firestore
                .collection(Col.users)
                .where('email', isEqualTo: email)
                .limit(2)
                .get()
          else
            Future.value(null),
          if (email.isNotEmpty)
            _firestore
                .collection(Col.admins)
                .where('email', isEqualTo: email)
                .limit(1)
                .get()
          else
            Future.value(null),
        ]);
        userDoc = results[0] as DocumentSnapshot<Map<String, dynamic>>;
        usersByEmail = results[1] as QuerySnapshot<Map<String, dynamic>>?;
        legacyAdmins = results[2] as QuerySnapshot<Map<String, dynamic>>?;
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied') rethrow;
        // Regular user — collection queries denied; read only own doc.
        userDoc = await _firestore.collection(Col.users).doc(uid).get();
      }

      if (userDoc.exists) {
        if (isSignUp) {
          await _firebaseAuth.signOut();
          throw Exception('auth.error.google_account_already_exists');
        }
        final accessError = await _validateAndNormalizeUserAccess(
          uid: uid,
          enforceRestriction: true,
        );
        if (accessError != null) {
          await _firebaseAuth.signOut();
          throw Exception(accessError);
        }

        // If this Google account has role:'user' but the same email belongs
        // to an admin account under a different UID (two-account problem),
        // promote the Google account immediately so both methods work.
        final googleRole = userDoc.data()?['role']?.toString() ?? 'user';
        if (!RoleGuard.isPrivileged(googleRole) && email.isNotEmpty) {
          Map<String, dynamic>? linkedAdminData;

          for (final doc in usersByEmail?.docs ?? <QueryDocumentSnapshot<Map<String, dynamic>>>[]) {
            if (doc.id != uid &&
                RoleGuard.isPrivileged(
                    doc.data()['role']?.toString() ?? '')) {
              linkedAdminData = doc.data();
              break;
            }
          }
          linkedAdminData ??= legacyAdmins?.docs.isNotEmpty == true
              ? legacyAdmins!.docs.first.data()
              : null;

          if (linkedAdminData != null) {
            final adminRole = linkedAdminData['role']?.toString() ?? 'admin';
            final sessionRole = RoleGuard.isSuperAdmin(adminRole)
                ? SessionRole.superAdmin
                : SessionRole.admin;

            // Set the session cache IMMEDIATELY (synchronous) so the router's
            // fast path finds admin before authStateChanges emits.
            _cacheSession(
              uid,
              SessionResult(
                role: sessionRole,
                adminType: linkedAdminData['adminType'] as String?,
                adminRole: adminRole,
                adminMatricule:
                    (linkedAdminData['matricule'] ?? '').toString(),
                adminName: (linkedAdminData['firstName'] ??
                        linkedAdminData['name'] ??
                        '')
                    .toString(),
              ),
            );

            // Repair Firestore doc in the background so next sign-in is instant.
            final updates = <String, dynamic>{'role': adminRole};
            if (linkedAdminData['adminType'] != null) {
              updates['adminType'] = linkedAdminData['adminType'];
            }
            if ((linkedAdminData['matricule'] ?? '').toString().isNotEmpty) {
              updates['matricule'] = linkedAdminData['matricule'];
            }
            unawaited(_firestore
                .collection(Col.users)
                .doc(uid)
                .update(updates)
                .catchError((_) {}));
          }
        }

        // Resolve and cache the session SYNCHRONOUSLY (awaited) before this
        // method returns. This mirrors loginWithMatriculeOrEmail, which caches
        // the admin role before the auth screen reads it.
        //
        // Why awaiting matters for Google sign-in: an admin account created via
        // createUserWithEmailAndPassword carries a 'password' provider, so the
        // `currentUser` getter returns null while emailVerified is false UNLESS
        // a privileged session is already cached. With a fire-and-forget
        // resolveSession the cache was still empty when _handleGoogleSignIn
        // checked currentUser, so the screen's direct `context.go('/admin')`
        // was skipped and the admin landed on the user home screen until the
        // async resolve finished and a later navigation re-triggered the
        // router. Awaiting guarantees the admin session is cached first.
        final prewarmUser = User(uid: uid, email: firebaseUser.email ?? '');
        final prewarmSession = await resolveSession(prewarmUser);
        developer.log(
          '[GoogleDbg] signInWithGoogle existing-doc branch: uid=$uid '
          'docRole=${userDoc.data()?['role']} '
          'resolvedRole=${prewarmSession.role.name} '
          'isPrivileged=${prewarmSession.isPrivileged}',
          name: 'AuthController',
        );
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
        // Guard: if this Google email already belongs to an admin (either in
        // the users collection under a different UID, or still in the legacy
        // admins collection), block the sign-in instead of silently creating a
        // new regular-user document that would shadow their admin role.
        final normalizedEmail = (firebaseUser.email ?? '').toLowerCase().trim();
        if (normalizedEmail.isNotEmpty) {
          final usersByEmail = await _firestore
              .collection(Col.users)
              .where('email', isEqualTo: normalizedEmail)
              .limit(1)
              .get();
          if (usersByEmail.docs.isNotEmpty) {
            final existingDoc = usersByEmail.docs.first;
            final existingRole =
                (existingDoc.data()['role'] ?? 'user').toString();
            if (RoleGuard.isAdmin(existingRole) ||
                RoleGuard.isSuperAdmin(existingRole)) {
              await _firebaseAuth.signOut();
              throw Exception('auth.error.admin_use_admin_login');
            }
            // Mode B (multiple-accounts-per-email): Firebase created a new UID
            // for the Google sign-in but a regular-user doc already exists for
            // this email under a different UID. Roll back the new account and
            // offer linking instead of silently duplicating the user.
            if (existingDoc.id != uid) {
              await _firebaseAuth.signOut();
              await firebaseUser.delete().catchError((_) {});
              _pendingLinkCredential = credential;
              _pendingLinkEmail = normalizedEmail;
              throw Exception('auth.error.link_required');
            }
          }

          try {
            final adminsByEmail = await _firestore
                .collection(Col.admins)
                .where('email', isEqualTo: normalizedEmail)
                .limit(1)
                .get();
            if (adminsByEmail.docs.isNotEmpty) {
              await _firebaseAuth.signOut();
              throw Exception('auth.error.admin_use_admin_login');
            }
          } on FirebaseException catch (e) {
            if (e.code != 'permission-denied') rethrow;
            // Non-privileged users can't list admins — safe to proceed.
          }
        }

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
        userData['authProvider'] = 'google.com';
        // Registration timestamp — used to hide admin broadcasts sent before
        // this account existed (matches the email-signup profile).
        userData['createdAt'] = FieldValue.serverTimestamp();
        userData['updatedAt'] = FieldValue.serverTimestamp();
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
      if (e.code == 'account-exists-with-different-credential') {
        // Mode A (one-account-per-email): store the Google credential so the
        // UI can prompt for the password and call linkGoogleToPendingAccount().
        _pendingLinkCredential = e.credential;
        _pendingLinkEmail = (e.email ?? '').toLowerCase().trim();
        throw Exception('auth.error.link_required');
      }
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

  /// Signs in with the existing email/password account and links the pending
  /// Google credential to it. After this call the user can authenticate with
  /// either provider. Throws if [password] is wrong, the email is unverified,
  /// or the account is banned/blocked.
  Future<User?> linkGoogleToPendingAccount(String password) async {
    final pendingCredential = _pendingLinkCredential;
    final email = _pendingLinkEmail;
    if (pendingCredential == null || email == null || email.isEmpty) {
      throw Exception('auth.error.generic');
    }
    _actingAsUser = false;
    try {
      final userCredential = await _firebaseAuth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      final firebaseUser = userCredential.user;
      if (firebaseUser == null) throw Exception('auth.error.generic');

      if (!firebaseUser.emailVerified) {
        await _firebaseAuth.signOut();
        throw Exception('email_not_verified:$email');
      }

      final accessError = await _validateAndNormalizeUserAccess(
        uid: firebaseUser.uid,
        enforceRestriction: true,
      );
      if (accessError != null) {
        await _firebaseAuth.signOut();
        throw Exception(accessError);
      }

      // Attach Google as a second sign-in provider to the existing account.
      await firebaseUser.linkWithCredential(pendingCredential);
      _pendingLinkCredential = null;
      _pendingLinkEmail = null;

      unawaited(resolveSession(
        User(uid: firebaseUser.uid, email: firebaseUser.email ?? ''),
      ));

      final userDoc = await _firestore
          .collection(Col.users)
          .doc(firebaseUser.uid)
          .get();
      unawaited(NotificationService.instance.onUserLoggedIn());
      if (userDoc.exists) {
        return User.fromMap(userDoc.data() ?? {});
      }
      return User(uid: firebaseUser.uid, email: firebaseUser.email ?? '');
    } on firebase_auth.FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    } on Exception {
      rethrow;
    } catch (e) {
      developer.log('linkGoogleToPendingAccount error: $e', name: 'AuthController');
      throw Exception('auth.error.generic');
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
      developer.log(
        '[GoogleDbg] resolveSession CACHE HIT uid=${current.uid} '
        'role=${_cachedSession!.role.name}',
        name: 'AuthController',
      );
      return _cachedSession!;
    }

    try {
      // Retry transient `unavailable` errors here: this is the read that
      // decides admin vs user routing, and it frequently fires `unavailable`
      // in the window right after a Google sign-in (see _getDocWithRetry).
      final userDoc = await _getDocWithRetry(
        _firestore.collection(Col.users).doc(current.uid),
        requireField: 'role',
      );

      developer.log(
        '[GoogleDbg] resolveSession READ uid=${current.uid} '
        'exists=${userDoc.exists} role=${userDoc.data()?['role']}',
        name: 'AuthController',
      );

      // Safety net: an existing doc with no `role` is a partial/stale read
      // (a real user doc always has a role). Never cache a guessed `user` for
      // it — that mis-routes an admin to the user home screen for 5 minutes.
      // Return guest WITHOUT caching so the next resolve re-reads cleanly.
      if (userDoc.exists && (userDoc.data()?['role'] == null)) {
        developer.log(
          '[GoogleDbg] resolveSession PARTIAL READ (role missing) — '
          'returning guest without caching uid=${current.uid}',
          name: 'AuthController',
        );
        return const SessionResult(role: SessionRole.guest);
      }

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

      // Belt-and-suspenders: users doc exists with role 'user', but check the
      // admins collection in case this account was promoted and the users doc
      // role was never updated (e.g. legacy admin with a users doc shadow).
      final adminFallback =
          await _firestore.collection(Col.admins).doc(current.uid).get();
      if (adminFallback.exists) {
        final ad = adminFallback.data() ?? {};
        // Repair the users doc so this extra read doesn't happen again.
        unawaited(
          _firestore.collection(Col.users).doc(current.uid).update({
            'role': 'admin',
            'adminType': ad['role'],
          }).catchError((_) {}),
        );
        final fallbackResult = SessionResult(
          role: SessionRole.admin,
          adminType: ad['role'] as String?,
          adminRole: ad['role'] as String?,
          adminMatricule: (ad['matricule'] ?? '').toString(),
          adminName: ad['name'] as String?,
        );
        _cacheSession(current.uid, fallbackResult);
        return fallbackResult;
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
      developer.log(
        '[GoogleDbg] resolveSession DOC-MISSING race default → user '
        'uid=${current.uid}',
        name: 'AuthController',
      );
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
      // Only restore a persisted session when it grants a privileged role.
      // A stale 'user' cache must never silently demote an admin and prevent
      // the router from redirecting them to /admin.
      if (persisted != null && persisted.isPrivileged) {
        _cacheSession(current.uid, persisted);
        developer.log(
          'resolveSession restored cached privileged role after transient failure: $e',
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
  }) async {
    try {
      final updateData = <String, dynamic>{};
      if (username != null) updateData['username'] = username;
      if (firstName != null) updateData['firstName'] = firstName;
      if (lastName != null) updateData['lastName'] = lastName;
      if (avatarId != null) updateData['avatarId'] = avatarId;
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

      // Block password reset for Google-only accounts.
      //
      // This check MUST run server-side. During the forgot-password flow the
      // user is signed out, so the client cannot read the `users` collection
      // (Firestore rules require an authenticated caller) and the deprecated
      // fetchSignInMethodsForEmail returns an empty list when Email Enumeration
      // Protection is enabled. The `getEmailSignInProviders` Cloud Function uses
      // the Admin SDK to read the account's real linked providers.
      //
      // Fail-open policy: if the function is unreachable we proceed with the
      // reset so a transient outage cannot block every legitimate email/password
      // user. The Google-only block only takes effect once the function returns
      // isGoogleOnly == true.
      try {
        final result = await FirebaseFunctions.instance
            .httpsCallable('getEmailSignInProviders')
            .call<dynamic>(<String, dynamic>{'email': normalizedEmail});
        final data = Map<String, dynamic>.from(result.data as Map);
        developer.log(
          'getEmailSignInProviders($normalizedEmail) → $data',
          name: 'AuthController',
        );
        if (data['isGoogleOnly'] == true) {
          developer.log(
            'Rejecting password reset for Google-only account: $normalizedEmail',
            name: 'AuthController',
          );
          throw Exception('auth.error.google_only_use_google');
        }
      } on Exception catch (e) {
        if (e.toString().contains('auth.error.google_only_use_google')) {
          rethrow;
        }
        // Function unavailable / network error — fail open and continue.
        developer.log(
          'getEmailSignInProviders check failed, proceeding with reset: $e',
          name: 'AuthController',
        );
      }

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
    } on Exception {
      rethrow;
    } catch (e) {
      developer.log(
        'Send password reset email error: $e',
        name: 'AuthController',
        error: e,
      );
      throw Exception('auth.error.password_reset_failed');
    }
  }

  // ── Admin / privileged sign-in methods ──────────────────────────────────────

  /// Signs in an admin or super-admin using their real email or matricule + password.
  /// For matricule input (no '@'), the real email is resolved from
  /// [Col.adminLoginLookup] — no @admin.local format is ever used.
  Future<AdminAuthResult> loginWithMatriculeOrEmail({
    required String emailOrMatricule,
    required String password,
  }) async {
    _actingAsUser = false;
    // Clear any stale session before sign-in so the router's resolveSession()
    // call (triggered by the Firebase Auth stream) reads fresh from Firestore
    // instead of returning a cached role from a previous session.
    final previousUid = _firebaseAuth.currentUser?.uid;
    if (previousUid != null) await _clearPersistedSession(previousUid);
    _invalidateSessionCache();

    final sanitizedInput = emailOrMatricule.trim();

    if (sanitizedInput.isEmpty || password.isEmpty) {
      return const AdminAuthResult(
        isAuthenticated: false,
        errorMessage: 'Email/matricule et mot de passe sont requis.',
      );
    }

    try {
      // Resolve email: if input has '@' use it directly, otherwise look up
      // the real email from admin_login_lookup by matricule.
      String email;
      if (sanitizedInput.contains('@')) {
        email = sanitizedInput.toLowerCase();
      } else {
        final lookupDoc = await _firestore
            .collection(Col.adminLoginLookup)
            .doc(sanitizedInput.toLowerCase())
            .get();
        final resolved =
            (lookupDoc.data()?['email'] as String? ?? '').trim().toLowerCase();
        if (resolved.isEmpty) {
          return const AdminAuthResult(
            isAuthenticated: false,
            errorMessage: 'Matricule non reconnu. Vérifiez votre matricule ou connectez-vous avec votre email.',
          );
        }
        email = resolved;
      }

      final firebase_auth.UserCredential credential;
      try {
        credential = await _firebaseAuth.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
      } on firebase_auth.FirebaseAuthException {
        rethrow;
      }

      final uid = credential.user?.uid;
      if (uid == null) {
        return const AdminAuthResult(
          isAuthenticated: false,
          errorMessage: 'Authentication failed: no user returned.',
        );
      }

      // Kick off resolveSession() immediately after sign-in so the session
      // cache is populated before the router's redirect fires.
      // resolveSession() checks the admins collection as a fallback (Fix 2),
      // so it correctly returns admin role even for legacy accounts where
      // users/{uid} has role:"user".
      unawaited(resolveSession(User(uid: uid, email: email)));

      Map<String, dynamic>? adminData;
      final userDoc = await _firestore.collection(Col.users).doc(uid).get();
      final userRole = userDoc.data()?['role']?.toString() ?? '';
      if (userDoc.exists && RoleGuard.isPrivileged(userRole)) {
        adminData = userDoc.data();
      } else {
        final adminDoc =
            await _firestore.collection(Col.admins).doc(uid).get();
        if (adminDoc.exists) adminData = adminDoc.data();
      }

      if (adminData == null) {
        await _firebaseAuth.signOut();
        return const AdminAuthResult(
          isAuthenticated: false,
          errorMessage: 'Admin profile not found.',
        );
      }

      final status = (adminData['status'] ?? 'active').toString();
      if (status == 'suspended' || status == 'inactive') {
        await _firebaseAuth.signOut();
        return const AdminAuthResult(
          isAuthenticated: false,
          errorMessage:
              'Ce compte administrateur a été désactivé. Contactez un super administrateur.',
        );
      }

      final firstName = (adminData['firstName'] as String?)?.trim() ?? '';
      final lastName = (adminData['lastName'] as String?)?.trim() ?? '';
      final legacyName = (adminData['name'] as String?)?.trim() ?? '';
      final resolvedName = firstName.isNotEmpty
          ? [firstName, lastName].where((s) => s.isNotEmpty).join(' ')
          : legacyName.isNotEmpty
          ? legacyName
          : null;
      final resolvedType =
          (adminData['adminType'] as String?) ?? (adminData['role'] as String?);

      // Pre-warm the session cache with the confirmed admin role so the router
      // routes to /admin immediately when the Firebase Auth stream fires,
      // without waiting for resolveSession() to re-read Firestore.
      final sessionRole = RoleGuard.isSuperAdmin(resolvedType)
          ? SessionRole.superAdmin
          : SessionRole.admin;
      _cacheSession(
        uid,
        SessionResult(
          role: sessionRole,
          adminType: resolvedType,
          adminRole: resolvedType,
          adminMatricule: (adminData['matricule'] ?? sanitizedInput).toString(),
          adminName: resolvedName,
        ),
        accountStatus: (adminData['status'] ?? 'active').toString(),
      );

      return AdminAuthResult(
        isAuthenticated: true,
        role: resolvedType,
        name: resolvedName,
        matricule: (adminData['matricule'] ?? sanitizedInput).toString(),
      );
    } on firebase_auth.FirebaseAuthException catch (e) {
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

  /// Sends a password-reset email to an admin using their email or matricule.
  /// If [emailOrMatricule] has no '@', it is treated as a matricule and the
  /// real email is resolved from [Col.adminLoginLookup] before sending.
  Future<void> sendAdminPasswordResetRequest(String emailOrMatricule) async {
    final input = emailOrMatricule.trim();
    if (input.contains('@')) {
      return sendPasswordResetEmail(input);
    }
    // Matricule path: look up real email from Firestore.
    final lookupDoc = await _firestore
        .collection(Col.adminLoginLookup)
        .doc(input.toLowerCase())
        .get();
    final email =
        (lookupDoc.data()?['email'] as String? ?? '').trim().toLowerCase();
    if (email.isEmpty) {
      throw Exception('auth.error.matricule_not_found');
    }
    return sendPasswordResetEmail(email);
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
      'account-exists-with-different-credential' => 'auth.error.link_required',
      _ => 'auth.error.generic',
    });
  }

  Future<String?> _validateAndNormalizeUserAccess({
    required String uid,
    required bool enforceRestriction,
  }) async {
    // Retry transient `unavailable` errors so a Firestore connection blip right
    // after Google sign-in doesn't abort the whole sign-in flow.
    final userDoc = await _getDocWithRetry(
      _firestore.collection(Col.users).doc(uid),
    );
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
