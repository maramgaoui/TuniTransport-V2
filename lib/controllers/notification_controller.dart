import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:get_it/get_it.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tuni_transport/models/notification_model.dart';

import '../constants/firestore_collections.dart';
import 'auth_controller.dart';

class NotificationController extends ChangeNotifier {
  NotificationController._();

  static final NotificationController instance = NotificationController._();
  static const String _storageKey = 'local_notifications_v2';
  static const String _l10nPrefix = 'l10n:';

  final List<NotificationModel> _notifications = [];
  SharedPreferences? _prefs;
  bool _initialized = false;
  bool _isLoading = false;
  String? _initializedForUid;

  // Serial write queue — prevents concurrent SharedPreferences writes from
  // overwriting each other with a stale snapshot. Each call to
  // _persistToStorage() snapshots the list at call time and chains the write
  // onto the tail of the queue, so writes are always in call order and the
  // last write always reflects the most recent state.
  Future<void> _persistQueue = Future.value();

  /// Clears in-memory and persisted notification data immediately on sign-out.
  /// Prevents stale notifications from leaking to the next account on a
  /// shared device before the next user's [initialize()] runs.
  Future<void> resetForSignOut() async {
    _notifications.clear();
    _initialized = false;
    _initializedForUid = null;
    _prefs = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_storageKey);
    } catch (_) {}
    notifyListeners();
  }

  @override
  void dispose() { // ignore: must_call_super
    // Singleton — intentionally skips super.dispose(). Calling it would mark
    // this ChangeNotifier as dead and make every subsequent notifyListeners()
    // throw.
  }

  Future<void> initialize() async {
    final uid = AuthController.instance.currentUser?.uid;
    if (_initialized && _initializedForUid == uid) return;
    if (_isLoading) return;

    // Switching users — discard the previous user's data before loading.
    if (_initializedForUid != null && _initializedForUid != uid) {
      _notifications.clear();
      _prefs = null;
      _initialized = false;
    }

    _isLoading = true;
    try {
      await _loadFromStorage();
      await _loadFromFirestore();
      await _loadBroadcastNotifications();
      await ensureSystemAnnouncement();
      _initialized = true;
      _initializedForUid = uid;
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationController] Initialization error: $e');
    } finally {
      _isLoading = false;
    }
  }

  List<NotificationModel> get notifications =>
      List<NotificationModel>.unmodifiable(_notifications);

  int get unreadCount =>
      _notifications.where((notification) => !notification.isRead).length;

  int get unreadChatCount => _notifications
      .where(
        (notification) =>
            notification.type == NotificationType.chat && !notification.isRead,
      )
      .length;

  String _l10nToken(String key) => '$_l10nPrefix$key';

  void addNotification(NotificationModel notification) {
    if (_notifications.any((n) => n.id == notification.id)) {
      if (kDebugMode) debugPrint('[NotificationController] Duplicate notification ignored: ${notification.id}');
      return;
    }

    _notifications.insert(0, notification);
    notifyListeners();
    _persistToStorage();
    unawaited(_writeToFirestore(notification));
  }

  void addFromRemoteMessage(RemoteMessage message) {
    final data = message.data;

    String title;
    String body;

    if (message.notification?.title != null &&
        message.notification!.title!.isNotEmpty) {
      title = message.notification!.title!;
    } else if (data['title'] != null && data['title'].toString().isNotEmpty) {
      title = data['title'].toString();
    } else {
      title = _l10nToken('newNotificationTitle');
    }

    if (message.notification?.body != null &&
        message.notification!.body!.isNotEmpty) {
      body = message.notification!.body!;
    } else if (data['body'] != null && data['body'].toString().isNotEmpty) {
      body = data['body'].toString();
    } else {
      body = _l10nToken('receivedNotificationBody');
    }

    final type = _typeFromString(data['type']?.toString());

    final String id;
    final rawDocId = data['docId']?.toString();
    final rawId = message.messageId;
    if (rawDocId != null && rawDocId.isNotEmpty) {
      // Stable ID matching _loadBroadcastNotifications() so FCM delivery and
      // startup load don't produce duplicate entries for the same broadcast.
      id = 'broadcast_$rawDocId';
    } else if (rawId != null && rawId.isNotEmpty) {
      id = rawId;
    } else {
      final bucket = DateTime.now().millisecondsSinceEpoch ~/ 120000;
      id = '${title.hashCode ^ body.hashCode ^ type.index}_$bucket';
    }

    addNotification(
      NotificationModel(
        id: id,
        title: title,
        body: body,
        type: type,
        timestamp: DateTime.now(),
        isRead: false,
      ),
    );
  }

  Future<void> ensureSystemAnnouncement() async {
    final hasAnnouncement = _notifications.any(
      (notification) => notification.type == NotificationType.system,
    );
    if (hasAnnouncement) return;

    final ref = _notifRef();
    if (ref != null) {
      try {
        final existing = await ref
            .where('type', isEqualTo: NotificationType.system.name)
            .limit(1)
            .get();
        if (existing.docs.isNotEmpty) return;
      } catch (_) {}
    }

    addNotification(
      NotificationModel(
        id: 'system_announcement_${DateTime.now().microsecondsSinceEpoch}',
        title: _l10nToken('systemAnnouncementTitle'),
        body: _l10nToken('systemWelcomeBody'),
        type: NotificationType.system,
        timestamp: DateTime.now(),
        isRead: false,
      ),
    );
  }

  void markAsRead(String id) {
    final index = _notifications.indexWhere(
      (notification) => notification.id == id,
    );
    if (index == -1) return;
    if (_notifications[index].isRead) return;

    _notifications[index] = _notifications[index].copyWith(isRead: true);
    notifyListeners();
    _persistToStorage();
    unawaited(_markIdsReadInFirestore([id]));
  }

  void markAllAsRead() {
    final unreadIds = _notifications
        .where((n) => !n.isRead)
        .map((n) => n.id)
        .toList();
    if (unreadIds.isEmpty) return;

    for (var i = 0; i < _notifications.length; i++) {
      if (!_notifications[i].isRead) {
        _notifications[i] = _notifications[i].copyWith(isRead: true);
      }
    }
    notifyListeners();
    _persistToStorage();
    unawaited(_markIdsReadInFirestore(unreadIds));
  }

  void markAllChatAsRead() {
    final unreadChatIds = _notifications
        .where((n) => n.type == NotificationType.chat && !n.isRead)
        .map((n) => n.id)
        .toList();
    if (unreadChatIds.isEmpty) return;

    for (var i = 0; i < _notifications.length; i++) {
      if (_notifications[i].type == NotificationType.chat &&
          !_notifications[i].isRead) {
        _notifications[i] = _notifications[i].copyWith(isRead: true);
      }
    }
    notifyListeners();
    _persistToStorage();
    unawaited(_markIdsReadInFirestore(unreadChatIds));
  }

  Future<void> _loadFromStorage() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_storageKey);
    if (raw == null || raw.isEmpty) return;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;

      _notifications
        ..clear()
        ..addAll(
          decoded.whereType<Map<String, dynamic>>().map(
            (json) => NotificationModel.fromJson(json),
          ),
        );
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationController] Failed to load from storage: $e');
    }
  }

  // Snapshots the current list, then chains the write onto _persistQueue so
  // concurrent callers never race: the snapshot captured at call-time is
  // written in call order, and each write sees the state at its own moment.
  Future<void> _persistToStorage() {
    final snapshot = _notifications.map((item) => item.toJson()).toList();
    _persistQueue = _persistQueue.whenComplete(() => _runPersist(snapshot));
    return _persistQueue;
  }

  Future<void> _runPersist(List<Map<String, dynamic>> payload) async {
    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(payload));
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationController] Failed to persist to storage: $e');
    }
  }

  CollectionReference<Map<String, dynamic>>? _notifRef() {
    final uid = AuthController.instance.currentUser?.uid;
    if (uid == null) return null;
    return GetIt.I<FirebaseFirestore>()
        .collection(Col.users)
        .doc(uid)
        .collection(Col.notifications);
  }

  Future<void> _loadBroadcastNotifications() async {
    final uid = AuthController.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final db = GetIt.I<FirebaseFirestore>();
      final userDoc = await db.collection(Col.users).doc(uid).get();
      final role = (userDoc.data()?['role'] as String?) ?? 'user';

      final List<String> targets;
      switch (role) {
        case 'super_admin':
          targets = ['all', 'admins', 'super_admins'];
        case 'admin':
          targets = ['all', 'admins'];
        default:
          targets = ['all'];
      }

      final snap = await db
          .collection(Col.notifications)
          .where('target', whereIn: targets)
          .limit(50)
          .get();

      bool changed = false;
      for (final doc in snap.docs) {
        final broadcastId = 'broadcast_${doc.id}';
        if (_notifications.any((n) => n.id == broadcastId)) continue;

        final data = doc.data();
        final title = (data['title'] as String?) ?? '';
        final body = (data['message'] as String?) ?? '';
        if (title.isEmpty && body.isEmpty) continue;

        final ts = (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
        _notifications.add(NotificationModel(
          id: broadcastId,
          title: title,
          body: body,
          type: NotificationType.system,
          timestamp: ts,
          isRead: false,
        ));
        changed = true;
      }

      if (changed) {
        _notifications.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationController] Broadcast load failed: $e');
    }
  }

  Future<void> _loadFromFirestore() async {
    final ref = _notifRef();
    if (ref == null) return;
    try {
      final snap = await ref
          .orderBy('timestamp', descending: true)
          .limit(100)
          .get();
      for (final doc in snap.docs) {
        final model = NotificationModel.fromJson(doc.data());
        if (!_notifications.any((n) => n.id == model.id)) {
          _notifications.add(model);
        }
      }
      _notifications.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationController] Firestore load failed: $e');
    }
  }

  Future<void> _writeToFirestore(NotificationModel notification) async {
    final ref = _notifRef();
    if (ref == null) return;
    try {
      await ref.doc(notification.id).set(notification.toJson());
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationController] Firestore write failed: $e');
    }
  }

  Future<void> _markIdsReadInFirestore(List<String> ids) async {
    if (ids.isEmpty) return;
    final ref = _notifRef();
    if (ref == null) return;
    try {
      final batch = GetIt.I<FirebaseFirestore>().batch();
      for (final id in ids) {
        batch.update(ref.doc(id), {'isRead': true});
      }
      await batch.commit();
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationController] Firestore batch update failed: $e');
    }
  }

  NotificationType _typeFromString(String? rawType) {
    if (rawType == null) return NotificationType.system;

    switch (rawType.toLowerCase()) {
      case 'chat':
        return NotificationType.chat;
      case 'journey':
        return NotificationType.journey;
      case 'system':
      default:
        return NotificationType.system;
    }
  }
}
