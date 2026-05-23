import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  Timer? _timer;
  double _timeOffset = 0.0;
  
  // State for collapsible Advanced Metrics
  bool _isAdvancedMetricsExpanded = false;
  
  // Live numeric values
  double _currentWatts = 1450.0;
  double _currentAmps = 6.3;
  double _currentVoltage = 230.2;
  
  // Colors matching your system design
  final Color primaryOrange = const Color(0xFFF26E22);
  final Color darkButtonColor = const Color(0xFF3B150F);
  final Color bgColor = const Color(0xFFFAFAFA);
  final Color cardColor = Colors.white;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      setState(() {
        _timeOffset += 0.006;
        _currentWatts = 1450 + (math.sin(_timeOffset * 1.5) * 20);
        _currentAmps = 6.3 + (math.sin((_timeOffset * 2.0) + (math.pi / 2)) * 0.1);
        _currentVoltage = 230.2 + (math.sin((_timeOffset * 1.0) + math.pi) * 0.5);
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  List<FlSpot> _generateLiveStepSpots() {
    List<FlSpot> spots = [];
    double segmentWidth = 2.5;
    double offset = _timeOffset % segmentWidth;
    for (double x = -2.5; x <= 12.5; x += segmentWidth) {
      double currentX = x - offset;
      int stepIndex = ((x + _timeOffset) / segmentWidth).floor();
      double y = 4.0 + (stepIndex % 3) * 1.8 + math.sin(stepIndex.toDouble()) * 0.7;
      y = y.clamp(1.5, 9.0);
      spots.add(FlSpot(currentX, y));
    }
    spots.sort((a, b) => a.x.compareTo(b.x));
    return spots;
  }

  List<FlSpot> _generateLiveSpots(
      double frequency, double amplitude, double phase, double yOffset) {
    return List.generate(20, (index) {
      final x = index.toDouble();
      final y = math.sin((x * frequency) + (_timeOffset * 3.5) + phase) *
              amplitude +
          yOffset;
      return FlSpot(x, y);
    });
  }

  String _formatWithCommas(double value) {
    RegExp reg = RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))');
    String mathFunc(Match match) => '${match[1]},';
    return value.toStringAsFixed(0).replaceAllMapped(reg, mathFunc);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        bottom: false, // Allows the scroll content to flow perfectly past the bottom notch/navbar
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 10),
                
                // HEADER SECTION
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    const Text(
                      '342.85',
                      style: TextStyle(
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
                  '+2.4 kWh (0.7%) today',
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
                
                // MAIN STEPPED LIVE CHART
                SizedBox(
                  height: 160,
                  width: double.infinity,
                  child: LineChart(
                    LineChartData(
                      gridData: const FlGridData(show: false),
                      titlesData: const FlTitlesData(show: false),
                      borderData: FlBorderData(show: false),
                      minX: 0,
                      maxX: 10,
                      minY: 0,
                      maxY: 10,
                      lineBarsData: [
                        LineChartBarData(
                          spots: _generateLiveStepSpots(),
                          isCurved: false,
                          isStepLineChart: true,
                          color: primaryOrange,
                          barWidth: 3,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            gradient: LinearGradient(
                              colors: [
                                primaryOrange.withOpacity(0.25),
                                primaryOrange.withOpacity(0.0),
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
                        'ALL',
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
                  value: _formatWithCommas(_currentWatts),
                  unit: 'W',
                  subtitle: 'Normal range',
                  spots: _generateLiveSpots(0.4, 1.5, 0, 5),
                ),
                const SizedBox(height: 12),
                _buildLiveFeedCard(
                  title: 'Current',
                  value: _currentAmps.toStringAsFixed(1),
                  unit: 'A',
                  subtitle: 'Peak load: 8.2 A',
                  spots: _generateLiveSpots(0.6, 2.0, math.pi / 2, 4),
                ),
                const SizedBox(height: 12),
                _buildLiveFeedCard(
                  title: 'Voltage',
                  value: _currentVoltage.toStringAsFixed(1),
                  unit: 'V',
                  subtitle: 'Normal range',
                  spots: _generateLiveSpots(0.3, 1.0, math.pi, 6),
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
                        Icon(
                          _isAdvancedMetricsExpanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          color: Colors.grey[800],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                
                // ADVANCED METRICS CARDS (Collapsible)
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  child: _isAdvancedMetricsExpanded
                      ? Column(
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: _buildMetricCard(
                                      'Frequency', '60.0', 'Hz'),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _buildMetricCard(
                                      'Power Factor', '0.95', 'PF'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
                
                // Padding block ensures the content rolls cleanly above the floating navbar
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
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
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
                minX: 0,
                maxX: 19,
                minY: 0,
                maxY: 10,
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
                          primaryOrange.withOpacity(0.2),
                          primaryOrange.withOpacity(0.0),
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
            color: Colors.black.withOpacity(0.02),
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