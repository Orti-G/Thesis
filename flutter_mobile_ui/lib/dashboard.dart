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
  // Firebase Subscription
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
        timestamp: now.subtract(Duration(seconds: (maxDataPoints - i) * 2)),
        value: 0.0,
      ),
      growable: true,
    );

    _ampsHistory = List.generate(
      maxDataPoints,
      (i) => ChartDataPoint(
        timestamp: now.subtract(Duration(seconds: (maxDataPoints - i) * 2)),
        value: 0.0,
      ),
      growable: true,
    );

    _voltageHistory = List.generate(
      maxDataPoints,
      (i) => ChartDataPoint(
        timestamp: now.subtract(Duration(seconds: (maxDataPoints - i) * 2)),
        value: 0.0,
      ),
      growable: true,
    );

    _setupFirebaseListener();
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

            // Append new points to the small charts
            // --- WATTS ---
            if (_wattsHistory.length >= maxDataPoints) {
              _wattsHistory.removeAt(0);
            }
            _wattsHistory.add(ChartDataPoint(timestamp: timestamp, value: _currentWatts));

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
          debugPrint("🔴 ERROR PARSING DATA: $e");
        }
      }
    });
  }

  @override
  void dispose() {
    _dbSubscription?.cancel();
    super.dispose();
  }

  // Generates FlSpots mapping list indexes on X axis against read values on Y axis
  List<FlSpot> _generateChartSpots(List<ChartDataPoint> history) {
    return history.asMap().entries.map((e) {
      return FlSpot(
        e.key.toDouble(),
        e.value.value,
      );
    }).toList();
  }

  double _getMinY(List<ChartDataPoint> history) {
    if (history.isEmpty) return 0;
    double min = history.map((e) => e.value).reduce((a, b) => a < b ? a : b);
    return (min * 0.8).clamp(0, double.infinity);
  }

  double _getMaxY(List<ChartDataPoint> history) {
    if (history.isEmpty) return 1;
    double max = history.map((e) => e.value).reduce((a, b) => a > b ? a : b);
    return max == 0 ? 1.0 : max * 1.2;
  }

  String _formatWithCommas(double value) {
    RegExp reg = RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))');
    String mathFunc(Match match) => '${match[1]},';
    return value.toStringAsFixed(1).replaceAllMapped(reg, mathFunc);
  }

  // Single dataset mock data
  List<FlSpot> _getMockChartData() {
    return const [
      FlSpot(0, 0.5), FlSpot(1, 0.8), FlSpot(2, 0.4), FlSpot(3, 0.6), FlSpot(4, 0.5),
      FlSpot(5, 0.8), FlSpot(6, 0.4), FlSpot(7, 1.2), FlSpot(17, 1.0), FlSpot(17.5, 0.8),
      FlSpot(18, 0.5), FlSpot(18.5, 14), FlSpot(19, 13.5), FlSpot(19.5, 13.8),
      FlSpot(20, 13), FlSpot(20.5, 1), FlSpot(21, 0.5), FlSpot(22, 0.8), FlSpot(23, 0.4), FlSpot(24, 0),
    ];
  }

  @override
  Widget build(BuildContext context) {
    String todayDate = DateFormat('EEE MMM d').format(DateTime.now());
    
    // Get total screen height for our 70% calculation
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: bgColor,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- HEADER SECTION ---
            Container(
              height: screenHeight * 0.70, // Takes up 70% of the screen
              width: double.infinity,
              color: topCardColor, // The Big Orange Section
              child: SafeArea(
                bottom: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header text
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                todayDate,
                                style: const TextStyle(
                                  fontSize: 16,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Total Used',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white.withValues(alpha: 0.9),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                _formatWithCommas(_cumulativeEnergy),
                                style: const TextStyle(
                                  fontSize: 36,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -1,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                'kWh',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),

                    // DAILY CHART WITH SUBTLE GLOW EFFECT
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: SizedBox(
                          width: double.infinity,
                          child: Padding(
                            padding: const EdgeInsets.only(
                              top: 24.0,
                              bottom: 0.0
                            ),
                            child: LineChart(
                              LineChartData(
                                minX: 0,
                                maxX: 24,
                                minY: 0,
                                maxY: 15,
                                gridData: FlGridData(
                                  show: true,
                                  drawVerticalLine: true,
                                  horizontalInterval: 7,
                                  verticalInterval: 6,
                                  getDrawingHorizontalLine: (value) => FlLine(
                                    color: Colors.white.withValues(alpha: 0.2),
                                    strokeWidth: 1,
                                  ),
                                  getDrawingVerticalLine: (value) => FlLine(
                                    color: Colors.white.withValues(alpha: 0.2),
                                    strokeWidth: 1,
                                  ),
                                ),
                                borderData: FlBorderData(show: false),
                                
                                extraLinesData: ExtraLinesData(
                                  horizontalLines: [
                                    HorizontalLine(
                                      y: 7,
                                      color: Colors.transparent,
                                      label: HorizontalLineLabel(
                                        show: true,
                                        alignment: Alignment.bottomRight,
                                        padding: const EdgeInsets.only(right: 4, bottom: 4),
                                        style: TextStyle(
                                          color: Colors.white.withValues(alpha: 0.8),
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        labelResolver: (line) => '7',
                                      ),
                                    ),
                                    HorizontalLine(
                                      y: 14,
                                      color: Colors.transparent,
                                      label: HorizontalLineLabel(
                                        show: true,
                                        alignment: Alignment.bottomRight,
                                        padding: const EdgeInsets.only(right: 4, bottom: 4),
                                        style: TextStyle(
                                          color: Colors.white.withValues(alpha: 0.8),
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        labelResolver: (line) => '14 kW',
                                      ),
                                    ),
                                  ],
                                ),

                                titlesData: FlTitlesData(
                                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                  leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                  bottomTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 24,
                                      interval: 6,
                                      getTitlesWidget: (value, meta) {
                                        String label = '';
                                        if (value == 6) label = '6 AM';
                                        if (value == 12) label = '12 PM';
                                        if (value == 18) label = '6 PM';
                                        
                                        return SideTitleWidget(
                                          meta: meta,
                                          space: 8,
                                          child: Text(
                                            label,
                                            style: TextStyle(
                                              color: Colors.white.withValues(alpha: 0.8),
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                                lineBarsData: [
                                  LineChartBarData(
                                    spots: _getMockChartData(),
                                    isCurved: false, 
                                    color: Colors.white, 
                                    barWidth: 2.0, 
                                    isStrokeCapRound: true,
                                    dotData: const FlDotData(show: false),
                                    // Softened neon line aura
                                    shadow: Shadow(
                                      blurRadius: 4,
                                      color: Colors.white.withValues(alpha: 0.25),
                                      offset: Offset.zero,
                                    ),
                                    // Much lighter, cleaner fade underneath the bar
                                    belowBarData: BarAreaData(
                                      show: true,
                                      gradient: LinearGradient(
                                        colors: [
                                          Colors.white.withValues(alpha: 0.20),
                                          Colors.white.withValues(alpha: 0.05),
                                          Colors.white.withValues(alpha: 0.0),
                                        ],
                                        stops: const [0.0, 0.5, 1.0],
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 0),
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
                    title: 'Power',
                    value: _currentWatts.toStringAsFixed(0),
                    unit: 'W',
                    subtitle: 'Live Power',
                    spots: _generateChartSpots(_wattsHistory),
                    history: _wattsHistory,
                  ),
                  const SizedBox(height: 12),

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

                  // Advanced Metrics Toggle
                  GestureDetector(
                    onTap: () => setState(
                      () => _isAdvancedMetricsExpanded = !_isAdvancedMetricsExpanded,
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
                  const SizedBox(height: 80),
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
                    barWidth: 2.0,
                    dotData: const FlDotData(show: false),
                    // Tamed line edge glow
                    shadow: Shadow(
                      blurRadius: 3,
                      color: primaryOrange.withValues(alpha: 0.2),
                      offset: Offset.zero,
                    ),
                    // Clean, minimal gradient fade for feed cards
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          primaryOrange.withValues(alpha: 0.15),
                          primaryOrange.withValues(alpha: 0.02),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.6, 1.0],
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