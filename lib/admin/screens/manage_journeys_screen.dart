import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:get_it/get_it.dart';
import '../../constants/firestore_collections.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:go_router/go_router.dart';
import 'package:tuni_transport/controllers/auth_controller.dart';
import 'package:tuni_transport/admin/widgets/admin_soft_card.dart';
import 'package:tuni_transport/l10n/app_localizations.dart';
import '../../widgets/app_header.dart';
import 'package:tuni_transport/theme/app_theme.dart';
import '../../services/admin_notification_service.dart';
import '../../services/audit_log_service.dart';

/// Filter applied to the route list.
enum _RouteFilter { all, active, inactive }

/// Admin screen for viewing and toggling the active/inactive state of routes.
///
/// - super_admin  : sees every route.
/// - other admins : see only routes that match their transport type
///                  (bus, metro_train, taxicollectifs, louage).
///
/// Admins can NOT add or delete routes from this screen.
/// They can only toggle the `isActive` flag on existing routes.
class ManageJourneysScreen extends StatefulWidget {
  const ManageJourneysScreen({super.key});

  @override
  State<ManageJourneysScreen> createState() => _ManageJourneysScreenState();
}

class _ManageJourneysScreenState extends State<ManageJourneysScreen> {
  FirebaseFirestore get _db => GetIt.I<FirebaseFirestore>();

  bool get _isTaxiAdmin => !_isSuperAdmin && _adminType == 'taxicollectifs';

  final TextEditingController _departureController = TextEditingController();
  final TextEditingController _arrivalController = TextEditingController();

  _RouteFilter _activeFilter = _RouteFilter.all;
  bool _isResolvingScope = true;
  bool _isSuperAdmin = false;
  String? _adminType;
  String _departureQuery = '';
  String _arrivalQuery = '';
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _scopeSub;

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _allDocs = const [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _results = const [];
  bool _isLoading = false;
  // Optimistic local overrides so the toggle reflects immediately without waiting
  // for a full reload. Cleared when _loadAll() fetches fresh data.
  final Map<String, bool> _activeOverrides = {};

  @override
  void initState() {
    super.initState();
    _departureController.addListener(_applySearch);
    _arrivalController.addListener(_applySearch);
    _resolveScope();
    _listenForScopeChanges();
  }

  void _listenForScopeChanges() {
    final uid = AuthController.instance.currentUser?.uid;
    if (uid == null) return;
    _scopeSub = GetIt.I<FirebaseFirestore>()
        .collection(Col.users)
        .doc(uid)
        .snapshots()
        .listen((snap) {
      if (!snap.exists || !mounted) return;
      final data = snap.data() ?? {};
      final newRole      = (data['role'] ?? 'user').toString();
      final newAdminType = data['adminType'] as String?;
      final newIsSuperAdmin = newRole == 'super_admin';
      if (newAdminType != _adminType || newIsSuperAdmin != _isSuperAdmin) {
        setState(() {
          _isSuperAdmin = newIsSuperAdmin;
          _adminType    = newAdminType;
        });
        _loadAll();
      }
    });
  }

  @override
  void dispose() {
    _scopeSub?.cancel();
    _departureController.removeListener(_applySearch);
    _arrivalController.removeListener(_applySearch);
    _departureController.dispose();
    _arrivalController.dispose();
    super.dispose();
  }

  Future<void> _resolveScope() async {
    if (Firebase.apps.isEmpty) {
      if (!mounted) return;
      setState(() => _isResolvingScope = false);
      return;
    }
    final currentUser = AuthController.instance.currentUser;
    if (currentUser == null) {
      if (!mounted) return;
      setState(() => _isResolvingScope = false);
      return;
    }
    try {
      final session = await AuthController.instance.resolveSession(currentUser);
      if (!mounted) return;
      setState(() {
        _isSuperAdmin = session.isSuperAdmin;
        _adminType = session.adminType;
        _isResolvingScope = false;
      });
      _loadAll();
    } catch (_) {
      if (!mounted) return;
      setState(() => _isResolvingScope = false);
    }
  }

  Future<void> _loadAll() async {
    if (!_isSuperAdmin && _adminType == null) {
      if (!mounted) return;
      setState(() {
        _allDocs = const [];
        _results = const [];
        _isLoading = false;
      });
      return;
    }

    setState(() => _isLoading = true);
    try {
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> fetched;
      if (_isSuperAdmin) {
        final results = await Future.wait([
          _db.collection(Col.routes).get(),
          _db.collection(Col.taxiCollectifRoutes).get(),
        ]);
        fetched = [
          ...results[0].docs,
          ...results[1].docs,
        ];
      } else if (_isTaxiAdmin) {
        final snap = await _db.collection(Col.taxiCollectifRoutes).get();
        fetched = snap.docs;
      } else {
        final snap = await _db.collection(Col.routes).get();
        fetched = snap.docs;
      }

      final filtered = fetched.where((doc) => _matchesAdminScope(doc.data())).toList();
      final sorted = filtered..sort((a, b) {
        final aTs = a.data()['createdAt'] as Timestamp?;
        final bTs = b.data()['createdAt'] as Timestamp?;
        if (aTs == null && bTs == null) return 0;
        if (aTs == null) return 1;
        if (bTs == null) return -1;
        return bTs.compareTo(aTs);
      });

      if (!mounted) return;
      setState(() {
        _activeOverrides.clear();
        _allDocs = sorted;
        _applyFilters();
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _allDocs = const [];
        _results = const [];
        _isLoading = false;
      });
    }
  }

  void _applySearch() => setState(_applyFilters);

  void _applyFilters() {
    _departureQuery = _departureController.text.trim().toLowerCase();
    _arrivalQuery = _arrivalController.text.trim().toLowerCase();

    var docs = _allDocs.where((doc) => _matchesAdminScope(doc.data())).toList();
    docs = switch (_activeFilter) {
      _RouteFilter.active => docs.where((d) => d.data()['isActive'] != false).toList(),
      _RouteFilter.inactive => docs.where((d) => d.data()['isActive'] == false).toList(),
      _RouteFilter.all => docs,
    };
    docs = docs.where((doc) => _matchesSearch(doc.data())).toList();
    _results = docs;
  }

  bool _matchesAdminScope(Map<String, dynamic> data) {
    if (_isSuperAdmin) return true;
    if (_adminType == null) return false;
    // Taxi collectif admin reads directly from taxi_collectif_routes,
    // so every document in that stream belongs to them.
    if (_isTaxiAdmin) return true;

    final operatorId = (data['operatorId'] ?? '').toString().toLowerCase();
    // Some seeded collections store the transport category in `typeId`,
    // others (metro sahel, banlieue, sncft) use `transportType`. Check both.
    final typeIdRaw = data['typeId'] ?? data['transportType'];
    final typeId = typeIdRaw is Iterable
        ? typeIdRaw.join(' ').toLowerCase()
        : (typeIdRaw?.toString() ?? '').toLowerCase();

    return switch (_adminType) {
      'bus' => operatorId == 'transtu' || operatorId == 'sts_sahel' || typeId.contains('bus'),
      'metro_train' => typeId.contains('metro') || typeId.contains('train')
          || operatorId.contains('sncft') || operatorId.contains('sahel')
          || operatorId.contains('banlieue'),
      'louage' => typeId.contains('louage'),
      _ => false,
    };
  }

  String _normalize(String value) => value
      .toLowerCase()
      .replaceAll('_', ' ')
      .replaceAll('-', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Search logic:
  /// - Only departure given  → return all routes whose origin matches.
  /// - Both given            → match both origin and destination.
  /// - Neither given         → return all.
  bool _matchesSearch(Map<String, dynamic> data) {
    final String origin;
    final String destination;
    final String routeName;
    final isTaxiDoc = _isTaxiAdmin ||
        data.containsKey('fromCityId') || data.containsKey('fromCityName');
    if (isTaxiDoc) {
      origin = _normalize(
          (data['fromCityName'] ?? data['fromCityId'] ?? '').toString());
      destination = _normalize(
          (data['toCityName'] ?? data['toCityId'] ?? '').toString());
      routeName = '$origin $destination';
    } else {
      origin = _normalize((data['originStationId'] ?? '').toString());
      destination =
          _normalize((data['destinationStationId'] ?? '').toString());
      routeName = _normalize((data['name'] ?? '').toString());
    }
    final depQ = _normalize(_departureQuery);
    final arrQ = _normalize(_arrivalQuery);

    if (depQ.isEmpty && arrQ.isEmpty) return true;

    if (depQ.isNotEmpty &&
        !origin.contains(depQ) &&
        !routeName.contains(depQ)) {
      return false;
    }

    if (arrQ.isEmpty) return true; // only departure entered → already matched

    return destination.contains(arrQ) || routeName.contains(arrQ);
  }

  /// Toggles the `isActive` field on a route document.
  /// The route write is committed immediately so the StreamBuilder reflects
  /// the change without delay. Bus-service propagation runs in the background
  /// to avoid blocking the UI while waiting for the secondary Firestore query.
  Future<void> _toggleActive(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    bool current,
  ) async {
    final newActive = !current;

    final data = doc.data();
    final isTaxiDoc = _isTaxiAdmin ||
        data.containsKey('fromCityId') || data.containsKey('fromCityName');
    try {
      // Use doc.reference directly — it already points to the correct collection.
      await doc.reference.update({
        'isActive': newActive,
        if (!isTaxiDoc) 'searchVisibilityManaged': true,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Erreur lors de la mise à jour : $e'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (!mounted) return;
    setState(() => _activeOverrides[doc.id] = newActive);

    // Bus service propagation only applies to TRANSTU routes.
    if (!isTaxiDoc) {
      unawaited(
        _propagateToBusServices(doc.id, newActive).onError(
          (Object e, _) => debugPrint('[ManageJourneys] Bus propagation failed: $e'),
        ),
      );
    }

    // Notify all users about the availability change.
    final String routeLabel;
    if (isTaxiDoc) {
      final from = (data['fromCityName'] ?? data['fromCityId'] ?? '').toString();
      final to   = (data['toCityName']   ?? data['toCityId']   ?? '').toString();
      routeLabel = '$from → $to';
    } else {
      final name   = (data['name'] ?? '').toString().trim();
      final origin = (data['originStationId'] ?? '').toString();
      final dest   = (data['destinationStationId'] ?? '').toString();
      routeLabel = name.isNotEmpty ? name : '$origin → $dest';
    }
    unawaited(AdminNotificationService.notifyRouteToggled(
      routeLabel: routeLabel,
      isActive:   newActive,
    ));

    final currentUser = AuthController.instance.currentUser;
    unawaited(AuditLogService().logAdminAction(
      action: newActive ? 'route_activated' : 'route_deactivated',
      targetUid: doc.id,
      actorUid: currentUser?.uid,
      actorEmail: currentUser?.email,
      details: {
        'routeDocId': doc.id,
        'collection': isTaxiDoc ? Col.taxiCollectifRoutes : Col.routes,
        'routeLabel': routeLabel,
        'previousIsActive': current,
      },
    ));
  }

  /// Batch-updates every `bus_services` document whose `routeId` matches
  /// [routeDocId] to reflect the new [isActive] value.
  Future<void> _propagateToBusServices(
    String routeDocId,
    bool isActive,
  ) async {
    final db = GetIt.I<FirebaseFirestore>();
    final busSnap = await db
        .collection(Col.busServices)
        .where('routeId', isEqualTo: routeDocId)
        .get();
    if (busSnap.docs.isEmpty) return;
    final batch = db.batch();
    for (final busDoc in busSnap.docs) {
      batch.update(busDoc.reference, {'isActive': isActive});
    }
    await batch.commit();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(80),
        child: AppHeader(
          title: l10n.manageJourneys,
          subtitle: 'Suivi des trajets',
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
      body: _isResolvingScope || _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _allDocs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.route, size: 64, color: AppTheme.lightGrey),
                      const SizedBox(height: 16),
                      Text(l10n.noJourneysFound),
                    ],
                  ),
                )
              : Column(
                  children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                      child: Row(
                        children: _RouteFilter.values.map((filter) {
                          final l10n = AppLocalizations.of(context)!;
                          final label = switch (filter) {
                            _RouteFilter.all => l10n.filterAll,
                            _RouteFilter.active => l10n.filterActive,
                            _RouteFilter.inactive => l10n.filterInactive,
                          };
                          final color = switch (filter) {
                            _RouteFilter.active => Colors.green.shade700,
                            _RouteFilter.inactive => Colors.red.shade700,
                            _RouteFilter.all => Colors.blueGrey.shade700,
                          };
                          final selected = _activeFilter == filter;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: FilterChip(
                              label: Text(label),
                              selected: selected,
                              selectedColor: color.withValues(alpha: 0.18),
                              checkmarkColor: color,
                              labelStyle: TextStyle(
                                color: selected ? color : null,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.normal,
                              ),
                              onSelected: (_) {
                                setState(() => _activeFilter = filter);
                                _applyFilters();
                              },
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const Divider(height: 1),

                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                      child: TextField(
                        controller: _departureController,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _applyFilters(),
                        decoration: InputDecoration(
                          labelText: l10n.departurePoint,
                          prefixIcon: const Icon(Icons.trip_origin),
                          suffixIcon: IconButton(
                            tooltip: MaterialLocalizations.of(context)
                                .searchFieldLabel,
                            icon: const Icon(Icons.search),
                            onPressed: _applyFilters,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: TextField(
                        controller: _arrivalController,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _applyFilters(),
                        decoration: InputDecoration(
                          labelText: l10n.arrivalPoint,
                          prefixIcon: const Icon(Icons.flag_outlined),
                          suffixIcon: IconButton(
                            tooltip: MaterialLocalizations.of(context)
                                .searchFieldLabel,
                            icon: const Icon(Icons.search),
                            onPressed: _applyFilters,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),

                    if (_results.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            AppLocalizations.of(context)!.noJourneysMatchFilter,
                          ),
                        ),
                      ),

                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _results.length,
                        itemBuilder: (_, i) {
                          final doc = _results[i];
                          final data = doc.data();
                          final isActive = _activeOverrides.containsKey(doc.id)
                              ? _activeOverrides[doc.id]!
                              : (data['isActive'] ?? true) == true;

                          // Detect taxi collectif docs by their field names
                          // (works for both taxi admins and super admin viewing taxi routes).
                          final isTaxiDoc = _isTaxiAdmin ||
                              data.containsKey('fromCityId') ||
                              data.containsKey('fromCityName');
                          final String name;
                          final String origin;
                          final String destination;
                          final String subtitle;
                          if (isTaxiDoc) {
                            origin = (data['fromCityName'] ?? data['fromCityId'] ?? '').toString();
                            destination = (data['toCityName'] ?? data['toCityId'] ?? '').toString();
                            name = '$origin → $destination';
                            final fare = (data['fare'] as num?)?.toStringAsFixed(3) ?? '—';
                            final dist = (data['distanceKm'] as num?)?.toStringAsFixed(1) ?? '—';
                            subtitle = 'Taxi Collectif • $fare TND • $dist km';
                          } else {
                            final lineNumber = (data['lineNumber'] ?? '').toString();
                            final operatorId = (data['operatorId'] ?? '').toString();
                            final transportType = (data['typeId'] ?? data['transportType'] ?? '').toString();
                            origin = (data['originStationId'] ?? '').toString();
                            destination = (data['destinationStationId'] ?? '').toString();
                            name = (data['name'] ?? 'Route $lineNumber').toString();
                            subtitle = '$operatorId • $transportType'
                                '${lineNumber.isNotEmpty ? ' • Ligne $lineNumber' : ''}';
                          }

                          return AdminSoftCard(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 14,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        if (!isTaxiDoc)
                                          Text(
                                            '$origin → $destination',
                                            style: const TextStyle(fontSize: 12),
                                          ),
                                        Text(
                                          subtitle,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.black54,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        // Active/inactive badge
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: isActive
                                                ? Colors.green.shade50
                                                : Colors.red.shade50,
                                            border: Border.all(
                                              color: isActive
                                                  ? Colors.green.shade700
                                                  : Colors.red.shade700,
                                            ),
                                            borderRadius:
                                                BorderRadius.circular(12),
                                          ),
                                          child: Text(
                                            isActive ? 'Actif' : 'Inactif',
                                            style: TextStyle(
                                              color: isActive
                                                  ? Colors.green.shade700
                                                  : Colors.red.shade700,
                                              fontWeight: FontWeight.w700,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),

                                  Tooltip(
                                    message: isActive
                                        ? 'Désactiver le trajet'
                                        : 'Activer le trajet',
                                    child: IconButton(
                                      icon: Icon(
                                        isActive
                                            ? Icons.toggle_on
                                            : Icons.toggle_off,
                                        color: isActive
                                            ? Colors.green.shade700
                                            : Colors.red.shade400,
                                        size: 34,
                                      ),
                                      onPressed: () =>
                                          _toggleActive(doc, isActive),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
