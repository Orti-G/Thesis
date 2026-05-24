import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';

// Wrapper class to store both the telemetry reading and its exact reception time
class ChartDataPoint {
  final DateTime timestamp;
  final double value;

  ChartDataPoint({
    required this.timestamp,
    required this.value,
  });
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  // Timer & Firebase Subscription
  Timer? _timer;
  StreamSubscription<DatabaseEvent>? _dbSubscription;

  // State for collapsible Advanced Metrics
  bool _isAdvancedMetricsExpanded = false;

  // Live numeric values from Firebase
  double _currentWatts = 0.0;
  double _cumulativeEnergy = 0.0;
  double _currentAmps = 0.0;
  double _frequency = 0.0;
  double _powerFactor = 0.0;
  double _currentVoltage = 0.0;

  // Chart History Arrays storing timed data objects
  final int maxDataPoints = 20;

  late List<ChartDataPoint> _wattsHistory;
  late List<ChartDataPoint> _ampsHistory;
  late List<ChartDataPoint> _voltageHistory;

  // Colors matching your system design
  final Color primaryOrange = const Color(0xFFF26E22);
  final Color topCardColor = const Color(0xFFFA8B39);
  final Color darkButtonColor = const Color(0xFF3B150F);
  final Color bgColor = const Color(0xFFFAFAFA);
  final Color cardColor = Colors.white;

  @override
  void initState() {
    super.initState();

    // Seed history structures with initial mock timestamps
    DateTime now = DateTime.now();

    _wattsHistory = List.generate(
      maxDataPoints,
      (i) => ChartDataPoint(
        timestamp: now.subtract(
          Duration(seconds: (maxDataPoints - i) * 2),
        ),
        value: 0.0,
      ),
      growable: true,
    );

    _ampsHistory = List.generate(
      maxDataPoints,
      (i) => ChartDataPoint(
        timestamp: now.subtract(
          Duration(seconds: (maxDataPoints - i) * 2),
        ),
        value: 0.0,
      ),
      growable: true,
    );

    _voltageHistory = List.generate(
      maxDataPoints,
      (i) => ChartDataPoint(
        timestamp: now.subtract(
          Duration(seconds: (maxDataPoints - i) * 2),
        ),
        value: 0.0,
      ),
      growable: true,
    );

    _setupFirebaseListener();

    // Timer running every 2 seconds appending data CONSTANTLY ONLY for the main Watts chart
    _timer = Timer.periodic(
      const Duration(seconds: 2),
      (timer) {
        setState(() {
          if (_wattsHistory.length >= maxDataPoints) {
            _wattsHistory.removeAt(0);
          }
          _wattsHistory.add(
            ChartDataPoint(
              timestamp: DateTime.now(),
              value: _currentWatts,
            ),
          );
        });
      },
    );
  }

  void _setupFirebaseListener() {
    DatabaseReference ref = FirebaseDatabase.instance.ref('live_reading');

    _dbSubscription = ref.onValue.listen((event) {
      if (event.snapshot.value != null) {
        try {
          final data = Map<String, dynamic>.from(
            event.snapshot.value as Map,
          );

          setState(() {
            _currentWatts = double.tryParse(data['power'].toString()) ?? 0.0;
            _cumulativeEnergy = double.tryParse(data['cumul_kwh'].toString()) ?? 0.0;
            _currentAmps = double.tryParse(data['current'].toString()) ?? 0.0;
            _frequency = double.tryParse(data['frequency'].toString()) ?? 0.0;
            _powerFactor = double.tryParse(data['power_factor'].toString()) ?? 0.0;
            _currentVoltage = double.tryParse(data['voltage'].toString()) ?? 0.0;

            final timestamp = DateTime.now();

            // Append new points to the smaller charts ONLY when Firebase pushes new data

            // --- AMPS ---
            if (_ampsHistory.length >= maxDataPoints) {
              _ampsHistory.removeAt(0);
            }
            _ampsHistory.add(ChartDataPoint(timestamp: timestamp, value: _currentAmps));

            // --- VOLTAGE ---
            if (_voltageHistory.length >= maxDataPoints) {
              _voltageHistory.removeAt(0);
            }
            _voltageHistory.add(ChartDataPoint(timestamp: timestamp, value: _currentVoltage));
          });
        } catch (e) {
          print("🔴 ERROR PARSING DATA: $e");
        }
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _dbSubscription?.cancel();
    super.dispose();
  }

  // Generates FlSpots mapping list indexes on X axis against read values on Y axis
  List<FlSpot> _generateChartSpots(
    List<ChartDataPoint> history,
  ) {
    return history.asMap().entries.map((e) {
      return FlSpot(
        e.key.toDouble(),
        e.value.value,
      );
    }).toList();
  }

  // MIN/MAX Helpers that work explicitly with our ChartDataPoint structures
  double _getMinY(List<ChartDataPoint> history) {
    if (history.isEmpty) return 0;

    double min = history
        .map((e) => e.value)
        .reduce((a, b) => a < b ? a : b);

    return (min * 0.8).clamp(0, double.infinity);
  }

  double _getMaxY(List<ChartDataPoint> history) {
    if (history.isEmpty) return 1;

    double max = history
        .map((e) => e.value)
        .reduce((a, b) => a > b ? a : b);

    return max == 0 ? 1.0 : max * 1.2;
  }

  String _formatWithCommas(double value) {
    RegExp reg = RegExp(
      r'(\d{1,3})(?=(\d{3})+(?!\d))',
    );

    String mathFunc(Match match) => '${match[1]},';

    return value.toStringAsFixed(2).replaceAllMapped(reg, mathFunc);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- HEADER SECTION WITH MAIN ZOOMABLE TIMED CHART ---
            Container(
              width: double.infinity,
              color: topCardColor,
              child: SafeArea(
                bottom: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'TOTAL ENERGY CONSUMPTION',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.white.withValues(alpha: 0.9),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                _formatWithCommas(_cumulativeEnergy),
                                style: const TextStyle(
                                  fontSize: 48,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -1,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'kWh',
                                style: TextStyle(
                                  fontSize: 20,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Icon(
                                Icons.visibility_off_outlined,
                                size: 20,
                                color: Colors.white.withValues(alpha: 0.8),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              // --- Custom Green Glowing Circle Widget ---
                              Container(
                                width: 16, // Original icon space
                                height: 16,
                                alignment: Alignment.center,
                                child: Container(
                                  width: 8, // Inner solid dot
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF00E676), // Bright Green
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      // Bloom effects
                             
                                      BoxShadow(
                                        color: const Color(0xFF00E676).withOpacity(0.3),
                                        blurRadius: 6.0,
                                        spreadRadius: 1.0,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Live Power: ${_currentWatts.toStringAsFixed(0)} W',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    // INTERACTIVE VIEW BOX FOR PAN & PINCH ZOOM
                    SizedBox(
                      height: 210,
                      width: double.infinity,
                      child: InteractiveViewer(
                        clipBehavior: Clip.none,
                        alignment: Alignment.center,
                        minScale: 1.0,
                        maxScale: 5.0,
                        scaleEnabled: true,
                        panEnabled: true,
                        child: Padding(
                          padding: const EdgeInsets.only(
                            right: 24.0,
                            left: 10.0,
                          ),
                          child: LineChart(
                            LineChartData(
                              gridData: const FlGridData(
                                show: false,
                              ),
                              borderData: FlBorderData(show: false),
                              minY: _getMinY(_wattsHistory),
                              maxY: _getMaxY(_wattsHistory),
                              titlesData: FlTitlesData(
                                topTitles: const AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: false,
                                  ),
                                ),
                                rightTitles: const AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: false,
                                  ),
                                ),
                                leftTitles: const AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: false,
                                  ),
                                ),
                                bottomTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: true,
                                    reservedSize: 28,
                                    interval: 4,
                                    getTitlesWidget: (value, meta) {
                                      int index = value.toInt();

                                      if (index >= 0 &&
                                          index < _wattsHistory.length) {
                                        DateTime time =
                                            _wattsHistory[index].timestamp;

                                        String formattedTime = DateFormat(
                                          'HH:mm:ss',
                                        ).format(time);

                                        return SideTitleWidget(
                                          meta: meta,
                                          space: 8,
                                          child: Text(
                                            formattedTime,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 9,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        );
                                      }

                                      return const SizedBox.shrink();
                                    },
                                  ),
                                ),
                              ),
                              lineBarsData: [
                                LineChartBarData(
                                  spots: _generateChartSpots(
                                    _wattsHistory,
                                  ),
                                  isCurved: true,
                                  color: Colors.white,
                                  barWidth: 3,
                                  isStrokeCapRound: true,
                                  dotData: FlDotData(
                                    show: true,
                                    checkToShowDot: (spot, barData) {
                                      return spot.x == barData.spots.last.x;
                                    },
                                    getDotPainter: (spot, percent, barData, index) {
                                      return FlDotCirclePainter(
                                        radius: 5,
                                        color: Colors.white,
                                        strokeWidth: 0,
                                      );
                                    },
                                  ),
                                  belowBarData: BarAreaData(
                                    show: false,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),

            // --- BOTTOM FEED SECTION ---
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 20.0,
                vertical: 20.0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'LIVE FEED',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                      Icon(
                        Icons.menu,
                        color: Colors.grey[800],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildLiveFeedCard(
                    title: 'Current',
                    value: _currentAmps.toStringAsFixed(2),
                    unit: 'A',
                    subtitle: 'Live Amperage',
                    spots: _generateChartSpots(_ampsHistory),
                    history: _ampsHistory,
                  ),
                  const SizedBox(height: 12),
                  _buildLiveFeedCard(
                    title: 'Voltage',
                    value: _currentVoltage.toStringAsFixed(1),
                    unit: 'V',
                    subtitle: 'Mains Voltage',
                    spots: _generateChartSpots(_voltageHistory),
                    history: _voltageHistory,
                  ),
                  const SizedBox(height: 30),
                  GestureDetector(
                    onTap: () => setState(
                      () => _isAdvancedMetricsExpanded =
                          !_isAdvancedMetricsExpanded,
                    ),
                    child: Container(
                      color: Colors.transparent,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'ADVANCED METRICS',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                          AnimatedRotation(
                            turns: _isAdvancedMetricsExpanded ? 0.5 : 0,
                            duration: const Duration(milliseconds: 300),
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.expand_more_rounded,
                              color: Colors.grey[800],
                              size: 24,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    child: _isAdvancedMetricsExpanded
                        ? Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: _buildMetricCard(
                                      'Frequency',
                                      _frequency.toStringAsFixed(1),
                                      'Hz',
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: _buildMetricCard(
                                      'Power Factor',
                                      _powerFactor.toStringAsFixed(2),
                                      'PF',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 20),
                            ],
                          )
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 120),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- SUB CARD WIDGET UI HELPERS ---
  Widget _buildLiveFeedCard({
    required String title,
    required String value,
    required String unit,
    required String subtitle,
    required List<FlSpot> spots,
    required List<ChartDataPoint> history,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[800],
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    unit,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[800],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
          SizedBox(
            height: 40,
            width: 100,
            child: LineChart(
              LineChartData(
                gridData: const FlGridData(show: false),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                minY: _getMinY(history),
                maxY: _getMaxY(history),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    color: primaryOrange,
                    barWidth: 2,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          primaryOrange.withValues(alpha: 0.2),
                          primaryOrange.withValues(alpha: 0.0),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
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

  Widget _buildMetricCard(
    String title,
    String value,
    String unit,
  ) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey[800],
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                unit,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[800],
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}