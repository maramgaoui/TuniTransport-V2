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
    if (!mounted) return;
    setState(() => _profile = p);
    // Re-run so the recommendation matches the actual saved profile.
    // Without this call, the balanced default recommendation set while
    // the async load was in-flight would remain visible even after the
    // profile tab switches to the user's real preference.
    _rerunRecommendation(p);
  }

  void _onSearchStateChanged() {
    if (!mounted) return;
    final controllerRec = _searchController.state.recommendation;

    // Controller produced a result for exactly our active profile — adopt it.
    if (controllerRec != null && controllerRec.profile == _profile) {
      setState(() => _recommendation = controllerRec);
      return;
    }

    // Results arrived (or changed) but controller's profile differs from ours.
    // Recompute rather than showing a mismatched recommendation.
    _rerunRecommendation(_profile);
  }

  Future<void> _changeProfile(UserProfile newProfile) async {
    setState(() => _profile = newProfile);
    await UserPreferenceService.instance.setProfile(newProfile);
    _rerunRecommendation(newProfile);
  }

  Future<void> _rerunRecommendation(UserProfile profile) async {
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
          );
        });
      }
      return;
    }

    // Équilibré: use the controller's recommendation immediately if it was
    // already computed for the balanced profile (no async wait needed).
    final controllerRec = _searchController.state.recommendation;
    if (controllerRec != null && controllerRec.profile == UserProfile.balanced) {
      if (mounted) setState(() => _recommendation = controllerRec);
      return;
    }

    // Otherwise run the ML model (Firestore + scoring ~300 ms).
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
    final state        = _searchController.state;
    final isLoading    = state.isLoading;
    final error        = state.error;
    final hasAnyResult = state.trainResults.isNotEmpty ||
        state.bestBusService != null ||
        state.taxiCollectifResult != null;

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
                              _RecommendationBanner(rec: _recommendation!, profile: _profile),
                            if (_recommendation != null) const SizedBox(height: 16),

                            // ── Sorted transport options ──────────────────────
                            for (final entry in _buildSortedEntries(state)) ...[
                              _sectionLabel(entry.label),
                              const SizedBox(height: 8),
                              _CardWrapper(
                                isRecommended: _isRecommended(entry.transportKey),
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
  final UserProfile profile;

  const _RecommendationBanner({required this.rec, required this.profile});

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

  /// Reason label driven by the active filter tab, not the ML model.
  /// When the user explicitly picks Prix or Rapide, the reason is obvious.
  String get _effectiveReasonLabel {
    switch (profile) {
      case UserProfile.price:    return 'Meilleur prix';
      case UserProfile.speed:    return 'Le plus rapide';
      case UserProfile.balanced: return rec.reasonLabel();
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
                    text: '  ·  $_effectiveReasonLabel',
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

