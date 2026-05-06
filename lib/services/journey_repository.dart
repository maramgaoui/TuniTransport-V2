import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/metro_sahel_result.dart';
import '../models/tariff_model.dart';
import 'route_repository.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Configuration object — one per line type.
//  All the per-line differences live here; the core search algorithm is shared.
// ─────────────────────────────────────────────────────────────────────────────

/// Resolves the Firestore routeId for a given (from, to) pair.
typedef RouteIdResolver = Future<String?> Function(
  String fromStationId,
  String toStationId,
);

/// Computes the fare given the resolved stop/section metadata.
typedef FareCalculator = double Function(_StopMeta from, _StopMeta to);

/// Metadata extracted from a single `route_stops` document.
class _StopMeta {
  final int offset;   // estimatedArrivalTimeMinutes from route origin
  final int order;    // stopOrder
  final int section;  // section number (used for section-based fares)

  const _StopMeta({
    required this.offset,
    required this.order,
    required this.section,
  });
}

/// Per-line static configuration.
class _LineConfig {
  final String lineType;
  final String operatorName;
  final String operatorPhone;
  /// First departure fallback shown when no trip is found today.
  final String fallbackFirstDeparture;
  final RouteIdResolver resolveRouteId;
  final FareCalculator calculateFare;
  /// Whether trips may have partial-origin / partial-destination overrides
  /// (only needed for SNCFT mainline long-distance trains).
  final bool supportsPartialTrips;
  /// When true, never infer that a train stops at a station unless the trip
  /// carries explicit stop metadata (override times or skipped-station rules).
  final bool requiresExplicitStopMetadata;

  const _LineConfig({
    required this.lineType,
    required this.operatorName,
    required this.operatorPhone,
    required this.fallbackFirstDeparture,
    required this.resolveRouteId,
    required this.calculateFare,
    this.supportsPartialTrips = false,
    this.requiresExplicitStopMetadata = false,
  });

  _LineConfig copyWith({RouteIdResolver? resolveRouteId}) => _LineConfig(
        lineType: lineType,
        operatorName: operatorName,
        operatorPhone: operatorPhone,
        fallbackFirstDeparture: fallbackFirstDeparture,
        resolveRouteId: resolveRouteId ?? this.resolveRouteId,
        calculateFare: calculateFare,
        supportsPartialTrips: supportsPartialTrips,
        requiresExplicitStopMetadata: requiresExplicitStopMetadata,
      );
}

class _RouteSearchMetadata {
  final String operatorId;
  final bool isSearchActive;

  const _RouteSearchMetadata({
    required this.operatorId,
    required this.isSearchActive,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
//  Repository
// ─────────────────────────────────────────────────────────────────────────────

class JourneyRepository {
  final FirebaseFirestore _firestore;
  final RouteRepository _routeRepository;

  JourneyRepository(this._firestore, this._routeRepository);

  List<String> _sncftAltCandidates(String stationId) {
    switch (stationId) {
      case 'sncft_tunis_barcelone':
      case 'sncft_tunis':
      case 'bn_tunis':
      case 'bs_tunis_ville':
      case 'tunis':
        return const [
          'sncft_tunis_barcelone',
          'sncft_tunis',
          'bn_tunis',
          'bs_tunis_ville',
          'tunis',
        ];
      case 'ms_sfax':
      case 'sncft_sfax':
        return const ['sncft_sfax', 'ms_sfax'];
      case 'ms_gabes':
      case 'sncft_gabes':
        return const ['sncft_gabes', 'ms_gabes'];
      default:
        return [stationId];
    }
  }

  String _resolveAltId({
    required Set<String> routeStationIds,
    required List<String> candidates,
  }) {
    for (final c in candidates) {
      if (routeStationIds.contains(c)) return c;
    }
    return candidates.first;
  }

  Future<String> _resolveSncftL5StationId(String stationId) async {
    final snap = await _firestore
        .collection('route_stops')
        .where('routeId', isEqualTo: 'route_sncft_l5_forward')
        .get();
    final ids = <String>{
      for (final doc in snap.docs) (doc.data()['stationId'] ?? '').toString(),
    };
    return _resolveAltId(
      routeStationIds: ids,
      candidates: _sncftAltCandidates(stationId),
    );
  }

  Future<_RouteSearchMetadata> _getRouteSearchMetadata(String routeId) async {
    final routeDoc = await _firestore.collection('routes').doc(routeId).get();
    final routeData = routeDoc.data();
    if (routeData == null) {
      return const _RouteSearchMetadata(operatorId: '', isSearchActive: true);
    }

    final operatorId = (routeData['operatorId'] ?? '').toString();
    final searchVisibilityManaged = routeData['searchVisibilityManaged'] == true;
    final explicitlyInactive = (routeData['isActive'] ?? true) != true;

    // User search still resolves canonical routes from route_stops/trips.
    // Only let route metadata hide results after an explicit admin opt-in,
    // otherwise legacy or incomplete route docs can suppress valid journeys.
    return _RouteSearchMetadata(
      operatorId: operatorId,
      isSearchActive: !(searchVisibilityManaged && explicitlyInactive),
    );
  }

  // Tariff lookup flow:
  // ManageTariffsScreen edits Firestore documents in the `tariffs` collection.
  // Journey search reads tariff values from `tariffs` at query time so users see
  // updated prices on the next render without relying on route-cached prices.
  Future<double?> _lookupTariffPrice({
    required String operatorId,
    required String fromStationId,
    required String toStationId,
    required DateTime referenceDate,
  }) async {
    final normalizedOperator = operatorId.trim().toLowerCase();
    final snapshot = await _firestore
        .collection('tariffs')
        .where('fromStationId', isEqualTo: fromStationId)
        .where('toStationId', isEqualTo: toStationId)
        .get();

    QueryDocumentSnapshot<Map<String, dynamic>>? bestDoc;
    DateTime? bestValidFrom;
    DateTime? bestTieBreaker;

    for (final doc in snapshot.docs) {
      final data = doc.data();
      final tariffOperator = (data['operatorId'] ?? '').toString().trim().toLowerCase();
      if (normalizedOperator.isNotEmpty && tariffOperator != normalizedOperator) {
        continue;
      }

      final validFromRaw = data['validFrom'];
      final validToRaw = data['validTo'];
      final validFrom = validFromRaw is Timestamp ? validFromRaw.toDate() : null;
      final validTo = validToRaw is Timestamp ? validToRaw.toDate() : null;
      if (validFrom == null) continue;

      final startsBeforeOrOn = !referenceDate.isBefore(validFrom);
      final endsAfterOrOn =
          validTo == null || !referenceDate.isAfter(validTo.add(const Duration(days: 1)));
      if (!startsBeforeOrOn || !endsAfterOrOn) continue;

      final updatedAtRaw = data['updatedAt'];
      final createdAtRaw = data['createdAt'];
      final tieBreaker = updatedAtRaw is Timestamp
          ? updatedAtRaw.toDate()
          : (createdAtRaw is Timestamp ? createdAtRaw.toDate() : validFrom);

      if (bestDoc == null) {
        bestDoc = doc;
        bestValidFrom = validFrom;
        bestTieBreaker = tieBreaker;
        continue;
      }

      final hasLaterValidity = validFrom.isAfter(bestValidFrom!);
      final sameValidity = validFrom.isAtSameMomentAs(bestValidFrom);
      final hasLaterTieBreaker = tieBreaker.isAfter(bestTieBreaker!);
      if (hasLaterValidity || (sameValidity && hasLaterTieBreaker)) {
        bestDoc = doc;
        bestValidFrom = validFrom;
        bestTieBreaker = tieBreaker;
      }
    }

    if (bestDoc == null) return null;
    final rawPrice = bestDoc.data()['price'];
    return (rawPrice as num?)?.toDouble();
  }

  // ── Public API — one thin wrapper per line type ───────────────────────────

  Future<MetroSahelResult?> findNextMetroSahelTrip({
    required String fromStationId,
    required String toStationId,
    required DateTime searchDateTime,
  }) =>
      _findNextMetroSahelTripInternal(
        fromStationId: fromStationId,
        toStationId: toStationId,
        searchDateTime: searchDateTime,
      );

  Future<MetroSahelResult?> findNextBanlieueSudTrip({
    required String fromStationId,
    required String toStationId,
    required DateTime searchDateTime,
  }) =>
      _findNextOffsetBasedTrip(
        fromStationId: fromStationId,
        toStationId: toStationId,
        searchDateTime: searchDateTime,
        config: _LineConfig(
          lineType: 'banlieue_sud',
          operatorName: 'Trains des Banlieues sud et ouest de Tunis',
          operatorPhone: '+216 71 337 000',
          fallbackFirstDeparture: '04:35',
          resolveRouteId: (f, t) =>
              _routeRepository.findBanlieueSudRouteId(f, t),
          calculateFare: (from, to) {
            final sectionsTraveled = (from.section - to.section).abs() + 1;
            return _bsFare(sectionsTraveled);
          },
          requiresExplicitStopMetadata: true,
        ),
      );

  Future<MetroSahelResult?> findNextBanlieueETrip({
    required String fromStationId,
    required String toStationId,
    required DateTime searchDateTime,
  }) =>
      _findNextOffsetBasedTrip(
        fromStationId: fromStationId,
        toStationId: toStationId,
        searchDateTime: searchDateTime,
        config: _LineConfig(
          lineType: 'banlieue_e',
          operatorName: 'Trains des Banlieues sud et ouest de Tunis',
          operatorPhone: '+216 71 334 444',
          fallbackFirstDeparture: '04:40',
          resolveRouteId: (f, t) =>
              _routeRepository.findBanlieueERouteId(f, t),
          calculateFare: (from, to) => 0.700,
        ),
      );

  Future<MetroSahelResult?> findNextBanlieueDTrip({
    required String fromStationId,
    required String toStationId,
    required DateTime searchDateTime,
  }) =>
      _findNextOffsetBasedTrip(
        fromStationId: fromStationId,
        toStationId: toStationId,
        searchDateTime: searchDateTime,
        config: _LineConfig(
          lineType: 'banlieue_d',
          operatorName: 'Trains des Banlieues sud et ouest de Tunis',
          operatorPhone: '+216 71 334 444',
          fallbackFirstDeparture: '04:10',
          resolveRouteId: (f, t) =>
              _routeRepository.findBanlieueDRouteId(f, t),
          calculateFare: (from, to) => 0.700,
        ),
      );

  Future<MetroSahelResult?> findNextBanlieueNabeulTrip({
    required String fromStationId,
    required String toStationId,
    required DateTime searchDateTime,
  }) =>
      _findNextOffsetBasedTrip(
        fromStationId: fromStationId,
        toStationId: toStationId,
        searchDateTime: searchDateTime,
        config: _LineConfig(
          lineType: 'banlieue_nabeul',
          operatorName: 'SNCFT - Banlieue de Nabeul',
          operatorPhone: '+216 71 334 444',
          fallbackFirstDeparture: '06:15',
          resolveRouteId: (f, t) =>
              _routeRepository.findBanlieueNabeulRouteId(f, t),
          calculateFare: (from, to) =>
              _bnFare((from.order - to.order).abs()),
          supportsPartialTrips: true,
        ),
      );

  Future<MetroSahelResult?> findNextSncftL5Trip({
    required String fromStationId,
    required String toStationId,
    required DateTime searchDateTime,
  }) async {
    final resolvedFrom = await _resolveSncftL5StationId(fromStationId);
    final resolvedTo = await _resolveSncftL5StationId(toStationId);

    return _findNextOffsetBasedTrip(
        fromStationId: resolvedFrom,
        toStationId: resolvedTo,
        searchDateTime: searchDateTime,
        config: _LineConfig(
          lineType: 'sncft_mainline',
          operatorName: 'SNCFT – Société Nationale des Chemins de Fer Tunisiens',
          operatorPhone: '+216 71 334 444',
          fallbackFirstDeparture: '07:35',
          resolveRouteId: (f, t) async =>
              await _routeRepository.findSncftL5RouteId(f, t) ??
              await _routeRepository.findSncftRedeyefRouteId(f, t) ??
              await _routeRepository.findSncftKefRouteId(f, t) ??
              await _routeRepository.findSncftGlAnnabaRouteId(f, t) ??
              await _routeRepository.findSncftGlBizerteRouteId(f, t),
          calculateFare: (from, to) =>
              _sncftL5Fare(_sncftFromId, _sncftToId),
          supportsPartialTrips: true,
        ),
      );
  }

  Future<MetroSahelResult?> findNextStsSahelTrip({
    required String fromStationId,
    required String toStationId,
    required DateTime searchDateTime,
  }) async {
    final baseConfig = _LineConfig(
      lineType: 'sts_sahel',
      operatorName: 'STS – Société de Transport du Sahel',
      operatorPhone: '+216 73 229 500',
      fallbackFirstDeparture: '04:45',
      resolveRouteId: (f, t) => _routeRepository.findStsSahelRouteId(f, t),
      calculateFare: (from, to) =>
          _stsSahelFare((from.order - to.order).abs()),
      supportsPartialTrips: true,
    );

    // Try both routes in parallel and return the one with the earliest departure.
    final results = await Future.wait([
      _findNextOffsetBasedTrip(
        fromStationId: fromStationId,
        toStationId: toStationId,
        searchDateTime: searchDateTime,
        config: baseConfig.copyWith(
          resolveRouteId: (f, t) =>
              _routeRepository.findStsSahelViaSayadaRouteId(f, t),
        ),
      ),
      _findNextOffsetBasedTrip(
        fromStationId: fromStationId,
        toStationId: toStationId,
        searchDateTime: searchDateTime,
        config: baseConfig.copyWith(
          resolveRouteId: (f, t) =>
              _routeRepository.findStsSahelViaMonastirRouteId(f, t),
        ),
      ),
    ]);

    final sayadaResult = results[0];
    final monastirResult = results[1];

    if (sayadaResult == null) return monastirResult;
    if (monastirResult == null) return sayadaResult;

    // Both routes serve this pair — return whichever departs sooner.
    return _pickEarlierStsResult(sayadaResult, monastirResult);
  }

  /// Returns the result with the earlier departure. Results scheduled for
  /// TOMORROW rank after any same-day result.
  static MetroSahelResult _pickEarlierStsResult(
    MetroSahelResult a,
    MetroSahelResult b,
  ) {
    final aTomorrow = a.noTrainToday;
    final bTomorrow = b.noTrainToday;
    if (aTomorrow && !bTomorrow) return b;
    if (!aTomorrow && bTomorrow) return a;
    return _parseStsDepMinutes(a.departureTime) <=
            _parseStsDepMinutes(b.departureTime)
        ? a
        : b;
  }

  static int _parseStsDepMinutes(String depTime) {
    final s = depTime.replaceAll(RegExp(r'\s*\(\+\d+\)'), '').trim();
    final parts = s.split(':');
    if (parts.length != 2) return 99999;
    final h = int.tryParse(parts[0]) ?? 99;
    final m = int.tryParse(parts[1]) ?? 99;
    return h * 60 + m;
  }

  static int? _extractDepartureMinutes(dynamic rawDepartureTime) {
    if (rawDepartureTime is Timestamp) {
      final dt = rawDepartureTime.toDate();
      return dt.hour * 60 + dt.minute;
    }
    if (rawDepartureTime is DateTime) {
      return rawDepartureTime.hour * 60 + rawDepartureTime.minute;
    }
    if (rawDepartureTime is String) {
      final clean = rawDepartureTime.trim();
      final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(clean);
      if (m == null) return null;
      final h = int.tryParse(m.group(1)!);
      final mm = int.tryParse(m.group(2)!);
      if (h == null || mm == null || h < 0 || h > 23 || mm < 0 || mm > 59) {
        return null;
      }
      return h * 60 + mm;
    }
    if (rawDepartureTime is num) {
      final minutes = rawDepartureTime.toInt();
      if (minutes < 0) return null;
      return minutes % 1440;
    }
    return null;
  }

  // ── Metro Sahel — kept separate due to its unique stop-order lookup ────────
  //
  // Metro Sahel uses RouteRepository.getStopOrder() rather than route_stops
  // offsets, and uses a per-stop duration model (numberOfStops * 4 min).
  // Every other line uses the offset-based model in _findNextOffsetBasedTrip.

  Future<MetroSahelResult?> _findNextMetroSahelTripInternal({
    required String fromStationId,
    required String toStationId,
    required DateTime searchDateTime,
  }) async {
    final routeId = await _routeRepository.findMetroSahelRouteId(
      fromStationId,
      toStationId,
    );
    if (routeId == null) return null;

    final routeMeta = await _getRouteSearchMetadata(routeId);
    final routeIsActive = routeMeta.isSearchActive;
    if (!routeIsActive) return null;
    final routeOperatorId = routeMeta.operatorId;
    // Price should be read from tariffs collection — see ManageTariffsScreen.

    final fromDoc =
        await _firestore.collection('stations').doc(fromStationId).get();
    final toDoc =
        await _firestore.collection('stations').doc(toStationId).get();
    final fromName = fromDoc.data()?['name'] ?? fromStationId;
    final toName = toDoc.data()?['name'] ?? toStationId;

    final fromOrder = await _routeRepository.getStopOrder(fromStationId);
    final toOrder = await _routeRepository.getStopOrder(toStationId);
    if (fromOrder == -1 || toOrder == -1) return null;

    final routeStopsSnap = await _firestore
        .collection('route_stops')
        .where('routeId', isEqualTo: routeId)
        .get();
    int fromOffset = 0;
    int toOffset = 0;
    for (final doc in routeStopsSnap.docs) {
      final data = doc.data();
      final sid = data['stationId'] as String?;
      if (sid == fromStationId) {
        fromOffset = (data['estimatedArrivalTimeMinutes'] ?? 0) as int;
      }
      if (sid == toStationId) {
        toOffset = (data['estimatedArrivalTimeMinutes'] ?? 0) as int;
      }
    }

    final numberOfStops = (toOrder - fromOrder).abs();
    if (numberOfStops == 0) return null;

    final tariffPrice = await _lookupTariffPrice(
      operatorId: routeOperatorId,
      fromStationId: fromStationId,
      toStationId: toStationId,
      referenceDate: searchDateTime,
    );
    final price = tariffPrice ?? Tariff.calculateMetroSahelPrice(numberOfStops);
    final durationMinutes = numberOfStops * 4;
    final routeName = '$fromName → $toName';

    final dayOfWeek = searchDateTime.weekday % 7;
    var tripsSnapshot = await _firestore
        .collection('trips')
        .where('routeId', isEqualTo: routeId)
        .where('daysOfWeek', arrayContains: dayOfWeek)
        .get();

    if (tripsSnapshot.docs.isEmpty) {
      // Legacy seed compatibility: older scripts wrote operatingDays only.
      tripsSnapshot = await _firestore
          .collection('trips')
          .where('routeId', isEqualTo: routeId)
          .where('operatingDays', arrayContains: dayOfWeek)
          .get();
    }

    if (tripsSnapshot.docs.isEmpty) return null;

    final searchMinutes = searchDateTime.hour * 60 + searchDateTime.minute;
    final candidates = <Map<String, dynamic>>[];
    String? firstDepartureOfDay;
    int firstDepartureMinutes = 99999;

    for (final doc in tripsSnapshot.docs) {
      final data = doc.data();
      final originMinutes = _extractDepartureMinutes(data['departureTime']);
      if (originMinutes == null) continue;
      final hasFromOverride = _hasStationOverride(data, fromStationId);
      final hasToOverride = _hasStationOverride(data, toStationId);
      final useExplicitTimes = hasFromOverride && hasToOverride;
      final depAtFrom = useExplicitTimes
          ? _resolveStationMinute(data, fromStationId, originMinutes, fromOffset)
          : originMinutes + fromOffset;
      final arrAtTo = useExplicitTimes
          ? _resolveStationMinute(data, toStationId, originMinutes, toOffset)
          : originMinutes + toOffset;
      final timeStr = _minutesToTime(depAtFrom % 1440);

      if (depAtFrom < firstDepartureMinutes) {
        firstDepartureMinutes = depAtFrom;
        firstDepartureOfDay = timeStr;
      }
      if (depAtFrom >= searchMinutes) {
        candidates.add({
          ...data,
          '_minutes': depAtFrom,
          '_timeStr': timeStr,
          '_arrMinutes': arrAtTo,
        });
      }
    }

    if (candidates.isEmpty) {
      final dep = firstDepartureOfDay ?? '05:48';
      return _assembleResult(
        departureTime: dep,
        arrivalTime: 'TOMORROW',
        tripNumber: 0,
        routeName: routeName,
        fromStationId: fromStationId,
        toStationId: toStationId,
        fromStationName: fromName,
        toStationName: toName,
        durationMinutes: durationMinutes,
        price: price,
        numberOfStops: numberOfStops,
        isActive: routeIsActive,
      );
    }

    candidates.sort(
        (a, b) => (a['_minutes'] as int).compareTo(b['_minutes'] as int));
    final next = candidates.first;
    final dep = next['_timeStr'] as String;
    final depMin = next['_minutes'] as int;
    final rawArr = next['_arrMinutes'] as int;
    final actualDuration = rawArr >= depMin
      ? rawArr - depMin
      : rawArr - depMin + 1440;
    final arrStr =
        '${_minutesToTime(rawArr % 1440)}${rawArr >= 1440 ? ' (+1)' : ''}';

    return _assembleResult(
      departureTime: dep,
      arrivalTime: arrStr,
      tripNumber: _normalizeTripNumberInt(next['tripNumber']),
      routeName: routeName,
      fromStationId: fromStationId,
      toStationId: toStationId,
      fromStationName: fromName,
      toStationName: toName,
      durationMinutes: actualDuration,
      price: price,
      numberOfStops: numberOfStops,
      isActive: routeIsActive,
    );
  }

  // ── Generic offset-based trip finder (shared by all other line types) ─────

  // Temporary fields used only during SNCFT fare resolution (see note below).
  String _sncftFromId = '';
  String _sncftToId = '';

  Future<MetroSahelResult?> _findNextOffsetBasedTrip({
    required String fromStationId,
    required String toStationId,
    required DateTime searchDateTime,
    required _LineConfig config,
  }) async {
    // Capture IDs for the SNCFT fare closure (which needs the original IDs).
    _sncftFromId = fromStationId;
    _sncftToId = toStationId;

    final routeId =
        await config.resolveRouteId(fromStationId, toStationId);
    if (kDebugMode && config.lineType == 'sncft_mainline') {
      debugPrint(
        '[JourneyRepo] sncft_mainline from=$fromStationId to=$toStationId '
        'routeId=$routeId',
      );
    }
    if (routeId == null) return null;

    final routeMeta = await _getRouteSearchMetadata(routeId);
    final routeIsActive = routeMeta.isSearchActive;
    if (!routeIsActive) return null;
    final routeOperatorId = routeMeta.operatorId;
    // Price should be read from tariffs collection — see ManageTariffsScreen.

    // ── 1. Station names ────────────────────────────────────────────────────
    final fromDoc =
        await _firestore.collection('stations').doc(fromStationId).get();
    final toDoc =
        await _firestore.collection('stations').doc(toStationId).get();
    final fromName = (fromDoc.data()?['name'] as String?) ?? fromStationId;
    final toName = (toDoc.data()?['name'] as String?) ?? toStationId;

    // ── 2. Stop offsets & orders ────────────────────────────────────────────
    final routeStopsSnap = await _firestore
        .collection('route_stops')
        .where('routeId', isEqualTo: routeId)
        .get();

    _StopMeta? fromMeta;
    _StopMeta? toMeta;
    final stationOrderMap = <String, int>{}; // used for SNCFT partial-trips

    for (final doc in routeStopsSnap.docs) {
      final data = doc.data();
      final sid = data['stationId'] as String;
      final order = data['stopOrder'] as int;
      stationOrderMap[sid] = order;

      final offset = (data['estimatedArrivalTimeMinutes'] ?? 0) as int;
        final section = _parseIntLike(data['section']) ??
          _sectionFromOrder(order);

      if (sid == fromStationId) {
        fromMeta = _StopMeta(offset: offset, order: order, section: section);
      }
      if (sid == toStationId) {
        toMeta = _StopMeta(offset: offset, order: order, section: section);
      }
    }

    // Also pick up sections from the station docs themselves (Banlieue Sud).
    final fromSection =
      _parseIntLike(fromDoc.data()?['section']) ?? fromMeta?.section ?? 1;
    final toSection =
      _parseIntLike(toDoc.data()?['section']) ?? toMeta?.section ?? 1;
    if (fromMeta != null) {
      fromMeta = _StopMeta(
          offset: fromMeta.offset, order: fromMeta.order, section: fromSection);
    }
    if (toMeta != null) {
      toMeta = _StopMeta(
          offset: toMeta.offset, order: toMeta.order, section: toSection);
    }

    if (kDebugMode && config.lineType == 'sncft_mainline') {
      final fromMetaLabel = fromMeta == null ? 'MISSING' : 'order${fromMeta.order}';
      final toMetaLabel = toMeta == null ? 'MISSING' : 'order${toMeta.order}';
      debugPrint(
        '[JourneyRepo] sncft_mainline stop resolution: '
        'from=$fromStationId meta=$fromMetaLabel '
        'to=$toStationId meta=$toMetaLabel',
      );
    }

    if (fromMeta == null || toMeta == null) return null;

    final numberOfStops = (fromMeta.order - toMeta.order).abs();
    if (numberOfStops == 0) return null;

    final durationMinutes = (fromMeta.offset - toMeta.offset).abs();
    final tariffPrice = await _lookupTariffPrice(
      operatorId: routeOperatorId,
      fromStationId: fromStationId,
      toStationId: toStationId,
      referenceDate: searchDateTime,
    );
    final price = tariffPrice ?? config.calculateFare(fromMeta, toMeta);
    final routeName = '$fromName → $toName';

    // ── 3. Query trips for today's day-of-week ──────────────────────────────
    final dayOfWeek = searchDateTime.weekday % 7;
    var tripsSnapshot = await _firestore
        .collection('trips')
        .where('routeId', isEqualTo: routeId)
        .where('daysOfWeek', arrayContains: dayOfWeek)
        .get();

    if (tripsSnapshot.docs.isEmpty) {
      // Legacy seed compatibility: older scripts wrote operatingDays only.
      tripsSnapshot = await _firestore
          .collection('trips')
          .where('routeId', isEqualTo: routeId)
          .where('operatingDays', arrayContains: dayOfWeek)
          .get();
    }

    if (tripsSnapshot.docs.isEmpty) return null;

    final searchMinutes = searchDateTime.hour * 60 + searchDateTime.minute;
    final candidates = <Map<String, dynamic>>[];
    int firstDepAtFrom = 99999;

    // ── 4. Filter candidates ────────────────────────────────────────────────
    for (final doc in tripsSnapshot.docs) {
      final data = doc.data();
      final originMinutes = _extractDepartureMinutes(data['departureTime']);
      if (originMinutes == null) continue;

      final overrides =
          data['stationTimeOverridesMinutes'] ?? data['stationTimeOverrides'];
      final hasOverridesMap = overrides is Map && overrides.isNotEmpty;
        final hasFromOverride = hasOverridesMap && _hasStationOverride(data, fromStationId);
        final hasToOverride = hasOverridesMap && _hasStationOverride(data, toStationId);
        final useExplicitTimes = hasFromOverride && hasToOverride;
      final hasSkippedList = data['skippedStationIds'] is List;

      if (config.requiresExplicitStopMetadata &&
          !hasOverridesMap &&
          !hasSkippedList) {
        continue;
      }

      if (config.requiresExplicitStopMetadata && hasOverridesMap && !useExplicitTimes) {
        continue;
      }

      // Apply explicit per-trip skipped stations for all train lines.
      final skippedRaw = data['skippedStationIds'];
      if (skippedRaw is List) {
        final skipped = skippedRaw.map((e) => e.toString()).toSet();
        if (skipped.contains(fromStationId) || skipped.contains(toStationId)) {
          continue;
        }
      }

      if (config.supportsPartialTrips) {
        if (overrides is Map && overrides.isNotEmpty) {
          // For partial-trip train lines, if a trip has explicit stop-time
          // overrides, treat them as the source of truth for served stops.
          if (!_hasStationOverride(data, fromStationId) ||
              !_hasStationOverride(data, toStationId)) {
            continue;
          }
        }

        // Skip trips that terminate before destination.
        final terminatesAt =
            (data['terminatesAtStationId'] ?? data['terminatesAt']) as String?;
        if (terminatesAt != null) {
          final terminateOrder = stationOrderMap[terminatesAt];
          if (terminateOrder != null && toMeta.order > terminateOrder) {
            continue;
          }
        }
        // Skip trips whose origin is after our boarding stop.
        final originStId = data['originStationId'] as String?;
        if (originStId != null) {
          final originOrder = stationOrderMap[originStId];
          if (originOrder != null && fromMeta.order < originOrder) continue;
        }
      }

      final actualDep = config.supportsPartialTrips
          ? _resolveStationMinute(data, fromStationId, originMinutes, fromMeta.offset)
          : useExplicitTimes
            ? _resolveStationMinute(
              data, fromStationId, originMinutes, fromMeta.offset)
          : originMinutes + fromMeta.offset;

      if (actualDep < firstDepAtFrom) firstDepAtFrom = actualDep;

      if (actualDep >= searchMinutes) {
        candidates.add({
          ...data,
          '_actualDep': actualDep,
          '_originMin': originMinutes,
          '_useExplicitTimes': useExplicitTimes,
        });
      }
    }

    // ── 5. No trip today → return next-day first departure ─────────────────
    if (candidates.isEmpty) {
      final firstDep = firstDepAtFrom < 99999
          ? _minutesToTime(firstDepAtFrom)
          : config.fallbackFirstDeparture;
      return _assembleResult(
        departureTime: firstDep,
        arrivalTime: 'TOMORROW',
        tripNumber: 0,
        tripNumberStr: config.supportsPartialTrips ? '–' : null,
        routeName: routeName,
        fromStationId: fromStationId,
        toStationId: toStationId,
        fromStationName: fromName,
        toStationName: toName,
        durationMinutes: durationMinutes,
        price: price,
        numberOfStops: numberOfStops,
        operatorName: config.operatorName,
        operatorPhone: config.operatorPhone,
        lineType: config.lineType,
        isActive: routeIsActive,
      );
    }

    // ── 6. Sort and pick the next departure ─────────────────────────────────
    candidates.sort(
        (a, b) => (a['_actualDep'] as int).compareTo(b['_actualDep'] as int));

    final next = candidates.first;
    final actualDep = next['_actualDep'] as int;
    final useExplicitTimes = next['_useExplicitTimes'] == true;

    if (kDebugMode && config.lineType == 'sncft_mainline') {
      debugPrint(
        '[JourneyRepo] Selected trip: tripNumber=${next['tripNumber']} '
        'actualDep=${_minutesToTime(actualDep)} '
        'originStationId=${next['originStationId']} '
        'terminatesAtStationId=${next['terminatesAtStationId']} '
        'hasOverrides=${next['stationTimeOverridesMinutes'] != null}',
      );
    }

    int rawActualArr = 0;
    if (kDebugMode && config.lineType == 'sncft_mainline') {
      debugPrint(
        '[JourneyRepo] BEFORE arrival: supportsPartialTrips=${config.supportsPartialTrips}',
      );
    }
    
    try {
      if (config.supportsPartialTrips || useExplicitTimes) {
        final originMin = next['_originMin'] as int;
        final overrides = next['stationTimeOverridesMinutes'] as Map<String, dynamic>?;
        if (kDebugMode && config.lineType == 'sncft_mainline') {
          debugPrint(
            '[JourneyRepo] Computing arrival for toStationId=$toStationId '
            'originMin=$originMin toMeta.offset=${toMeta.offset} '
            'lookingForKeys=${_overrideStationIdCandidates(toStationId).toList()}',
          );
          if (overrides != null) {
            debugPrint('[JourneyRepo] Available overrides: ${overrides.keys.toList()}');
          } else {
            debugPrint('[JourneyRepo] NO OVERRIDES FOUND in trip data');
          }
        }
        rawActualArr = _resolveStationMinute(
            next, toStationId, originMin, toMeta.offset);
        if (kDebugMode && config.lineType == 'sncft_mainline') {
          debugPrint(
            '[JourneyRepo] Computed arrival: rawMin=$rawActualArr '
            '(${_minutesToTime(rawActualArr % 1440)})',
          );
        }
      } else {
        rawActualArr = actualDep + durationMinutes;
        if (kDebugMode && config.lineType == 'sncft_mainline') {
          debugPrint(
            '[JourneyRepo] Using offset-based arrival: actualDep=$actualDep + durationMinutes=$durationMinutes = $rawActualArr',
          );
        }
      }
    } catch (e, st) {
      if (kDebugMode && config.lineType == 'sncft_mainline') {
        debugPrint('[JourneyRepo] EXCEPTION in arrival computation: $e\n$st');
      }
      rawActualArr = actualDep + durationMinutes;
    }

    final actualArr = rawActualArr % 1440;
    final crossesMidnight = rawActualArr >= 1440;
    final depCrossesMidnight = actualDep >= 1440;
    final actualDuration = (config.supportsPartialTrips || useExplicitTimes)
        ? (rawActualArr >= actualDep
            ? rawActualArr - actualDep
            : rawActualArr - actualDep + 1440)
        : durationMinutes;

    return _assembleResult(
      departureTime:
          '${_minutesToTime(actualDep)}${depCrossesMidnight ? ' (+1)' : ''}',
      arrivalTime:
          '${_minutesToTime(actualArr)}${crossesMidnight ? ' (+1)' : ''}',
      tripNumber: config.supportsPartialTrips
          ? 0
        : _normalizeTripNumberInt(next['tripNumber']),
      tripNumberStr: config.supportsPartialTrips
          ? _normalizeTripNumberStr(next['tripNumber'])
          : null,
      routeName: routeName,
      fromStationId: fromStationId,
      toStationId: toStationId,
      fromStationName: fromName,
      toStationName: toName,
      durationMinutes: actualDuration,
      price: price,
      numberOfStops: numberOfStops,
      operatorName: config.operatorName,
      operatorPhone: config.operatorPhone,
      lineType: config.lineType,
      isActive: routeIsActive,
    );
  }

  // ── Shared result assembler ───────────────────────────────────────────────

  MetroSahelResult _assembleResult({
    required String departureTime,
    required String arrivalTime,
    required int tripNumber,
    String? tripNumberStr,
    required String routeName,
    required String fromStationId,
    required String toStationId,
    required String fromStationName,
    required String toStationName,
    required int durationMinutes,
    required double price,
    required int numberOfStops,
    String operatorName = 'Métro du Sahel - SNCFT',
    String operatorPhone = '+216 73 447 425',
    String lineType = 'metro_sahel',
    bool isActive = true,
  }) {
    return MetroSahelResult(
      tripNumber: tripNumber,
      tripNumberStr: tripNumberStr,
      routeName: routeName,
      fromStationId: fromStationId,
      toStationId: toStationId,
      fromStationName: fromStationName,
      toStationName: toStationName,
      departureTime: departureTime,
      arrivalTime: arrivalTime,
      durationMinutes: durationMinutes,
      price: price,
      numberOfStops: numberOfStops,
      operatorName: operatorName,
      operatorPhone: operatorPhone,
      lineType: lineType,
      isActive: isActive,
    );
  }

  // ── SNCFT per-station time override ──────────────────────────────────────

  /// Returns the per-station scheduled minute if an override exists in the
  /// trip document, otherwise falls back to originMinutes + routeOffset.
  static int _resolveStationMinute(
    Map<String, dynamic> tripData,
    String stationId,
    int originMinutes,
    int routeOffset,
  ) {
    final overrides =
        tripData['stationTimeOverridesMinutes'] ?? tripData['stationTimeOverrides'];
    if (overrides is Map) {
      for (final candidate in _overrideStationIdCandidates(stationId)) {
        final raw = overrides[candidate];
        if (raw is int) {
          if (kDebugMode) {
            debugPrint(
              '[JourneyRepo._resolveStationMinute] Found override for $candidate: $raw min',
            );
          }
          return raw;
        }
        if (raw is num) {
          if (kDebugMode) {
            debugPrint(
              '[JourneyRepo._resolveStationMinute] Found override (num) for $candidate: ${raw.toInt()} min',
            );
          }
          return raw.toInt();
        }
        if (raw is String) {
          final parts = raw.split(':');
          if (parts.length == 2) {
            final hh = int.tryParse(parts[0]);
            final mm = int.tryParse(parts[1]);
            if (hh != null && mm != null) {
              final result = hh * 60 + mm;
              if (kDebugMode) {
                debugPrint(
                  '[JourneyRepo._resolveStationMinute] Parsed override string for $candidate: $raw → $result min',
                );
              }
              return result;
            }
          }
        }
      }
      if (kDebugMode) {
        debugPrint(
          '[JourneyRepo._resolveStationMinute] No override found for candidates '
          '${_overrideStationIdCandidates(stationId).toList()}; using offset fallback',
        );
      }
    }
    return originMinutes + routeOffset;
  }

  /// Returns true when a trip has an explicit timetable entry for stationId.
  static bool _hasStationOverride(Map<String, dynamic> tripData, String stationId) {
    final overrides =
        tripData['stationTimeOverridesMinutes'] ?? tripData['stationTimeOverrides'];
    if (overrides is! Map) return false;
    for (final candidate in _overrideStationIdCandidates(stationId)) {
      final raw = overrides[candidate];
      if (raw is int || raw is num) return true;
      if (raw is String) {
        final parts = raw.split(':');
        if (parts.length == 2 &&
            int.tryParse(parts[0]) != null &&
            int.tryParse(parts[1]) != null) {
          return true;
        }
      }
    }
    return false;
  }

  /// Returns alias candidates used when looking up per-station overrides.
  /// This avoids fallback-to-offset when the UI picks a synonymous station ID.
  static Iterable<String> _overrideStationIdCandidates(String stationId) {
    switch (stationId) {
      case 'sncft_tunis_barcelone':
      case 'sncft_tunis':
      case 'bn_tunis':
      case 'bs_tunis_ville':
      case 'tunis':
        return const [
          'sncft_tunis_barcelone',
          'sncft_tunis',
          'bn_tunis',
          'bs_tunis_ville',
          'tunis',
        ];
      case 'ms_sfax':
      case 'sncft_sfax':
        return const ['sncft_sfax', 'ms_sfax'];
      case 'ms_gabes':
      case 'sncft_gabes':
        return const ['sncft_gabes', 'ms_gabes'];
      default:
        return [stationId];
    }
  }

  // ── Time utilities ────────────────────────────────────────────────────────

  /// Normalises a raw Firestore tripNumber value (for partial-trip lines like
  /// STS) into a display string. Returns '–' for null, 0, "0", or empty.
  static String _normalizeTripNumberStr(dynamic raw) {
    if (raw == null) return '–';
    final s = raw.toString().trim();
    if (s.isEmpty || s == '0') return '–';
    return s;
  }

  static int _normalizeTripNumberInt(dynamic raw) {
    if (raw == null) return 0;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    final s = raw.toString().trim();
    if (s.isEmpty) return 0;
    return int.tryParse(s) ?? 0;
  }

  static int? _parseIntLike(dynamic raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) {
      final s = raw.trim();
      if (s.isEmpty) return null;
      return int.tryParse(s);
    }
    return null;
  }

  int _parseMinutes(String timeStr) {
    final parts = timeStr.split(':');
    if (parts.length != 2) return 0;
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }

  static String _minutesToTime(int minutes) {
    final m = minutes % 1440;
    return '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
  }

  // ── Fare calculators ──────────────────────────────────────────────────────

  /// Banlieue Sud: section-based fare.
  static double _bsFare(int sections) {
    if (sections <= 2) return 0.500;
    if (sections <= 4) return 1.000;
    if (sections <= 6) return 1.450;
    return 1.900;
  }

  /// Banlieue de Nabeul: stop-count-based fare.
  static double _bnFare(int numberOfStops) {
    if (numberOfStops <= 2) return 1.500;
    if (numberOfStops <= 4) return 2.500;
    if (numberOfStops <= 6) return 4.000;
    return 5.500;
  }

  /// Fallback section from stop order when the station doc has no section field.
  static int _sectionFromOrder(int order) {
    if (order <= 3) return 1;
    if (order <= 6) return 2;
    if (order <= 9) return 3;
    if (order <= 12) return 4;
    if (order <= 14) return 5;
    if (order <= 16) return 6;
    if (order <= 18) return 7;
    return 8;
  }



  /// STS Sahel: stop-count-based fare (Sousse ↔ Mahdia intercity bus).
  static double _stsSahelFare(int numberOfStops) {
    if (numberOfStops <= 2) return 1.500;
    if (numberOfStops <= 4) return 2.000;
    if (numberOfStops <= 8) return 3.000;
    return 4.500;
  }

  /// SNCFT: known pair lookup with distance-band fallback.
  static double _sncftL5Fare(String fromId, String toId) {
    const fares = {
      'bs_tunis_ville|sncft_sfax': 20.000,
      'sncft_sfax|bs_tunis_ville': 20.000,
      'bs_tunis_ville|sncft_metlaoui': 10.000,
      'sncft_metlaoui|bs_tunis_ville': 10.000,
      'bs_tunis_ville|sncft_tozeur': 25.000,
      'sncft_tozeur|bs_tunis_ville': 25.000,
      'bs_tunis_ville|sncft_sousse_voyageurs': 9.000,
      'sncft_sousse_voyageurs|bs_tunis_ville': 9.000,
      'bs_tunis_ville|sncft_gabes': 18.000,
      'sncft_gabes|bs_tunis_ville': 18.000,
      'bs_tunis_ville|sncft_gafsa': 22.000,
      'sncft_gafsa|bs_tunis_ville': 22.000,
      'sncft_sfax|sncft_gabes': 7.000,
      'sncft_gabes|sncft_sfax': 7.000,
      'sncft_sfax|sncft_tozeur': 15.000,
      'sncft_tozeur|sncft_sfax': 15.000,
      'sncft_sousse_voyageurs|sncft_sfax': 12.000,
      'sncft_sfax|sncft_sousse_voyageurs': 12.000,
      // Grandes Lignes – Annaba
      'bs_tunis_ville|sncft_beja': 5.600,
      'sncft_beja|bs_tunis_ville': 5.600,
      'bs_tunis_ville|sncft_jendouba': 8.200,
      'sncft_jendouba|bs_tunis_ville': 8.200,
      'bs_tunis_ville|sncft_ghardimaou': 9.800,
      'sncft_ghardimaou|bs_tunis_ville': 9.800,
      'bs_tunis_ville|sncft_souk_ahras': 15.000,
      'sncft_souk_ahras|bs_tunis_ville': 15.000,
      // International route (2nd class, one-way): Tunis <-> Annaba.
      'bs_tunis_ville|sncft_annaba': 38.000,
      'sncft_annaba|bs_tunis_ville': 38.000,
      'sncft_beja|sncft_jendouba': 3.500,
      'sncft_jendouba|sncft_beja': 3.500,
      'sncft_beja|sncft_ghardimaou': 5.000,
      'sncft_ghardimaou|sncft_beja': 5.000,
      'sncft_jendouba|sncft_ghardimaou': 2.500,
      'sncft_ghardimaou|sncft_jendouba': 2.500,
      // Grandes Lignes – Bizerte
      'bs_tunis_ville|sncft_mateur': 4.500,
      'sncft_mateur|bs_tunis_ville': 4.500,
      'bs_tunis_ville|sncft_bizerte': 6.800,
      'sncft_bizerte|bs_tunis_ville': 6.800,
      // SNCFT Kef / Kalaa Khasba (approx. 2nd class)
      'bs_tunis_ville|sncft_kef_gaafour': 6.500,
      'sncft_kef_gaafour|bs_tunis_ville': 6.500,
      'bs_tunis_ville|sncft_kef_dahmani': 9.000,
      'sncft_kef_dahmani|bs_tunis_ville': 9.000,
      'bs_tunis_ville|sncft_kef_le_kef': 10.200,
      'sncft_kef_le_kef|bs_tunis_ville': 10.200,
      'bs_tunis_ville|sncft_kef_kalaa_khasba': 11.500,
      'sncft_kef_kalaa_khasba|bs_tunis_ville': 11.500,
      'sncft_kef_gaafour|sncft_kef_le_kef': 6.000,
      'sncft_kef_le_kef|sncft_kef_gaafour': 6.000,
      'sncft_kef_dahmani|sncft_kef_le_kef': 3.000,
      'sncft_kef_le_kef|sncft_kef_dahmani': 3.000,
    };
    return fares['$fromId|$toId'] ?? 5.000;
  }
}
