import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'audit_log_service.dart';

class AdminUserService {
  AdminUserService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  static const String _usersCollection = 'users';

  Future<void> _logAdminAction({
    required String action,
    required String targetUid,
    required Map<String, dynamic> details,
  }) async {
    final currentUser = _auth.currentUser;
    await AuditLogService(firestore: _firestore).logAdminAction(
      action: action,
      targetUid: targetUid,
      actorUid: currentUser?.uid,
      actorEmail: currentUser?.email,
      details: details,
    );
  }

  Future<void> banUser(String userId, {required int days}) async {
    final until = DateTime.now().add(Duration(days: days));
    await _firestore.collection(_usersCollection).doc(userId).update({
      'status': 'banned',
      'banUntil': Timestamp.fromDate(until),
    });
    unawaited(_logAdminAction(
      action: 'ban_user',
      targetUid: userId,
      details: {
        'days': days,
        'banUntil': until.toIso8601String(),
      },
    ));
  }

  Future<void> blockUser(String userId) async {
    await _firestore.collection(_usersCollection).doc(userId).update({
      'status': 'blocked',
      'banUntil': null,
    });
    unawaited(_logAdminAction(
      action: 'block_user',
      targetUid: userId,
      details: const {
        'status': 'blocked',
      },
    ));
  }

  Future<void> unblockUser(String userId) async {
    await _firestore.collection(_usersCollection).doc(userId).update({
      'status': 'active',
      'banUntil': null,
    });
    unawaited(_logAdminAction(
      action: 'unblock_user',
      targetUid: userId,
      details: const {
        'status': 'active',
      },
    ));
  }
}
