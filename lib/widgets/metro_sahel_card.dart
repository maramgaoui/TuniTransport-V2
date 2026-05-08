import 'package:flutter/material.dart';
import '../models/metro_sahel_result.dart';
import 'transport_card.dart';

class MetroSahelCard extends StatelessWidget {
  final MetroSahelResult result;

  const MetroSahelCard({super.key, required this.result});

  bool get _noTrainToday => result.arrivalTime == 'TOMORROW';
  bool get _isBus => result.lineType == 'sts_sahel';

  String get _durationLabel {
    final h = result.durationMinutes ~/ 60;
    final m = result.durationMinutes % 60;
    return h > 0 ? '${h}h ${m}min' : '${result.durationMinutes} min';
  }

  String get _lineNumber {
    if (result.tripNumberStr != null &&
        result.tripNumberStr != '–' &&
        result.tripNumberStr != '0') {
      return _isBus ? 'Bus ${result.tripNumberStr}' : 'Train ${result.tripNumberStr}';
    }
    if (result.tripNumber != 0) {
      return _isBus ? 'Bus ${result.tripNumber}' : 'Train ${result.tripNumber}';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    // Bus (STS Sahel) → green; Train/Metro → blue
    final gradientColors = _isBus
        ? const [Color(0xFF00695C), Color(0xFF00897B)]
        : const [Color(0xFF1A3A6B), Color(0xFF2E6DA4)];

    final icon = _isBus ? Icons.directions_bus : Icons.train;

    return TransportCard(
      transportName:    _isBus ? 'Bus' : 'Train',
      operatorSubtitle: result.operatorName,
      lineNumber:       _lineNumber.isEmpty ? null : _lineNumber,
      icon:             icon,
      gradientColors:   gradientColors,
      departureStation: result.fromStationName,
      arrivalStation:   result.toStationName,
      departureTime:    _noTrainToday ? null : result.departureTime,
      arrivalTime:      _noTrainToday ? null : result.arrivalTime,
      durationLabel:    _durationLabel,
      tarif:            '${result.price.toStringAsFixed(3)} ${MetroSahelResult.currency}',
      isActive:         result.isActive,
      noServiceTonight: _noTrainToday,
      tomorrowTime:     _noTrainToday ? result.departureTime : null,
    );
  }
}
