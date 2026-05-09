import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:tuni_transport/widgets/time_text.dart';
import '../services/active_journey_service.dart';
import '../services/map_routing_service.dart';
import '../services/rating_service.dart';
import '../services/recommendation_service.dart';
import '../controllers/favorites_controller.dart';
import '../theme/app_theme.dart';
import '../models/journey_model.dart';
import '../models/metro_sahel_result.dart';
import '../constants/firestore_collections.dart';
import '../widgets/star_rating_widget.dart';

class JourneyDetailsScreen extends StatefulWidget {
  final Journey? journey;
  final MetroSahelResult? metroResult;

  const JourneyDetailsScreen({
    super.key,
    this.journey,
    this.metroResult,
  }) : assert(journey != null || metroResult != null);

  @override
  State<JourneyDetailsScreen> createState() => _JourneyDetailsScreenState();
}

class _JourneyDetailsScreenState extends State<JourneyDetailsScreen> {
  late MapController _mapController;
  late Journey _journey;
  List<_StopInfo> _intermediateStops = [];
  List<LatLng> _routePolylinePoints = const <LatLng>[];
  bool _stopsLoading = true;
  int? _resolvedBusFrequencyMinutes;

  /// True when this details screen is showing a TRANSTU bus journey.
  bool get _isTranstuBus =>
      widget.journey != null && widget.journey!.type == 'Bus TRANSTU';

  // ── Transport colour theme ────────────────────────────────────────────────

  List<Color> get _themeGradient {
    if (widget.metroResult != null) {
      final lt = widget.metroResult!.lineType;
      if (lt == 'sts_sahel') {
        return const [Color(0xFF00695C), Color(0xFF00897B)]; // STS bus → green
      }
      return const [Color(0xFF1A3A6B), Color(0xFF2E6DA4)];   // train / metro → blue
    }
    switch (_journey.iconKey) {
      case 'bus':
        return const [Color(0xFF00695C), Color(0xFF00897B)]; // TRANSTU → green
      case 'taxi':
        return const [Color(0xFFB34700), Color(0xFFD4680A)]; // taxi → dark amber
      default:
        return const [Color(0xFF1A3A6B), Color(0xFF2E6DA4)]; // default → blue
    }
  }

  Color get _themeColor => _themeGradient.first;

  String get _displayFirstDeparture =>
      _journey.timetableFirstDepartureTime ?? _journey.departureTime;

  String? get _displayLastDeparture {
    final value = _journey.timetableLastDepartureTime ?? _journey.arrivalTime;
    if (value == null || value.isEmpty) return null;
    return value;
  }

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _journey = widget.journey ?? widget.metroResult!.toJourney();
    if (widget.metroResult != null) {
      _loadIntermediateStops();
    } else if (_isTranstuBus) {
      _loadTranstuStops();
    } else {
      _stopsLoading = false;
    }
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }


  Future<void> _loadIntermediateStops() async {
    try {
      final metro = widget.metroResult!;
      final db = FirebaseFirestore.instance;

      String routeId;
      if (metro.lineType == 'banlieue_sud') {
        routeId = metro.tripNumber.isEven ? 'route_bs_north' : 'route_bs_south';
      } else if (metro.lineType == 'banlieue_d') {
        routeId = metro.tripNumber.isEven
            ? 'route_rd_line_d_reverse'
            : 'route_rd_line_d_forward';
      } else if (metro.lineType == 'banlieue_e') {
        routeId = metro.tripNumber.isEven
            ? 'route_line_e_reverse'
            : 'route_line_e_forward';
      } else if (metro.lineType == 'banlieue_nabeul') {
        routeId = metro.tripNumber.isEven
            ? 'route_bn_reverse'
            : 'route_bn_forward';
      } else if (metro.lineType == 'sncft_mainline') {
        final resolvedRouteId = await _resolveSncftMainlineRouteId(metro);
        if (resolvedRouteId == null) {
          setState(() => _stopsLoading = false);
          return;
        }
        routeId = resolvedRouteId;
      } else if (metro.lineType == 'sts_sahel') {
        final resolvedRouteId = await _resolveStsSahelRouteId(metro);
        if (resolvedRouteId == null) {
          setState(() => _stopsLoading = false);
          return;
        }
        routeId = resolvedRouteId;
      } else {
        routeId =
            metro.tripNumber.isEven ? 'route_ms_504' : 'route_ms_503';
      }

      final routeStops = await db
          .collection(Col.routeStops)
          .where('routeId', isEqualTo: routeId)
          .get();

      int fromOrder = -1;
      int toOrder = -1;
      final orderToStationId = <int, String>{};
      final orderToMinutes = <int, int>{};

      for (final doc in routeStops.docs) {
        final data = doc.data();
        final stationId = data['stationId'] as String;
        final order = data['stopOrder'] as int;
        orderToStationId[order] = stationId;
        orderToMinutes[order] =
            (data['estimatedArrivalTimeMinutes'] ?? 0) as int;
        if (stationId == metro.fromStationId) fromOrder = order;
        if (stationId == metro.toStationId) toOrder = order;
      }

      if (fromOrder == -1 || toOrder == -1) {
        setState(() => _stopsLoading = false);
        return;
      }

      final start = fromOrder < toOrder ? fromOrder : toOrder;
      final end = fromOrder < toOrder ? toOrder : fromOrder;
      final orderedKeys = <int>[];
      for (int i = start; i <= end; i++) {
        if (orderToStationId.containsKey(i)) orderedKeys.add(i);
      }
      if (fromOrder > toOrder) {
        orderedKeys.sort((a, b) => b.compareTo(a));
      }

      final stationFutures = orderedKeys.map((o) =>
          db.collection(Col.stations).doc(orderToStationId[o]!).get());
      final stationDocs = await Future.wait(stationFutures);

      // For train lines with explicit per-trip stop metadata, fetch the trip
      // document so blank timetable cells are treated as non-stops.
      Map<String, dynamic>? tripOverrides;
      Set<String> skippedStations = const <String>{};
      if (metro.lineType == 'sncft_mainline' ||
          metro.lineType == 'banlieue_nabeul' ||
          metro.lineType == 'banlieue_sud' ||
          metro.lineType == 'metro_sahel') {
        final tripNumber = metro.tripNumberStr ?? metro.tripNumber.toString();
        if (tripNumber.isNotEmpty && tripNumber != '0' && tripNumber != '–') {
          var tripSnap = await db
              .collection(Col.trips)
              .where('routeId', isEqualTo: routeId)
              .where('tripNumber', isEqualTo: tripNumber)
              .limit(1)
              .get();

          // Compatibility fallback for older docs where tripNumber was numeric.
          if (tripSnap.docs.isEmpty) {
            final tripNumberInt = int.tryParse(tripNumber);
            if (tripNumberInt != null) {
              tripSnap = await db
                  .collection(Col.trips)
                  .where('routeId', isEqualTo: routeId)
                  .where('tripNumber', isEqualTo: tripNumberInt)
                  .limit(1)
                  .get();
            }
          }

          if (tripSnap.docs.isNotEmpty) {
            final td = tripSnap.docs.first.data();
            tripOverrides = (td['stationTimeOverridesMinutes'] as Map?)
                    ?.cast<String, dynamic>() ??
                (td['stationTimeOverrides'] as Map?)?.cast<String, dynamic>();

            final skippedRaw = td['skippedStationIds'];
            if (skippedRaw is List) {
              skippedStations = skippedRaw.map((e) => e.toString()).toSet();
            }
          }
        }
      }

      final stops = <_StopInfo>[];
      final depMinutes = _parseMinutes(metro.departureTime);
      final baseOffset = orderToMinutes[fromOrder] ?? 0;

      for (int i = 0; i < orderedKeys.length; i++) {
        final data = stationDocs[i].data();
        if (data == null) continue;

        final stationId = orderToStationId[orderedKeys[i]]!;
        if (skippedStations.contains(stationId)) continue;

        int arrMinutes;
        if (tripOverrides != null) {
          // Only show stops that have an actual timetable entry — skip estimated ones.
          final resolved = _resolveOverrideMinutes(tripOverrides, stationId);
          if (resolved == null) continue; // train doesn't stop here — skip it
          arrMinutes = resolved;
        } else {
          final offset = (orderToMinutes[orderedKeys[i]] ?? 0) - baseOffset;
          arrMinutes = depMinutes + offset;
        }
        // Handle next-day wrap-around
        final displayMin = arrMinutes % 1440;
        final overflow = arrMinutes >= 1440 ? ' (+1)' : '';
        final timeStr =
            '${(displayMin ~/ 60).toString().padLeft(2, '0')}:${(displayMin % 60).toString().padLeft(2, '0')}$overflow';

        stops.add(_StopInfo(
          name: data['name'] ?? stationId,
          time: timeStr,
          lat: (data['latitude'] ?? 0.0).toDouble(),
          lng: (data['longitude'] ?? 0.0).toDouble(),
        ));
      }

      if (mounted) {
        setState(() {
          _intermediateStops = stops;
          _routePolylinePoints =
              stops.map((s) => LatLng(s.lat, s.lng)).toList(growable: false);
          _stopsLoading = false;
        });
        _loadRoutedPolyline();
      }
    } catch (_) {
      if (mounted) setState(() => _stopsLoading = false);
    }
  }


  /// Loads route stops for a TRANSTU bus journey from Firestore.
  Future<void> _loadTranstuStops() async {
    try {
      final db = FirebaseFirestore.instance;
      // Derive routeId: Journey.id is 'bus_svc_route_transtu_...' → 'route_transtu_...'
      String routeId;
      if (_journey.id.startsWith('bus_svc_')) {
        routeId = _journey.id.substring('bus_svc_'.length);
      } else {
        final svcDoc =
            await db.collection(Col.busServices).doc(_journey.id).get();
        if (!svcDoc.exists) {
          routeId = '';
        } else {
          final svcData = svcDoc.data()!;
          routeId = (svcData['routeId'] as String?) ?? '';
          _resolvedBusFrequencyMinutes =
              (svcData['peakFrequencyMinutes'] as num?)?.toInt();
        }
      }

      // Favorites / legacy entries may not carry a bus service document id.
      // In that case, infer the matching service from line + station labels.
      if (routeId.isEmpty) {
        final inferred = await _inferTranstuServiceFromJourney(db);
        routeId = inferred.$1;
        _resolvedBusFrequencyMinutes ??= inferred.$2;
      }

      if (routeId.isEmpty) {
        if (mounted) setState(() => _stopsLoading = false);
        return;
      }

      final rsSnap = await db
          .collection(Col.routeStops)
          .where('routeId', isEqualTo: routeId)
          .get();

      if (rsSnap.docs.isEmpty) {
        if (mounted) setState(() => _stopsLoading = false);
        return;
      }

      final sorted = rsSnap.docs.toList()
        ..sort((a, b) => (a.data()['stopOrder'] as int)
            .compareTo(b.data()['stopOrder'] as int));

      final stationDocs = await Future.wait(
        sorted.map((d) =>
            db.collection(Col.stations).doc(d.data()['stationId'] as String).get()),
      );

      final stops = <_StopInfo>[];
      final depMinutes = _parseMinutes(_journey.departureTime);
      final baseOffset =
          (sorted.first.data()['estimatedArrivalTimeMinutes'] ?? 0) as int;

      for (int i = 0; i < sorted.length; i++) {
        final data = stationDocs[i].data();
        if (data == null) continue;
        final offset =
            ((sorted[i].data()['estimatedArrivalTimeMinutes'] ?? 0) as int) -
                baseOffset;
        final arr = depMinutes + offset;
        final timeStr =
            '${(arr ~/ 60).toString().padLeft(2, '0')}:${(arr % 60).toString().padLeft(2, '0')}';
        stops.add(_StopInfo(
          name: data['name'] ?? sorted[i].data()['stationId'],
          time: timeStr,
          lat: (data['latitude'] ?? 0.0).toDouble(),
          lng: (data['longitude'] ?? 0.0).toDouble(),
        ));
      }

      if (mounted) {
        setState(() {
          _intermediateStops = stops;
          _routePolylinePoints =
              stops.map((s) => LatLng(s.lat, s.lng)).toList(growable: false);
          _stopsLoading = false;
        });
        _loadRoutedPolyline();
      }
    } catch (_) {
      if (mounted) setState(() => _stopsLoading = false);
    }
  }

  Future<(String, int?)> _inferTranstuServiceFromJourney(
    FirebaseFirestore db,
  ) async {
    final line = _extractLineNumber(_journey.line);
    if (line.isEmpty) return ('', null);

    final servicesSnap = await db
        .collection(Col.busServices)
        .where('lineNumber', isEqualTo: line)
        .get();

    if (servicesSnap.docs.isEmpty) return ('', null);

    final departure = _normalizeText(_journey.departureStation);
    final arrival = _normalizeText(_journey.arrivalStation);

    int bestScore = -1;
    String bestRouteId = '';
    int? bestFreq;

    for (final doc in servicesSnap.docs) {
      final data = doc.data();
      final hubId = (data['hubStationId'] as String?) ?? '';
      final destId = (data['destinationStationId'] as String?) ?? '';
      final destinationNameFr =
          _normalizeText((data['destinationNameFr'] as String?) ?? '');

      final ids = <String>{hubId, destId}.where((id) => id.isNotEmpty).toList();
      final stationSnapshots = await Future.wait(
        ids.map((id) => db.collection(Col.stations).doc(id).get()),
      );

      String hubName = '';
      String destName = '';
      for (int i = 0; i < ids.length; i++) {
        final stationData = stationSnapshots[i].data();
        final name = _normalizeText((stationData?['name'] as String?) ?? '');
        if (ids[i] == hubId) hubName = name;
        if (ids[i] == destId) destName = name;
      }

      var score = 0;
      if (_textMatches(hubName, departure)) score += 2;
      if (_textMatches(destName, arrival)) score += 2;
      if (_textMatches(destinationNameFr, arrival)) score += 1;

      if (score > bestScore) {
        bestScore = score;
        bestRouteId = (data['routeId'] as String?) ?? '';
        bestFreq = (data['peakFrequencyMinutes'] as num?)?.toInt();
      }
    }

    return (bestRouteId, bestFreq);
  }

  String _extractLineNumber(String rawLine) {
    final cleaned = rawLine.replaceAll('Ligne', '').trim();
    if (cleaned.isEmpty) return '';
    return cleaned;
  }

  String _normalizeText(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r"[^a-z0-9\u0600-\u06FF\s]"), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _textMatches(String a, String b) {
    if (a.isEmpty || b.isEmpty) return false;
    return a == b || a.contains(b) || b.contains(a);
  }

  int _parseMinutes(String timeStr) {
    final parts = timeStr.split(':');
    if (parts.length != 2) return 0;
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }

  /// Resolves a station's arrival time in minutes from a trip's
  /// stationTimeOverridesMinutes map, checking known station ID aliases.
  int? _resolveOverrideMinutes(Map<String, dynamic> overrides, String stationId) {
    // Alias groups for stations with multiple IDs
    const aliases = <String, List<String>>{
      'bs_tunis_ville': ['bs_tunis_ville', 'sncft_tunis_barcelone', 'sncft_tunis', 'bn_tunis', 'tunis'],
      'sncft_tunis_barcelone': ['bs_tunis_ville', 'sncft_tunis_barcelone', 'sncft_tunis', 'bn_tunis', 'tunis'],
      'sncft_tunis': ['bs_tunis_ville', 'sncft_tunis_barcelone', 'sncft_tunis', 'bn_tunis', 'tunis'],
      'bn_tunis': ['bs_tunis_ville', 'sncft_tunis_barcelone', 'sncft_tunis', 'bn_tunis', 'tunis'],
      'sncft_sfax': ['sncft_sfax', 'ms_sfax'],
      'ms_sfax': ['sncft_sfax', 'ms_sfax'],
      'sncft_gabes': ['sncft_gabes', 'ms_gabes'],
      'ms_gabes': ['sncft_gabes', 'ms_gabes'],
    };
    final candidates = aliases[stationId] ?? [stationId];
    for (final c in candidates) {
      final raw = overrides[c];
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
      if (raw is String) {
        final parts = raw.split(':');
        if (parts.length == 2) {
          final hh = int.tryParse(parts[0]);
          final mm = int.tryParse(parts[1]);
          if (hh != null && mm != null) return hh * 60 + mm;
        }
      }
    }
    return null;
  }

  LatLng _getCoordinates() {
    if (_intermediateStops.isNotEmpty) {
      final first = _intermediateStops.first;
      final last = _intermediateStops.last;
      return LatLng((first.lat + last.lat) / 2, (first.lng + last.lng) / 2);
    }
    final name = _journey.departureStation.toLowerCase();
    if (name.contains('mahdia')) return const LatLng(35.5047, 11.0622);
    if (name.contains('monastir')) return const LatLng(35.7441, 10.8081);
    if (name.contains('sousse')) return const LatLng(35.8256, 10.6369);
    return const LatLng(35.66, 10.85);
  }

  double _getZoom() {
    if (_intermediateStops.isEmpty) return 7.5;  // inter-city (taxi) view
    if (_intermediateStops.length <= 3) return 13.0;
    if (_intermediateStops.length <= 8) return 11.0;
    return 10.0;
  }

  List<Marker> _buildMarkers() {
    final markers = <Marker>[];
    if (_intermediateStops.isEmpty) return markers;

    markers.add(Marker(
      point:
          LatLng(_intermediateStops.first.lat, _intermediateStops.first.lng),
      width: 80,
      height: 80,
      child: _markerWidget(Colors.green, Icons.play_arrow, 'Départ'),
    ));

    for (int i = 1; i < _intermediateStops.length - 1; i++) {
      final stop = _intermediateStops[i];
      markers.add(Marker(
        point: LatLng(stop.lat, stop.lng),
        width: 14,
        height: 14,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFFFF8C00),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
        ),
      ));
    }

    markers.add(Marker(
      point:
          LatLng(_intermediateStops.last.lat, _intermediateStops.last.lng),
      width: 80,
      height: 80,
      child: _markerWidget(Colors.red, Icons.stop, 'Arrivée'),
    ));

    return markers;
  }

  Widget _markerWidget(Color color, IconData icon, String label) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
          ),
          padding: const EdgeInsets.all(6),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  List<Polyline> _buildPolylines() {
    if (_intermediateStops.length < 2) return [];
    final points = _routePolylinePoints.isNotEmpty
        ? _routePolylinePoints
        : _intermediateStops.map((s) => LatLng(s.lat, s.lng)).toList();
    return [
      Polyline(
        points: points,
        color: _themeColor,
        strokeWidth: 3.0,
      ),
    ];
  }

  Future<void> _loadRoutedPolyline() async {
    if (_intermediateStops.length < 2) return;
    final base = _intermediateStops
        .map((s) => LatLng(s.lat, s.lng))
        .toList(growable: false);
    final routed = await MapRoutingService.buildRoadPath(base);
    if (!mounted || routed.length < 2) return;
    setState(() {
      _routePolylinePoints = routed;
    });
  }

  Future<void> _shareJourney() async {
    final metro = widget.metroResult;
    final shareText = StringBuffer();

    if (metro != null) {
      final isBus = metro.lineType == 'sts_sahel';
      shareText
        ..writeln('${isBus ? '🚌' : '🚆'} ${metro.operatorName}')
        ..writeln('${metro.fromStationName} → ${metro.toStationName}')
        ..writeln('${isBus ? 'Bus N°' : 'Train N°'}${metro.tripNumberStr ?? metro.tripNumber}')
        ..writeln('Départ: ${metro.departureTime}')
        ..writeln(
            'Arrivée: ${metro.noTrainToday ? "Demain" : metro.arrivalTime}')
        ..writeln('Durée: ${metro.durationMinutes} min')
        ..writeln('Prix: ${metro.price.toStringAsFixed(3)} TND')
        ..writeln('Arrêts: ${metro.numberOfStops}')
        ..writeln('☎️ ${metro.operatorPhone}');
    } else {
      final j = _journey;
      shareText
        ..writeln('🚌 Bus TRANSTU – ${j.line}')
        ..writeln('${j.departureStation} → ${j.arrivalStation}')
        ..writeln('Premier départ: $_displayFirstDeparture');
      if (_displayLastDeparture != null) {
        shareText.writeln('Dernier départ: $_displayLastDeparture');
      }
      shareText
        ..writeln(j.duration.isNotEmpty ? j.duration : '')
        ..writeln('Prix: ${j.price} TND');
    }

    try {
      await Share.share(shareText.toString());
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Impossible de partager ce trajet.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<String?> _resolveSncftMainlineRouteId(MetroSahelResult metro) async {
    final db = FirebaseFirestore.instance;
    const candidateRoutes = [
      'route_sncft_l5_forward',
      'route_sncft_l5_reverse',
      'route_sncft_redeyef_forward',
      'route_sncft_redeyef_reverse',
      'route_sncft_kef_forward',
      'route_sncft_kef_reverse',
      'route_sncft_gl_annaba_forward',
      'route_sncft_gl_annaba_reverse',
      'route_sncft_gl_bizerte_forward',
      'route_sncft_gl_bizerte_reverse',
    ];

    String? fallbackRouteId;
    for (final candidateRouteId in candidateRoutes) {
      final routeStops = await db
          .collection(Col.routeStops)
          .where('routeId', isEqualTo: candidateRouteId)
          .get();

      int? fromOrder;
      int? toOrder;
      for (final doc in routeStops.docs) {
        final data = doc.data();
        final sid = data['stationId'] as String;
        final order = data['stopOrder'] as int;
        if (sid == metro.fromStationId) fromOrder = order;
        if (sid == metro.toStationId) toOrder = order;
      }

      if (fromOrder != null && toOrder != null) {
        if (fromOrder < toOrder) return candidateRouteId;
        fallbackRouteId ??= candidateRouteId;
      }
    }
    return fallbackRouteId;
  }

  Future<String?> _resolveStsSahelRouteId(MetroSahelResult metro) async {
    final db = FirebaseFirestore.instance;
    const candidateRoutes = [
      'route_sts_mahdia_sousse_basic',
      'route_sts_sousse_mahdia_basic',
      'route_sts_mahdia_sousse',
      'route_sts_sousse_mahdia',
      'route_sts_mahdia_sousse_monastir',
      'route_sts_sousse_mahdia_monastir',
    ];

    String? fallbackRouteId;
    final tripNumber = (metro.tripNumberStr ?? '').trim();
    for (final candidateRouteId in candidateRoutes) {
      final routeStops = await db
          .collection(Col.routeStops)
          .where('routeId', isEqualTo: candidateRouteId)
          .get();

      int? fromOrder;
      int? toOrder;
      for (final doc in routeStops.docs) {
        final data = doc.data();
        final sid = data['stationId'] as String;
        final order = data['stopOrder'] as int;
        if (sid == metro.fromStationId) fromOrder = order;
        if (sid == metro.toStationId) toOrder = order;
      }

      if (fromOrder != null && toOrder != null) {
        if (fromOrder < toOrder) {
          if (tripNumber.isNotEmpty && tripNumber != '0' && tripNumber != '–') {
            final tripSnap = await db
                .collection(Col.trips)
                .where('routeId', isEqualTo: candidateRouteId)
                .where('tripNumber', isEqualTo: tripNumber)
                .limit(1)
                .get();
            if (tripSnap.docs.isNotEmpty) {
              return candidateRouteId;
            }
          } else {
            return candidateRouteId;
          }
        }
        fallbackRouteId ??= candidateRouteId;
      }
    }
    return fallbackRouteId;
  }

  // ── Bus details panel ─────────────────────────────────────────────────────

  Widget _buildBusDetailsPanel() {
    final j = _journey;
    final frequencyValue = j.duration.isNotEmpty
        ? j.duration
        : (_resolvedBusFrequencyMinutes != null
            ? 'Fréquence: $_resolvedBusFrequencyMinutes min'
            : '');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Informations de la ligne',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          _buildInfoCard(
            icon: Icons.directions_bus,
            title: 'Ligne',
            value: j.line,
          ),
          const SizedBox(height: 12),
          _buildInfoCard(
            icon: Icons.my_location,
            title: 'Hub de départ',
            value: j.departureStation,
          ),
          const SizedBox(height: 12),
          _buildInfoCard(
            icon: Icons.place_outlined,
            title: 'Destination',
            value: j.arrivalStation,
          ),
          const SizedBox(height: 12),
          _buildInfoCard(
            icon: Icons.access_time,
            title: 'Premier départ',
            value: _displayFirstDeparture,
          ),
          const SizedBox(height: 12),
          if (_displayLastDeparture != null)
            _buildInfoCard(
              icon: Icons.access_time_filled,
              title: 'Dernier départ',
              value: _displayLastDeparture!,
            ),
          const SizedBox(height: 12),
          if (frequencyValue.isNotEmpty)
            _buildInfoCard(
              icon: Icons.schedule,
              title: 'Fréquence',
              value: frequencyValue,
            ),
          const SizedBox(height: 12),
          _buildInfoCard(
            icon: Icons.payments_outlined,
            title: 'Tarif estimé',
            value: '${j.price} TND',
          ),
          if (j.estimatedTripDurationMinutes != null) ...[
            const SizedBox(height: 12),
            _buildInfoCard(
              icon: Icons.timer_outlined,
              title: 'Durée estimée du trajet',
              value: '~${j.estimatedTripDurationMinutes} min',
            ),
          ],
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFA5D6A7)),
            ),
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(Icons.info_outline,
                    color: Color(0xFF2E7D32), size: 20),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Les bus TRANSTU opèrent à fréquence régulière. '
                    'Le premier et le dernier départ sont indiqués depuis le point de départ du trajet.',
                    style:
                        TextStyle(fontSize: 13, color: Color(0xFF1B5E20)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Rating sheet ─────────────────────────────────────────────────────────

  static String _iconKeyToTransportType(String iconKey) {
    switch (iconKey) {
      case 'bus':
        return 'transtu_bus';
      case 'taxi':
        return 'taxi_collectif';
      case 'train':
        return 'sncft';
      default:
        return 'metro_sahel';
    }
  }

  Future<void> _showRatingSheet(BuildContext ctx, Journey journey) {
    final metro = widget.metroResult;
    return showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      builder: (_) => _RatingSheet(
        journey: journey,
        fromStationId: metro?.fromStationId,
        toStationId: metro?.toStationId,
        transportType: metro != null
            ? RecommendationService.lineTypeToTransportType(metro.lineType)
            : _iconKeyToTransportType(journey.iconKey),
      ),
    );
  }

  Future<void> _openMaps() async {
    final coords = _getCoordinates();
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1'
      '&destination=${coords.latitude},${coords.longitude}',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ── Section header ────────────────────────────────────────────────────────

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 10),
      child: Row(
        children: [
          Container(width: 4, height: 18, color: _themeColor,
              margin: const EdgeInsets.only(right: 10)),
          Text(title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // ── Shadow card wrapper used for each info section ────────────────────────

  Widget _sectionCard(Widget child) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: child,
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final metro = widget.metroResult;
    final isMetro = metro != null;
    final isTaxi = !isMetro && _journey.iconKey == 'taxi';
    final isStusBus = isMetro && metro.lineType == 'sts_sahel';

    // ── Derive transport display names ──────────────────────────────────────
    final String transportName = isMetro
        ? (isStusBus ? 'Bus' : 'Train')
        : isTaxi
            ? 'Taxi Collectif'
            : 'Bus';

    final String? lineNum = isMetro
        ? '${metro.tripNumberStr ?? metro.tripNumber}'
        : _isTranstuBus
            ? _journey.line
            : null;

    final String operatorSub =
        isMetro ? metro.operatorName : _journey.operator;

    // Icon for transport type in header
    final IconData transportIcon = isMetro
        ? (isStusBus ? Icons.directions_bus : Icons.train)
        : isTaxi
            ? Icons.local_taxi
            : Icons.directions_bus;

    // ── Duration string ─────────────────────────────────────────────────────
    final String durationStr = isMetro
        ? '${metro.durationMinutes} min'
        : _journey.estimatedTripDurationMinutes != null
            ? '~${_journey.estimatedTripDurationMinutes} min'
            : _journey.duration.isNotEmpty
                ? _journey.duration
                : '--';

    // ── Price string ────────────────────────────────────────────────────────
    final String priceStr = isMetro
        ? '${metro.price.toStringAsFixed(3)} TND'
        : '${_journey.price} TND';

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ───────────────────────────────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(4, 12, 8, 16),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: _themeGradient),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Back button
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go('/home/journey-input');
                      }
                    },
                  ),
                  // Transport icon
                  Icon(transportIcon, color: Colors.white, size: 22),
                  const SizedBox(width: 10),
                  // Transport name + operator
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          transportName,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          operatorSub,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.70),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Line number (no circle, plain white text) — hidden for taxi
                  if (lineNum != null && lineNum.isNotEmpty) ...[
                    Text(
                      lineNum,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  // ⭐ and 📤 only for taxi — hidden for train and bus
                  if (isTaxi) ...[
                    IconButton(
                      icon: const Icon(Icons.star_border, color: Colors.white),
                      tooltip: 'Évaluer',
                      onPressed: () => _showRatingSheet(context, _journey),
                    ),
                    IconButton(
                      icon: const Icon(Icons.ios_share, color: Colors.white),
                      tooltip: 'Partager',
                      onPressed: _shareJourney,
                    ),
                  ],
                ],
              ),
            ),

            // ── Scrollable content ────────────────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Map (250 px) — shown for all modes ─────────────────
                    SizedBox(
                      height: 250,
                      child: _stopsLoading
                          ? const Center(child: CircularProgressIndicator())
                          : ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                bottom: Radius.circular(20),
                              ),
                              child: FlutterMap(
                                mapController: _mapController,
                                options: MapOptions(
                                  initialCenter: _getCoordinates(),
                                  initialZoom: _getZoom(),
                                  maxZoom: 18,
                                  minZoom: 5,
                                ),
                                children: [
                                  TileLayer(
                                    urlTemplate:
                                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                    userAgentPackageName:
                                        'com.example.tunitransport',
                                    maxNativeZoom: 19,
                                  ),
                                  if (_buildPolylines().isNotEmpty)
                                    PolylineLayer(
                                        polylines: _buildPolylines()),
                                  if (_buildMarkers().isNotEmpty)
                                    MarkerLayer(markers: _buildMarkers()),
                                ],
                              ),
                            ),
                    ),

                    // ── Informations du trajet ────────────────────────────────
                    _sectionHeader('Informations du trajet'),
                    _sectionCard(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // No-service banner
                          if (isMetro && metro.noTrainToday)
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.amber.shade50,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.amber.shade200),
                              ),
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  const Icon(Icons.info_outline,
                                      color: Colors.amber, size: 20),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text.rich(
                                      TextSpan(children: [
                                        TextSpan(
                                          text: isStusBus
                                              ? 'Aucun bus ce soir. Prochain demain à '
                                              : 'Aucun train ce soir. Premier demain à ',
                                        ),
                                        WidgetSpan(
                                          alignment: PlaceholderAlignment.middle,
                                          child: TimeText(metro.departureTime,
                                              style: TextStyle(
                                                  color: Colors.amber.shade900,
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 13)),
                                        ),
                                      ]),
                                      style: TextStyle(
                                          color: Colors.amber.shade900,
                                          fontSize: 13),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                          // Départ / Arrivée — hidden for taxi
                          if (!isTaxi && !(isMetro && metro.noTrainToday)) ...[
                            _infoRow(
                              label: 'Départ',
                              station: isMetro
                                  ? metro.fromStationName
                                  : _journey.departureStation,
                              time: isMetro
                                  ? metro.departureTime
                                  : _journey.departureTime,
                            ),
                            const SizedBox(height: 8),
                            _infoRow(
                              label: 'Arrivée',
                              station: isMetro
                                  ? metro.toStationName
                                  : _journey.arrivalStation,
                              time: isMetro
                                  ? metro.arrivalTime
                                  : (_journey.arrivalTime ?? ''),
                            ),
                            const SizedBox(height: 12),
                            const Divider(height: 1),
                            const SizedBox(height: 10),
                          ],

                          // Durée du trajet
                          Row(
                            children: [
                              Icon(Icons.timer_outlined,
                                  size: 18, color: _themeColor),
                              const SizedBox(width: 8),
                              Text('Durée du trajet',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.mediumGrey)),
                              const Spacer(),
                              Text(durationStr,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // ── Étapes du trajet — hidden for taxi ──────────────────
                    if (!isTaxi) ...[
                      _sectionHeader('Étapes du trajet'),
                      _sectionCard(
                        _stopsLoading
                            ? const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(16),
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            : _isTranstuBus && _intermediateStops.isEmpty
                                ? _buildBusDetailsPanel()
                                : _intermediateStops.isNotEmpty
                                    ? Column(children: _buildStopsList())
                                    : Column(
                                        children: [
                                          _buildRouteStep(
                                            time: _journey.departure,
                                            station: _journey.departureStation,
                                            isFirst: true,
                                            isLast: false,
                                          ),
                                          _buildRouteStep(
                                            time: _journey.arrival,
                                            station: _journey.arrivalStation,
                                            isFirst: false,
                                            isLast: true,
                                            type: 'Destination',
                                          ),
                                        ],
                                      ),
                      ),
                    ],

                    // ── Tarif ───────────────────────────────────────────────
                    _sectionHeader('Tarif'),
                    _sectionCard(
                      Row(
                        children: [
                          Icon(Icons.confirmation_number_outlined,
                              size: 18, color: _themeColor),
                          const SizedBox(width: 8),
                          Text(
                            priceStr,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: _themeColor,
                            ),
                          ),
                        ],
                      ),
                    ),


                    // ── Fréquence — bus only ─────────────────────────────────
                    if (_isTranstuBus && _resolvedBusFrequencyMinutes != null) ...[
                      _sectionHeader('Fréquence'),
                      _sectionCard(
                        Row(
                          children: [
                            Icon(Icons.schedule, size: 18, color: _themeColor),
                            const SizedBox(width: 8),
                            Text(
                              'Toutes les $_resolvedBusFrequencyMinutes minutes',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // ── Actions ──────────────────────────────────────────────
                    _sectionHeader('Actions'),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: [

                          // ── Train + Bus: Commencer le trajet ─────────────────
                          if (!isTaxi) ...[
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _themeColor,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 14),
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(12)),
                                  elevation: 0,
                                ),
                                onPressed: () async {
                                  await ActiveJourneyService.instance
                                      .setActiveJourney(_journey);
                                  if (!context.mounted) return;
                                  context.push('/home/active-journey',
                                      extra: <String, dynamic>{
                                        'journey':       _journey,
                                        'fromStationId': widget.metroResult?.fromStationId,
                                        'toStationId':   widget.metroResult?.toStationId,
                                        'metroResult':   widget.metroResult,
                                      });
                                },
                                icon:
                                    const Icon(Icons.directions_run),
                                label: const Text(
                                  'Commencer le trajet',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                          ],

                          // ── Taxi only: Google Maps + Évaluer ─────────────────
                          if (isTaxi) ...[
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _themeColor,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 14),
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(12)),
                                  elevation: 0,
                                ),
                                onPressed: _openMaps,
                                icon: const Icon(Icons.map_outlined),
                                label: const Text(
                                  'Consulter sur Google Maps',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: _themeColor,
                                  side: BorderSide(color: _themeColor),
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 14),
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(12)),
                                ),
                                onPressed: () =>
                                    _showRatingSheet(context, _journey),
                                icon:
                                    const Icon(Icons.star_border_rounded),
                                label: const Text('Évaluer le trajet',
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600)),
                              ),
                            ),
                            const SizedBox(height: 10),
                          ],

                          // Favoris + Partager — side by side
                          Row(
                            children: [
                              Expanded(
                                child: AnimatedBuilder(
                                  animation: FavoritesController.instance,
                                  builder: (bCtx, _) {
                                    final isFav = FavoritesController.instance
                                        .isFavorite(_journey.id);
                                    return OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: isFav
                                            ? Colors.red
                                            : AppTheme.mediumGrey,
                                        side: BorderSide(
                                          color: isFav
                                              ? Colors.red.shade200
                                              : AppTheme.lightGrey,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 12),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(12)),
                                      ),
                                      onPressed: () async {
                                        try {
                                          await FavoritesController.instance
                                              .toggleFavorite(_journey);
                                          if (!bCtx.mounted) return;
                                          final nowFav =
                                              FavoritesController.instance
                                                  .isFavorite(_journey.id);
                                          ScaffoldMessenger.of(bCtx)
                                              .showSnackBar(SnackBar(
                                            content: Text(nowFav
                                                ? 'Ajouté aux favoris'
                                                : 'Retiré des favoris'),
                                            duration:
                                                const Duration(seconds: 2),
                                          ));
                                        } catch (_) {}
                                      },
                                      icon: Icon(isFav
                                          ? Icons.favorite_rounded
                                          : Icons.favorite_border_rounded),
                                      label: Text(isFav ? 'Favoris ♥' : 'Favoris'),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: AppTheme.mediumGrey,
                                    side: const BorderSide(
                                        color: AppTheme.lightGrey),
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 12),
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(12)),
                                  ),
                                  onPressed: _shareJourney,
                                  icon: const Icon(Icons.ios_share),
                                  label: const Text('Partager'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Départ / Arrivée row ──────────────────────────────────────────────────

  Widget _infoRow({
    required String label,
    required String station,
    required String time,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 56,
          child: Text(
            '$label:',
            style: const TextStyle(
                fontSize: 13, color: AppTheme.mediumGrey),
          ),
        ),
        Expanded(
          child: Text(
            station,
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 8),
        TimeText(
          time,
          style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: _themeColor),
        ),
      ],
    );
  }

  List<Widget> _buildStopsList() {
    final widgets = <Widget>[];
    for (int i = 0; i < _intermediateStops.length; i++) {
      final stop = _intermediateStops[i];
      final isFirst = i == 0;
      final isLast = i == _intermediateStops.length - 1;
      widgets.add(_buildRouteStep(
        time: stop.time,
        station: stop.name,
        isFirst: isFirst,
        isLast: isLast,
        type: isFirst ? 'Départ' : isLast ? 'Destination' : null,
      ));
    }
    return widgets;
  }

  Widget _buildRouteStep({
    required String time,
    required String station,
    required bool isFirst,
    required bool isLast,
    String? type,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            if (isFirst || isLast)
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: isFirst ? Colors.green : Colors.red,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isFirst
                        ? Colors.green.shade200
                        : Colors.red.shade200,
                    width: 4,
                  ),
                ),
              )
            else
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF8C00),
                  shape: BoxShape.circle,
                  border:
                      Border.all(color: Colors.orange.shade100, width: 2),
                ),
              ),
            if (!isLast)
              Container(
                width: 2,
                height: isFirst || isLast ? 40 : 28,
                color: _themeColor.withValues(alpha: 0.5),
              ),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 2),
              TimeText(
                time,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700),
              ),
              Text(station,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500)),
              if (type != null)
                Text(type,
                    style: TextStyle(
                        fontSize: 11, color: AppTheme.mediumGrey)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String title,
    required String value,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.lightGrey),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              color: _themeColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            padding: const EdgeInsets.all(8),
            child: Icon(icon, color: _themeColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 12, color: AppTheme.mediumGrey)),
                Text(value,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StopInfo {
  final String name;
  final String time;
  final double lat;
  final double lng;

  const _StopInfo({
    required this.name,
    required this.time,
    required this.lat,
    required this.lng,
  });
}

// ── Rating bottom sheet ────────────────────────────────────────────────────

class _RatingSheet extends StatefulWidget {
  final Journey journey;
  final String? fromStationId;
  final String? toStationId;
  final String transportType;

  const _RatingSheet({
    required this.journey,
    required this.transportType,
    this.fromStationId,
    this.toStationId,
  });

  @override
  State<_RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends State<_RatingSheet> {
  final _ratingService = RatingService();
  int _transportRating = 0;
  int _experienceRating = 0;
  final _commentController = TextEditingController();
  bool _submitting = false;

  String? get _uid =>
      firebase_auth.FirebaseAuth.instance.currentUser?.uid;

  bool get _canSave =>
      widget.fromStationId != null &&
      widget.toStationId != null &&
      _uid != null;

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_transportRating == 0 || _experienceRating == 0) return;
    setState(() => _submitting = true);

    final combined = ((_transportRating + _experienceRating) / 2).round();

    if (_canSave) {
      try {
        await _ratingService.submitRating(
          uid: _uid!,
          fromStationId: widget.fromStationId!,
          toStationId: widget.toStationId!,
          transportType: widget.transportType,
          rating: combined,
        );
      } catch (e) {
        debugPrint('[RatingSheet] submit failed: $e');
      }
    }

    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Merci pour votre évaluation !'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  Widget _starRow(String label, int current, ValueChanged<int> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppTheme.textDark,
          ),
        ),
        const SizedBox(height: 8),
        StarRatingWidget(
          rating: current,
          starSize: 36,
          onRated: onChanged,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottom),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppTheme.mediumGrey,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            const Text(
              'Évaluer le trajet',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppTheme.textDark,
              ),
            ),
            const SizedBox(height: 20),

            _starRow(
              'Qualité du transport',
              _transportRating,
              (v) => setState(() => _transportRating = v),
            ),
            const SizedBox(height: 16),
            _starRow(
              'Expérience globale',
              _experienceRating,
              (v) => setState(() => _experienceRating = v),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: _commentController,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'Commentaire (facultatif)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: (_submitting ||
                        _transportRating == 0 ||
                        _experienceRating == 0)
                    ? null
                    : _submit,
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Soumettre'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
