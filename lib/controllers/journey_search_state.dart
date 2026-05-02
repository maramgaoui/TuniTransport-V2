import 'package:equatable/equatable.dart';
import '../models/bus_service_model.dart';
import '../models/metro_sahel_result.dart';

class JourneySearchState extends Equatable {
  final bool isLoading;
  final String? error;
  final List<MetroSahelResult> trainResults;   // all matched train/metro results
  final List<BusService>? busServices;         // full timetable list (hub → hub)
  final BusService? bestBusService;            // single "next bus" result
  final String? bestBusDepartureTime;          // computed next departure "HH:MM"
  final String? busHubName;                    // display name for best bus result

  const JourneySearchState({
    this.isLoading = false,
    this.error,
    this.trainResults = const [],
    this.busServices,
    this.bestBusService,
    this.bestBusDepartureTime,
    this.busHubName,
  });

  // ── Convenience getters for UI state checks ──────────────────────────────

  /// First train result, or null — for backward-compat with any callers
  /// that still reference a single metroSahelResult.
  MetroSahelResult? get metroSahelResult =>
      trainResults.isNotEmpty ? trainResults.first : null;

  /// True when at least one result (train or bus) is available to display.
  bool get hasResult => trainResults.isNotEmpty || bestBusService != null;

  /// True when not loading, no error, and no result — initial/reset state.
  bool get isEmpty => !isLoading && error == null && !hasResult;

  /// True when an error message is present.
  bool get hasError => error != null;

  // ── Equatable ─────────────────────────────────────────────────────────────

  @override
  List<Object?> get props => [
        isLoading,
        error,
        trainResults,
        busServices,
        bestBusService,
        bestBusDepartureTime,
        busHubName,
      ];

  /// Enables readable toString() output for debugPrint and Flutter DevTools.
  @override
  bool get stringify => true;

  // ── copyWith ──────────────────────────────────────────────────────────────

  /// The clearX flags exist because null is a valid target value for nullable
  /// fields — without them there is no way to distinguish "set to null" from
  /// "keep existing value" through a nullable parameter alone.
  ///
  /// Grouping:
  ///   clearError        → clears error only
  ///   clearTrainResults → clears trainResults list
  ///   clearBus          → clears busServices only
  ///   clearBestBus      → clears bestBusService + bestBusDepartureTime + busHubName
  JourneySearchState copyWith({
    bool? isLoading,
    String? error,
    bool clearError = false,
    List<MetroSahelResult>? trainResults,
    bool clearTrainResults = false,
    List<BusService>? busServices,
    bool clearBus = false,
    BusService? bestBusService,
    String? bestBusDepartureTime,
    bool clearBestBus = false,
    String? busHubName,
  }) {
    return JourneySearchState(
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      trainResults: clearTrainResults ? const [] : (trainResults ?? this.trainResults),
      busServices: clearBus ? null : (busServices ?? this.busServices),
      bestBusService:
          clearBestBus ? null : (bestBusService ?? this.bestBusService),
      bestBusDepartureTime: clearBestBus
          ? null
          : (bestBusDepartureTime ?? this.bestBusDepartureTime),
      busHubName: clearBestBus ? null : (busHubName ?? this.busHubName),
    );
  }
}