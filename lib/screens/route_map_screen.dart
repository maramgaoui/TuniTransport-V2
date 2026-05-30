import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import '../l10n/app_localizations.dart';
import '../models/station_model.dart';
import '../services/station_repository.dart';
import '../widgets/route_map_widget.dart';
import '../widgets/app_header.dart';

class RouteMapScreen extends StatefulWidget {
  /// List of station IDs to display on the map in order
  final List<String> stationIds;
  
  /// Optional route title
  final String? routeTitle;
  
  /// Optional line number
  final String? lineNumber;

  const RouteMapScreen({
    super.key,
    required this.stationIds,
    this.routeTitle,
    this.lineNumber,
  });

  @override
  State<RouteMapScreen> createState() => _RouteMapScreenState();
}

class _RouteMapScreenState extends State<RouteMapScreen> {
  late Future<List<Station>> _stationsFuture;
  final StationRepository _stationRepository = GetIt.instance<StationRepository>();

  @override
  void initState() {
    super.initState();
    _stationsFuture = _loadStations();
  }

  Future<List<Station>> _loadStations() async {
    Future<Station?> safeLoad(String id) async {
      try {
        return await _stationRepository.getStationById(id);
      } catch (e) {
        if (kDebugMode) debugPrint('Error loading station $id: $e');
        return null;
      }
    }
    final results = await Future.wait(widget.stationIds.map(safeLoad));
    return results.whereType<Station>().toList();
  }

  String _buildTitle(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final buf = StringBuffer();
    if (widget.lineNumber != null) {
      buf.write('${l10n.lineLabel} ${widget.lineNumber}');
    }
    if (widget.routeTitle != null) {
      if (buf.isNotEmpty) buf.write(' - ');
      buf.write(widget.routeTitle);
    }
    return buf.toString().isNotEmpty ? buf.toString() : l10n.routeMap;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              title: _buildTitle(context),
            ),
            Expanded(
              child: FutureBuilder<List<Station>>(
                future: _stationsFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return Center(
                      child: CircularProgressIndicator(),
                    );
                  }

                  if (snapshot.hasError) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.error_outline,
                              size: 48, color: Colors.red),
                          const SizedBox(height: 16),
                          Text('Error loading map: ${snapshot.error}'),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: () =>
                                setState(() => _stationsFuture = _loadStations()),
                            icon: const Icon(Icons.refresh),
                            label: const Text('Réessayer'),
                          ),
                        ],
                      ),
                    );
                  }

                  if (!snapshot.hasData || snapshot.data!.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.location_off,
                              size: 48, color: Colors.grey),
                          const SizedBox(height: 16),
                          Text('No stations available'),
                        ],
                      ),
                    );
                  }

                  final stations = snapshot.data!;
                  return RouteMapWidget(
                    stations: stations,
                    title: _buildTitle(context),
                    onStationTapped: (station) {
                      // Optional: Handle station tap
                      if (kDebugMode) debugPrint('Tapped station: ${station.name}');
                    },
                  );
                },
              ),
            ),
            // Legend at bottom
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: Colors.grey.shade300)),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildLegendItem(Colors.green, AppLocalizations.of(context)!.legendStart),
                    const SizedBox(width: 16),
                    _buildLegendItem(Colors.blue, AppLocalizations.of(context)!.legendStop),
                    const SizedBox(width: 16),
                    _buildLegendItem(Colors.red, AppLocalizations.of(context)!.legendEnd),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLegendItem(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1),
          ),
        ),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
