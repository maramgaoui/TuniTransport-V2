import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../constants/firestore_collections.dart';
import 'package:go_router/go_router.dart';
import 'package:tuni_transport/l10n/app_localizations.dart';
import 'package:tuni_transport/theme/app_theme.dart';
import '../../widgets/app_header.dart';

class SendNotificationsScreen extends StatefulWidget {
  const SendNotificationsScreen({super.key});

  @override
  State<SendNotificationsScreen> createState() =>
      _SendNotificationsScreenState();
}

class _SendNotificationsScreenState extends State<SendNotificationsScreen> {
  final CollectionReference<Map<String, dynamic>> _notificationsRef =
      FirebaseFirestore.instance.collection(Col.notifications);
  final CollectionReference<Map<String, dynamic>> _usersRef =
      FirebaseFirestore.instance.collection(Col.users);

  final titleCtrl = TextEditingController();
  final messageCtrl = TextEditingController();
  bool _isSending = false;
  DateTime? _lastSentAt;
  Timer? _cooldownTicker;
  String selectedTarget = 'all'; // all, admins, super_admins

  int get _cooldownRemainingSeconds {
    final last = _lastSentAt;
    if (last == null) {
      return 0;
    }
    final elapsed = DateTime.now().difference(last).inSeconds;
    final remaining = 10 - elapsed;
    return remaining > 0 ? remaining : 0;
  }

  void _startCooldownTicker() {
    _cooldownTicker?.cancel();
    _cooldownTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _cooldownRemainingSeconds == 0) {
        _cooldownTicker?.cancel();
        _cooldownTicker = null;
        return;
      }
      setState(() {});
    });
  }

  Future<int> _estimateRecipients(String target) async {
    final AggregateQuery query;
    switch (target) {
      case 'admins':
        query = _usersRef.where('role', isNotEqualTo: 'user').count();
      case 'super_admins':
        query = _usersRef.where('role', isEqualTo: 'super_admin').count();
      default: // 'all'
        query = _usersRef.count();
    }
    final snapshot = await query.get();
    return snapshot.count ?? 0;
  }

  Future<void> _sendNotification() async {
    final l10n = AppLocalizations.of(context)!;

    if (_cooldownRemainingSeconds > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.sendNotificationCooldown(_cooldownRemainingSeconds))),
      );
      return;
    }

    if (titleCtrl.text.isEmpty || messageCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.fillAllFields)),
      );
      return;
    }

    setState(() => _isSending = true);
    try {
      final recipients = await _estimateRecipients(selectedTarget);
      await _notificationsRef.add({
        'title': titleCtrl.text.trim(),
        'message': messageCtrl.text.trim(),
        'target': selectedTarget,
        'recipientsCount': recipients,
        'auto': false,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      titleCtrl.clear();
      messageCtrl.clear();
      _lastSentAt = DateTime.now();
      _startCooldownTicker();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.notificationSavedForRecipients(recipients)),
        ),
      );
    } on FirebaseException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? l10n.firestoreUpdateError)),
      );
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(80),
        child: AppHeader(
          title: l10n.sendNotifications,
          subtitle: 'Alertes et annonces',
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () {
              if (Navigator.of(context).canPop()) {
                context.pop();
              } else {
                context.go('/admin');
              }
            },
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Compose section
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: AppTheme.lightGrey),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.composeNotification,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: titleCtrl,
                      maxLength: 100,
                      decoration: InputDecoration(
                        labelText: l10n.title,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: messageCtrl,
                      maxLines: 4,
                      maxLength: 500,
                      decoration: InputDecoration(
                        labelText: l10n.content,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.recipients,
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    DropdownButton<String>(
                      isExpanded: true,
                      value: selectedTarget,
                      items: const [
                        DropdownMenuItem(
                          value: 'all',
                          child: Row(
                            children: [
                              Icon(Icons.people, size: 18, color: AppTheme.primaryTeal),
                              SizedBox(width: 8),
                              Text('Tous les utilisateurs'),
                            ],
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'admins',
                          child: Row(
                            children: [
                              Icon(Icons.admin_panel_settings, size: 18, color: AppTheme.primaryTeal),
                              SizedBox(width: 8),
                              Text('Admins & Super admins'),
                            ],
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'super_admins',
                          child: Row(
                            children: [
                              Icon(Icons.security, size: 18, color: AppTheme.primaryTeal),
                              SizedBox(width: 8),
                              Text('Super admins uniquement'),
                            ],
                          ),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => selectedTarget = v);
                      },
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryTeal,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: (_isSending || _cooldownRemainingSeconds > 0)
                          ? null
                          : _sendNotification,
                        icon: _isSending
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.send),
                        label: Text(
                          _isSending
                              ? l10n.sendingInProgress
                              : (_cooldownRemainingSeconds > 0
                                  ? l10n.sendNotificationResend(_cooldownRemainingSeconds)
                                  : l10n.sendNotificationAction),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _cooldownTicker?.cancel();
    titleCtrl.dispose();
    messageCtrl.dispose();
    super.dispose();
  }
}
