import 'dart:async';

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
  static const List<String> _allTypeOptions = [
    'bus',
    'metro',
    'train',
    'taxi_collectif',
    'louage',
  ];

  static const List<String> _allOperatorOptions = [
    'TRANSTU',
    'STS',
    'TRANSTU_METRO',
    'SNCFT',
    'TAXI_COLLECTIF',
    'LOUAGE',
  ];

  static const Map<String, List<String>> _operatorOptionsByAdminType = {
    'bus': ['TRANSTU', 'STS'],
    'metro_train': ['TRANSTU_METRO', 'SNCFT'],
    'taxicollectifs': ['TAXI_COLLECTIF'],
    'louage': ['LOUAGE'],
  };

  static const Map<String, String> _lockedOperatorByAdminType = {
    'bus': 'TRANSTU',
    'metro_train': 'TRANSTU_METRO',
    'taxicollectifs': 'TAXI_COLLECTIF',
    'louage': 'LOUAGE',
  };

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

  List<String> _operatorOptionsForCurrentAdmin() {
    if (_isSuperAdmin) {
      return _allOperatorOptions;
    }
    final adminType = _adminType;
    if (adminType == null) return const [];
    return _operatorOptionsByAdminType[adminType] ?? const [];
  }

  String? _lockedOperatorForCurrentAdmin() {
    if (_isSuperAdmin) return null;
    final adminType = _adminType;
    if (adminType == null) return null;
    return _lockedOperatorByAdminType[adminType];
  }

  Future<void> _showCreateRouteSheet(BuildContext context) async {
    final formKey = GlobalKey<FormState>();
    final nameController = TextEditingController();
    final lineNumberController = TextEditingController();
    final originController = TextEditingController();
    final destinationController = TextEditingController();

    final operatorOptions = _operatorOptionsForCurrentAdmin();
    final lockedOperator = _lockedOperatorForCurrentAdmin();

    String? selectedOperator =
        lockedOperator ?? (operatorOptions.isNotEmpty ? operatorOptions.first : null);
    String selectedType = _allTypeOptions.first;
    bool isActive = true;
    bool isSubmitting = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            Future<void> submit() async {
              if (isSubmitting) return;
              final isValid = formKey.currentState?.validate() ?? false;
              if (!isValid) return;
              if (selectedOperator == null || selectedOperator!.trim().isEmpty) {
                ScaffoldMessenger.of(sheetContext).showSnackBar(
                  const SnackBar(
                    content: Text('Veuillez sélectionner un opérateur.'),
                  ),
                );
                return;
              }

              setSheetState(() => isSubmitting = true);
              try {
                await _routesRef.add({
                  'name': nameController.text.trim(),
                  'lineNumber': lineNumberController.text.trim(),
                  'originStationId': originController.text.trim(),
                  'destinationStationId': destinationController.text.trim(),
                  'operatorId': selectedOperator,
                  'typeId': selectedType,
                  'isActive': isActive,
                  'searchVisibilityManaged': false,
                  'createdAt': FieldValue.serverTimestamp(),
                  'updatedAt': FieldValue.serverTimestamp(),
                });

                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Trajet ajouté avec succès')),
                );
                Navigator.of(sheetContext).pop();
              } finally {
                if (sheetContext.mounted) {
                  setSheetState(() => isSubmitting = false);
                }
              }
            }

            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                12,
                16,
                MediaQuery.of(sheetContext).viewInsets.bottom + 16,
              ),
              child: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Ajouter un trajet',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: nameController,
                        decoration: const InputDecoration(
                          labelText: 'Nom du trajet',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Le nom est requis.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: lineNumberController,
                        decoration: const InputDecoration(
                          labelText: 'Numéro de ligne',
                          hintText: 'Ex: Bus 35',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Le numéro de ligne est requis.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: originController,
                        decoration: const InputDecoration(
                          labelText: 'originStationId',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Le point de départ est requis.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: destinationController,
                        decoration: const InputDecoration(
                          labelText: 'destinationStationId',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Le point d\'arrivée est requis.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        value: selectedOperator,
                        decoration: const InputDecoration(
                          labelText: 'operatorId',
                          border: OutlineInputBorder(),
                        ),
                        items: operatorOptions
                            .map(
                              (value) => DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(),
                        onChanged: lockedOperator != null
                            ? null
                            : (value) {
                                setSheetState(() => selectedOperator = value);
                              },
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'L\'opérateur est requis.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        value: selectedType,
                        decoration: const InputDecoration(
                          labelText: 'typeId',
                          border: OutlineInputBorder(),
                        ),
                        items: _allTypeOptions
                            .map(
                              (value) => DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          setSheetState(() => selectedType = value);
                        },
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        title: const Text('Actif'),
                        contentPadding: EdgeInsets.zero,
                        value: isActive,
                        onChanged: (value) {
                          setSheetState(() => isActive = value);
                        },
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryTeal,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: isSubmitting ? null : submit,
                          child: Text(
                            isSubmitting
                                ? 'Ajout en cours...'
                                : 'Ajouter le trajet',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    nameController.dispose();
    lineNumberController.dispose();
    originController.dispose();
    destinationController.dispose();
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
    final l10n = AppLocalizations.of(context)!;
    final data = routeDoc.data();
    final formKey = GlobalKey<FormState>();
    final nameController = TextEditingController(
      text: (data['name'] ?? '').toString(),
    );
    final lineNumberController = TextEditingController(
      text: (data['lineNumber'] ?? '').toString(),
    );
    final originController = TextEditingController(
      text: (data['originStationId'] ?? '').toString(),
    );
    final destinationController = TextEditingController(
      text: (data['destinationStationId'] ?? '').toString(),
    );
    bool isActive = (data['isActive'] ?? true) == true;
    bool isSaving = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: const Text('Modifier le trajet'),
              content: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Trajet actif / inactif'),
                        value: isActive,
                        onChanged: (value) {
                          setDialogState(() => isActive = value);
                        },
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: nameController,
                        decoration: const InputDecoration(
                          labelText: 'Nom du trajet',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Le nom est requis.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: lineNumberController,
                        decoration: const InputDecoration(
                          labelText: 'Numéro de ligne',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Le numéro de ligne est requis.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: originController,
                        decoration: const InputDecoration(
                          labelText: 'originStationId',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Le point de départ est requis.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: destinationController,
                        decoration: const InputDecoration(
                          labelText: 'destinationStationId',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Le point d\'arrivée est requis.';
                          }
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Annuler'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryTeal,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: isSaving
                      ? null
                      : () async {
                          final isValid = formKey.currentState?.validate() ?? false;
                          if (!isValid) return;
                          final messenger = ScaffoldMessenger.of(context);
                          setDialogState(() => isSaving = true);
                          try {
                            // Admin isActive toggles are consumed by user search filtering
                            // in JourneyRepository (inactive routes are excluded there).
                            await _routesRef.doc(routeDoc.id).update({
                              'name': nameController.text.trim(),
                              'lineNumber': lineNumberController.text.trim(),
                              'originStationId': originController.text.trim(),
                              'destinationStationId': destinationController.text.trim(),
                              'isActive': isActive,
                              'searchVisibilityManaged': true,
                              'updatedAt': FieldValue.serverTimestamp(),
                            }).timeout(const Duration(seconds: 12));
                            if (!mounted) return;
                            messenger.showSnackBar(
                              const SnackBar(content: Text('Trajet mis à jour')),
                            );
                            if (!dialogContext.mounted) return;
                            Navigator.of(dialogContext).pop();
                          } on TimeoutException {
                            if (!mounted) return;
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'La mise à jour du trajet a expiré. Réessayez.',
                                ),
                              ),
                            );
                          } on FirebaseException catch (e) {
                            if (!mounted) return;
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text(
                                  e.message ?? l10n.firestoreUpdateError,
                                ),
                              ),
                            );
                          } finally {
                            if (dialogContext.mounted) {
                              setDialogState(() => isSaving = false);
                            }
                          }
                        },
                  child: Text(isSaving ? 'Enregistrement...' : 'Enregistrer'),
                ),
              ],
            );
          },
        );
      },
    );

    nameController.dispose();
    lineNumberController.dispose();
    originController.dispose();
    destinationController.dispose();
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
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppTheme.primaryTeal,
        foregroundColor: Colors.white,
        onPressed: _isResolvingScope ? null : () => _showCreateRouteSheet(context),
        icon: const Icon(Icons.add),
        label: const Text('Ajouter un trajet'),
      ),
    );
  }
}
