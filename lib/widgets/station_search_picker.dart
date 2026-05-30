import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../models/station_model.dart';
import '../services/station_repository.dart';
import '../theme/app_theme.dart';
import '../constants/firestore_collections.dart';
import '../utils/text_normalizer.dart';

class StationSearchPicker extends StatefulWidget {
  final String label;
  final Station? initialValue;
  final ValueChanged<Station> onSelected;
  final FirebaseFirestore? firestore;

  const StationSearchPicker({
    super.key,
    required this.label,
    required this.onSelected,
    this.initialValue,
    this.firestore,
  });

  @override
  State<StationSearchPicker> createState() => _StationSearchPickerState();
}

class _StationSearchPickerState extends State<StationSearchPicker> {
  static const int _maxSearchResults = 8;
  static const int _nearbyLimit = 5;
  static const Duration _debounceDelay = Duration(milliseconds: 300);

  late final FirebaseFirestore _firestore;
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  Timer? _debounce;
  bool _isLoadingSearch = false;
  bool _isLoadingNearby = false;

  String _query = '';

  List<_StationSearchItem> _searchResults = const <_StationSearchItem>[];
  List<_StationSearchItem> _nearbyStations = const <_StationSearchItem>[];
  List<_StationSearchItem> _allStations = const <_StationSearchItem>[];


  @override
  void initState() {
    super.initState();
    _firestore = widget.firestore ?? FirebaseFirestore.instance;
    // Keep a stable primary label across locales.
    _controller = TextEditingController(
      text: widget.initialValue != null
          ? _primaryStationName(widget.initialValue!)
          : '',
    );
    _focusNode = FocusNode();

    _query = _controller.text.trim();
    _bootstrap();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final stations = await _fetchStationsFromFirestore();
    if (!mounted) return;
    _allStations = stations;

    if (_query.length >= 2) {
      _runSearch(_query);
    } else {
      _loadNearbyStations();
    }
  }

  Future<List<_StationSearchItem>> _fetchStationsFromFirestore() async {
    // 1. Fetch real stations.
    final snapshot = await _firestore.collection(Col.stations).limit(500).get();
    final seen = <String>{};
    final items = snapshot.docs
        .map((doc) => _StationSearchItem.fromDoc(doc))
        .where((item) {
          if (item.station.name.trim().isEmpty) return false;
          final key =
              '${TextNormalizer.normalize(item.station.name)}|${item.station.cityId.toLowerCase().trim()}';
          return seen.add(key);
        })
        .toList();

    // 2. Fetch unique cities from taxi_collectif_routes and add those that are
    //    not already covered by a real station entry (matched by cityId OR name).
    try {
      final taxiSnapshot =
          await _firestore.collection(Col.taxiCollectifRoutes).limit(300).get();
      final existingCityIds = <String>{
        for (final item in items)
          item.station.cityId.toLowerCase().trim(),
      };
      for (final doc in taxiSnapshot.docs) {
        final data = doc.data();
        final cities = [
          (
            name: (data['fromCityName'] ?? '').toString(),
            nameAr: data['fromCityNameAr']?.toString(),
            id: (data['fromCityId'] ?? '').toString(),
          ),
          (
            name: (data['toCityName'] ?? '').toString(),
            nameAr: data['toCityNameAr']?.toString(),
            id: (data['toCityId'] ?? '').toString(),
          ),
        ];
        for (final city in cities) {
          if (city.name.isEmpty || city.id.isEmpty) continue;
          // Skip if a real station already covers this city by cityId or name.
          if (existingCityIds.contains(city.id.toLowerCase())) continue;
          final key = '${TextNormalizer.normalize(city.name)}|${city.id}';
          if (!seen.add(key)) continue;
          existingCityIds.add(city.id.toLowerCase());
          items.add(_StationSearchItem.taxiCity(
            name: city.name,
            nameAr: city.nameAr,
            cityId: city.id,
          ));
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[StationSearchPicker] taxi_collectif_routes fetch failed: $e');
    }

    return items;
  }

  void _onQueryChanged(String value) {
    _query = value.trim();
    _debounce?.cancel();

    if (_query.length < 2) {
      setState(() {
        _searchResults = const <_StationSearchItem>[];
      });
      _loadNearbyStations();
      return;
    }

    _debounce = Timer(_debounceDelay, () {
      _runSearch(_query);
    });
  }

  Future<void> _runSearch(String rawQuery) async {
    final query = TextNormalizer.normalize(rawQuery);
    if (query.length < 2) return;

    setState(() {
      _isLoadingSearch = true;
    });

    if (_allStations.isEmpty) {
      _allStations = await _fetchStationsFromFirestore();
    }
    final source = _allStations;

    final matches = <_ScoredStation>[];
    for (final item in source) {
      final score = _scoreMatch(item, query);
      if (score > 0) {
        matches.add(_ScoredStation(item: item, score: score));
      }
    }

    matches.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.item.station.name.compareTo(b.item.station.name);
    });

    if (!mounted || _query.trim() != rawQuery.trim()) return;

    setState(() {
      _isLoadingSearch = false;
      _searchResults =
          matches.take(_maxSearchResults).map((m) => m.item).toList();
    });
  }

  /// Returns a list of known aliases for [stationId].
  List<String> _aliasesFor(String stationId) {
    return StationRepository.stationAliasesById[stationId] ?? const [];
  }

  double _scoreMatch(_StationSearchItem item, String query) {
    final fields = <String>[
      TextNormalizer.normalize(item.station.name),
      TextNormalizer.normalize(item.nameAr ?? ''),
      TextNormalizer.normalize(item.nameEn ?? ''),
    ].where((f) => f.isNotEmpty).toList();

    // Add static aliases for this station.
    final aliases = _aliasesFor(item.station.id);
    fields.addAll(aliases.map(TextNormalizer.normalize));

    var score = 0.0;
    for (final field in fields) {
      if (field == query) {
        score = score < 1.0 ? 1.0 : score;
      } else if (field.startsWith(query)) {
        score = score < 0.9 ? 0.9 : score;
      } else if (field.contains(query)) {
        score = score < 0.75 ? 0.75 : score;
      } else {
        // Token-overlap fallback: at least half the query tokens appear in field.
        final qTokens =
            query.split(' ').where((t) => t.length > 1).toList();
        final fTokens = field.split(' ');
        if (qTokens.isNotEmpty) {
          final matched = qTokens
              .where((qt) => fTokens.any((ft) => ft.startsWith(qt)))
              .length;
          final ratio = matched / qTokens.length;
          if (ratio >= 0.5) {
            final tokenScore = 0.5 + ratio * 0.2;
            score = score < tokenScore ? tokenScore : score;
          }
        }
      }
    }

    return score;
  }

  Future<void> _loadNearbyStations() async {
    if (_query.length >= 2) return;

    setState(() {
      _isLoadingNearby = true;
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!mounted) return;
        setState(() {
          _nearbyStations = const <_StationSearchItem>[];
          _isLoadingNearby = false;
        });
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        setState(() {
          _nearbyStations = const <_StationSearchItem>[];
          _isLoadingNearby = false;
        });
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 8),
      );

      List<_StationSearchItem> source = _allStations;
      if (source.isEmpty) {
        source = await _fetchStationsFromFirestore();
        _allStations = source;
      }

      final ranked = source
          .map(
            (item) => _NearbyDistance(
              item: item,
              distanceMeters: Geolocator.distanceBetween(
                position.latitude,
                position.longitude,
                item.station.latitude,
                item.station.longitude,
              ),
            ),
          )
          .toList()
        ..sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));

      if (!mounted || _query.length >= 2) return;

      setState(() {
        _nearbyStations =
            ranked.take(_nearbyLimit).map((e) => e.item).toList();
        _isLoadingNearby = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _nearbyStations = const <_StationSearchItem>[];
        _isLoadingNearby = false;
      });
    }
  }

  String _normalizeLabel(String value) {
    return value.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  String _primaryStationName(Station station) {
    final frenchName = station.name.trim();
    if (frenchName.isNotEmpty) return frenchName;
    final arabicName = (station.nameAr ?? '').trim();
    if (arabicName.isNotEmpty) return arabicName;
    return station.cityId;
  }

  Color _lineColor(Station station) {
    final operators = station.operatorsHere;
    final isMetroSahel = operators.contains('sncft_sahel');
    final isBanlieue =
        operators.any((op) => op.startsWith('sncft_banlieue_'));
    final isGrandesLignes = operators.contains('sncft_grandes_lignes') ||
        station.id.startsWith('sncft_');
    final isTaxi = operators.contains('taxi_collectif');

    if (isMetroSahel) return AppTheme.primaryTealBrand;
    if (isBanlieue) return const Color(0xFF1E88E5);
    if (isGrandesLignes) return const Color(0xFFFB8C00);
    if (isTaxi) return const Color(0xFFF9A825);
    return AppTheme.mediumGrey;
  }

  void _selectStation(_StationSearchItem item) {
    _controller.text = _primaryStationName(item.station);
    widget.onSelected(item.station);
    _focusNode.unfocus();
  }

  Widget _buildResultTile(_StationSearchItem item) {
    final color = _lineColor(item.station);
    final cityLabel = item.cityLabel.isNotEmpty ? item.cityLabel : '-';
    final frenchName = _primaryStationName(item.station);
    final arabicName = (item.nameAr ?? item.station.nameAr ?? '').trim();
    final showArabic = arabicName.isNotEmpty &&
        _normalizeLabel(arabicName) != _normalizeLabel(frenchName);

    return ListTile(
      onTap: () => _selectStation(item),
      leading: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      title: Text(
        frenchName,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showArabic)
            Text(
              arabicName,
              textDirection: TextDirection.rtl,
            ),
          const SizedBox(height: 2),
          Text(
            cityLabel,
            style: const TextStyle(fontSize: 12, color: AppTheme.mediumGrey),
          ),
        ],
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      dense: true,
    );
  }

  Widget _buildResultsPanel() {
    if (_query.length < 2) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          const Text(
            'Stations proches',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          if (_isLoadingNearby)
            const LinearProgressIndicator(minHeight: 2)
          else if (_nearbyStations.isEmpty)
            const Text(
              'Localisation indisponible',
              style: TextStyle(color: AppTheme.mediumGrey),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: ListView.separated(
                itemCount: _nearbyStations.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, index) => _buildResultTile(_nearbyStations[index]),
              ),
            ),
        ],
      );
    }

    if (_isLoadingSearch) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }

    if (_searchResults.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          'Aucune station trouvée',
          style: TextStyle(color: AppTheme.mediumGrey),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: _searchResults.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, index) => _buildResultTile(_searchResults[index]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          focusNode: _focusNode,
          onChanged: _onQueryChanged,
          decoration: InputDecoration(
            labelText: widget.label,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    onPressed: () {
                      _controller.clear();
                      _onQueryChanged('');
                      setState(() {});
                    },
                    icon: const Icon(Icons.close),
                  ),
          ),
        ),
        _buildResultsPanel(),
      ],
    );
  }
}

class _StationSearchItem {
  final Station station;
  final String? nameAr;
  final String? nameEn;
  final String cityLabel;

  const _StationSearchItem({
    required this.station,
    required this.cityLabel,
    this.nameAr,
    this.nameEn,
  });

  factory _StationSearchItem.fromDoc(
      QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();

    final cityLabel =
        (data['city'] ?? data['cityName'] ?? data['cityId'] ?? '').toString();
    final cityId = (data['cityId'] ?? data['city'] ?? '').toString();
    final latitude = (data['latitude'] ?? data['lat'] ?? 0.0) as num;
    final longitude = (data['longitude'] ?? data['lng'] ?? 0.0) as num;

    // Support two Firestore schemas:
    //   old (FirestoreInitializationService): name=Arabic, nameFr=French
    //   new (seed_transtu.js): name=French, nameAr=Arabic
    final nameFr = (data['nameFr'] ?? '').toString().trim();
    final nameField = (data['name'] ?? '').toString().trim();
    final nameArField = (data['nameAr'] ?? '').toString().trim();
    final frenchName = nameFr.isNotEmpty ? nameFr : nameField;
    final arabicName = nameFr.isNotEmpty
        ? (nameArField.isNotEmpty ? nameArField : nameField)
        : nameArField;

    final station = Station(
      id: doc.id,
      name: frenchName,
      nameAr: arabicName.isNotEmpty ? arabicName : null,
      nameEn: data['nameEn']?.toString(),
      cityId: cityId,
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
      address: data['address']?.toString(),
      transportTypes:
          List<String>.from(data['transportTypes'] as List? ?? const []),
      operatorsHere:
          List<String>.from(data['operatorsHere'] as List? ?? const []),
      services: StationServices.fromMap(
        Map<String, dynamic>.from(
            data['services'] as Map? ?? const <String, dynamic>{}),
      ),
      isMainHub: data['isMainHub'] == true,
      createdAt:
          (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );

    return _StationSearchItem(
      station: station,
      nameAr: arabicName.isNotEmpty ? arabicName : null,
      nameEn: data['nameEn']?.toString(),
      cityLabel: cityLabel,
    );
  }

  /// Creates a synthetic search item for a taxi-collectif-only city that has
  /// no real station document in Firestore.
  factory _StationSearchItem.taxiCity({
    required String name,
    required String cityId,
    String? nameAr,
  }) {
    final station = Station(
      id: 'tc_city_$cityId',
      name: name,
      nameAr: nameAr,
      cityId: cityId,
      latitude: 0.0,
      longitude: 0.0,
      transportTypes: const ['taxi'],
      operatorsHere: const ['taxi_collectif'],
      isMainHub: false,
      createdAt: DateTime(2024),
    );
    return _StationSearchItem(
      station: station,
      nameAr: nameAr,
      cityLabel: name,
    );
  }
}

class _ScoredStation {
  final _StationSearchItem item;
  final double score;

  const _ScoredStation({required this.item, required this.score});
}

class _NearbyDistance {
  final _StationSearchItem item;
  final double distanceMeters;

  const _NearbyDistance({required this.item, required this.distanceMeters});
}