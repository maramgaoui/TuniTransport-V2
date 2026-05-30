import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:tuni_transport/constants/firestore_collections.dart';
import 'package:tuni_transport/l10n/app_localizations.dart';
import 'package:tuni_transport/services/admin_user_service.dart';
import 'package:tuni_transport/controllers/auth_controller.dart';
import 'package:tuni_transport/utils/role_guard.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

mixin AdminModerationMixin<T extends StatefulWidget> on State<T> {
  final AdminUserService _adminUserService = GetIt.I<AdminUserService>();

  Future<bool> _targetIsPrivileged(String userId) async {
    try {
      final firestore = GetIt.I<FirebaseFirestore>();
      final doc = await firestore
          .collection(Col.admins)
          .doc(userId)
          .get();
      if (doc.exists) return true;
      final userDoc = await firestore
          .collection(Col.users)
          .doc(userId)
          .get();
      final role = userDoc.data()?['role']?.toString();
      return RoleGuard.isPrivileged(role);
    } on FirebaseException {
      // Network failure: deny the action rather than risk moderating an admin.
      return true;
    }
  }

  Future<void> banUserWithFeedback(
    BuildContext context,
    String userId, {
    required int days,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    
    final currentUser = AuthController.instance.currentUser;
    if (currentUser != null && currentUser.uid == userId) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Cannot ban your own account.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (await _targetIsPrivileged(userId)) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot moderate another administrator.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    
    try {
      await _adminUserService.banUser(userId, days: days);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.userBannedDays(days))),
      );
    } on FirebaseException catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.firestoreUpdateError),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> blockUserWithFeedback(BuildContext context, String userId) async {
    final l10n = AppLocalizations.of(context)!;
    
    // Prevent self-block: check if target user is the current admin
    final currentUser = AuthController.instance.currentUser;
    if (currentUser != null && currentUser.uid == userId) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Cannot block your own account.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (await _targetIsPrivileged(userId)) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot moderate another administrator.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    
    try {
      await _adminUserService.blockUser(userId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.userBlockedPermanently)),
      );
    } on FirebaseException catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.firestoreUpdateError),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> unblockUserWithFeedback(
    BuildContext context,
    String userId,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    
    // Prevent self-unblock: check if target user is the current admin
    final currentUser = AuthController.instance.currentUser;
    if (currentUser != null && currentUser.uid == userId) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Cannot modify your own account from this action.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (await _targetIsPrivileged(userId)) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot moderate another administrator.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    
    try {
      await _adminUserService.unblockUser(userId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.userUnblocked)),
      );
    } on FirebaseException catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.firestoreUpdateError),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
