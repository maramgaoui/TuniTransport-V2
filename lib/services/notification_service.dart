import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../controllers/auth_controller.dart';
import '../controllers/notification_controller.dart';
import '../constants/firestore_collections.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  bool _initialized = false;
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<RemoteMessage>? _openedAppSubscription;

  bool get _isMessagingSupported {
    if (kIsWeb) return false;

    // Firebase Messaging token APIs are not available on Windows/Linux.
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  Future<void> initialize() async {
    if (_initialized) return;

    if (!_isMessagingSupported) {
      if (kDebugMode) debugPrint('Firebase Messaging is not supported on this platform. Skipping init.');
      _initialized = true;
      return;
    }

    final permStatus = await _requestPermissions();
    if (permStatus == AuthorizationStatus.denied) {
      _initialized = true;
      return;
    }
    await _initializeToken();
    _registerTokenRefreshHandler();
    _registerForegroundHandler();
    _registerOpenedAppHandler();
    await _handleInitialMessage();

    _initialized = true;
  }

  Future<AuthorizationStatus> _requestPermissions() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    if (kDebugMode) debugPrint('Notification permission status: ${settings.authorizationStatus}');
    return settings.authorizationStatus;
  }

  Future<void> _initializeToken() async {
    try {
      final token = await _messaging.getToken();
      if (token != null && token.isNotEmpty) {
        await _saveTokenToCurrentUser(token);
      }
      if (kDebugMode) {
        debugPrint('FCM token initialized.');
      }
    } on MissingPluginException {
      // Defensive fallback for desktop targets where channel impl is absent.
      if (kDebugMode) debugPrint('FCM getToken is not implemented on this platform.');
    } catch (e) {
      // Do not crash app startup if FCM token provisioning is temporarily
      // unavailable (for example after key restriction changes).
      if (kDebugMode) debugPrint('FCM token initialization failed: $e');
    }
  }

  void _registerTokenRefreshHandler() {
    _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = _messaging.onTokenRefresh.listen((token) async {
      if (token.isEmpty) return;
      await _saveTokenToCurrentUser(token);
    });
  }

  Future<void> _saveTokenToCurrentUser(String token) async {
    final uid = AuthController.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;

    try {
      await FirebaseFirestore.instance.collection(Col.users).doc(uid).set({
        'fcmToken': token,
      }, SetOptions(merge: true));
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to persist FCM token: $e');
    }
  }

  /// Called when a user logs in. Ensures FCM token is saved to Firestore
  /// (in case the initial attempt in initialize() happened before auth).
  Future<void> onUserLoggedIn() async {
    // Reload this user's notifications on every login. The app only calls
    // NotificationController.initialize() once at startup, so without this a
    // logout → login cycle (same app session) would leave the list empty and
    // newly pushed admin broadcasts would never be fetched.
    unawaited(NotificationController.instance.initialize());

    if (!_isMessagingSupported) return;

    try {
      final token = await _messaging.getToken();
      if (token != null && token.isNotEmpty) {
        await _saveTokenToCurrentUser(token);
        if (kDebugMode) debugPrint('FCM token saved on user login.');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to save FCM token on login: $e');
    }
  }

  /// Removes the FCM token from the current user's Firestore document.
  /// Call this on sign-out so stale tokens don't accumulate across accounts.
  Future<void> clearTokenFromCurrentUser() async {
    final uid = AuthController.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;
    try {
      await FirebaseFirestore.instance
          .collection(Col.users)
          .doc(uid)
          .update({'fcmToken': FieldValue.delete()});
    } catch (_) {}
  }

  void _registerForegroundHandler() {
    _foregroundSubscription?.cancel();
    _foregroundSubscription = FirebaseMessaging.onMessage.listen((message) {
      if (kDebugMode) debugPrint('Foreground notification received: ${message.messageId}');
      NotificationController.instance.addFromRemoteMessage(message);
    });
  }

  void _registerOpenedAppHandler() {
    _openedAppSubscription?.cancel();
    _openedAppSubscription = FirebaseMessaging.onMessageOpenedApp.listen((message) {
      if (kDebugMode) debugPrint('Opened from notification: ${message.messageId}');
      NotificationController.instance.addFromRemoteMessage(message);
    });
  }

  Future<void> _handleInitialMessage() async {
    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage == null) return;

    if (kDebugMode) debugPrint('Initial notification open: ${initialMessage.messageId}');
    NotificationController.instance.addFromRemoteMessage(initialMessage);
  }

  Future<void> dispose() async {
    await _tokenRefreshSubscription?.cancel();
    await _foregroundSubscription?.cancel();
    await _openedAppSubscription?.cancel();
    _tokenRefreshSubscription = null;
    _foregroundSubscription = null;
    _openedAppSubscription = null;
  }
}
