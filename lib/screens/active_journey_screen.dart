import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:tuni_transport/l10n/app_localizations.dart';
import 'package:tuni_transport/widgets/time_text.dart';
import '../models/journey_model.dart';
import '../models/metro_sahel_result.dart';
import '../services/active_journey_service.dart';
import '../services/recommendation_service.dart';
import '../theme/app_theme.dart';
import '../widgets/rating_sheet.dart';

class ActiveJourneyScreen extends StatefulWidget {
  final Journey journey;

  /// Station IDs — only available when the journey was started from a
  /// MetroSahelResult. Used to build the rating routeKey.
  final String? fromStationId;
  final String? toStationId;
  final MetroSahelResult? metroResult;

  const ActiveJourneyScreen({
    super.key,
    required this.journey,
    this.fromStationId,
    this.toStationId,
    this.metroResult,
  });

  @override
  State<ActiveJourneyScreen> createState() => _ActiveJourneyScreenState();
}

class _ActiveJourneyScreenState extends State<ActiveJourneyScreen> {
  Timer? _ticker;
  Timer? _bannerTimer;
  DateTime? _departureDateTime;
  DateTime? _arrivalDateTime;
  bool _showStartBanner = true;

  @override
  void initState() {
    super.initState();
    _departureDateTime = _parseTime(widget.journey.departureTime);
    _arrivalDateTime   = _parseTime(widget.journey.arrivalTime);
    // Tick every 30 s so the badge label stays accurate.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    _bannerTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showStartBanner = false);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _bannerTimer?.cancel();
    super.dispose();
  }

  /// Parses a "HH:MM" or "HH:MM (+1)" time string into today's DateTime.
  /// If the time is earlier than now, assumes tomorrow.
  DateTime? _parseTime(String? raw) {
    if (raw == null || raw.isEmpty || raw == '--:--') return null;
    final clean = raw.replaceAll(RegExp(r'\s*\(\+\d+\)'), '').trim();
    final parts = clean.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    final now = DateTime.now();
    var dt = DateTime(now.year, now.month, now.day, h, m);
    if (dt.isBefore(now)) dt = dt.add(const Duration(days: 1));
    return dt;
  }

  bool get _hasStarted {
    final dep = _departureDateTime;
    return dep == null || !DateTime.now().isBefore(dep);
  }

  bool get _hasArrived {
    final arr = _arrivalDateTime;
    return arr != null && DateTime.now().isAfter(arr);
  }

  /// Badge label and color based on real time vs departure/arrival.
  ({String label, Color color, IconData icon}) get _statusBadge {
    if (_hasArrived) {
      return (
        label: 'Arrivé(e)',
        color: Colors.lightBlueAccent,
        icon: Icons.check_circle_outline,
      );
    }
    if (_hasStarted) {
      return (
        label: 'En route',
        color: Colors.greenAccent,
        icon: Icons.circle,
      );
    }
    // Before departure — show countdown to departure
    final diff = _departureDateTime!.difference(DateTime.now());
    final totalMin = diff.inMinutes + (diff.inSeconds % 60 > 0 ? 1 : 0);
    final h = totalMin ~/ 60;
    final m = totalMin % 60;
    final label = h > 0 ? 'Départ dans ${h}h ${m}min' : 'Départ dans $totalMin min';
    return (label: label, color: Colors.orangeAccent, icon: Icons.schedule);
  }

  IconData _iconFor(String iconKey) {
    switch (iconKey) {
      case 'bus':   return Icons.directions_bus;
      case 'metro': return Icons.directions_subway;
      case 'taxi':  return Icons.local_taxi;
      case 'train': return Icons.train;
      default:      return Icons.directions_transit;
    }
  }

  Future<void> _openMaps() async {
    final origin      = Uri.encodeComponent('${widget.journey.departureStation}, Tunis, Tunisia');
    final destination = Uri.encodeComponent('${widget.journey.arrivalStation}, Tunis, Tunisia');
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1'
      '&origin=$origin&destination=$destination&travelmode=transit',
    );
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossible d\'ouvrir Google Maps')),
        );
      }
    }
  }

  Future<void> _onTerminer() async {
    await ActiveJourneyService.instance.clearActiveJourney();
    if (!mounted) return;
    // If the active journey screen was pushed on top of another screen
    // (e.g. the user tapped "Voir le trajet actif" from a journey details
    // screen they wanted to start), pop back to that screen so they can
    // immediately start the new trip.  Otherwise fall back to home.
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home/journey-input');
    }
  }

  Future<void> _showRatingSheet() {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      builder: (_) => RatingSheet(
        journey:       widget.journey,
        fromStationId: widget.fromStationId ?? widget.metroResult?.fromStationId,
        toStationId:   widget.toStationId   ?? widget.metroResult?.toStationId,
        transportType: widget.metroResult != null
            ? RecommendationService.lineTypeToTransportType(widget.metroResult!.lineType)
            : _journeyTypeToTransportType(widget.journey.iconKey),
      ),
    );
  }

  static String _journeyTypeToTransportType(String iconKey) {
    switch (iconKey) {
      case 'bus':   return 'transtu_bus';
      case 'taxi':  return 'taxi_collectif';
      case 'train': return 'sncft';
      default:      return 'metro_sahel';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n        = AppLocalizations.of(context)!;
    final hasTransfer = widget.journey.transferStation != null &&
        widget.journey.transferStation!.isNotEmpty;

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(8, 16, 16, 16),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppTheme.primaryTeal, AppTheme.lightTeal],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () {
                          if (context.canPop()) {
                            context.pop();
                          } else {
                            context.go('/home/journey-input');
                          }
                        },
                      ),
                      const Expanded(
                        child: Text(
                          'Trajet en cours',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      // Status badge — only for modes with a fixed schedule
                      if (widget.journey.iconKey != 'taxi')
                        Builder(builder: (_) {
                          final badge = _statusBadge;
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.25),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(badge.icon, color: badge.color, size: 10),
                                const SizedBox(width: 5),
                                Text(
                                  badge.label,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          );
                        }),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Route line
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Row(
                      children: [
                        Icon(_iconFor(widget.journey.iconKey),
                            color: Colors.white, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${widget.journey.departureStation} → '
                            '${widget.journey.arrivalStation}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Map button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryTeal,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _openMaps,
                        icon: const Icon(Icons.map_outlined),
                        label: const Text(
                          'Voir le trajet sur Google Maps',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Info card
                    _InfoCard(
                      children: [
                        // Departure/arrival times are hidden for taxi collectif
                        // (no fixed schedule — departureTime is empty string).
                        if (widget.journey.departureTime.isNotEmpty)
                          _InfoRow(
                            icon: Icons.schedule,
                            label: 'Départ',
                            value: widget.journey.departureTime,
                            forceLtrValue: true,
                          ),
                        if (widget.journey.arrivalTime != null &&
                            widget.journey.arrivalTime!.isNotEmpty)
                          _InfoRow(
                            icon: Icons.flag_outlined,
                            label: 'Arrivée prévue',
                            value: widget.journey.arrivalTime!,
                            forceLtrValue: true,
                          ),
                        _InfoRow(
                          icon: Icons.timer_outlined,
                          label: l10n.totalDuration,
                          value: widget.journey.duration,
                        ),
                        _InfoRow(
                          icon: Icons.payments_outlined,
                          label: 'Prix',
                          value: '${widget.journey.price} TND',
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Route steps
                    Text(
                      l10n.journeySteps,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textDark,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _RouteSteps(
                        journey: widget.journey, hasTransfer: hasTransfer),
                    const SizedBox(height: 20),

                    // Evaluate during journey (optional)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.primaryTeal,
                          side: const BorderSide(color: AppTheme.primaryTeal),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _showRatingSheet,
                        icon: const Icon(Icons.star_rate_outlined),
                        label: const Text(
                          'Évaluer le trajet pour feedback',
                          style: TextStyle(fontSize: 15),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // End journey — clears active journey and navigates home
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: const BorderSide(color: Colors.red),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _onTerminer,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text(
                          'Terminer le trajet',
                          style: TextStyle(fontSize: 15),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
          if (_showStartBanner)
            Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(
                child: AnimatedOpacity(
                  opacity: _showStartBanner ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 400),
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.green.shade600,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle,
                            color: Colors.white, size: 22),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Trajet démarré ! Bonne route 🚌',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () =>
                              setState(() => _showStartBanner = false),
                          child: const Icon(Icons.close,
                              color: Colors.white70, size: 18),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final List<Widget> children;
  const _InfoCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.lightGrey),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(children: children),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool forceLtrValue;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.forceLtrValue = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppTheme.primaryTeal),
          const SizedBox(width: 12),
          Text(label,
              style: const TextStyle(fontSize: 13, color: AppTheme.darkGrey)),
          const Spacer(),
          forceLtrValue
              ? TimeText(
                  value,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textDark),
                )
              : Text(
                  value,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textDark),
                ),
        ],
      ),
    );
  }
}

class _RouteSteps extends StatelessWidget {
  final Journey journey;
  final bool hasTransfer;
  const _RouteSteps({required this.journey, required this.hasTransfer});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _StepTile(
          icon: Icons.my_location,
          iconColor: AppTheme.primaryTeal,
          title: journey.departureStation,
          subtitle: journey.departureTime,
          forceLtrSubtitle: true,
          isFirst: true,
        ),
        _StepConnector(
          label:
              '${journey.type}  ·  Ligne ${journey.line}  ·  ${journey.operator}',
        ),
        if (hasTransfer) ...[
          _StepTile(
            icon: Icons.sync_alt,
            iconColor: Colors.orange,
            title: journey.transferStation!,
            subtitle: journey.transferTime != null
                ? 'Correspondance à ${journey.transferTime}'
                : 'Correspondance',
          ),
          _StepConnector(label: 'Correspondance'),
        ],
        _StepTile(
          icon: Icons.location_on,
          iconColor: Colors.red,
          title: journey.arrivalStation,
          subtitle: journey.arrivalTime ?? '',
          forceLtrSubtitle: true,
          isLast: true,
        ),
      ],
    );
  }
}

class _StepTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool forceLtrSubtitle;
  final bool isFirst;
  final bool isLast;

  const _StepTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.forceLtrSubtitle = false,
    this.isFirst = false,
    this.isLast  = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: iconColor, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textDark)),
              if (subtitle.isNotEmpty)
                forceLtrSubtitle
                    ? TimeText(
                        subtitle,
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.darkGrey),
                      )
                    : Text(subtitle,
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.darkGrey)),
            ],
          ),
        ),
      ],
    );
  }
}

class _StepConnector extends StatelessWidget {
  final String label;
  const _StepConnector({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const SizedBox(width: 17),
          Container(width: 2, height: 40, color: AppTheme.lightGrey),
          const SizedBox(width: 16),
          Expanded(
            child: Text(label,
                style:
                    const TextStyle(fontSize: 12, color: AppTheme.darkGrey),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
