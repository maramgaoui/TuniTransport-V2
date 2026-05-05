import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:go_router/go_router.dart';
import 'package:tuni_transport/controllers/auth_controller.dart';
import 'package:tuni_transport/admin/utils/admin_data_scope.dart';
import 'package:tuni_transport/admin/widgets/admin_soft_card.dart';
import 'package:tuni_transport/l10n/app_localizations.dart';
import 'package:tuni_transport/theme/app_theme.dart';

/// Filter options for the route list.
enum _RouteFilter { all, active, inactive }

class ManageJourneysScreen extends StatefulWidget {
  const ManageJourneysScreen({super.key});

  @override
  State<ManageJourneysScreen> createState() => _ManageJourneysScreenState();
}

class _ManageJourneysScreenState extends State<ManageJourneysScreen> {
  final CollectionReference<Map<String, dynamic>> _routesRef =
      FirebaseFirestore.instance.collection('routes');
  final TextEditingController _departureController = TextEditingController();
  final TextEditingController _arrivalController = TextEditingController();

  _RouteFilter _activeFilter = _RouteFilter.all;
  bool _isResolvingScope = true;
  bool _isSuperAdmin = false;
  String? _adminType;
  String _departureQuery = '';
  String _arrivalQuery = '';

  @override
  void initState() {
    super.initState();
    _resolveScope();
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
    } catch (_) {
      if (!mounted) return;
      setState(() => _isResolvingScope = false);
    }
  }

  @override
  void dispose() {
    _departureController.dispose();
    _arrivalController.dispose();
    super.dispose();
  }

  void _applySearch() {
    setState(() {
      _departureQuery = _departureController.text.trim().toLowerCase();
      _arrivalQuery = _arrivalController.text.trim().toLowerCase();
    });
  }

  String _normalizeForSearch(String value) {
    return value
        .toLowerCase()
        .replaceAll('_', ' ')
        .replaceAll('-', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Future<void> _showRouteStatusEditor(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> routeDoc,
  ) async {
    final data = routeDoc.data();
    bool isActive = (data['isActive'] ?? true) == true;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: const Text('Modifier le statut du trajet'),
              content: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Trajet actif'),
                value: isActive,
                onChanged: (value) {
                  setDialogState(() => isActive = value);
                },
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Annuler'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await _routesRef.doc(routeDoc.id).update({
                      'isActive': isActive,
                      'updatedAt': FieldValue.serverTimestamp(),
                    });
                    if (!dialogContext.mounted) return;
                    Navigator.of(dialogContext).pop();
                  },
                  child: const Text('Enregistrer'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  bool _matchesSearch(Map<String, dynamic> data) {
    final origin = _normalizeForSearch((data['originStationId'] ?? '').toString());
    final destination = _normalizeForSearch(
      (data['destinationStationId'] ?? '').toString(),
    );
    final routeName = _normalizeForSearch((data['name'] ?? '').toString());
    final routeDescription = _normalizeForSearch(
      (data['description'] ?? '').toString(),
    );
    final departureQuery = _normalizeForSearch(_departureQuery);
    final arrivalQuery = _normalizeForSearch(_arrivalQuery);

    if (departureQuery.isEmpty && arrivalQuery.isEmpty) {
      return true;
    }

    if (departureQuery.isNotEmpty &&
        !origin.contains(departureQuery) &&
        !routeName.contains(departureQuery) &&
        !routeDescription.contains(departureQuery)) {
      return false;
    }

    if (arrivalQuery.isEmpty) {
      return true;
    }

    return destination.contains(arrivalQuery) ||
        routeName.contains(arrivalQuery) ||
        routeDescription.contains(arrivalQuery);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.manageJourneys),
        backgroundColor: AppTheme.primaryTeal,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/admin'),
        ),
      ),
      body: _isResolvingScope
          ? const Center(child: CircularProgressIndicator())
          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _routesRef.snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text(l10n.journeysLoadError));
          }

          final allDocs = snapshot.data?.docs ?? [];
          allDocs.sort((a, b) {
            final aTs = a.data()['createdAt'] as Timestamp?;
            final bTs = b.data()['createdAt'] as Timestamp?;
            if (aTs == null && bTs == null) return 0;
            if (aTs == null) return 1;
            if (bTs == null) return -1;
            return bTs.compareTo(aTs);
          });
          final scopedDocs = (!_isSuperAdmin && _adminType != null)
              ? allDocs
                  .where(
                    (doc) => AdminDataScope.matchesRouteData(
                      adminType: _adminType!,
                      data: doc.data(),
                    ),
                  )
                  .toList()
              : allDocs;

          final docs = scopedDocs.where((doc) {
            if (!_matchesSearch(doc.data())) return false;
            final isActive = (doc.data()['isActive'] ?? true) == true;
            return switch (_activeFilter) {
              _RouteFilter.active   => isActive,
              _RouteFilter.inactive => !isActive,
              _RouteFilter.all      => true,
            };
          }).toList();

          if (scopedDocs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.route, size: 64, color: AppTheme.lightGrey),
                  const SizedBox(height: 16),
                  Text(l10n.noJourneysFound),
                ],
              ),
            );
          }

          return Column(
            children: [
              // ── Filter chips ──────────────────────────────────────
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: Row(
                  children: _RouteFilter.values.map((filter) {
                    final label = switch (filter) {
                      _RouteFilter.all      => 'Tous',
                      _RouteFilter.active   => 'Actif',
                      _RouteFilter.inactive => 'Désactivé',
                    };
                    final color = switch (filter) {
                      _RouteFilter.active   => Colors.green.shade700,
                      _RouteFilter.inactive => Colors.red.shade700,
                      _RouteFilter.all      => Colors.blueGrey.shade700,
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
                        onSelected: (_) =>
                            setState(() => _activeFilter = filter),
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
                  onSubmitted: (_) => _applySearch(),
                  decoration: InputDecoration(
                    labelText: l10n.departurePoint,
                    prefixIcon: const Icon(Icons.trip_origin),
                    suffixIcon: IconButton(
                      tooltip: MaterialLocalizations.of(context).searchFieldLabel,
                      icon: const Icon(Icons.search),
                      onPressed: _applySearch,
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
                  onSubmitted: (_) => _applySearch(),
                  decoration: InputDecoration(
                    labelText: l10n.arrivalPoint,
                    prefixIcon: const Icon(Icons.flag_outlined),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    suffixIcon: IconButton(
                      tooltip: MaterialLocalizations.of(context).searchFieldLabel,
                      icon: const Icon(Icons.search),
                      onPressed: _applySearch,
                    ),
                  ),
                ),
              ),
              if (docs.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Aucun trajet trouvé pour cette recherche.'),
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final doc = docs[i];
                    final data = doc.data();
                    final lineNumber = (data['lineNumber'] ?? '').toString();
                    final name = (data['name'] ?? '').toString();
                    final operatorId = (data['operatorId'] ?? '').toString();
                    final typeId = (data['typeId'] ?? '').toString();
                    final originStationId =
                        (data['originStationId'] ?? '').toString();
                    final destinationStationId =
                        (data['destinationStationId'] ?? '').toString();
                    final isActive = (data['isActive'] ?? true) == true;

                    return AdminSoftCard(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name.isNotEmpty
                                            ? name
                                            : 'Route $lineNumber',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '$originStationId → $destinationStationId',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      Text(
                                        '$operatorId • $typeId • Line $lineNumber',
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.black54),
                                      ),
                                    ],
                                  ),
                                ),
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
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    isActive ? 'Active' : 'Inactive',
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
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: OutlinedButton(
                                onPressed: () =>
                                    _showRouteStatusEditor(context, doc),
                                child: const Text('Modifier'),
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
          );
        },
      ),
    );
  }
}
