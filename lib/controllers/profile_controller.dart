import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:get_it/get_it.dart';
import 'dart:developer' as developer;
import 'package:image_picker/image_picker.dart';
import '../models/user_model.dart';
import '../services/avatar_service.dart';
import '../constants/firestore_collections.dart';

// Fields that only privileged server-side code or admins may change.
// Regular users must never write these through profile update paths.
const _kProtectedFields = {
  'uid',
  'status',
  'banUntil',
  'role',
  'adminType',
  'permissions',
};

class ProfileController {
  ProfileController() {
    _profileSub = _buildProfileStream().listen(
      _streamController.add,
      onError: _streamController.addError,
      cancelOnError: false,
    );
  }

  final firebase_auth.FirebaseAuth _firebaseAuth =
      GetIt.I<firebase_auth.FirebaseAuth>();
  final FirebaseFirestore _firestore = GetIt.I<FirebaseFirestore>();

  final _streamController = StreamController<User?>.broadcast();
  StreamSubscription<User?>? _profileSub;

  Stream<User?> get profileStream => _streamController.stream;

  void dispose() {
    _profileSub?.cancel();
    _streamController.close();
  }

  Stream<User?> _buildProfileStream() {
    return _firebaseAuth.authStateChanges().asyncExpand((firebase_auth.User? user) {
      if (user == null) return Stream<User?>.value(null);

      return _firestore.collection(Col.users).doc(user.uid).snapshots().map((userDoc) {
        try {
          if (!userDoc.exists) {
            return User(uid: user.uid, email: user.email ?? '');
          }
          final userData = userDoc.data() ?? <String, dynamic>{};
          userData['uid'] = _getStringValue(userData['uid'], user.uid);
          userData['email'] = _getStringValue(userData['email'], user.email ?? '');
          return User.fromMap(userData);
        } catch (e) {
          developer.log('Error mapping profile stream: $e', name: 'ProfileController');
          return User(uid: user.uid, email: user.email ?? '');
        }
      });
    });
  }

  String _getStringValue(dynamic value, String defaultValue) {
    if (value is String && value.isNotEmpty) return value;
    if (value != null) return value.toString();
    return defaultValue;
  }

  // Short exponential backoff (up to 4 attempts) for transient Firestore delays.
  Future<User?> getCurrentProfile() async {
    final firebaseUser = _firebaseAuth.currentUser;
    if (firebaseUser == null) return null;

    const maxAttempts = 4;
    var delayMs = 150;
    Exception? lastError;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final userDoc = await _firestore.collection(Col.users).doc(firebaseUser.uid).get();
        final userData = userDoc.data() ?? <String, dynamic>{};

        userData['uid'] = _getStringValue(userData['uid'], firebaseUser.uid);
        userData['email'] = _getStringValue(userData['email'], firebaseUser.email ?? '');

        return User.fromMap(userData);
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        if (attempt == maxAttempts) {
          developer.log(
            'getCurrentProfile Error after $maxAttempts attempts: $lastError',
            name: 'ProfileController',
          );
          break;
        }
      }

      await Future<void>.delayed(Duration(milliseconds: delayMs));
      delayMs *= 2;
    }

    return User(
      uid: firebaseUser.uid,
      email: firebaseUser.email ?? '',
    );
  }

  // Strips protected fields before writing so users can't escalate their own role.
  Future<bool> updateProfile(User profile) async {
    final firebaseUser = _firebaseAuth.currentUser;
    if (firebaseUser == null) return false;

    try {
      final profileMap = Map<String, dynamic>.from(
        profile.copyWith(uid: firebaseUser.uid).toMap(),
      )..removeWhere((key, _) => _kProtectedFields.contains(key));

      await _firestore
          .collection(Col.users)
          .doc(firebaseUser.uid)
          .set(profileMap, SetOptions(merge: true));
      return true;
    } catch (e) {
      developer.log('Error updating profile: $e', name: 'ProfileController');
      return false;
    }
  }

  Future<bool> updateProfileFields(Map<String, dynamic> fields) async {
    final firebaseUser = _firebaseAuth.currentUser;
    if (firebaseUser == null) return false;

    fields.removeWhere((key, _) => _kProtectedFields.contains(key));
    if (fields.isEmpty) return true;

    try {
      await _firestore.collection(Col.users).doc(firebaseUser.uid).set(
            fields,
            SetOptions(merge: true),
          );
      return true;
    } catch (e) {
      developer.log('Error updating profile fields: $e', name: 'ProfileController');
      return false;
    }
  }

  // Stores the download URL in customAvatarUrl field after successful upload.
  Future<String?> uploadCustomAvatar({
    required XFile imageFile,
    void Function(double progress)? onProgress,
  }) async {
    final firebaseUser = _firebaseAuth.currentUser;
    if (firebaseUser == null) {
      developer.log('Cannot upload avatar: user not authenticated', name: 'ProfileController');
      return null;
    }

    try {
      final avatarService = AvatarService();
      final downloadUrl = await avatarService.uploadAvatar(
        uid: firebaseUser.uid,
        imageFile: imageFile,
        onProgress: onProgress,
      );

      if (downloadUrl != null) {
        await updateProfileFields({
          'customAvatarUrl': downloadUrl,
          'avatarUpdatedAt': FieldValue.serverTimestamp(),
        });
      }

      return downloadUrl;
    } catch (e) {
      developer.log('Error uploading custom avatar: $e', name: 'ProfileController');
      return null;
    }
  }

  // Returns null on success; error strings are French constants (_PasswordErrors).
  // Controller has no BuildContext — l10n is the caller's responsibility.
  Future<String?> changePassword(String currentPassword, String newPassword) async {
    final firebaseUser = _firebaseAuth.currentUser;
    if (firebaseUser == null) {
      return _PasswordErrors.notAuthenticated;
    }

    if (newPassword.length < 6) {
      return _PasswordErrors.tooShort;
    }

    if (currentPassword == newPassword) {
      return _PasswordErrors.sameAsCurrent;
    }

    try {
      final credential = firebase_auth.EmailAuthProvider.credential(
        email: firebaseUser.email ?? '',
        password: currentPassword,
      );

      await firebaseUser.reauthenticateWithCredential(credential);
      await firebaseUser.updatePassword(newPassword);

      // Stamp audit field — non-blocking so a Firestore hiccup doesn't
      // fail the password change that already succeeded in Firebase Auth.
      _firestore
          .collection(Col.users)
          .doc(firebaseUser.uid)
          .update({'passwordChangedAt': FieldValue.serverTimestamp()})
          .catchError((Object e) {
            developer.log(
              'passwordChangedAt update failed: $e',
              name: 'ProfileController',
            );
          });

      return null;
    } on firebase_auth.FirebaseAuthException catch (e) {
      developer.log(
        'Error changing password (${e.code}): ${e.message}',
        name: 'ProfileController',
      );

      switch (e.code) {
        case 'wrong-password':
        case 'invalid-credential':
          return _PasswordErrors.wrongCurrentPassword;
        case 'weak-password':
          return _PasswordErrors.tooWeak;
        case 'requires-recent-login':
          return _PasswordErrors.requiresRecentLogin;
        case 'too-many-requests':
          return _PasswordErrors.tooManyRequests;
        case 'user-disabled':
          return _PasswordErrors.userDisabled;
        case 'user-not-found':
          return _PasswordErrors.userNotFound;
        default:
          return 'Échec du changement de mot de passe: ${e.message}';
      }
    } catch (e) {
      developer.log('Error changing password: $e', name: 'ProfileController');
      return _PasswordErrors.genericFailure;
    }
  }

  Future<void> refreshUserProfile() async {
    final firebaseUser = _firebaseAuth.currentUser;
    if (firebaseUser == null) return;

    try {
      await firebaseUser.reload();
      developer.log('User profile refreshed', name: 'ProfileController');
    } catch (e) {
      developer.log('Failed to refresh user profile: $e', name: 'ProfileController');
    }
  }

  Future<bool> profileExists() async {
    final firebaseUser = _firebaseAuth.currentUser;
    if (firebaseUser == null) return false;

    try {
      final doc = await _firestore.collection(Col.users).doc(firebaseUser.uid).get();
      return doc.exists;
    } catch (e) {
      developer.log('Error checking profile existence: $e', name: 'ProfileController');
      return false;
    }
  }
}

// French error strings for changePassword() — no BuildContext available here.
abstract final class _PasswordErrors {
  static const notAuthenticated      = 'Utilisateur non connecté';
  static const tooShort              = 'Le nouveau mot de passe doit contenir au moins 6 caractères';
  static const sameAsCurrent         = 'Le nouveau mot de passe doit être différent de l\'ancien';
  static const wrongCurrentPassword  = 'Le mot de passe actuel est incorrect';
  static const tooWeak               = 'Le nouveau mot de passe est trop faible';
  static const requiresRecentLogin   = 'Session expirée. Veuillez vous reconnecter puis réessayer';
  static const tooManyRequests       = 'Trop de tentatives. Veuillez réessayer plus tard';
  static const userDisabled          = 'Ce compte a été désactivé';
  static const userNotFound          = 'Utilisateur non trouvé';
  static const genericFailure        = 'Échec du changement de mot de passe';
}