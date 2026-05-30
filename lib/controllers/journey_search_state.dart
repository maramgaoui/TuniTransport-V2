import 'package:equatable/equatable.dart';
import '../models/bus_service_model.dart';
import '../models/journey_recommendation.dart';
import '../models/metro_sahel_result.dart';
import '../models/taxi_collectif_result.dart';

class JourneySearchState extends Equatable {
  final bool isLoading;
  final String? error;
  final List<MetroSahelResult> trainResults;
  final BusService? bestBusService;
  final String? bestBusDepartureTime;
  final String? busHubName;
  final bool busIsReverse;
  final TaxiCollectifResult? taxiCollectifResult;
  final JourneyRecommendation? recommendation;

  const JourneySearchState({
    this.isLoading = false,
    this.error,
    this.trainResults = const [],
    this.bestBusService,
    this.bestBusDepartureTime,
    this.busHubName,
    this.busIsReverse = false,
    this.taxiCollectifResult,
    this.recommendation,
  });

  /// First train result — backward-compat alias for callers predating multi-result support.
  MetroSahelResult? get metroSahelResult =>
      trainResults.isNotEmpty ? trainResults.first : null;

  /// True when at least one result (train, bus, or taxi) is available to display.
  bool get hasResult =>
      trainResults.isNotEmpty ||
      bestBusService != null ||
      taxiCollectifResult != null;

  /// True when not loading, no error, and no result — initial/reset state.
  bool get isEmpty => !isLoading && error == null && !hasResult;

  /// True when an error message is present.
  bool get hasError => error != null;

  @override
  List<Object?> get props => [
        isLoading,
        error,
        trainResults,
        bestBusService,
        bestBusDepartureTime,
        busHubName,
        busIsReverse,
        taxiCollectifResult,
        recommendation,
      ];

  /// Enables readable toString() output for debugPrint and Flutter DevTools.
  @override
  bool get stringify => true;

  /// The clearX flags exist because null is a valid target value for nullable
  /// fields — without them there is no way to distinguish "set to null" from
  /// "keep existing value" through a nullable parameter alone.
  ///
  /// Grouping:
  ///   clearError        → clears error only
  ///   clearTrainResults → clears trainResults list
  ///   clearBestBus      → clears bestBusService + bestBusDepartureTime + busHubName
  JourneySearchState copyWith({
    bool? isLoading,
    String? error,
    bool clearError = false,
    List<MetroSahelResult>? trainResults,
    bool clearTrainResults = false,
    BusService? bestBusService,
    String? bestBusDepartureTime,
    bool clearBestBus = false,
    String? busHubName,
    bool? busIsReverse,
    TaxiCollectifResult? taxiCollectifResult,
    bool clearTaxi = false,
    JourneyRecommendation? recommendation,
    bool clearRecommendation = false,
  }) {
    return JourneySearchState(
      isLoading:    isLoading ?? this.isLoading,
      error:        clearError ? null : (error ?? this.error),
      trainResults: clearTrainResults ? const [] : (trainResults ?? this.trainResults),
      bestBusService: clearBestBus ? null : (bestBusService ?? this.bestBusService),
      bestBusDepartureTime: clearBestBus
          ? null
          : (bestBusDepartureTime ?? this.bestBusDepartureTime),
      busHubName:   clearBestBus ? null : (busHubName ?? this.busHubName),
      busIsReverse: clearBestBus ? false : (busIsReverse ?? this.busIsReverse),
      taxiCollectifResult:
          clearTaxi ? null : (taxiCollectifResult ?? this.taxiCollectifResult),
      recommendation:
          clearRecommendation ? null : (recommendation ?? this.recommendation),
    );
  }
}