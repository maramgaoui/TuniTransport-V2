import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tuni_transport/l10n/app_localizations.dart';
import '../controllers/journey_search_controller.dart';
import '../controllers/journey_search_state.dart';
import '../models/bus_service_model.dart';
import '../models/journey_model.dart';
import '../models/journey_recommendation.dart';
import '../services/recommendation_service.dart';
import '../services/user_preference_service.dart';
import '../widgets/app_header.dart';
import '../widgets/metro_sahel_card.dart';
import '../widgets/taxi_collectif_card.dart';
import '../widgets/transport_card.dart';

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
  Map<String, ({double avg, int count})> _communityByType = {};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchStateChanged);
    _initWithProfile();
  }

  // Load the saved profile first, then start the search so that when results
  // arrive _profile is already correct and no recommendation flip occurs.
  Future<void> _initWithProfile() async {
    final p = await UserPreferenceService.instance.getProfile();
    if (!mounted) return;
    setState(() => _profile = p);
    if (widget.fromStationId != null && widget.toStationId != null) {
      _searchController.search(
        fromStationId: widget.fromStationId!,
        toStationId:   widget.toStationId!,
      );
    }
  }

  void _onSearchStateChanged() {
    if (!mounted) return;
    _rerunRecommendation(_profile);
    _fetchCommunityStats();
  }

  Future<void> _fetchCommunityStats() async {
    final fromId = widget.fromStationId;
    final toId   = widget.toStationId;
    if (fromId == null || toId == null) return;

    final s = _searchController.state;
    final types = <String>[
      if (s.trainResults.isNotEmpty)
        RecommendationService.lineTypeToTransportType(s.trainResults.first.lineType),
      if (s.bestBusService != null) 'transtu_bus',
      if (s.taxiCollectifResult != null) 'taxi_collectif',
    ];
    if (types.isEmpty) return;

    final ratings = await _recommendationService.getCommunityRatings(
      fromStationId: fromId,
      toStationId:   toId,
      transportTypes: types,
    );
    if (mounted) setState(() => _communityByType = ratings);
  }

  Future<void> _changeProfile(UserProfile newProfile) async {
    setState(() => _profile = newProfile);
    await UserPreferenceService.instance.setProfile(newProfile);
    _rerunRecommendation(newProfile);
  }

  Future<void> _rerunRecommendation(UserProfile profile) async {
    if (widget.fromStationId == null || widget.toStationId == null) return;
    final s = _searchController.state;
    if (!s.hasResult) return;

    // Prix and Rapide: the winner is exactly the top card of the sorted list.
    // Using the ML model here causes inconsistency (model balances price +
    // comfort + duration, so it may pick a different option than the cheapest).
    if (profile != UserProfile.balanced) {
      final entries = _buildSortedEntries(s);
      if (entries.isEmpty) return;
      final n = entries.length;
      // Assign relative scores from rank: 1st → 5.0, last → 1.0 (linear).
      // entry.score is from the balanced model and defaults to 0 before that
      // model runs, so we compute ranks independently here.
      final relativeScores = <String, double>{
        for (int i = 0; i < n; i++)
          entries[i].transportKey: n == 1 ? 5.0 : 5.0 - (i * 4.0 / (n - 1)),
      };
      if (mounted) {
        setState(() {
          _recommendation = JourneyRecommendation(
            winnerTransportType: entries.first.transportKey,
            winnerScore:         relativeScores[entries.first.transportKey]!,
            reason: profile == UserProfile.price
                ? RecommendationReason.bestPrice
                : RecommendationReason.fastest,
            allScores:        relativeScores,
            isHighConfidence: n > 1,
            profile:          profile,
            priceByType:    {for (final e in entries) e.transportKey: e.price},
            durationByType: {for (final e in entries) e.transportKey: e.durationMin},
          );
        });
      }
      return;
    }

    // Show instant result (no Firestore) so the banner appears immediately.
    final syncRec = _recommendationService.recommendSync(
      trainResults:  s.trainResults,
      busService:    s.bestBusService,
      taxiResult:    s.taxiCollectifResult,
      fromStationId: widget.fromStationId ?? '',
      toStationId:   widget.toStationId   ?? '',
      profile:       profile,
    );
    if (mounted && syncRec != null) setState(() => _recommendation = syncRec);

    // Then silently update with community reviews blended in.
    final rec = await _recommendationService.recommend(
      trainResults:  s.trainResults,
      busService:    s.bestBusService,
      taxiResult:    s.taxiCollectifResult,
      fromStationId: widget.fromStationId ?? '',
      toStationId:   widget.toStationId   ?? '',
      profile:       profile,
    );
    if (mounted && rec != null) setState(() => _recommendation = rec);
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

  bool _isRecommended(String transportType) =>
      _recommendation?.winnerTransportType == transportType;

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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              title: l10n.results,
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
              child: ListenableBuilder(
                listenable: _searchController,
                builder: (context, _) {
                  final state        = _searchController.state;
                  final isLoading    = state.isLoading;
                  final error        = state.error;
                  final hasAnyResult = state.trainResults.isNotEmpty ||
                      state.bestBusService != null ||
                      state.taxiCollectifResult != null;

                  if (isLoading) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  if (!hasAnyResult) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          error ?? l10n.noJourneysMatchFilter,
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 15, color: Colors.grey[600]),
                        ),
                      ),
                    );
                  }

                  return ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: [

                      _ProfileSelector(
                        current: _profile,
                        onChanged: _changeProfile,
                      ),
                      const SizedBox(height: 16),

                      if (_recommendation != null)
                        _RecommendationBanner(
                          rec:             _recommendation!,
                          profile:         _profile,
                          communityByType: _communityByType,
                        ),
                      if (_recommendation != null) const SizedBox(height: 16),

                      for (final entry in _buildSortedEntries(state)) ...[
                        _sectionLabel(entry.label),
                        const SizedBox(height: 8),
                        _CardWrapper(
                          isRecommended: _isRecommended(entry.transportKey),
                          communityData: _communityByType[entry.transportKey],
                          onTap: entry.onTap,
                          child: entry.card,
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Bus error (if any)
                      if (error != null && state.bestBusService != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            error,
                            style: const TextStyle(
                                color: Colors.orange, fontSize: 13),
                          ),
                        ),
                    ],
                  );
                },
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

  // Suggestion 2: subtitle shown under the active tab.
  static String _subtitle(UserProfile profile) => switch (profile) {
    UserProfile.price    => 'Le moins cher',
    UserProfile.balanced => 'Prix · Durée',
    UserProfile.speed    => 'Le plus direct',
  };

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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? const Color(0xFF1A3A6B) : Colors.grey.shade500,
                ),
              ),
              if (active) ...[
                const SizedBox(height: 2),
                Text(
                  _subtitle(profile),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RecommendationBanner extends StatelessWidget {
  final JourneyRecommendation rec;
  final UserProfile profile;
  final Map<String, ({double avg, int count})> communityByType;

  const _RecommendationBanner({
    required this.rec,
    required this.profile,
    required this.communityByType,
  });

  String _effectiveReasonLabel(AppLocalizations l10n) {
    switch (profile) {
      case UserProfile.price:   return l10n.reasonBestPrice;
      case UserProfile.speed:   return l10n.reasonFastest;
      case UserProfile.balanced:
        switch (rec.reason) {
          case RecommendationReason.bestPrice:   return l10n.reasonBestPrice;
          case RecommendationReason.fastest:     return l10n.reasonFastest;
          case RecommendationReason.bestOverall: return l10n.reasonBestOverall;
        }
    }
  }

  // Concrete savings or time-gain label shown under the reason.
  String? get _concreteDetail {
    final winner = rec.winnerTransportType;
    if (profile == UserProfile.price) {
      final prices = rec.priceByType;
      if (prices == null || prices.length < 2) return null;
      final winnerPrice = prices[winner];
      if (winnerPrice == null) return null;
      final cheapestOther = prices.entries
          .where((e) => e.key != winner)
          .map((e) => e.value)
          .reduce((a, b) => a < b ? a : b);
      final savings = cheapestOther - winnerPrice;
      if (savings > 0.05) return 'Économisez ~${savings.toStringAsFixed(3)} TND';
    }
    if (profile == UserProfile.speed) {
      final durations = rec.durationByType;
      if (durations == null || durations.length < 2) return null;
      final winnerDur = durations[winner];
      if (winnerDur == null) return null;
      final slowestOther = durations.entries
          .where((e) => e.key != winner)
          .map((e) => e.value)
          .reduce((a, b) => a < b ? a : b);
      final gained = slowestOther - winnerDur;
      if (gained > 1) return '~${gained.round()} min plus rapide';
    }
    return null;
  }

  Widget _stars(double score) {
    final filled = score.round().clamp(1, 5);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) => Icon(
        i < filled ? Icons.star_rounded : Icons.star_outline_rounded,
        size: 13,
        color: i < filled ? const Color(0xFFFFB300) : Colors.grey.shade400,
      )),
    );
  }

  // Contextual "why" sentence for the balanced profile.
  String _balancedWhy({({double avg, int count})? community}) {
    final winner   = rec.winnerTransportType;
    final prices   = rec.priceByType;
    final durations = rec.durationByType;

    if (prices == null || prices.length < 2) {
      return community != null
          ? 'Mieux noté par les voyageurs'
          : 'Meilleur équilibre prix · durée';
    }

    final winnerPrice = prices[winner] ?? 0;
    final winnerDur   = durations?[winner] ?? 0;

    final otherPrices = prices.entries.where((e) => e.key != winner).map((e) => e.value);
    final otherDurs   = durations == null
        ? <double>[]
        : durations.entries.where((e) => e.key != winner).map((e) => e.value).toList();

    if (otherPrices.isEmpty) return 'Seule option disponible';

    final cheapestOther = otherPrices.reduce((a, b) => a < b ? a : b);
    final fastestOther  = otherDurs.isNotEmpty
        ? otherDurs.reduce((a, b) => a < b ? a : b)
        : null;

    final isMoreExpensive = winnerPrice > cheapestOther * 1.08;
    final isSlower = fastestOther != null && winnerDur > fastestOther * 1.08;

    if (!isMoreExpensive && !isSlower) {
      return 'Meilleur prix et durée réunis — option idéale';
    }
    if (isMoreExpensive && isSlower) {
      if (community != null) {
        return 'Très apprécié des voyageurs (★${community.avg.toStringAsFixed(1)}) malgré prix et durée supérieurs';
      }
      return 'Très apprécié selon notre modèle malgré prix et durée supérieurs';
    }
    if (isMoreExpensive) {
      final timeSaved = fastestOther != null ? (fastestOther - winnerDur) : 0.0;
      if (timeSaved > 5) return 'Plus rapide (~${timeSaved.round()} min) · prix légèrement supérieur';
      if (community != null) return 'Bien noté par les voyageurs · prix légèrement plus élevé';
      return 'Option bien notée · prix légèrement plus élevé';
    }
    // Winner is cheaper but slower
    final savings = cheapestOther - winnerPrice;
    if (savings > 0.1) return 'Plus économique (~${savings.toStringAsFixed(3)} TND) · durée légèrement supérieure';
    return 'Meilleur prix pour une durée comparable';
  }

  @override
  Widget build(BuildContext context) {
    final l10n       = AppLocalizations.of(context)!;
    final community  = communityByType[rec.winnerTransportType];
    final isBalanced = profile == UserProfile.balanced;

    // Low-confidence: balanced gets a why sentence; prix/rapide get a neutral note.
    if (!rec.isHighConfidence) {
      if (isBalanced) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 16, color: Colors.grey.shade500),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Notre suggestion',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _balancedWhy(community: community),
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded, size: 16, color: Colors.grey.shade500),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Options similaires — voici notre suggestion',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
            ),
          ],
        ),
      );
    }

    // Stars only for balanced (rank-based scores for prix/rapide are meaningless as stars).
    Widget? starsWidget;
    if (isBalanced) {
      starsWidget = _stars(community != null ? community.avg : rec.winnerScore);
    }

    final detail = _concreteDetail;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A3A6B).withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1A3A6B).withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xFF1A3A6B).withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.auto_awesome_rounded, size: 16, color: Color(0xFF1A3A6B)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _effectiveReasonLabel(l10n),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1A3A6B),
                  ),
                ),
                // Prix/Rapide: show concrete number (savings / time gained).
                if (!isBalanced && detail != null) ...[
                  const SizedBox(height: 2),
                  Text(detail, style: const TextStyle(fontSize: 12, color: Color(0xFF5C7AAA))),
                ],
                // Balanced: always show why sentence.
                if (isBalanced) ...[
                  const SizedBox(height: 3),
                  Text(
                    _balancedWhy(community: community),
                    style: const TextStyle(fontSize: 11, color: Color(0xFF5C7AAA)),
                  ),
                ],
                // Balanced: stars + "selon X avis" when community data exists.
                if (isBalanced && community != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (starsWidget != null) starsWidget,
                      const SizedBox(width: 5),
                      Text(
                        'selon ${community.count} avis',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF5C7AAA),
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ] else if (isBalanced && starsWidget != null) ...[
                  const SizedBox(height: 3),
                  starsWidget,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CardWrapper extends StatelessWidget {
  final bool isRecommended;
  final VoidCallback onTap;
  final Widget child;
  // Suggestion 4: community rating shown below the recommended card.
  final ({double avg, int count})? communityData;

  const _CardWrapper({
    required this.isRecommended,
    required this.onTap,
    required this.child,
    this.communityData,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
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
                          'Meilleur choix',
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
          // Suggestion 4: community chip below the winning card only.
          if (isRecommended && communityData != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.star_rounded, size: 13, color: Color(0xFFFFB300)),
                  const SizedBox(width: 3),
                  Text(
                    '${communityData!.avg.toStringAsFixed(1)}  ·  ${communityData!.count} avis',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF5C7AAA),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _BestBusCard extends StatelessWidget {
  final BusService service;
  final String? nextDeparture;
  final String routeLabel;

  const _BestBusCard({
    required this.service,
    required this.nextDeparture,
    required this.routeLabel,
  });

  String? _estimatedArrival() {
    final dep = nextDeparture;
    final dur = service.estimatedTripDurationMinutes;
    if (dep == null || dur == null) return null;
    final parts = dep.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    final total = h * 60 + m + dur;
    final ah = (total ~/ 60) % 24;
    final am = total % 60;
    return '${ah.toString().padLeft(2, '0')}:${am.toString().padLeft(2, '0')}';
  }

  String get _durationLabel {
    final dur = service.estimatedTripDurationMinutes;
    if (dur == null) return service.frequencyLabel.isNotEmpty ? service.frequencyLabel : '—';
    final h = dur ~/ 60;
    final m = dur % 60;
    return h > 0 ? '${h}h ${m}min' : '$dur min';
  }

  // Split "Hub → Destination" label into two station names.
  String get _depStation {
    final parts = routeLabel.split(' → ');
    return parts.isNotEmpty ? parts.first : routeLabel;
  }

  String get _arrStation {
    final parts = routeLabel.split(' → ');
    return parts.length > 1 ? parts.last : (service.destinationNameFr ?? service.directionAr);
  }

  @override
  Widget build(BuildContext context) {
    return TransportCard(
      transportName:    'Bus',
      operatorSubtitle: 'TRANSTU',
      lineNumber:       service.lineNumber,
      icon:             Icons.directions_bus,
      gradientColors:   const [Color(0xFF00695C), Color(0xFF00897B)],
      departureStation: _depStation,
      arrivalStation:   _arrStation,
      departureTime:    nextDeparture,
      arrivalTime:      _estimatedArrival(),
      durationLabel:    _durationLabel,
      tarif:            service.priceLabel.isNotEmpty ? service.priceLabel : '—',
    );
  }
}

