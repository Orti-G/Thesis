import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

class AdvisoriesScreen extends StatelessWidget {
  AdvisoriesScreen({super.key});

  final Color primaryOrange = const Color(0xFFF26E22);
  final Color lightOrangeBg = const Color(0xFFFA8B39);
  final Color creamBg = const Color(0xFFFFFDF9);
  final Color textDark = const Color(0xFF1E1E1E);
  final Color upText = const Color(0xFFE53935);
  final Color upBg = const Color(0xFFFFEBEE);
  final Color downText = const Color(0xFF2E7D32);
  final Color downBg = const Color(0xFFE8F5E9);

  // TODO: replace with real per-day totals (Firebase / FastAPI), same
  // pattern as Dashboard's _weeklyKwhPlaceholder. Last entry = today.
  final List<double> _thisWeek = const [5.8, 6.4, 7.1, 5.2, 8.0, 9.0, 7.4];
  final List<double> _lastWeek = const [6.0, 5.9, 6.5, 6.1, 7.0, 7.8, 6.9];
  final List<String> _weekDayLabels = const [
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'
  ];

  double get _thisWeekTotal => _thisWeek.reduce((a, b) => a + b);
  double get _lastWeekTotal => _lastWeek.reduce((a, b) => a + b);
  double get _dailyAverage => _thisWeekTotal / _thisWeek.length;
  double get _pctChange =>
      _lastWeekTotal == 0 ? 0 : ((_thisWeekTotal - _lastWeekTotal) / _lastWeekTotal) * 100;

  @override
  Widget build(BuildContext context) {
    final isUp = _pctChange >= 0;

    return Scaffold(
      backgroundColor: creamBg,
      body: Stack(
        children: [
          // ── FIXED BACKGROUND GRADIENT LAYER ─────────────────────────────
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    lightOrangeBg,
                    lightOrangeBg.withValues(alpha: 0.6),
                    creamBg,
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.4, 1.0],
                ),
              ),
            ),
          ),

          // ── SCROLLABLE CONTENTS LAYER ───────────────────────────────────
          Positioned.fill(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── TOP HERO SECTION ──────
                  SizedBox(
                    width: double.infinity,
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24.0, vertical: 20.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 10),
                            const Text(
                              'Advisories',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Weekly consumption insights',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // ── STAT TILES: DAILY AVG + WEEK-OVER-WEEK ──────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: _buildStatTile(
                            label: 'Daily Average',
                            value: '${_dailyAverage.toStringAsFixed(1)}',
                            unit: 'kWh/day',
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildComparisonTile(
                            isUp: isUp,
                            pct: _pctChange,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ── WEEKLY BAR CHART CARD ────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24.0, 16.0, 24.0, 8.0),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.03),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Weekly Consumption',
                            style: TextStyle(
                              color: textDark,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Last 7 days',
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            height: 180,
                            child: _buildWeeklyBarChart(),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 120),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── STAT TILE: simple label/value card ──────────────────────────────────
  Widget _buildStatTile({
    required String label,
    required String value,
    required String unit,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 12,
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
                style: TextStyle(
                  color: textDark,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                unit,
                style: TextStyle(
                  color: Colors.grey[500],
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── STAT TILE: week-over-week comparison with up/down badge ─────────────
  Widget _buildComparisonTile({required bool isUp, required double pct}) {
    final badgeColor = isUp ? upText : downText;
    final badgeBg = isUp ? upBg : downBg;
    final icon = isUp ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'vs Last Week',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: badgeColor, size: 13),
                    const SizedBox(width: 2),
                    Text(
                      '${pct.abs().toStringAsFixed(1)}%',
                      style: TextStyle(
                        color: badgeColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── WEEKLY BAR CHART (placeholder data) ─────────────────────────────────
  Widget _buildWeeklyBarChart() {
    final maxVal = _thisWeek.reduce((a, b) => a > b ? a : b);
    final maxY = maxVal == 0 ? 1.0 : maxVal * 1.3;
    final midY = maxY / 2;
    final todayIndex = _thisWeek.length - 1;

    return BarChart(
      BarChartData(
        minY: 0,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: midY == 0 ? 1 : midY,
          getDrawingHorizontalLine: (value) => FlLine(
            color: Colors.grey.withValues(alpha: 0.15),
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        barTouchData: BarTouchData(
          enabled: true,
          touchTooltipData: BarTouchTooltipData(
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              return BarTooltipItem(
                '${_weekDayLabels[groupIndex]}\n${rod.toY.toStringAsFixed(2)} kWh',
                const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              );
            },
          ),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (value, meta) {
                final index = value.toInt();
                if (index < 0 || index >= _weekDayLabels.length) {
                  return const SizedBox.shrink();
                }
                final isToday = index == todayIndex;
                return SideTitleWidget(
                  meta: meta,
                  space: 8,
                  child: Text(
                    _weekDayLabels[index],
                    style: TextStyle(
                      color: isToday ? textDark : Colors.grey[500],
                      fontSize: 11,
                      fontWeight: isToday ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        barGroups: List.generate(_thisWeek.length, (i) {
          final isToday = i == todayIndex;
          return BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: _thisWeek[i],
                color: isToday ? primaryOrange : primaryOrange.withValues(alpha: 0.35),
                width: 22,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(6),
                  topRight: Radius.circular(6),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}