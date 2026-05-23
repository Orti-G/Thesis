import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_database/firebase_database.dart';

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

  // Chart History Arrays (keeps the last 20 data points)
  final int maxDataPoints = 20;
  late List<double> _energyHistory; // For cumulative energy (kWh)
  late List<double> _wattsHistory;
  late List<double> _ampsHistory;
  late List<double> _voltageHistory;
  
  // Colors matching your system design
  final Color primaryOrange = const Color(0xFFF26E22);
  final Color darkButtonColor = const Color(0xFF3B150F);
  final Color bgColor = const Color(0xFFFAFAFA);
  final Color cardColor = Colors.white;

  @override
  void initState() {
    super.initState();
    
    // Initialize history arrays with zeros and make them GROWABLE
    _energyHistory = List.filled(maxDataPoints, 0.0, growable: true);
    _wattsHistory = List.filled(maxDataPoints, 0.0, growable: true);
    _ampsHistory = List.filled(maxDataPoints, 0.0, growable: true);
    _voltageHistory = List.filled(maxDataPoints, 0.0, growable: true);

    _setupFirebaseListener();

    // Timer to update charts every 2 seconds
    _timer = Timer.periodic(const Duration(seconds: 2), (timer) {
      setState(() {
        // Shift data to the left and append the newest live reading
        if (_energyHistory.length >= maxDataPoints) {
          _energyHistory.removeAt(0);
        }
        _energyHistory.add(_cumulativeEnergy);

        if (_wattsHistory.length >= maxDataPoints) {
          _wattsHistory.removeAt(0);
        }
        _wattsHistory.add(_currentWatts);

        if (_ampsHistory.length >= maxDataPoints) {
          _ampsHistory.removeAt(0);
        }
        _ampsHistory.add(_currentAmps);

        if (_voltageHistory.length >= maxDataPoints) {
          _voltageHistory.removeAt(0);
        }
        _voltageHistory.add(_currentVoltage);
      });
    });
  }

  void _setupFirebaseListener() {
    // Reference to your specific Firebase Realtime Database node
    DatabaseReference ref = FirebaseDatabase.instance.ref('live_reading');
    
    _dbSubscription = ref.onValue.listen((event) {
      if (event.snapshot.value != null) {
        final data = event.snapshot.value as Map<dynamic, dynamic>;
        
        setState(() {
          // Parse values safely, defaulting to 0.0 if missing
          // Match exact Firebase field names from your database
          _currentWatts = (data['active_power_W'] ?? 0).toDouble();
          _cumulativeEnergy = (data['cumulative_energy_kWh'] ?? 0).toDouble();
          _currentAmps = (data['current_A'] ?? 0).toDouble();
          _frequency = (data['frequency_Hz'] ?? 0).toDouble();
          _powerFactor = (data['power_factor'] ?? 0).toDouble();
          _currentVoltage = (data['voltage_V'] ?? 0).toDouble();
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _dbSubscription?.cancel();
    super.dispose();
  }

  // Helper to convert historical double arrays into FlSpots for the charts
  List<FlSpot> _generateChartSpots(List<double> history) {
    return history.asMap().entries.map((e) {
      return FlSpot(e.key.toDouble(), e.value);
    }).toList();
  }

  // Calculate min and max for dynamic chart scaling
  double _getMinY(List<double> history) {
    if (history.isEmpty) return 0;
    double min = history.reduce((a, b) => a < b ? a : b);
    // Add 20% padding below
    return (min * 0.8).clamp(0, double.infinity);
  }

  double _getMaxY(List<double> history) {
    if (history.isEmpty) return 1;
    double max = history.reduce((a, b) => a > b ? a : b);
    // Add 20% padding above
    return max * 1.2;
  }

  String _formatWithCommas(double value) {
    RegExp reg = RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))');
    String mathFunc(Match match) => '${match[1]},';
    return value.toStringAsFixed(2).replaceAllMapped(reg, mathFunc);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 10),
                
                // HEADER SECTION (Cumulative Energy)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      _formatWithCommas(_cumulativeEnergy),
                      style: const TextStyle(
                        fontSize: 44,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'kWh',
                      style: TextStyle(fontSize: 20, color: Colors.black),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.visibility_off_outlined,
                        size: 20, color: Colors.grey[700]),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Live Update Mode Active',
                  style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[800],
                      fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 4),
                Text(
                  'TOTAL ENERGY CONSUMPTION (KWH)',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5),
                ),
                const SizedBox(height: 25),
                
                // MAIN STEPPED LIVE CHART (Cumulative Energy / kWh)
                SizedBox(
                  height: 160,
                  width: double.infinity,
                  child: LineChart(
                    LineChartData(
                      gridData: const FlGridData(show: false),
                      titlesData: const FlTitlesData(show: false),
                      borderData: FlBorderData(show: false),
                      minY: _getMinY(_energyHistory),
                      maxY: _getMaxY(_energyHistory),
                      lineBarsData: [
                        LineChartBarData(
                          spots: _generateChartSpots(_energyHistory),
                          isCurved: false,
                          isStepLineChart: true,
                          color: primaryOrange,
                          barWidth: 3,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            gradient: LinearGradient(
                              colors: [
                                primaryOrange.withValues(alpha: 0.25),
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
                const SizedBox(height: 20),
                
                // TIME SELECTORS
                Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    _buildTimeTab('1M'),
                    _buildTimeTab('3M'),
                    _buildTimeTab('6M'),
                    _buildTimeTab('1Y'),
                    const SizedBox(width: 20),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: darkButtonColor,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'LIVE',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 40),
                
                // LIVE FEED HEADER
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'LIVE FEED',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5),
                    ),
                    Icon(Icons.menu, color: Colors.grey[800]),
                  ],
                ),
                const SizedBox(height: 16),
                
                // LIVE FEED CARDS
                _buildLiveFeedCard(
                  title: 'Watts',
                  value: _currentWatts.toStringAsFixed(0),
                  unit: 'W',
                  subtitle: 'Active Power',
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
                  subtitle: 'Mains Line Voltage',
                  spots: _generateChartSpots(_voltageHistory),
                  history: _voltageHistory,
                ),
                const SizedBox(height: 30),
                
                // ADVANCED METRICS COLLAPSIBLE HEADER
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _isAdvancedMetricsExpanded = !_isAdvancedMetricsExpanded;
                    });
                  },
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
                              letterSpacing: 0.5),
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
                
                // ADVANCED METRICS CARDS (Collapsible)
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
                                      'Frequency', _frequency.toStringAsFixed(1), 'Hz'),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _buildMetricCard(
                                      'Power Factor', _powerFactor.toStringAsFixed(2), 'PF'),
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
        ),
      ),
    );
  }

  // ── UI WIDGET HELPERS ──────────────────────────────────────────────────────
  Widget _buildTimeTab(String text) {
    return Padding(
      padding: const EdgeInsets.only(right: 24.0),
      child: Text(
        text,
        style: TextStyle(
            color: Colors.grey[500],
            fontSize: 13,
            fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildLiveFeedCard({
    required String title,
    required String value,
    required String unit,
    required String subtitle,
    required List<FlSpot> spots,
    required List<double> history,
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
              Text(title,
                  style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey[800],
                      fontWeight: FontWeight.w600)),
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
                        letterSpacing: -0.5),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    unit,
                    style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[800],
                        fontWeight: FontWeight.w500),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style:
                    TextStyle(fontSize: 11, color: Colors.grey[600]),
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

  Widget _buildMetricCard(String title, String value, String unit) {
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
          Text(title,
              style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[800],
                  fontWeight: FontWeight.w600)),
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
                    letterSpacing: -0.5),
              ),
              const SizedBox(width: 4),
              Text(
                unit,
                style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[800],
                    fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ],
      ),
    );
  }
}