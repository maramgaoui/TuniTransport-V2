class Journey {
  final String id;
  final String departureStation;
  final String arrivalStation;
  final String departureTime;
  final String price;
  final bool isFavorite;

  // Extra metadata used by UI screens — kept flat for favorites JSON serialization.
  final String type;
  final String iconKey;
  final String? arrivalTime;
  final String? transferStation;
  final String? transferTime;
  final String duration;
  final int transfers;
  final bool isOptimal;
  final String operator;
  final String line;
  final int? estimatedTripDurationMinutes;
  final String? timetableFirstDepartureTime;
  final String? timetableLastDepartureTime;

  // Metro/train favorites: stored so the details screen can reconstruct
  // a MetroSahelResult and show the full route map + stops.
  final String? fromStationId;
  final String? toStationId;
  final String? metroLineType;
  final int?    metroTripNumber;
  final String? metroTripNumberStr;

  Journey({
    required this.id,
    required this.departureStation,
    required this.arrivalStation,
    required this.departureTime,
    required this.price,
    this.isFavorite = false,
    required this.type,
    required this.iconKey,
    this.arrivalTime,
    this.transferStation,
    this.transferTime,
    required this.duration,
    required this.transfers,
    required this.isOptimal,
    required this.operator,
    required this.line,
    this.estimatedTripDurationMinutes,
    this.timetableFirstDepartureTime,
    this.timetableLastDepartureTime,
    this.fromStationId,
    this.toStationId,
    this.metroLineType,
    this.metroTripNumber,
    this.metroTripNumberStr,
  });

  // Backward-compat aliases; prefer departureTime/arrivalTime in new code.
  String get departure => departureTime;
  String get arrival => arrivalTime ?? '';

  Journey copyWith({
    String? id,
    String? departureStation,
    String? arrivalStation,
    String? departureTime,
    String? price,
    bool? isFavorite,
    String? type,
    String? iconKey,
    String? arrivalTime,
    String? transferStation,
    String? transferTime,
    String? duration,
    int? transfers,
    bool? isOptimal,
    String? operator,
    String? line,
    int? estimatedTripDurationMinutes,
    String? timetableFirstDepartureTime,
    String? timetableLastDepartureTime,
    String? fromStationId,
    String? toStationId,
    String? metroLineType,
    int?    metroTripNumber,
    String? metroTripNumberStr,
  }) {
    return Journey(
      id: id ?? this.id,
      departureStation: departureStation ?? this.departureStation,
      arrivalStation: arrivalStation ?? this.arrivalStation,
      departureTime: departureTime ?? this.departureTime,
      price: price ?? this.price,
      isFavorite: isFavorite ?? this.isFavorite,
      type: type ?? this.type,
      iconKey: iconKey ?? this.iconKey,
      arrivalTime: arrivalTime ?? this.arrivalTime,
      transferStation: transferStation ?? this.transferStation,
      transferTime: transferTime ?? this.transferTime,
      duration: duration ?? this.duration,
      transfers: transfers ?? this.transfers,
      isOptimal: isOptimal ?? this.isOptimal,
      operator: operator ?? this.operator,
      line: line ?? this.line,
      estimatedTripDurationMinutes: estimatedTripDurationMinutes ?? this.estimatedTripDurationMinutes,
      timetableFirstDepartureTime: timetableFirstDepartureTime ?? this.timetableFirstDepartureTime,
      timetableLastDepartureTime: timetableLastDepartureTime ?? this.timetableLastDepartureTime,
      fromStationId: fromStationId ?? this.fromStationId,
      toStationId: toStationId ?? this.toStationId,
      metroLineType: metroLineType ?? this.metroLineType,
      metroTripNumber: metroTripNumber ?? this.metroTripNumber,
      metroTripNumberStr: metroTripNumberStr ?? this.metroTripNumberStr,
    );
  }

  @override
  String toString() =>
      'Journey(id: $id, $departureStation→$arrivalStation, '
      'dep: $departureTime, type: $type, operator: $operator)';

  factory Journey.fromJson(Map<String, dynamic> json) {
    return Journey(
      id: (json['id'] ?? '').toString(),
      departureStation: (json['departureStation'] ?? '').toString(),
      arrivalStation: (json['arrivalStation'] ?? '').toString(),
      departureTime: (json['departureTime'] ?? json['departure'] ?? '').toString(),
      price: (json['price'] ?? '').toString(),
      isFavorite: (json['isFavorite'] ?? false) == true,
      type: (json['type'] ?? 'Trajet').toString(),
      iconKey: (json['iconKey'] ?? 'bus').toString(),
      arrivalTime: json['arrivalTime']?.toString() ?? json['arrival']?.toString(),
      transferStation: json['transferStation']?.toString(),
      transferTime: json['transferTime']?.toString(),
      duration: (json['duration'] ?? '').toString(),
      transfers: (json['transfers'] ?? 0) is int
          ? (json['transfers'] ?? 0) as int
          : int.tryParse((json['transfers'] ?? '0').toString()) ?? 0,
      isOptimal: (json['isOptimal'] ?? false) == true,
      operator: (json['operator'] ?? '').toString(),
      line: (json['line'] ?? '').toString(),
      estimatedTripDurationMinutes: (json['estimatedTripDurationMinutes'] as num?)?.toInt(),
      timetableFirstDepartureTime: json['timetableFirstDepartureTime']?.toString(),
      timetableLastDepartureTime:  json['timetableLastDepartureTime']?.toString(),
      fromStationId:      json['fromStationId']?.toString(),
      toStationId:        json['toStationId']?.toString(),
      metroLineType:      json['metroLineType']?.toString(),
      metroTripNumber:    (json['metroTripNumber'] as num?)?.toInt(),
      metroTripNumberStr: json['metroTripNumberStr']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'departureStation': departureStation,
      'arrivalStation': arrivalStation,
      'departureTime': departureTime,
      'price': price,
      'isFavorite': isFavorite,
      'type': type,
      'iconKey': iconKey,
      'arrivalTime': arrivalTime,
      'transferStation': transferStation,
      'transferTime': transferTime,
      'duration': duration,
      'transfers': transfers,
      'isOptimal': isOptimal,
      'operator': operator,
      'line': line,
      'estimatedTripDurationMinutes': estimatedTripDurationMinutes,
      'timetableFirstDepartureTime':  timetableFirstDepartureTime,
      'timetableLastDepartureTime':   timetableLastDepartureTime,
      'fromStationId':      fromStationId,
      'toStationId':        toStationId,
      'metroLineType':      metroLineType,
      'metroTripNumber':    metroTripNumber,
      'metroTripNumberStr': metroTripNumberStr,
    };
  }
}
