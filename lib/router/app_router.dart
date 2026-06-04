import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/admin_dashboard.dart';
import '../screens/profile_screen.dart';
import '../screens/manage_users_screen.dart';
import '../screens/manage_journeys_screen.dart';
import '../screens/manage_tariffs_screen.dart';
import '../screens/manage_admins_screen.dart';
import '../screens/send_notifications_screen.dart';
import '../controllers/auth_controller.dart';
import '../models/journey_model.dart';
import '../models/metro_sahel_result.dart';
import '../models/session_result.dart';
import '../models/taxi_collectif_result.dart';
import '../screens/auth_screen.dart';
import '../screens/home_screen.dart';
import '../screens/active_journey_screen.dart';
import '../screens/journey_details_screen.dart';
import '../screens/journey_results_screen.dart';
import '../screens/splash_screen.dart';
import '../screens/super_admin_dashboard.dart';
import '../screens/route_map_screen.dart';
class AppRouter {
  AppRouter._();

  static GoRouter create({
    required AuthController authController,
  }) {
    final refresh = _GoRouterRefreshStream(
      authController.authStateChanges,
      authController.sessionChanges,
    );

    const adminLocation = '/admin';

    return GoRouter(
      initialLocation: '/splash',
      refreshListenable: refresh,
      redirect: (context, state) async {
        final path = state.uri.path;
        final user = authController.currentUser;
        debugPrint('[Router] path=$path uid=${user?.uid} cached=${authController.cachedSession?.role.name} acting=${authController.isActingAsUser}');

        final isSuperAdminRoute = path.startsWith('/super-admin');
        final isPublic = path == '/auth' || path == '/splash';

        if (user == null) {
          if (path == '/splash') return '/auth';
          // Grace period: a transient Firebase null auth event (common during
          // Google sign-in on web, or token refresh) must not kick an admin
          // who just landed on /admin back to /auth.
          final cachedPrivileged =
              authController.cachedSession?.isPrivileged ?? false;
          if (cachedPrivileged &&
              (path.startsWith('/admin') || isSuperAdminRoute)) {
            return null;
          }
          if (isSuperAdminRoute) return '/auth';
          if (isPublic) return null;
          return '/auth';
        }

        // Fast path: use the cached session for all paths to avoid a Firestore
        // round-trip and eliminate the async race that causes admin to land on
        // the user home screen on subsequent sign-ins.
        final cached = authController.cachedSession;
        if (cached != null) {
          final actingAsUser = authController.isActingAsUser;
          if (cached.isPrivileged && !actingAsUser) {
            // Cached admin session — redirect everywhere except admin area.
            if (path == '/auth' ||
                path == '/splash' ||
                path.startsWith('/home') ||
                path == '/') {
              return adminLocation;
            }
            // Admin on admin area — stay.
            if (path.startsWith('/admin') || isSuperAdminRoute) return null;
          }
          if (cached.isUser || actingAsUser) {
            if (path == '/auth' || path == '/splash' || path == '/') {
              return '/home/journey-input';
            }
            if (path.startsWith('/admin') || isSuperAdminRoute) {
              return actingAsUser ? '/home/journey-input' : null;
            }
            return null;
          }
        }

        // Slow path: cache miss — resolve from Firestore.
        // Splash has no UI, so fall back to /auth on failure.
        SessionResult session;
        try {
          session = await authController.resolveSession(user);
        } catch (_) {
          return path == '/splash' ? '/auth' : null;
        }

        if (session.isGuest) {
          return path == '/splash' ? '/auth' : null;
        }

        final actingAsUser = authController.isActingAsUser;

        if (session.isSuperAdmin && !actingAsUser) {
          if (path == '/splash' || path == '/auth' || path.startsWith('/home')) {
            return adminLocation;
          }
          return null;
        }

        if (session.isAdmin && !actingAsUser) {
          if (path == '/splash' || path == '/auth' || path.startsWith('/home')) {
            return adminLocation;
          }
          if (path == '/admin/manage-admins') return adminLocation;
          if (isSuperAdminRoute) return adminLocation;
          return null;
        }

        // Privileged user in user mode — block navigation back to admin areas.
        if (actingAsUser && session.isPrivileged) {
          if (path.startsWith('/admin') || isSuperAdminRoute) {
            return '/home/journey-input';
          }
        }

        if (path.startsWith('/admin')) return '/home/journey-input';
        if (isSuperAdminRoute) return '/home/journey-input';
        if (path == '/splash' || path == '/auth' || path == '/') {
          return '/home/journey-input';
        }

        return null;
      },
      routes: [
        GoRoute(
          path: '/splash',
          builder: (context, state) => const SplashScreen(),
        ),
        GoRoute(
          path: '/auth',
          builder: (context, state) => const AuthScreen(),
        ),
        // All /home/* tabs render the same HomeScreen; it derives the active tab from the path.
        for (final tabPath in const [
          '/home',
          '/home/journey-input',
          '/home/favorites',
          '/home/notifications',
          '/home/chat',
          '/home/profile',
        ])
          GoRoute(
            path: tabPath,
            builder: (context, state) => const HomeScreen(),
          ),
        GoRoute(
          path: '/home/journey-results',
          builder: (context, state) {
            final extra = state.extra;
            if (extra is Map<String, dynamic>) {
              return JourneyResultsScreen(
                departure: (extra['departure'] ?? '').toString(),
                arrival: (extra['arrival'] ?? '').toString(),
                fromStationId: extra['fromStationId']?.toString(),
                toStationId: extra['toStationId']?.toString(),
              );
            }
            return const HomeScreen();
          },
        ),
        GoRoute(
          path: '/home/journey-details',
          builder: (context, state) {
            final extra = state.extra;
            if (extra is Journey) {
              return JourneyDetailsScreen(journey: extra);
            }
            if (extra is MetroSahelResult) {
              return JourneyDetailsScreen(metroResult: extra);
            }
            if (extra is TaxiCollectifResult) {
              final h = extra.durationMinutes ~/ 60;
              final m = extra.durationMinutes % 60;
              final dur = h > 0 ? '${h}h ${m}min' : '$m min';
              final journey = Journey(
                id:               extra.id,
                departureStation: extra.fromCityName,
                arrivalStation:   extra.toCityName,
                departureTime:    '--:--',
                price:            extra.fare.toStringAsFixed(3),
                type:             'Taxi Collectif',
                iconKey:          'taxi',
                duration:         dur,
                transfers:        0,
                isOptimal:        false,
                operator:         'Taxi Collectif',
                line:             '${extra.distanceKm.toStringAsFixed(0)} km',
                estimatedTripDurationMinutes: extra.durationMinutes,
              );
              return JourneyDetailsScreen(journey: journey);
            }
            return const HomeScreen();
          },
        ),
        GoRoute(
          path: '/home/active-journey',
          builder: (context, state) {
            final extra = state.extra;
            if (extra is Map<String, dynamic>) {
              final journey = extra['journey'] as Journey?;
              if (journey != null) {
                return ActiveJourneyScreen(
                  journey:       journey,
                  fromStationId: extra['fromStationId'] as String?,
                  toStationId:   extra['toStationId']   as String?,
                  metroResult:   extra['metroResult']   as MetroSahelResult?,
                );
              }
            }
            if (extra is Journey) {
              return ActiveJourneyScreen(journey: extra);
            }
            return const HomeScreen();
          },
        ),
        GoRoute(
          path: '/home/route-map',
          builder: (context, state) {
            final extra = state.extra;
            if (extra is Map<String, dynamic>) {
              return RouteMapScreen(
                stationIds: List<String>.from(extra['stationIds'] as List? ?? []),
                routeTitle: extra['routeTitle']?.toString(),
                lineNumber: extra['lineNumber']?.toString(),
              );
            }
            return const HomeScreen();
          },
        ),
        GoRoute(
          path: '/admin',
          builder: (context, state) => const AdminDashboard(),
        ),
        GoRoute(
          path: '/admin/manage-users',
          builder: (context, state) => const ManageUsersScreen(),
        ),
        GoRoute(
          path: '/admin/manage-journeys',
          builder: (context, state) => const ManageJourneysScreen(),
        ),
        GoRoute(
          path: '/admin/manage-tariffs',
          builder: (context, state) => const ManageTariffsScreen(),
        ),
        GoRoute(
          path: '/admin/manage-admins',
          builder: (context, state) => const ManageAdminsScreen(),
        ),
        GoRoute(
          path: '/admin/send-notifications',
          builder: (context, state) => const SendNotificationsScreen(),
        ),
        GoRoute(
          path: '/admin/profile',
          builder: (context, state) => const ProfileScreen(isAdminContext: true),
        ),
        GoRoute(
          path: '/super-admin/dashboard',
          builder: (context, state) => const SuperAdminDashboard(),
        ),
      ],
    );
  }
}

/// Bridges a [Stream] into a [ChangeNotifier] so [GoRouter.refreshListenable]
/// can react to auth-state changes.
///
/// **Lifecycle:** GoRouter calls [dispose] on its [refreshListenable] when the
/// router itself is disposed (e.g. when the owning widget is unmounted).
/// If GoRouter ever changes this contract, the owning widget must call
/// `dispose()` explicitly.
class _GoRouterRefreshStream extends ChangeNotifier {
  _GoRouterRefreshStream(
    Stream<dynamic> authStream,
    Stream<void> sessionStream,
  ) {
    _authSub = authStream.listen((_) => notifyListeners());
    _sessionSub = sessionStream.listen((_) => notifyListeners());
  }

  late final StreamSubscription<dynamic> _authSub;
  late final StreamSubscription<void> _sessionSub;

  @override
  void dispose() {
    _authSub.cancel();
    _sessionSub.cancel();
    super.dispose();
  }
}
