import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'journey_search_state.dart';
import '../models/bus_service_model.dart';
import '../models/metro_sahel_result.dart';
import '../services/station_repository.dart';
import '../services/route_repository.dart';
import '../services/journey_repository.dart';
import '../services/bus_service_repository.dart';
import '../services/taxi_collectif_service.dart';

class JourneySearchController extends ChangeNotifier {
  final StationRepository _stationRepository;
  final JourneyRepository _journeyRepository;
  final BusServiceRepository _busServiceRepository;
  final TaxiCollectifService _taxiCollectifService;

  JourneySearchState _state = const JourneySearchState();
  JourneySearchState get state => _state;

  JourneySearchController({
    StationRepository? stationRepository,
    JourneyRepository? journeyRepository,
    BusServiceRepository? busServiceRepository,
    TaxiCollectifService? taxiCollectifService,
  })  : _stationRepository = stationRepository ??
            StationRepository(FirebaseFirestore.instance),
        _journeyRepository = journeyRepository ??
            JourneyRepository(
              FirebaseFirestore.instance,
              RouteRepository(FirebaseFirestore.instance),
            ),
        _busServiceRepository =
            busServiceRepository ?? BusServiceRepository(),
        _taxiCollectifService =
            taxiCollectifService ?? TaxiCollectifService(FirebaseFirestore.instance);

  static const Set<String> _bnCanonicalStationIds = {
    'bn_tunis',
    'bn_borj_cedria',
    'bn_foundouk_jedid',
    'bn_khanguet',
    'bn_grombalia',
    'bn_turki',
    'bn_belli',
    'bn_bou_arkoub',
    'bn_bir_bou_regba',
    'bn_hammamet',
    'bn_omar_khayem',
    'bn_mrazga',
    'bn_nabeul',
  };

  static const Map<String, String> _bnLegacyIdMap = {
    'sncft_bir_bou_regba': 'bn_bir_bou_regba',
    'bs_bir_el_bey': 'bn_bir_bou_regba',
    'bs_boukornine': 'bn_grombalia',
    'bs_hammam_lif': 'bn_hammamet',
    'bs_hammam_echatt': 'bn_hammamet',
    'bs_ezzahra': 'bn_grombalia',
    'bs_tunis_ville': 'bn_tunis',
  };

  static const Set<String> _bnDeprecatedStationIds = {
    'sncft_grombalia',
  };

  /// Maps a metro/STS station ID to its SNCFT mainline equivalent for cities
  /// served by both networks, so picking one "Sousse" covers all modes.
  static const Map<String, String> _sncftMainlineAlias = {
    'ms_sousse_bab_jedid': 'sncft_sousse_voyageurs',
  };

  /// Remaps redundant STS-only station IDs to their canonical metro hub IDs.
  /// The STS Sahel and Métro du Sahel share the same physical stations; some
  /// Firestore seeds created `sts_*` documents that only list `sts_sahel` as
  /// operator.  By remapping early we ensure both the metro and STS branches
  /// resolve against the fully-populated `ms_*` station document.
  static const Map<String, String> _stsToMetroHubMap = {
    'sts_sousse':   'ms_sousse_bab_jedid',
    'sts_monastir': 'ms_monastir',
    'sts_mahdia':   'ms_mahdia',
    'sts_bekalta':  'ms_bekalta',
    'sts_moknine':  'ms_moknine',
    'sts_ksar_hellal': 'ms_ksar_hellal',
    'sts_jem':      'ms_el_jem',
    'sts_sahline':  'ms_sahline',
  };

  /// Emits a new state and notifies listeners in one call.
  void _emit(JourneySearchState newState) {
    _state = newState;
    notifyListeners();
  }

  bool _isBnStationSet(String fromStationId, String toStationId) {
    return _bnCanonicalStationIds.contains(fromStationId) &&
        _bnCanonicalStationIds.contains(toStationId);
  }

  /// Maps a legacy station ID to its canonical BN equivalent, if any.
  String _normalizeBnLegacyStationId(String stationId) {
    return _bnLegacyIdMap[stationId] ?? stationId;
  }

  /// Remaps redundant STS-only station IDs to their canonical metro hub.
  String _normalizeStsToMetroHub(String stationId) {
    return _stsToMetroHubMap[stationId] ?? stationId;
  }

  /// Remaps bn_tunis → bs_tunis_ville when the other station is a Banlieue Sud
  /// station (bs_ prefix), so the correct shared-hub ID is used.
  String _normalizeSharedTunisForBanlieueSud(
    String stationId,
    String otherStationId,
  ) {
    if (stationId == 'bn_tunis' && otherStationId.startsWith('bs_')) {
      return 'bs_tunis_ville';
    }
    return stationId;
  }

  Future<void> search({
    required String fromStationId,
    required String toStationId,
  }) async {
    // Reject deprecated station IDs immediately with a clear message.
    if (_bnDeprecatedStationIds.contains(fromStationId) ||
        _bnDeprecatedStationIds.contains(toStationId)) {
      _emit(_state.copyWith(
        isLoading: false,
        clearTrainResults: true,
        error:
            'Station BN ancienne détectée. Veuillez re-sélectionner les stations depuis la recherche (ex: Bir El Bey, Bou Kornine, Hammam Chott).',
      ));
      return;
    }

    // Step 1 — map legacy IDs to canonical BN IDs, independently for each.
    final rawFromNormalized = _normalizeBnLegacyStationId(fromStationId);
    final rawToNormalized = _normalizeBnLegacyStationId(toStationId);

    // Step 1b — remap redundant sts_* duplicates to their ms_* metro hub.
    final bnFromNormalized = _normalizeStsToMetroHub(rawFromNormalized);
    final bnToNormalized = _normalizeStsToMetroHub(rawToNormalized);

    // Step 2 — remap bn_tunis → bs_tunis_ville when paired with a bs_ station.
    // Both calls use the raw-normalized values (symmetric, no ordering dependency).
    final normalizedFromStationId = _normalizeSharedTunisForBanlieueSud(
      bnFromNormalized,
      bnToNormalized,
    );
    final normalizedToStationId = _normalizeSharedTunisForBanlieueSud(
      bnToNormalized,
      bnFromNormalized,
    );

    if (kDebugMode) {
      debugPrint(
        '[JourneySearch] start from=$fromStationId to=$toStationId '
        'normalizedFrom=$normalizedFromStationId normalizedTo=$normalizedToStationId',
      );
    }

    _emit(_state.copyWith(
      isLoading: true,
      clearTrainResults: true,
      clearError: true,
      clearBus: true,
      clearBestBus: true,
      clearTaxi: true,
    ));

    try {
      // Parallel Firestore reads — both station lookups run concurrently.
      final results = await Future.wait([
        _stationRepository.getStationById(normalizedFromStationId),
        _stationRepository.getStationById(normalizedToStationId),
      ]);
      final fromStation = results[0];
      final toStation = results[1];

      if (fromStation == null || toStation == null) {
        _emit(_state.copyWith(isLoading: false, error: 'Station introuvable.'));
        return;
      }

      if (kDebugMode) {
        debugPrint(
          '[JourneySearch] resolved from=${fromStation.id} to=${toStation.id}',
        );
        debugPrint(
          '[JourneySearch] from.operatorsHere=${fromStation.operatorsHere} '
          'to.operatorsHere=${toStation.operatorsHere}',
        );
        debugPrint(
          '[JourneySearch] isMetro(from)=${_stationRepository.isMetroSahelStation(fromStation)} '
          'isMetro(to)=${_stationRepository.isMetroSahelStation(toStation)} '
          'isSts(from)=${_stationRepository.isStsSahelStation(fromStation)} '
          'isSts(to)=${_stationRepository.isStsSahelStation(toStation)}',
        );
      }

      // Capture search time once so all branches use the same reference time.
      final searchDateTime = DateTime.now();

      // ═══════════════════════════════════════════════════════════════════════
      // All branches run — results are collected and emitted together so the
      // UI can show every available transport mode for this A→B pair.
      // Banlieue Nabeul is still checked first and gates Banlieue Sud to avoid
      // duplicates for their overlapping physical station set.
      // ═══════════════════════════════════════════════════════════════════════

      final List<MetroSahelResult> collectedTrainResults = [];

      // Banlieue Nabeul — priority; if it matches, skip Banlieue Sud.
      bool bnMatched = false;
      if (_isBnStationSet(fromStation.id, toStation.id)) {
        if (kDebugMode) {
          debugPrint('[JourneySearch] branch=banlieue_nabeul (priority)');
        }
        final bnResult = await _journeyRepository.findNextBanlieueNabeulTrip(
          fromStationId: fromStation.id,
          toStationId: toStation.id,
          searchDateTime: searchDateTime,
        );
        if (bnResult != null) {
          collectedTrainResults.add(bnResult);
          bnMatched = true;
        }
      }

      // Métro du Sahel.
      if (_stationRepository.isMetroSahelStation(fromStation) &&
          _stationRepository.isMetroSahelStation(toStation)) {
        if (kDebugMode) debugPrint('[JourneySearch] branch=metro_sahel firing');
        final metroResult = await _journeyRepository.findNextMetroSahelTrip(
          fromStationId: fromStation.id,
          toStationId: toStation.id,
          searchDateTime: searchDateTime,
        );
        if (kDebugMode) debugPrint('[JourneySearch] metro_sahel result=$metroResult');
        if (metroResult != null) collectedTrainResults.add(metroResult);
      }

      // Banlieue Sud — skipped when Banlieue Nabeul already matched to avoid
      // duplicate results for their shared station set.
      if (!bnMatched &&
          _stationRepository.isBanlieueSudStation(fromStation) &&
          _stationRepository.isBanlieueSudStation(toStation)) {
        final bsResult = await _journeyRepository.findNextBanlieueSudTrip(
          fromStationId: fromStation.id,
          toStationId: toStation.id,
          searchDateTime: searchDateTime,
        );
        if (bsResult != null) collectedTrainResults.add(bsResult);
      }

      // Banlieue Ligne D.
      if (_stationRepository.isBanlieueDStation(fromStation) &&
          _stationRepository.isBanlieueDStation(toStation)) {
        final bdResult = await _journeyRepository.findNextBanlieueDTrip(
          fromStationId: fromStation.id,
          toStationId: toStation.id,
          searchDateTime: searchDateTime,
        );
        if (bdResult != null) collectedTrainResults.add(bdResult);
      }

      // Banlieue Ligne E.
      if (_stationRepository.isBanlieueEStation(fromStation) &&
          _stationRepository.isBanlieueEStation(toStation)) {
        final beResult = await _journeyRepository.findNextBanlieueETrip(
          fromStationId: fromStation.id,
          toStationId: toStation.id,
          searchDateTime: searchDateTime,
        );
        if (beResult != null) collectedTrainResults.add(beResult);
      }

      // SNCFT Grandes Lignes (L5, Kef, Bizerte, Annaba…).
      // If either station is a cross-network hub (e.g. ms_sousse_bab_jedid),
      // resolve its SNCFT mainline equivalent before running the branch.
      {
        final sncftFromId = _sncftMainlineAlias[fromStation.id] ?? fromStation.id;
        final sncftToId   = _sncftMainlineAlias[toStation.id]   ?? toStation.id;
        if ((_stationRepository.isSncftMainlineStation(fromStation) ||
                _sncftMainlineAlias.containsKey(fromStation.id)) &&
            (_stationRepository.isSncftMainlineStation(toStation) ||
                _sncftMainlineAlias.containsKey(toStation.id))) {
          final sncftResult = await _journeyRepository.findNextSncftL5Trip(
            fromStationId: sncftFromId,
            toStationId: sncftToId,
            searchDateTime: searchDateTime,
          );
          if (sncftResult != null) collectedTrainResults.add(sncftResult);
        }
      }

      // STS Sahel intercity bus (Sousse ↔ Mahdia via Sahel corridor).
      if (_stationRepository.isStsSahelStation(fromStation) &&
          _stationRepository.isStsSahelStation(toStation)) {
        if (kDebugMode) {
          debugPrint('[JourneySearch] branch=sts_sahel');
        }
        final stsResult = await _journeyRepository.findNextStsSahelTrip(
          fromStationId: fromStation.id,
          toStationId: toStation.id,
          searchDateTime: searchDateTime,
        );
        if (stsResult != null) collectedTrainResults.add(stsResult);
      }

      // ─── TRANSTU bus — departure must be a TRANSTU hub. ──────────────────
      BusService? bestBusService;
      String? bestBusDepartureTime;
      String? busHubName;
      String? busError;

      if (_stationRepository.isTranstuStation(fromStation)) {
        if (kDebugMode) {
          debugPrint('[JourneySearch] branch=transtu hub=${fromStation.id}');
        }

        final busServices =
            await _busServiceRepository.findServicesConnectingStations(
          fromStationId: fromStation.id,
          toStationId: toStation.id,
        );

        if (busServices.isNotEmpty) {
          int bestMinutes = -1;

          // Detect reverse direction (dest→hub or hub→hub where services run
          // the other way).
          final isReverse = _busServiceRepository.isTranstuHub(toStation.id) &&
              (!_busServiceRepository.isTranstuHub(fromStation.id) ||
                  busServices.any((s) => s.destinationStationId == fromStation.id));

          for (final svc in busServices) {
            final nextDep = isReverse
                ? svc.nextDepartureFromSuburb(now: searchDateTime)
                : svc.nextDepartureFromHub(now: searchDateTime);
            if (nextDep == null) continue;

            final parts = nextDep.split(':');
            if (parts.length != 2) continue;
            final h = int.tryParse(parts[0]);
            final m = int.tryParse(parts[1]);
            if (h == null || m == null) {
              if (kDebugMode) {
                debugPrint(
                  '[JourneySearch] Invalid time format: $nextDep '
                  'for service ${svc.id}',
                );
              }
              continue;
            }

            final depMins = h * 60 + m;
            if (bestBusService == null || depMins < bestMinutes) {
              bestMinutes = depMins;
              bestBusService = svc;
              bestBusDepartureTime = nextDep;
            }
          }

          if (bestBusService == null) {
            // All services ended for today — pick the earliest for tomorrow.
            final sorted = List<BusService>.from(busServices)
              ..sort((BusService a, BusService b) =>
                  (a.parseTimePublic(isReverse
                              ? a.firstDepartureFromSuburb
                              : a.firstDepartureFromHub) ??
                          9999)
                      .compareTo(b.parseTimePublic(isReverse
                              ? b.firstDepartureFromSuburb
                              : b.firstDepartureFromHub) ??
                          9999));
            bestBusService = sorted.first;
            bestBusDepartureTime = isReverse
                ? sorted.first.firstDepartureFromSuburb
                : sorted.first.firstDepartureFromHub;
            busError = 'Service terminé pour ce soir. Prochain départ demain.';
          }

          busHubName =
              '${fromStation.localizedName('fr')} → ${toStation.localizedName('fr')}';
        } else if (collectedTrainResults.isEmpty) {
          // Hub found but no connecting lines — only surface error when there
          // are no train results either.
          if (kDebugMode) {
            debugPrint(
              '[JourneySearch] No connecting lines found from '
              '${fromStation.name} to ${toStation.name}',
            );
          }
          busError =
              'Aucune ligne ne relie ${fromStation.name} à ${toStation.name}.';
        }
      }

      // ─── Taxi collectif — runs for every search, independent of other modes ─
      // Use cityId (e.g. "sousse", "monastir") which already matches the seed
      // script's normalization, rather than the full station name which may
      // contain suffixes like " - Bab Jedid" that break the lookup.
      final taxiResult = await _taxiCollectifService.findRoute(
        fromCityId: fromStation.cityId,
        toCityId: toStation.cityId,
      );

      // ─── Emit combined results ────────────────────────────────────────────
      if (collectedTrainResults.isEmpty &&
          bestBusService == null &&
          taxiResult == null) {
        if (kDebugMode) {
          debugPrint(
            '[JourneySearch] no branch matched for from=$fromStationId '
            'to=$toStationId normalizedFrom=$normalizedFromStationId '
            'normalizedTo=$normalizedToStationId',
          );
        }
        _emit(_state.copyWith(
          isLoading: false,
          clearTrainResults: true,
          clearTaxi: true,
          error: busError ?? 'Ces stations n\'appartiennent pas à la même ligne.',
        ));
      } else {
        _emit(_state.copyWith(
          isLoading: false,
          trainResults: collectedTrainResults,
          bestBusService: bestBusService,
          bestBusDepartureTime: bestBusDepartureTime,
          busHubName: busHubName,
          error: busError,
          taxiCollectifResult: taxiResult,
          clearTaxi: taxiResult == null,
        ));
      }
    } catch (e) {
      // Map exceptions to user-friendly French messages.
      // Raw exception text is only visible in debug logs, never shown in the UI.
      final userMessage = switch (e) {
        final FirebaseException e => switch (e.code) {
            'unavailable' || 'network-request-failed' || 'failed' =>
              'Connexion impossible. Vérifiez votre connexion réseau.',
            'permission-denied' =>
              'Accès non autorisé. Veuillez réessayer plus tard.',
            'not-found' => 'Données introuvables. Veuillez réessayer.',
            _ => 'Une erreur est survenue. Veuillez réessayer.',
          },
        _ => 'Une erreur inattendue est survenue. Veuillez réessayer.',
      };

      if (kDebugMode) debugPrint('[JourneySearch] error=$e');
      _emit(_state.copyWith(isLoading: false, error: userMessage));
    }
  }
}