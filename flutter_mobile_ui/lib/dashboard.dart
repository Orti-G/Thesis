import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;
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
  // Firebase Subscription (live feed cards)
  StreamSubscription<DatabaseEvent>? _dbSubscription;

  // --- HOURLY CHART (History + Live) STATE ---
  // Base URL of the FastAPI VM — used for any date that isn't today
  static const String _apiBaseUrl = 'http://35.209.250.46:8000';

  DateTime _selectedDate = DateTime.now();
  Map<int, double> _hourlyKwh = {}; // hour (0-23) -> total kWh for that hour
  bool _isLoadingHistory = false;
  String? _historyError;
  StreamSubscription<DatabaseEvent>? _historySubscription;

  bool get _isTodaySelected {
    final now = DateTime.now();
    return _selectedDate.year == now.year &&
        _selectedDate.month == now.month &&
        _selectedDate.day == now.day;
  }

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

    // Hourly chart defaults to today -> live Firebase listener
    _attachTodayHistoryListener();
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

  // --- HOURLY CHART: LIVE (today) via Firebase `/history/today` ---
  // Matches backend's Option C hybrid: current hour is always live-updating,
  // previous hours are finalized once the hour changes.
  void _attachTodayHistoryListener() {
    _historySubscription?.cancel();
    setState(() {
      _isLoadingHistory = true;
      _historyError = null;
    });

    final ref = FirebaseDatabase.instance.ref('history/today');
    _historySubscription = ref.onValue.listen((event) {
      if (!mounted) return;
      if (event.snapshot.value == null) {
        setState(() {
          _hourlyKwh = {};
          _isLoadingHistory = false;
        });
        return;
      }
      try {
        final data = Map<String, dynamic>.from(event.snapshot.value as Map);
        final hourlyRaw = data['hourly'];
        final Map<int, double> parsed = {};

        if (hourlyRaw is Map) {
          hourlyRaw.forEach((key, value) {
            final hour = int.tryParse(key.toString());
            final kwh = double.tryParse(value.toString());
            if (hour != null && kwh != null) {
              parsed[hour] = kwh;
            }
          });
        }

        setState(() {
          _hourlyKwh = parsed;
          _isLoadingHistory = false;
          _historyError = null;
        });
      } catch (e) {
        debugPrint("🔴 ERROR PARSING HOURLY HISTORY: $e");
        setState(() => _isLoadingHistory = false);
      }
    });
  }

  // --- HOURLY CHART: PAST DATES via FastAPI GET /history/{date} ---
  Future<void> _fetchHistoryForDate(DateTime date) async {
    _historySubscription?.cancel(); // stop live updates while viewing a past date

    setState(() {
      _isLoadingHistory = true;
      _historyError = null;
    });

    final dateStr = DateFormat('yyyy-MM-dd').format(date);

    try {
      final response = await http
          .get(Uri.parse('$_apiBaseUrl/history/$dateStr'))
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final List<dynamic> rows = body['data'] as List<dynamic>? ?? [];
        final Map<int, double> parsed = {};

        for (final row in rows) {
          final hour = row['hour'] as int?;
          final kwh = (row['total_kwh'] as num?)?.toDouble();
          if (hour != null && kwh != null) {
            parsed[hour] = kwh;
          }
        }

        setState(() {
          _hourlyKwh = parsed;
          _isLoadingHistory = false;
        });
      } else {
        // e.g. 404 "No data found for {date}"
        setState(() {
          _hourlyKwh = {};
          _isLoadingHistory = false;
          _historyError = 'No data for $dateStr';
        });
      }
    } catch (e) {
      debugPrint("🔴 ERROR FETCHING HISTORY: $e");
      if (!mounted) return;
      setState(() {
        _isLoadingHistory = false;
        _historyError = 'Failed to load history';
      });
    }
  }

  // --- HOURLY CHART: open a calendar to jump straight to any date ---
  Future<void> _pickDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2024, 1, 1),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: primaryOrange,
                ),
          ),
          child: child!,
        );
      },
    );

    if (picked == null) return;

    setState(() => _selectedDate = picked);

    final now = DateTime.now();
    final isPickedToday = picked.year == now.year &&
        picked.month == now.month &&
        picked.day == now.day;

    if (isPickedToday) {
      _attachTodayHistoryListener();
    } else {
      _fetchHistoryForDate(picked);
    }
  }

  // --- HOURLY CHART: date navigation (placeholder UI, arrows in header) ---
  void _changeDate(int dayOffset) {
    final newDate = _selectedDate.add(Duration(days: dayOffset));
    if (newDate.isAfter(DateTime.now())) return; // no future dates

    setState(() => _selectedDate = newDate);

    final now = DateTime.now();
    final isNewDateToday = newDate.year == now.year &&
        newDate.month == now.month &&
        newDate.day == now.day;

    if (isNewDateToday) {
      _attachTodayHistoryListener();
    } else {
      _fetchHistoryForDate(newDate);
    }
  }

  List<FlSpot> _generateHourlySpots() {
    if (_hourlyKwh.isEmpty) return const [];
    final hours = _hourlyKwh.keys.toList()..sort();
    return hours.map((h) => FlSpot(h.toDouble(), _hourlyKwh[h]!)).toList();
  }

  double _getHourlyMaxY() {
    if (_hourlyKwh.isEmpty) return 1.0;
    final maxVal = _hourlyKwh.values.reduce((a, b) => a > b ? a : b);
    return maxVal == 0 ? 1.0 : maxVal * 1.3;
  }

  @override
  void dispose() {
    _dbSubscription?.cancel();
    _historySubscription?.cancel();
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

  @override
  Widget build(BuildContext context) {
    // Get total screen height for our 70% calculation
    final screenHeight = MediaQuery.of(context).size.height;

    final double chartMaxY = _getHourlyMaxY();
    final double chartMidY = chartMaxY / 2;

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
                              // Date navigator (placeholder for hourly history browsing)
                              Row(
                                children: [
                                  GestureDetector(
                                    onTap: () => _changeDate(-1),
                                    child: const Icon(
                                      Icons.chevron_left,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  GestureDetector(
                                    onTap: () => _pickDate(context),
                                    child: Text(
                                      _isTodaySelected
                                          ? 'Today'
                                          : DateFormat('EEE MMM d').format(_selectedDate),
                                      style: const TextStyle(
                                        fontSize: 16,
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  GestureDetector(
                                    onTap: _isTodaySelected ? null : () => _changeDate(1),
                                    child: Icon(
                                      Icons.chevron_right,
                                      color: Colors.white.withValues(
                                        alpha: _isTodaySelected ? 0.3 : 1.0,
                                      ),
                                      size: 22,
                                    ),
                                  ),
                                ],
                              ),
                              if (_isTodaySelected)
                                Row(
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: const BoxDecoration(
                                        color: Colors.white,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    const Text(
                                      'LIVE',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ],
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
                            child: Stack(
                              children: [
                                LineChart(
                                  LineChartData(
                                    minX: 0,
                                    maxX: 24,
                                    minY: 0,
                                    maxY: chartMaxY,
                                    gridData: FlGridData(
                                      show: true,
                                      drawVerticalLine: true,
                                      horizontalInterval: chartMidY == 0 ? 1 : chartMidY,
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
                                          y: chartMidY,
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
                                            labelResolver: (line) => chartMidY.toStringAsFixed(2),
                                          ),
                                        ),
                                        HorizontalLine(
                                          y: chartMaxY,
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
                                            labelResolver: (line) =>
                                                '${chartMaxY.toStringAsFixed(2)} kWh',
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
                                            if (value == 0) label = '12 AM';
                                            if (value == 6) label = '6 AM';
                                            if (value == 12) label = '12 PM';
                                            if (value == 18) label = '6 PM';
                                            if (value == 24) label = '12 AM';

                                            if (label.isEmpty) {
                                              return const SizedBox.shrink();
                                            }

                                            final textWidget = Text(
                                              label,
                                              style: TextStyle(
                                                color: Colors.white.withValues(alpha: 0.8),
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            );

                                            // The "12 AM" ticks sit exactly at the left
                                            // (x = 0) and right (x = 24) edges of the
                                            // chart, so their centered labels get
                                            // clipped. Nudge them inward instead of
                                            // centering on the tick.
                                            if (value == 0) {
                                              return SideTitleWidget(
                                                meta: meta,
                                                space: 8,
                                                child: Transform.translate(
                                                  offset: const Offset(16, 0),
                                                  child: textWidget,
                                                ),
                                              );
                                            }

                                            if (value == 24) {
                                              return SideTitleWidget(
                                                meta: meta,
                                                space: 8,
                                                child: Transform.translate(
                                                  offset: const Offset(-16, 0),
                                                  child: textWidget,
                                                ),
                                              );
                                            }

                                            return SideTitleWidget(
                                              meta: meta,
                                              space: 8,
                                              child: textWidget,
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                    lineBarsData: [
                                      LineChartBarData(
                                        spots: _generateHourlySpots(),
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

                                // Loading / empty-state overlay for the hourly chart
                                if (_isLoadingHistory)
                                  const Positioned.fill(
                                    child: Center(
                                      child: SizedBox(
                                        height: 24,
                                        width: 24,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    ),
                                  )
                                else if (_hourlyKwh.isEmpty)
                                  Positioned.fill(
                                    child: Center(
                                      child: Text(
                                        _historyError ?? 'No data yet',
                                        style: TextStyle(
                                          color: Colors.white.withValues(alpha: 0.8),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
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
                    alignment: Alignment.topCenter,
                    // Fixed full-width wrapper so only height animates —
                    // otherwise width snaps in from the left, making the
                    // reveal look like it's growing out of the top-left corner.
                    child: SizedBox(
                      width: double.infinity,
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
        border: Border.all(
          color: Colors.grey.withValues(alpha: 0.35),
          width: 1,
        ),
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
                style: const TextStyle(
                  fontSize: 16,
                  color: Colors.black,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
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
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    unit,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[500],
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
          SizedBox(
            height: 60,
            width: 110,
            child: LineChart(
              LineChartData(
                gridData: const FlGridData(show: false),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                minY: _getMinY(history),
                maxY: _getMaxY(history),
                lineTouchData: const LineTouchData(enabled: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    curveSmoothness: 0.35,
                    color: primaryOrange,
                    barWidth: 2.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          primaryOrange.withValues(alpha: 0.35),
                          primaryOrange.withValues(alpha: 0.08),
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