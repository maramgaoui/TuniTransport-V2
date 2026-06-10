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
  static const String _storageKeyBase = 'local_notifications_v2';
  static const String _l10nPrefix = 'l10n:';

  // Per-user local cache key. Keeping each account's cache under its own key
  // means sign-out never has to delete it (no cross-account leak on a shared
  // device — user B simply reads their own key), so notifications survive a
  // sign-out / sign-in cycle.
  String _storageKeyForUid(String? uid) =>
      (uid == null || uid.isEmpty) ? _storageKeyBase : '${_storageKeyBase}_$uid';

  String get _currentStorageKey =>
      _storageKeyForUid(AuthController.instance.currentUser?.uid);

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

  // Real-time listener on the global `notifications` collection so admin
  // broadcasts reach recipients live (a one-time get only loads what existed at
  // login). Filtered to the user's audience in-memory; cancelled on sign-out.
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _broadcastSub;
  String? _broadcastListenerUid;

  // The signed-in user's account creation time. Broadcasts created before this
  // are skipped so a freshly registered user does not inherit older admin
  // notifications. Null = no filter (unknown registration time).
  DateTime? _registeredAt;

  /// Clears only the in-memory list on sign-out so the UI does not show the
  /// previous user's notifications. The persisted copy (per-user local cache +
  /// Firestore) is intentionally KEPT — sign-out must never delete a user's
  /// notifications; they are restored when the same user signs back in.
  /// Cross-account leakage is prevented by the per-user storage key
  /// ([_storageKeyForUid]) and by the user-switch guard in [initialize].
  Future<void> resetForSignOut() async {
    _stopBroadcastListener();
    _registeredAt = null;
    _notifications.clear();
    _initialized = false;
    _initializedForUid = null;
    _prefs = null;
    notifyListeners();
  }

  static List<String> _broadcastTargetsForRole(String role) {
    switch (role) {
      case 'super_admin':
        return const ['all', 'admins', 'super_admins'];
      case 'admin':
        return const ['all', 'admins'];
      default:
        return const ['all'];
    }
  }

  /// Adds any broadcast docs the user is targeted by that aren't already in the
  /// list. Returns true if the list changed (caller decides when to notify).
  bool _ingestBroadcastDocs(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    List<String> targets,
  ) {
    var changed = false;
    for (final doc in docs) {
      final data = doc.data();
      final target = (data['target'] as String?) ?? 'all';
      if (!targets.contains(target)) continue;

      final broadcastId = 'broadcast_${doc.id}';
      if (_notifications.any((n) => n.id == broadcastId)) continue;

      final title = (data['title'] as String?) ?? '';
      final body = (data['message'] as String?) ?? '';
      if (title.isEmpty && body.isEmpty) continue;

      final ts = (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
      // Skip broadcasts sent before this user registered.
      if (_registeredAt != null && ts.isBefore(_registeredAt!)) continue;

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
    return changed;
  }

  /// Subscribes to new admin broadcasts so they appear the moment they are sent.
  /// Orders only by `createdAt` (no composite index needed) and filters the
  /// audience in-memory.
  Future<void> _startBroadcastListener() async {
    final uid = AuthController.instance.currentUser?.uid;
    if (uid == null) return;
    if (_broadcastSub != null && _broadcastListenerUid == uid) return;

    await _broadcastSub?.cancel();
    _broadcastListenerUid = uid;

    final db = GetIt.I<FirebaseFirestore>();
    var targets = const ['all'];
    try {
      final userDoc = await db.collection(Col.users).doc(uid).get();
      final role = (userDoc.data()?['role'] as String?) ?? 'user';
      targets = _broadcastTargetsForRole(role);
      _registeredAt = (userDoc.data()?['createdAt'] as Timestamp?)?.toDate();
    } catch (_) {}

    _broadcastSub = db
        .collection(Col.notifications)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .listen(
      (snap) {
        if (_ingestBroadcastDocs(snap.docs, targets)) {
          notifyListeners();
        }
      },
      onError: (Object e) {
        if (kDebugMode) {
          debugPrint('[NotificationController] Broadcast listener error: $e');
        }
      },
    );
  }

  void _stopBroadcastListener() {
    unawaited(_broadcastSub?.cancel());
    _broadcastSub = null;
    _broadcastListenerUid = null;
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
      // Subscribe for live admin broadcasts so they arrive without a refresh.
      await _startBroadcastListener();
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationController] Initialization error: $e');
    } finally {
      _isLoading = false;
      // The loaders above append to _notifications without notifying; notify
      // once here so the notifications screen (an AnimatedBuilder on this
      // controller) repaints when a post-login / refresh load completes.
      notifyListeners();
    }
  }

  /// Re-fetches notifications from Firestore + admin broadcasts WITHOUT clearing
  /// the in-memory list (loaders dedupe by id). Use this to pick up new admin
  /// broadcasts while the user is already signed in — e.g. when the
  /// notifications tab is opened.
  Future<void> refresh() async {
    if (_isLoading) return;
    _isLoading = true;
    try {
      await _loadFromFirestore();
      await _loadBroadcastNotifications();
      await ensureSystemAnnouncement();
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationController] Refresh error: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
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

    // Admin broadcasts carry the source doc id and are added to the in-app list
    // by the real-time Firestore listener ([_startBroadcastListener]). Skipping
    // them here prevents a second copy when an FCM push for the same broadcast
    // is delivered in the foreground / on open. Non-broadcast pushes (e.g.
    // account-status changes) carry no docId and are still handled below.
    final broadcastDocId = data['docId']?.toString() ?? '';
    if (broadcastDocId.isNotEmpty) return;

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

    // Broadcasts already returned above, so this is a non-broadcast push.
    final String id;
    final rawId = message.messageId;
    if (rawId != null && rawId.isNotEmpty) {
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
    final raw = _prefs!.getString(_currentStorageKey);
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
    // Capture the key at call time so the write always lands in the key of the
    // user who owned the list when persistence was requested.
    final key = _currentStorageKey;
    _persistQueue = _persistQueue.whenComplete(() => _runPersist(snapshot, key));
    return _persistQueue;
  }

  Future<void> _runPersist(List<Map<String, dynamic>> payload, String key) async {
    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode(payload));
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
      final targets = _broadcastTargetsForRole(role);

      // Order by createdAt only (single-field, no composite index) and filter
      // the audience in-memory via _ingestBroadcastDocs.
      final snap = await db
          .collection(Col.notifications)
          .orderBy('createdAt', descending: true)
          .limit(50)
          .get();

      _ingestBroadcastDocs(snap.docs, targets);
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
