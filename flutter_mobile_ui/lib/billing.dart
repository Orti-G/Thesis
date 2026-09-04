import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;
import 'package:lottie/lottie.dart';
import 'package:custom_refresh_indicator/custom_refresh_indicator.dart';

class BillingScreen extends StatelessWidget {
  BillingScreen({super.key});

  final Color primaryOrange = const Color(0xFFFCB775); // Jaffa 300 — main fill
  final Color tierCardBorder = const Color(0xFFFA8B39);
  final Color creamBg = const Color(0xFFFFFDF9);
  final Color textDark = const Color(0xFF1E1E1E);
  final Color brandOrangeText = const Color(0xFFE25319);
  final Color tierTextColor = const Color(0xFF7A3712); // Jaffa 700

  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();

  // ── FALLBACK RATES ───────────────────────────────────────────────────
  // Used only if `meralco_rates/brackets` hasn't loaded yet (e.g. first
  // frame before the stream emits, or the node is briefly missing) so the
  // UI never flashes ₱0.0000/kWh. Once the DB value arrives, these are
  // fully overridden — they are not a permanent rate source.
  static const Map<String, double> _fallbackRates = {
    '0-200': 0.9803,
    '201-300': 1.2908,
    '301-400': 1.5837,
    'over 400': 2.0941,
  };

  Future<void> _handleRefresh() async {
    final url = Uri.parse('http://35.209.250.46:8000/forecast');
    try {
      final response = await http.post(url);
      if (response.statusCode == 200) {
        debugPrint('Forecast successfully refreshed via API.');
      } else {
        debugPrint('API server returned an error: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error sending refresh request: $e');
    }
  }

  // ── Parse `meralco_rates/brackets` into a clean rate map ────────────────
  // Falls back per-key to _fallbackRates if a specific bracket is missing
  // or unparsable, rather than failing the whole map.
  Map<String, double> _parseRates(dynamic meralcoRatesNode) {
    final Map<String, double> rates = Map.of(_fallbackRates);
    if (meralcoRatesNode is Map) {
      final bracketsRaw = meralcoRatesNode['brackets'];
      if (bracketsRaw is Map) {
        bracketsRaw.forEach((key, value) {
          final parsed = double.tryParse(value.toString());
          if (parsed != null) {
            rates[key.toString()] = parsed;
          }
        });
      }
    }
    return rates;
  }

  String _parseEffectivePeriod(dynamic meralcoRatesNode) {
    if (meralcoRatesNode is Map) {
      final period = meralcoRatesNode['effective_period'];
      if (period != null && period.toString().isNotEmpty) {
        return period.toString();
      }
    }
    return '';
  }

  String _formatRate(Map<String, double> rates, String key) {
    final value = rates[key] ?? _fallbackRates[key] ?? 0.0;
    return '₱${value.toStringAsFixed(4)}/kWh';
  }

  // ── Tiered bill calculation using live bracket rates ────────────────────
  // Applies each portion of `kwh` to its own bracket rate rather than a
  // flat rate — e.g. 250 kWh is billed at the Tier-1 rate for the first
  // 200 kWh and the Tier-2 rate for the remaining 50 kWh.
  double _calculateBill(double kwh, Map<String, double> rates) {
    if (kwh <= 0) return 0.0;

    final r1 = rates['0-200'] ?? _fallbackRates['0-200']!;
    final r2 = rates['201-300'] ?? _fallbackRates['201-300']!;
    final r3 = rates['301-400'] ?? _fallbackRates['301-400']!;
    final r4 = rates['over 400'] ?? _fallbackRates['over 400']!;

    double bill = 0.0;

    final tier1Kwh = kwh > 200 ? 200 : kwh;
    bill += tier1Kwh * r1;

    if (kwh > 200) {
      final tier2Kwh = (kwh > 300 ? 300 : kwh) - 200;
      bill += tier2Kwh * r2;
    }
    if (kwh > 300) {
      final tier3Kwh = (kwh > 400 ? 400 : kwh) - 300;
      bill += tier3Kwh * r3;
    }
    if (kwh > 400) {
      final tier4Kwh = kwh - 400;
      bill += tier4Kwh * r4;
    }

    return bill;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: creamBg,
      body: StreamBuilder<DatabaseEvent>(
        stream: _dbRef.onValue,
        builder: (context, snapshot) {
          double estimatedMonthEnd = 0.0;
          double predictedDayTotal = 0.0;
          double cumulativeEnergy = 0.0;

          Map<String, double> rates = Map.of(_fallbackRates);
          String effectivePeriod = '';

          // New forecast-node fields (not yet wired into the UI, available if needed):
          // double accumulatedPast = 0.0;
          // double avgDaily = 0.0;
          // String billingCycleStart = '';
          // double combinedKWh = 0.0;
          // int daysRemaining = 0;
          // int daysSoFar = 0;
          // String forecastStatus = '';

          if (snapshot.hasData && snapshot.data?.snapshot.value != null) {
            final data = snapshot.data!.snapshot.value as Map<dynamic, dynamic>;

            final forecastData = data['forecast'] as Map<dynamic, dynamic>?;
            if (forecastData != null) {
              estimatedMonthEnd =
                  (forecastData['projected_eom_kWh'] ?? 0).toDouble();
              predictedDayTotal =
                  (forecastData['predicted_day_total_kWh'] ?? 0).toDouble();

              // accumulatedPast = (forecastData['accumulated_past_kWh'] ?? 0).toDouble();
              // avgDaily = (forecastData['avg_daily_kWh'] ?? 0).toDouble();
              // billingCycleStart = forecastData['billing_cycle_start'] ?? '';
              // combinedKWh = (forecastData['combined_kWh'] ?? 0).toDouble();
              // daysRemaining = (forecastData['days_remaining'] ?? 0).toInt();
              // daysSoFar = (forecastData['days_so_far'] ?? 0).toInt();
              // forecastStatus = forecastData['status'] ?? '';
            }

            final liveReading = data['live_reading'] as Map<dynamic, dynamic>?;
            if (liveReading != null) {
              cumulativeEnergy =
                  (liveReading['cumul_kWh'] ?? liveReading['cumul_kwh'] ?? 0)
                      .toDouble();
            }

            rates = _parseRates(data['meralco_rates']);
            effectivePeriod = _parseEffectivePeriod(data['meralco_rates']);
          }

          // ── ESTIMATED BILL: tiered calculation on the projected
          // end-of-month kWh, using the live bracket rates above. ─────────
          final double estimatedBillPeso =
              _calculateBill(estimatedMonthEnd, rates);

          String currentTierTitle = 'TIER 1 STATUS';
          String currentTierRate = _formatRate(rates, '0-200');
          double currentTierMax = 200.0;
          String remainingText = '';

          if (cumulativeEnergy <= 200) {
            currentTierTitle = 'TIER 1 STATUS';
            currentTierRate = _formatRate(rates, '0-200');
            currentTierMax = 200.0;
            double remaining = (200.0 - cumulativeEnergy).clamp(0.0, 200.0);
            remainingText =
                '${remaining.toStringAsFixed(2)} kWh na lang bago umakyat ang tier';
          } else if (cumulativeEnergy <= 300) {
            currentTierTitle = 'TIER 2 STATUS';
            currentTierRate = _formatRate(rates, '201-300');
            currentTierMax = 300.0;
            double remaining = (300.0 - cumulativeEnergy).clamp(0.0, 100.0);
            remainingText =
                '${remaining.toStringAsFixed(2)} kWh na lang bago umakyat ang tier';
          } else if (cumulativeEnergy <= 400) {
            currentTierTitle = 'TIER 3 STATUS';
            currentTierRate = _formatRate(rates, '301-400');
            currentTierMax = 400.0;
            double remaining = (400.0 - cumulativeEnergy).clamp(0.0, 100.0);
            remainingText =
                '${remaining.toStringAsFixed(2)} kWh na lang bago umakyat ang tier';
          } else {
            currentTierTitle = 'TIER 4 STATUS';
            currentTierRate = _formatRate(rates, 'over 400');
            currentTierMax = 400.0;
            remainingText = 'Naabot na ang pinakamataas na tier';
          }

          final double percentage = (cumulativeEnergy / currentTierMax).clamp(
            0.0,
            1.0,
          );

          return CustomMaterialIndicator(
            onRefresh: _handleRefresh,
            backgroundColor: Colors.white,
            indicatorBuilder: (context, controller) {
              return Padding(
                padding: const EdgeInsets.all(6.0),
                child: Lottie.asset(
                  'assets/spark loading.json',
                  width: 30,
                  height: 30,
                  fit: BoxFit.contain,
                ),
              );
            },
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      Image.asset(
                        'assets/billingbg.png',
                        width: double.infinity,
                        fit: BoxFit.fitWidth,
                      ),
                      SafeArea(
                        bottom: false,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24.0,
                            vertical: 20.0,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 5),
                              Row(
                                children: [
                                  Text(
                                    'END OF DAY CONSUMPTION',
                                    style: TextStyle(
                                      color: brandOrangeText.withValues(
                                        alpha: 0.85,
                                      ),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.6,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  GestureDetector(
                                    onTap: () {
                                      showModalBottomSheet(
                                        context: context,
                                        backgroundColor: Colors.white,
                                        shape: const RoundedRectangleBorder(
                                          borderRadius: BorderRadius.vertical(
                                            top: Radius.circular(20),
                                          ),
                                        ),
                                        builder: (context) => Padding(
                                          padding: const EdgeInsets.all(24.0),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Icon(
                                                    Icons.refresh_rounded,
                                                    color: brandOrangeText,
                                                    size: 18,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Text(
                                                    'Refresh forecast',
                                                    style: TextStyle(
                                                      color: textDark,
                                                      fontSize: 16,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 10),
                                              Text(
                                                'Pull down on this screen anytime to recalculate your forecast based on current consumption trajectory.',
                                                style: TextStyle(
                                                  color: textDark.withValues(
                                                    alpha: 0.7,
                                                  ),
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w500,
                                                  height: 1.4,
                                                ),
                                              ),
                                              const SizedBox(height: 12),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                    child: Icon(
                                      Icons.info_outline_rounded,
                                      size: 14,
                                      color: brandOrangeText.withValues(
                                        alpha: 0.5,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${predictedDayTotal.toStringAsFixed(2)} kWh',
                                style: TextStyle(
                                  color: brandOrangeText,
                                  fontSize: 44,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 10.0,
                        left: 24.0, // Added left padding anchor
                        right: 24.0, // Added right padding anchor
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            // LEFT SIDE: PROJECTED END OF MONTH
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start, // Align to left
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.trending_up_rounded,
                                      color: Colors.greenAccent,
                                      size: 15,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'PROJECTED END OF MONTH',
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.95),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${estimatedMonthEnd.toStringAsFixed(2)} kWh',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            // RIGHT SIDE: ESTIMATED BILL
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end, // Align to right
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.payments_rounded,
                                      color: Colors.greenAccent,
                                      size: 15,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'ESTIMATED BILL',
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.95),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '₱${estimatedBillPeso.toStringAsFixed(2)}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 20),
                        Text(
                          'TIER',
                          style: TextStyle(
                            color: brandOrangeText,
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(28),
                          child: Container(
                            width: double.infinity,
                            color: primaryOrange,
                            child: CustomPaint(
                              painter: CardCirclePainter(),
                              child: Padding(
                                padding: const EdgeInsets.all(22),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          currentTierTitle,
                                          style: TextStyle(
                                            color: tierTextColor,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                        Text(
                                          currentTierRate,
                                          style: TextStyle(
                                            color: tierTextColor.withValues(
                                              alpha: 0.95,
                                            ),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 20),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.baseline,
                                      textBaseline: TextBaseline.alphabetic,
                                      children: [
                                        RichText(
                                          text: TextSpan(
                                            style: TextStyle(
                                              color: tierTextColor,
                                            ),
                                            children: [
                                              TextSpan(
                                                text:
                                                    '${cumulativeEnergy.toStringAsFixed(2)} ',
                                                style: const TextStyle(
                                                  fontSize: 26,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                              TextSpan(
                                                text:
                                                    '/ ${currentTierMax.toStringAsFixed(0)}',
                                                style: const TextStyle(
                                                  fontSize: 20,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Text(
                                          '${(percentage * 100).toStringAsFixed(1)}%',
                                          style: TextStyle(
                                            color: tierTextColor,
                                            fontSize: 15,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'TOTAL KWH CONSUMPTION',
                                      style: TextStyle(
                                        color: tierTextColor.withValues(
                                          alpha: 0.75,
                                        ),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: LinearProgressIndicator(
                                        value: percentage,
                                        backgroundColor: Colors.white
                                            .withValues(alpha: 0.4),
                                        valueColor:
                                            const AlwaysStoppedAnimation<Color>(
                                          Colors.white,
                                        ),
                                        minHeight: 7,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    Row(
                                      children: [
                                        Icon(
                                          Icons.info_outline_rounded,
                                          color: tierTextColor,
                                          size: 15,
                                        ),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            remainingText,
                                            style: TextStyle(
                                              color: tierTextColor.withValues(
                                                alpha: 0.95,
                                              ),
                                              fontSize: 11,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24.0),
                          child: Divider(
                            color: textDark.withValues(alpha: 0.08),
                            thickness: 1,
                            height: 1,
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              'RATE BRACKETS',
                              style: TextStyle(
                                color: textDark,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                            if (effectivePeriod.isNotEmpty)
                              Text(
                                'Effective $effectivePeriod',
                                style: TextStyle(
                                  color: textDark.withValues(alpha: 0.45),
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 170,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 18.0),
                      physics: const BouncingScrollPhysics(),
                      children: [
                        _buildRateCard(
                          tierTitle: 'TIER 1',
                          range: 'Up to 200 kWh',
                          rate: _formatRate(rates, '0-200'),
                          isActive: cumulativeEnergy <= 200,
                        ),
                        _buildRateCard(
                          tierTitle: 'TIER 2',
                          range: '201 - 300 kWh',
                          rate: _formatRate(rates, '201-300'),
                          isActive:
                              cumulativeEnergy > 200 && cumulativeEnergy <= 300,
                        ),
                        _buildRateCard(
                          tierTitle: 'TIER 3',
                          range: '301 - 400 kWh',
                          rate: _formatRate(rates, '301-400'),
                          isActive:
                              cumulativeEnergy > 300 && cumulativeEnergy <= 400,
                        ),
                        _buildRateCard(
                          tierTitle: 'TIER 4',
                          range: 'Over 400 kWh',
                          rate: _formatRate(rates, 'over 400'),
                          isActive: cumulativeEnergy > 400,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 120),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRateCard({
    required String tierTitle,
    required String range,
    required String rate,
    required bool isActive,
  }) {
    final Color activeCardColor = const Color(0xFFFA8B39); // Jaffa 400
    final Color inactiveCardColor = const Color(0xFFFAEEDA); // soft cream
    final Color activeTextColor = Colors.white;
    final Color activeSubTextColor = Colors.white.withValues(alpha: 0.85);
    final Color inactiveTextColor = const Color(0xFF7A3712); // Jaffa 700
    final Color inactiveSubTextColor = const Color(
      0xFF7A3712,
    ).withValues(alpha: 0.55);

    return Container(
      width: 200,
      margin: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 4.0),
      padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 18.0),
      decoration: BoxDecoration(
        color: isActive ? activeCardColor : inactiveCardColor,
        borderRadius: BorderRadius.circular(20),
        border: isActive
            ? null
            : Border.all(
                color: const Color(0xFFFA8B39).withValues(alpha: 0.15),
                width: 1,
              ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                tierTitle,
                style: TextStyle(
                  color: isActive ? activeSubTextColor : inactiveSubTextColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
              if (isActive)
                Container(
                  width: 20,
                  height: 20,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.bolt_rounded,
                    size: 13,
                    color: activeCardColor,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            range,
            style: TextStyle(
              color: isActive ? activeTextColor : inactiveTextColor,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            height: 1,
            color: isActive
                ? Colors.white.withValues(alpha: 0.25)
                : const Color(0xFFFA8B39).withValues(alpha: 0.15),
          ),
          const SizedBox(height: 12),
          Text(
            'RATE',
            style: TextStyle(
              color: isActive ? activeSubTextColor : inactiveSubTextColor,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            rate,
            style: TextStyle(
              color: isActive ? activeTextColor : inactiveTextColor,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class CardCirclePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFA8B39).withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final center1 = Offset(size.width * 1.05, size.height * 1.15);
    for (double radius in [50, 85, 120, 155, 190]) {
      canvas.drawCircle(center1, radius, paint);
    }

    final center2 = Offset(size.width * -0.1, size.height * -0.2);
    for (double radius in [40, 70, 100, 130]) {
      canvas.drawCircle(center2, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}