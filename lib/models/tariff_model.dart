import 'package:cloud_firestore/cloud_firestore.dart';

class Tariff {
  final String id;
  final String operatorId;
  final String fromStationId;
  final String toStationId;
  final double price; // in TND
  final String currency;
  final String? tariffClass; // economy, comfort, vip
  final DateTime? validFrom;
  final DateTime? validTo;
  final String? notes;
  final List<SpecialDiscount> specialDiscounts;
  final DateTime createdAt;

  const Tariff({
    required this.id,
    required this.operatorId,
    required this.fromStationId,
    required this.toStationId,
    required this.price,
    this.currency = 'TND',
    this.tariffClass,
    this.validFrom,
    this.validTo,
    this.notes,
    required this.specialDiscounts,
    required this.createdAt,
  });

  factory Tariff.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    if (data == null) throw StateError('Tariff document ${doc.id} does not exist');
    return Tariff(
      id: doc.id,
      operatorId: (data['operatorId'] as String?) ?? '',
      fromStationId: (data['fromStationId'] as String?) ?? '',
      toStationId: (data['toStationId'] as String?) ?? '',
      price: (data['price'] as num?)?.toDouble() ?? 0.0,
      currency: (data['currency'] as String?) ?? 'TND',
      tariffClass: data['tariffClass'] as String?,
      validFrom: data['validFrom'] != null
          ? (data['validFrom'] as Timestamp).toDate()
          : null,
      validTo: (data['validTo'] as Timestamp?)?.toDate(),
      notes: data['notes'] as String?,
      specialDiscounts: (data['specialDiscounts'] as List?)
              ?.map((d) => SpecialDiscount.fromMap(Map<String, dynamic>.from(d as Map)))
              .toList() ??
          [],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => {
        'operatorId': operatorId,
        'fromStationId': fromStationId,
        'toStationId': toStationId,
        'price': price,
        'currency': currency,
        'tariffClass': tariffClass,
        'validFrom': validFrom != null ? Timestamp.fromDate(validFrom!) : null,
        'validTo': validTo != null ? Timestamp.fromDate(validTo!) : null,
        'notes': notes,
        'specialDiscounts': specialDiscounts.map((d) => d.toMap()).toList(),
        'createdAt': Timestamp.fromDate(createdAt),
      };

  /// Metro Sahel pricing formula:
  /// Base: 0.550 TND for 1-3 stops
  /// Every additional 3 stops: +0.250 TND
  /// Formula: price(n) = 0.550 + floor((n-1) / 3) * 0.250
  static double calculateMetroSahelPrice(int numberOfStops) {
    if (numberOfStops <= 0) return 0.0;
    final basePrice = 0.550;
    final incrementPrice = 0.250;
    final additionalIncrements = ((numberOfStops - 1) / 3).floor();
    return basePrice + (additionalIncrements * incrementPrice);
  }

  String get formattedPrice => '${price.toStringAsFixed(3)} $currency';

  Tariff copyWith({
    String? id,
    String? operatorId,
    String? fromStationId,
    String? toStationId,
    double? price,
    String? currency,
    String? tariffClass,
    DateTime? validFrom,
    DateTime? validTo,
    String? notes,
    List<SpecialDiscount>? specialDiscounts,
    DateTime? createdAt,
  }) {
    return Tariff(
      id: id ?? this.id,
      operatorId: operatorId ?? this.operatorId,
      fromStationId: fromStationId ?? this.fromStationId,
      toStationId: toStationId ?? this.toStationId,
      price: price ?? this.price,
      currency: currency ?? this.currency,
      tariffClass: tariffClass ?? this.tariffClass,
      validFrom: validFrom ?? this.validFrom,
      validTo: validTo ?? this.validTo,
      notes: notes ?? this.notes,
      specialDiscounts: specialDiscounts ?? this.specialDiscounts,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  String toString() =>
      'Tariff($fromStationId → $toStationId: $formattedPrice)';
}

class SpecialDiscount {
  final String condition; // student, senior, group, return
  final double discountPercentage;
  final int? minQuantity;
  final DateTime? validFrom;
  final DateTime? validTo;

  const SpecialDiscount({
    required this.condition,
    required this.discountPercentage,
    this.minQuantity,
    this.validFrom,
    this.validTo,
  });

  factory SpecialDiscount.fromMap(Map<String, dynamic> map) {
    return SpecialDiscount(
      condition: (map['condition'] as String?) ?? '',
      discountPercentage: (map['discountPercentage'] as num?)?.toDouble() ?? 0.0,
      minQuantity: map['minQuantity'] as int?,
      validFrom: (map['validFrom'] as Timestamp?)?.toDate(),
      validTo: (map['validTo'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() => {
        'condition': condition,
        'discountPercentage': discountPercentage,
        'minQuantity': minQuantity,
        'validFrom': validFrom != null ? Timestamp.fromDate(validFrom!) : null,
        'validTo': validTo != null ? Timestamp.fromDate(validTo!) : null,
      };

  bool appliesToQuantity(int quantity) {
    return minQuantity == null || quantity >= minQuantity!;
  }
}
