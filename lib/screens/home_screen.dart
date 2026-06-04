import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tuni_transport/l10n/app_localizations.dart';
import 'package:tuni_transport/theme/app_theme.dart';
import '../controllers/auth_controller.dart';
import '../services/active_journey_service.dart';
import 'journey_input_screen.dart';
import 'favorites_screen.dart';
import 'notification_screen.dart';
import 'chat_screen.dart';
import 'profile_screen.dart';
import '../models/journey_model.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final List<Widget> _screens;
  int _selectedIndex = 0;
  // Tracks which tabs have been visited at least once.
  // Only visited tabs are mounted — avoids a burst of 5 simultaneous
  // Firestore queries that blocks the Android main thread (ANR on MIUI).
  final Set<int> _mountedTabs = {0};

  @override
  void initState() {
    super.initState();
    _screens = [
      const JourneyInputScreen(),
      const FavoritesScreen(),
      const NotificationScreen(),
      const ChatScreen(),
      const ProfileScreen(),
    ];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Sync tab index from URL. The guard below prevents redundant setState calls.
    final path = GoRouterState.of(context).uri.path;
    final fromUrl = _tabIndexFromLocation(path);
    if (fromUrl != _selectedIndex) {
      _selectedIndex = fromUrl;
      _mountedTabs.add(fromUrl);
    }
  }

  static int _tabIndexFromLocation(String path) {
    if (path.startsWith('/home/favorites')) return 1;
    if (path.startsWith('/home/notifications')) return 2;
    if (path.startsWith('/home/chat')) return 3;
    if (path.startsWith('/home/profile')) return 4;
    return 0;
  }


  static const _tabPaths = [
    '/home/journey-input',
    '/home/favorites',
    '/home/notifications',
    '/home/chat',
    '/home/profile',
  ];

  void _onTabTapped(int index) {
    if (index == _selectedIndex) return;
    setState(() {
      _selectedIndex = index;
      _mountedTabs.add(index);
    });
    context.go(_tabPaths[index]);
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (innerContext) {
        final l10n = AppLocalizations.of(innerContext)!;
        final selectedIndex = _selectedIndex;

    // Wrap the shell in inherited text direction to keep RTL/LTR behavior consistent.
    return Directionality(
      textDirection: Directionality.of(context),
      child: PopScope(
        canPop: selectedIndex == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) context.go('/home/journey-input');
        },
        child: Scaffold(
        key: const Key('home_screen'),
        body: Column(
          children: [
            if (AuthController.instance.isActingAsUser)
              _AdminModeBanner(
                isSuperAdmin: AuthController.instance.cachedSession?.isSuperAdmin ?? false,
                onSwitch: () {
                  AuthController.instance.switchToAdminMode();
                  context.go('/admin');
                },
              ),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeTop: AuthController.instance.isActingAsUser,
                child: IndexedStack(
                  index: selectedIndex,
                  children: List.generate(
                    _screens.length,
                    (i) => _mountedTabs.contains(i)
                        ? _screens[i]
                        : const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ],
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButton: ListenableBuilder(
          listenable: ActiveJourneyService.instance,
          builder: (context, _) {
            final Journey? activeJourney =
                ActiveJourneyService.instance.activeJourney;
            if (activeJourney == null) {
              return const SizedBox.shrink();
            }

            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FloatingActionButton.extended(
                heroTag: 'active-journey-shortcut',
                onPressed: () => context.push(
                  '/home/active-journey',
                  extra: activeJourney,
                ),
                backgroundColor: AppTheme.primaryTeal,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.navigation),
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 170),
                  child: Text(
                    '${activeJourney.departureStation} -> ${activeJourney.arrivalStation}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            );
          },
        ),
        bottomNavigationBar: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          currentIndex: selectedIndex,
          onTap: _onTabTapped,
          backgroundColor: Theme.of(context).colorScheme.surface,
          selectedItemColor: Theme.of(context).colorScheme.primary,
          unselectedItemColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
          selectedLabelStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
          unselectedLabelStyle: const TextStyle(
            fontSize: 12,
          ),
          items: [
            BottomNavigationBarItem(
              icon: Icon(Icons.location_on_outlined, key: const Key('home_nav_journeys_icon')),
              activeIcon: Icon(Icons.location_on, key: const Key('home_nav_journeys_active_icon')),
              label: l10n.journeys,
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.favorite_border),
              activeIcon: Icon(Icons.favorite),
              label: l10n.favorites,
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.notifications_none),
              activeIcon: Icon(Icons.notifications),
              label: l10n.notifications,
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.chat_bubble_outline),
              activeIcon: Icon(Icons.chat_bubble),
              label: l10n.messages,
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person_outline, key: const Key('home_nav_profile_icon')),
              activeIcon: Icon(Icons.person, key: const Key('home_nav_profile_active_icon')),
              label: l10n.profile,
            ),
          ],
        ),
      ),
      ),
    );
      },
    );
  }
}

class _AdminModeBanner extends StatelessWidget {
  const _AdminModeBanner({required this.onSwitch, this.isSuperAdmin = false});

  final VoidCallback onSwitch;
  final bool isSuperAdmin;

  @override
  Widget build(BuildContext context) {
    final roleLabel = isSuperAdmin ? 'Super Admin' : 'Admin';
    final dashboardLabel = isSuperAdmin ? 'Dashboard Super Admin' : 'Dashboard Admin';
    final bannerColor = isSuperAdmin ? const Color(0xFF4A148C) : const Color(0xFF1A6B5E);

    return Material(
      color: bannerColor,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              const Icon(Icons.shield_outlined, color: Colors.white70, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Mode utilisateur · $roleLabel',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white54),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onSwitch,
                icon: const Icon(Icons.switch_account, size: 16),
                label: Text(dashboardLabel, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

