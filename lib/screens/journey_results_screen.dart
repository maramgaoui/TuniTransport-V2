import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tuni_transport/l10n/app_localizations.dart';
import '../controllers/journey_search_controller.dart';
import '../controllers/journey_search_state.dart';
import '../models/bus_service_model.dart';
import '../models/journey_model.dart';
import '../models/journey_recommendation.dart';
import '../models/metro_sahel_result.dart';
import '../models/taxi_collectif_result.dart';
import '../services/recommendation_service.dart';
import '../services/user_preference_service.dart';
import '../widgets/app_header.dart';
import '../widgets/metro_sahel_card.dart';
import '../widgets/taxi_collectif_card.dart';

class JourneyResultsScreen extends StatefulWidget {
  final String departure;
  final String arrival;
  final String? fromStationId;
  final String? toStationId;
  final bool preloadFavorites;

  const JourneyResultsScreen({
    super.key,
    required this.departure,
    required this.arrival,
    this.fromStationId,
    this.toStationId,
    this.preloadFavorites = true,
  });

  @override
  State<JourneyResultsScreen> createState() => _JourneyResultsScreenState();
}

class _JourneyResultsScreenState extends State<JourneyResultsScreen> {
  final JourneySearchController _searchController = JourneySearchController();
  final RecommendationService   _recommendationService = RecommendationService();

  UserProfile _profile = UserProfile.balanced;
  JourneyRecommendation? _recommendation;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    if (widget.fromStationId != null && widget.toStationId != null) {
      _searchController.search(
        fromStationId: widget.fromStationId!,
        toStationId:   widget.toStationId!,
      );
    }
    _searchController.addListener(_onSearchStateChanged);
  }

  Future<void> _loadProfile() async {
    final p = await UserPreferenceService.instance.getProfile();
    if (mounted) setState(() => _profile = p);
  }

  void _onSearchStateChanged() {
    if (!mounted) return;
    setState(() {
      // Mirror the controller's recommendation only if we haven't overridden locally.
      _recommendation ??= _searchController.state.recommendation;
      if (_searchController.state.recommendation != null) {
        _recommendation = _searchController.state.recommendation;
      }
    });
  }

  Future<void> _changeProfile(UserProfile newProfile) async {
    setState(() => _profile = newProfile);
    await UserPreferenceService.instance.setProfile(newProfile);
    _rerunRecommendation(newProfile);
  }

  Future<void> _rerunRecommendation(UserProfile profile) async {
    final s = _searchController.state;
    if (!s.hasResult) return;
    final rec = await _recommendationService.recommend(
      trainResults:  s.trainResults,
      busService:    s.bestBusService,
      taxiResult:    s.taxiCollectifResult,
      fromStationId: widget.fromStationId ?? '',
      toStationId:   widget.toStationId   ?? '',
      profile:       profile,
    );
    if (mounted) setState(() => _recommendation = rec);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchStateChanged);
    _searchController.dispose();
    super.dispose();
  }

  Journey _busServiceToJourney(
    BusService service, {
    String? hubName,
    String? nextDeparture,
    bool isReverseDirection = false,
  }) {
    final parts = (hubName ?? '').split(' → ');
    return Journey(
      id: service.id,
      departureStation: parts.isNotEmpty ? parts.first : (service.hubStationId ?? ''),
      arrivalStation: parts.length > 1
          ? parts.last
          : (service.destinationNameFr ?? service.directionAr),
      departureTime: nextDeparture ??
          (isReverseDirection
              ? service.firstDepartureFromSuburb
              : service.firstDepartureFromHub) ??
          '--:--',
      arrivalTime: isReverseDirection
          ? service.lastDepartureFromSuburb
          : service.lastDepartureFromHub,
      price:    (service.price ?? 0.5).toStringAsFixed(3),
      type:     'Bus TRANSTU',
      iconKey:  'bus',
      duration: service.peakFrequencyMinutes != null
          ? 'Fréquence: ${service.peakFrequencyMinutes} min'
          : '',
      transfers: 0,
      isOptimal: true,
      operator:  'TRANSTU',
      line:      'Ligne ${service.lineNumber}',
      estimatedTripDurationMinutes:  service.estimatedTripDurationMinutes,
      timetableFirstDepartureTime: isReverseDirection
          ? service.firstDepartureFromSuburb
          : service.firstDepartureFromHub,
      timetableLastDepartureTime: isReverseDirection
          ? service.lastDepartureFromSuburb
          : service.lastDepartureFromHub,
    );
  }

  // ── Which transport type won? ─────────────────────────────────────────────

  bool _isRecommended(String transportType) =>
      _recommendation?.winnerTransportType == transportType;

  bool _isTrainRecommended(String lineType) {
    final rec = _recommendation;
    if (rec == null) return false;
    return RecommendationService.lineTypeToTransportType(lineType) ==
        rec.winnerTransportType;
  }

  // ── Build a flat sorted list of all available result cards ────────────────

  List<_ResultEntry> _buildSortedEntries(JourneySearchState state) {
    final entries = <_ResultEntry>[];

    for (final result in state.trainResults) {
      final ttype = RecommendationService.lineTypeToTransportType(result.lineType);
      entries.add(_ResultEntry(
        label:        result.lineType == 'sts_sahel'
            ? 'Bus ${result.operatorName}'
            : result.operatorName,
        transportKey: ttype,
        price:        result.price.toDouble(),
        durationMin:  result.durationMinutes.toDouble(),
        score:        _recommendation?.allScores[ttype] ?? 0,
        card:         MetroSahelCard(result: result),
        onTap:        () => context.push('/home/journey-details', extra: result),
      ));
    }

    if (state.bestBusService != null) {
      final bus = state.bestBusService!;
      entries.add(_ResultEntry(
        label:        'Bus TRANSTU',
        transportKey: 'transtu_bus',
        price:        (bus.price ?? 0.8).toDouble(),
        durationMin:  (bus.estimatedTripDurationMinutes ?? 35).toDouble(),
        score:        _recommendation?.allScores['transtu_bus'] ?? 0,
        card: _BestBusCard(
          service:       bus,
          nextDeparture: state.bestBusDepartureTime,
          routeLabel:    state.busHubName ?? '',
        ),
        onTap: () {
          final journey = _busServiceToJourney(
            bus,
            hubName:            state.busHubName,
            nextDeparture:      state.bestBusDepartureTime,
            isReverseDirection: state.busIsReverse,
          );
          context.push('/home/journey-details', extra: journey);
        },
      ));
    }

    if (state.taxiCollectifResult != null) {
      final taxi = state.taxiCollectifResult!;
      entries.add(_ResultEntry(
        label:        'Taxi Collectif',
        transportKey: 'taxi_collectif',
        price:        taxi.fare,
        durationMin:  taxi.durationMinutes.toDouble(),
        score:        _recommendation?.allScores['taxi_collectif'] ?? 0,
        card:         TaxiCollectifCard(result: taxi),
        onTap:        () => context.push('/home/journey-details', extra: taxi),
      ));
    }

    switch (_profile) {
      case UserProfile.price:
        entries.sort((a, b) => a.price.compareTo(b.price));
      case UserProfile.speed:
        entries.sort((a, b) => a.durationMin.compareTo(b.durationMin));
      case UserProfile.balanced:
        if (_recommendation != null) {
          entries.sort((a, b) => b.score.compareTo(a.score));
        } else {
          entries.sort((a, b) => a.price.compareTo(b.price));
        }
    }

    return entries;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final state       = _searchController.state;
    final trainResults = state.trainResults;
    final busHubName  = state.busHubName;
    final bestBus     = state.bestBusService;
    final bestTime    = state.bestBusDepartureTime;
    final taxiResult  = state.taxiCollectifResult;
    final isLoading   = state.isLoading;
    final error       = state.error;
    final hasAnyResult = trainResults.isNotEmpty || bestBus != null || taxiResult != null;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              title: AppLocalizations.of(context)!.results,
              subtitle: '${widget.departure} → ${widget.arrival}',
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go('/home/journey-input');
                  }
                },
              ),
            ),
            Expanded(
              child: isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : !hasAnyResult
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              error ?? 'Aucun trajet trouvé pour cette recherche.',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 15, color: Colors.grey[600]),
                            ),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                          children: [

                            // ── Profile selector ──────────────────────────────
                            _ProfileSelector(
                              current: _profile,
                              onChanged: _changeProfile,
                            ),
                            const SizedBox(height: 16),

                            // ── Recommendation banner ─────────────────────────
                            if (_recommendation != null)
                              _RecommendationBanner(rec: _recommendation!),
                            if (_recommendation != null) const SizedBox(height: 16),

                            // ── Train / metro results ─────────────────────────
                            for (final result in trainResults) ...[
                              _sectionLabel(
                                result.lineType == 'sts_sahel'
                                    ? 'Bus ${result.operatorName}'
                                    : result.operatorName,
                              ),
                              const SizedBox(height: 8),
                              _CardWrapper(
                                isRecommended: _isTrainRecommended(result.lineType),
                                onTap: () => context.push(
                                  '/home/journey-details',
                                  extra: result,
                                ),
                                child: MetroSahelCard(result: result),
                              ),
                              const SizedBox(height: 16),
                            ],

                            // ── TRANSTU Bus ───────────────────────────────────
                            if (bestBus != null) ...[
                              _sectionLabel('Bus TRANSTU'),
                              const SizedBox(height: 8),
                              if (error != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Text(
                                    error,
                                    style: const TextStyle(color: Colors.orange, fontSize: 13),
                                  ),
                                ),
                              _CardWrapper(
                                isRecommended: _isRecommended('transtu_bus'),
                                onTap: () {
                                  final journey = _busServiceToJourney(
                                    bestBus,
                                    hubName:            busHubName,
                                    nextDeparture:      bestTime,
                                    isReverseDirection: state.busIsReverse,
                                  );
                                  context.push('/home/journey-details', extra: journey);
                                },
                                child: _BestBusCard(
                                  service:      bestBus,
                                  nextDeparture: bestTime,
                                  routeLabel:   busHubName ?? '',
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],

                            // ── Taxi collectif ────────────────────────────────
                            if (taxiResult != null) ...[
                              _sectionLabel('Taxi Collectif'),
                              const SizedBox(height: 8),
                              _CardWrapper(
                                isRecommended: _isRecommended('taxi_collectif'),
                                onTap: () => context.push(
                                  '/home/journey-details',
                                  extra: taxiResult,
                                ),
                                child: TaxiCollectifCard(result: taxiResult),
                              ),
                            ],
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: 13,
        color: Color(0xFF1A3A6B),
        letterSpacing: 0.3,
      ),
    );
  }
}

// ── Result entry model ────────────────────────────────────────────────────────

class _ResultEntry {
  final String label;
  final String transportKey;
  final double price;
  final double durationMin;
  final double score;
  final Widget card;
  final VoidCallback onTap;

  const _ResultEntry({
    required this.label,
    required this.transportKey,
    required this.price,
    required this.durationMin,
    required this.score,
    required this.card,
    required this.onTap,
  });
}

// ── Profile selector ──────────────────────────────────────────────────────────

class _ProfileSelector extends StatelessWidget {
  final UserProfile current;
  final ValueChanged<UserProfile> onChanged;

  const _ProfileSelector({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _tab(UserProfile.price,    '💰 Prix',      Icons.savings_outlined),
          _tab(UserProfile.balanced, '⚖️ Équilibré', Icons.balance_outlined),
          _tab(UserProfile.speed,    '⚡ Rapide',    Icons.speed_outlined),
        ],
      ),
    );
  }

  Widget _tab(UserProfile profile, String label, IconData icon) {
    final active = current == profile;
    return Expanded(
      child: GestureDetector(
        onTap: () => onChanged(profile),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: active
                ? [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 4)]
                : null,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? const Color(0xFF1A3A6B) : Colors.grey.shade500,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Recommendation banner ─────────────────────────────────────────────────────

class _RecommendationBanner extends StatelessWidget {
  final JourneyRecommendation rec;

  const _RecommendationBanner({required this.rec});

  String get _transportLabel {
    switch (rec.winnerTransportType) {
      case 'metro_sahel':     return 'Métro du Sahel';
      case 'banlieue_nabeul': return 'Banlieue Nabeul';
      case 'banlieue_sud':    return 'Banlieue Sud';
      case 'sncft':           return 'SNCFT';
      case 'sts_sahel':       return 'STS Sahel';
      case 'transtu_bus':     return 'Bus TRANSTU';
      case 'taxi_collectif':  return 'Taxi Collectif';
      default:                return rec.winnerTransportType;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A3A6B).withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF1A3A6B).withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xFF1A3A6B).withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              size: 16,
              color: Color(0xFF1A3A6B),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 13, color: Color(0xFF1A3A6B)),
                children: [
                  const TextSpan(
                    text: 'Recommandé  ',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(text: _transportLabel),
                  TextSpan(
                    text: '  ·  ${rec.reasonLabel()}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF5C7AAA),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (rec.isHighConfidence)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF1A3A6B).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '${(rec.winnerScore / 5 * 100).round()}%',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1A3A6B),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Card wrapper with recommended badge ───────────────────────────────────────

class _CardWrapper extends StatelessWidget {
  final bool isRecommended;
  final VoidCallback onTap;
  final Widget child;

  const _CardWrapper({
    required this.isRecommended,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          if (isRecommended)
            Positioned(
              top: -10,
              right: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A3A6B),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF1A3A6B).withValues(alpha: 0.35),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.auto_awesome_rounded, size: 12, color: Colors.white),
                    SizedBox(width: 4),
                    Text(
                      'Recommandé',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── _BestBusCard ──────────────────────────────────────────────────────────────

class _BestBusCard extends StatelessWidget {
  final BusService service;
  final String? nextDeparture;
  final String routeLabel;

  const _BestBusCard({
    required this.service,
    required this.nextDeparture,
    required this.routeLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF00695C), Color(0xFF00897B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00695C).withValues(alpha: 0.35),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.directions_bus, color: Colors.white, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      'Ligne ${service.lineNumber}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  routeLabel,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.access_time, color: Colors.white70, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Prochain départ',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const Spacer(),
                Text(
                  nextDeparture ?? '--:--',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 26,
                  ),
                ),
              ],
            ),
          ),
          if (service.estimatedTripDurationMinutes != null ||
              service.frequencyLabel.isNotEmpty ||
              service.priceLabel.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                if (service.estimatedTripDurationMinutes != null) ...[
                  const Icon(Icons.timer_outlined, color: Colors.white70, size: 16),
                  const SizedBox(width: 4),
                  Text(
                    '~${service.estimatedTripDurationMinutes} min',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ] else if (service.frequencyLabel.isNotEmpty) ...[
                  const Icon(Icons.schedule, color: Colors.white54, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    service.frequencyLabel,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
                const Spacer(),
                if (service.priceLabel.isNotEmpty)
                  Text(
                    service.priceLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
              ],
            ),
            if (service.estimatedTripDurationMinutes != null &&
                service.frequencyLabel.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.schedule, color: Colors.white38, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    service.frequencyLabel,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),
            ],
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              const Icon(Icons.info_outline, color: Colors.white38, size: 14),
              const SizedBox(width: 4),
              Text(
                'Appuyez pour les détails',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
