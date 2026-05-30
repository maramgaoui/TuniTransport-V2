import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../constants/firestore_collections.dart';
import 'admin_notification_service.dart';
import 'audit_log_service.dart';

class AdminUserService {
  AdminUserService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
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

  Future<String> _resolveUsername(String userId) async {
    try {
      final doc = await _firestore.collection(Col.users).doc(userId).get();
      final data = doc.data() ?? {};
      final username = (data['username'] ?? '').toString().trim();
      if (username.isNotEmpty) return username;
      return (data['email'] ?? userId).toString();
    } catch (_) {
      return userId;
    }
  }

  Future<void> banUser(String userId, {required int days}) async {
    final until    = DateTime.now().add(Duration(days: days));
    final username = await _resolveUsername(userId);
    await _firestore.collection(Col.users).doc(userId).update({
      'status':   'banned',
      'banUntil': Timestamp.fromDate(until),
    });
    unawaited(AdminNotificationService.notifyUserBanned(username: username, days: days));
    unawaited(_logAdminAction(
      action: 'ban_user',
      targetUid: userId,
      details: {'days': days, 'banUntil': until.toIso8601String()},
    ));
  }

  Future<void> blockUser(String userId) async {
    final username = await _resolveUsername(userId);
    await _firestore.collection(Col.users).doc(userId).update({
      'status':   'blocked',
      'banUntil': null,
    });
    unawaited(AdminNotificationService.notifyUserBlocked(username: username));
    unawaited(_logAdminAction(
      action: 'block_user',
      targetUid: userId,
      details: const {'status': 'blocked'},
    ));
  }

  Future<void> unblockUser(String userId) async {
    final username = await _resolveUsername(userId);
    await _firestore.collection(Col.users).doc(userId).update({
      'status':   'active',
      'banUntil': null,
    });
    unawaited(AdminNotificationService.notifyUserUnblocked(username: username));
    unawaited(_logAdminAction(
      action: 'unblock_user',
      targetUid: userId,
      details: const {'status': 'active'},
    ));
  }
}
