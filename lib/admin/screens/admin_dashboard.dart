import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tuni_transport/controllers/auth_controller.dart';
import 'package:tuni_transport/models/session_result.dart';
import 'package:tuni_transport/controllers/notification_controller.dart';
import 'package:tuni_transport/l10n/app_localizations.dart';
import 'package:tuni_transport/screens/profile_screen.dart';
import 'package:tuni_transport/screens/chat_screen.dart';
import 'package:tuni_transport/theme/app_theme.dart';
import 'package:tuni_transport/utils/notification_l10n.dart';

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  int _selectedIndex = 0;
  SessionResult? _session;

  @override
  void initState() {
    super.initState();
    _resolveTrustedSession();
  }

  Future<void> _resolveTrustedSession() async {
    final currentUser = AuthController.instance.currentUser;
    if (currentUser == null) {
      if (!mounted) return;
      context.go('/admin/login');
      return;
    }

    try {
      final session = await AuthController.instance.resolveSession(currentUser);

      if (!mounted) return;

      if (session.isGuest) {
        context.go('/admin/login');
        return;
      }

      setState(() {
        _session = session;
      });
    } catch (_) {
      if (!mounted) return;
      context.go('/admin/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_session == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final l10n = AppLocalizations.of(context)!;
    final trustedRole = _session?.adminType;
    final isSuperAdmin = _session?.isSuperAdmin ?? false;

    final pages = <Widget>[
      _DashboardTab(
        role: trustedRole,
        isSuperAdmin: isSuperAdmin,
      ),
      ChatScreen(
        isAdminMode: true,
        adminMatricule: _session?.adminMatricule,
        adminName: _session?.adminName,
        adminRole: trustedRole,
      ),
      const _AdminNotificationsTab(),
      const ProfileScreen(),
    ];

    return Scaffold(
      key: const Key('admin_dashboard_screen'),
      appBar: AppBar(
        title: Text(switch (_selectedIndex) {
          0 => l10n.adminDashboard,
          1 => l10n.messages,
          2 => l10n.notifications,
          _ => l10n.profile,
        }),
        automaticallyImplyLeading: false,
        backgroundColor: AppTheme.primaryTeal,
        foregroundColor: Colors.white,
        actions: [
          if (_selectedIndex != 3)
            IconButton(
              tooltip: l10n.profile,
              icon: const Icon(Icons.account_circle_outlined),
              onPressed: () => setState(() => _selectedIndex = 3),
            ),
        ],
      ),
      body: IndexedStack(index: _selectedIndex, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _selectedIndex,
        onTap: (index) {
          if (index == 1) {
            NotificationController.instance.markAllChatAsRead();
          }
          setState(() => _selectedIndex = index);
        },
        items: [
          BottomNavigationBarItem(
            icon: const Icon(Icons.dashboard_outlined),
            activeIcon: const Icon(Icons.dashboard),
            label: l10n.adminDashboard,
          ),
          BottomNavigationBarItem(
            icon: ListenableBuilder(
              listenable: NotificationController.instance,
              builder: (context, _) {
                final unread = NotificationController.instance.unreadChatCount;
                if (unread == 0) {
                  return const Icon(Icons.chat_bubble_outline);
                }
                return Badge(
                  label: Text(unread > 99 ? '99+' : unread.toString()),
                  child: const Icon(Icons.chat_bubble_outline),
                );
              },
            ),
            label: l10n.messages,
          ),
          BottomNavigationBarItem(
            icon: ListenableBuilder(
              listenable: NotificationController.instance,
              builder: (context, _) {
                final unread = NotificationController.instance.unreadCount;
                if (unread == 0) {
                  return const Icon(Icons.notifications_outlined);
                }
                return Badge(
                  label: Text(unread > 99 ? '99+' : unread.toString()),
                  child: const Icon(Icons.notifications_outlined),
                );
              },
            ),
            label: l10n.notifications,
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.person_outline),
            activeIcon: const Icon(Icons.person),
            label: l10n.profile,
          ),
        ],
      ),
    );
  }
}

class _DashboardTab extends StatelessWidget {
  const _DashboardTab({this.role, required this.isSuperAdmin});

  final String? role;
  final bool isSuperAdmin;

  String _roleChipLabel(String role) {
    return switch (role) {
      'super_admin' => 'Super Admin',
      'bus' => 'Admin Bus',
      'metro_train' => 'Admin Métro / Train',
      'taxicollectifs' => 'Admin Taxi Collectifs',
      'louage' => 'Admin Louage',
      _ => role,
    };
  }

  Widget _buildDashboardCard(
    BuildContext context,
    String title,
    IconData icon, {
    required VoidCallback onTap,
    required double height,
  }) {
    final primaryGreen = AppTheme.primaryTeal;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: primaryGreen.withValues(alpha: 0.08),
            blurRadius: 20,
            spreadRadius: 2,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          splashColor: primaryGreen.withValues(alpha: 0.10),
          highlightColor: primaryGreen.withValues(alpha: 0.05),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: primaryGreen.withValues(alpha: 0.10),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 32, color: primaryGreen),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  color: primaryGreen.withValues(alpha: 0.85),
                  size: 28,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final commonActions = <_AdminAction>[
      _AdminAction(
        labelKey: (l) => l.manageUsers,
        icon: Icons.people_outline,
        onTap: (ctx) => ctx.push('/admin/manage-users'),
      ),
      _AdminAction(
        labelKey: (l) => l.manageJourneys,
        icon: Icons.route_outlined,
        onTap: (ctx) => ctx.push('/admin/manage-journeys'),
      ),
      _AdminAction(
        labelKey: (l) => l.manageTariffs,
        icon: Icons.sell_outlined,
        onTap: (ctx) => ctx.push('/admin/manage-tariffs'),
      ),
      _AdminAction(
        labelKey: (l) => l.sendNotifications,
        icon: Icons.notifications_active_outlined,
        onTap: (ctx) => ctx.push('/admin/send-notifications'),
      ),
    ];

    final superAdminActions = <_AdminAction>[
      _AdminAction(
        labelKey: (l) => l.manageAdmins,
        icon: Icons.badge_outlined,
        isSuperAdminOnly: true,
        onTap: (ctx) => ctx.push('/admin/manage-admins'),
      ),
      _AdminAction(
        labelKey: (l) => l.manageAdminRolesPermissions,
        icon: Icons.manage_accounts_outlined,
        isSuperAdminOnly: true,
        onTap: (ctx) => ctx.push('/super-admin/dashboard?tab=roles'),
      ),
      _AdminAction(
        labelKey: (l) => l.globalPlatformSupervision,
        icon: Icons.monitor_outlined,
        isSuperAdminOnly: true,
        onTap: (ctx) => ctx.push('/super-admin/dashboard?tab=supervision'),
      ),
    ];

    final actions = <_AdminAction>[
      ...commonActions,
      if (isSuperAdmin) ...superAdminActions,
    ];

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () {
                AuthController.instance.switchToUserMode();
                context.go('/home/journey-input');
              },
              icon: const Icon(Icons.switch_account, size: 18),
              label: Text(l10n.switchToUserMode),
              style: OutlinedButton.styleFrom(
                shape: const StadiumBorder(),
                side: BorderSide(
                  color: AppTheme.primaryTeal.withValues(alpha: 0.35),
                ),
                foregroundColor: AppTheme.primaryTeal,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (role != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  Text(
                    l10n.role,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Chip(
                    avatar: const Icon(
                      Icons.verified_user_outlined,
                      size: 18,
                      color: AppTheme.primaryTeal,
                    ),
                    label: Text(
                      _roleChipLabel(role!),
                      style: const TextStyle(
                        color: AppTheme.primaryTeal,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    backgroundColor: Colors.white,
                    side: BorderSide(color: AppTheme.primaryTeal.withValues(alpha: 0.3)),
                  ),
                ],
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const spacing = 12.0;
                final cardHeight = (constraints.maxHeight - (spacing * 3)) / 4;

                return ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: actions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: spacing),
                  itemBuilder: (context, index) {
                    final action = actions[index];
                    final label = action.labelKey(l10n);

                    return TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: Duration(milliseconds: 220 + (index * 35)),
                      curve: Curves.easeOutCubic,
                      builder: (context, t, child) {
                        return Opacity(
                          opacity: t,
                          child: Transform.translate(
                            offset: Offset(0, (1 - t) * 12),
                            child: child,
                          ),
                        );
                      },
                      child: _buildDashboardCard(
                        context,
                        label,
                        action.icon,
                        height: cardHeight,
                        onTap: () => action.onTap(context),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminAction {
  const _AdminAction({
    required this.labelKey,
    required this.icon,
    required this.onTap,
    this.isSuperAdminOnly = false,
  });

  final String Function(AppLocalizations) labelKey;
  final IconData icon;
  final void Function(BuildContext) onTap;
  final bool isSuperAdminOnly;
}

class _AdminNotificationsTab extends StatelessWidget {
  const _AdminNotificationsTab();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final controller = NotificationController.instance;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final items = controller.notifications;

        if (items.isEmpty) {
          return Center(
            child: Text(
              l10n.noNotificationsYet,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          );
        }

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Text(
                    l10n.notifications,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: controller.unreadCount == 0
                        ? null
                        : controller.markAllAsRead,
                    icon: const Icon(Icons.done_all),
                    label: Text(l10n.markAllAsRead),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return ListTile(
                    leading: Icon(
                      item.isRead
                          ? Icons.notifications_outlined
                          : Icons.notifications_active,
                    ),
                    title: Text(NotificationL10n.localizedTitle(l10n, item)),
                    subtitle: Text(NotificationL10n.localizedBody(l10n, item)),
                    trailing: Text(
                      '${item.timestamp.hour.toString().padLeft(2, '0')}:${item.timestamp.minute.toString().padLeft(2, '0')}',
                    ),
                    onTap: () => controller.markAsRead(item.id),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
