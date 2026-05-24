import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart'; 

class BillingScreen extends StatelessWidget {
  BillingScreen({super.key});

  final Color primaryOrange = const Color(0xFFF26E22);
  final Color creamBg = const Color(0xFFFFFDF9);
  final Color textDark = const Color(0xFF1E1E1E);
  final Color brandOrangeText = const Color(0xFFE25319);

  // Reference to the root of your Realtime Database
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: creamBg,
      body: StreamBuilder<DatabaseEvent>(
        stream: _dbRef.onValue,
        builder: (context, snapshot) {
          // Default fallback values
          double forecast = 0.0;
          double cumulativeEnergy = 0.0;

          // Safely extract data if it exists
          if (snapshot.hasData && snapshot.data?.snapshot.value != null) {
            final data = snapshot.data!.snapshot.value as Map<dynamic, dynamic>;
            
            // Remapped forecast to predicted_day_total_kwh
            final forecastData = data['forecast'] as Map<dynamic, dynamic>?;
            if (forecastData != null) {
              forecast = (forecastData['predicted_day_total_kwh'] ?? 0).toDouble();
            }
            
            // Remapped cumulative energy to cumul_kwh
            final liveReading = data['live_reading'] as Map<dynamic, dynamic>?;
            if (liveReading != null) {
              cumulativeEnergy = (liveReading['cumul_kwh'] ?? 0).toDouble();
            }
          }

          // Calculate dynamic tier values based on a 200 kWh limit
          final double percentage = (cumulativeEnergy / 200).clamp(0.0, 1.0);
          final double remaining = (200 - cumulativeEnergy).clamp(0.0, 200.0);

          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── TOP HERO SECTION WITH PNG BACKGROUND ─────────────────────────
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
                        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 10),
                            Text(
                              'ESTIMATED END OF THE DAY BILL:',
                              style: TextStyle(
                                color: brandOrangeText.withValues(alpha: 0.9),
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '(Based on current consumption trajectory)',
                              style: TextStyle(
                                color: const Color(0xFFBA7A5F).withValues(alpha: 0.8),
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 12),
                            // MAPPED FORECAST
                            Text(
                              '₱${forecast.toStringAsFixed(2)}',
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
                      right: 24.0,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
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
                                'Current Consumption',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.95),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          // MAPPED CUMULATIVE ENERGY
                          Text(
                            '${cumulativeEnergy.toStringAsFixed(2)} kWh',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                // ── MAIN CONTENT BODY ────────────────────────────────────────────
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
                            painter: CardWavePainter(),
                            child: Padding(
                              padding: const EdgeInsets.all(22),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text(
                                        'TIER 1 STATUS',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                      Text(
                                        '₱0.9803/kWh',
                                        style: TextStyle(
                                          color: Colors.white.withValues(alpha: 0.9),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 20),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    crossAxisAlignment: CrossAxisAlignment.baseline,
                                    textBaseline: TextBaseline.alphabetic,
                                    children: [
                                      RichText(
                                        text: TextSpan(
                                          style: const TextStyle(color: Colors.white),
                                          children: [
                                            // DYNAMIC CONSUMPTION FOR TIER
                                            TextSpan(
                                              text: '${cumulativeEnergy.toStringAsFixed(2)} ',
                                              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                                            ),
                                            const TextSpan(
                                              text: '/ 200',
                                              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                                            ),
                                          ],
                                        ),
                                      ),
                                      // DYNAMIC PERCENTAGE
                                      Text(
                                        '${(percentage * 100).toStringAsFixed(1)}%',
                                        style: const TextStyle(
                                          color: Colors.white,
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
                                      color: Colors.white.withValues(alpha: 0.75),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: LinearProgressIndicator(
                                      value: percentage, // DYNAMIC PROGRESS BAR
                                      backgroundColor: Colors.white.withValues(alpha: 0.25),
                                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                                      minHeight: 7,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.info_outline_rounded,
                                        color: Colors.white,
                                        size: 15,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          // DYNAMIC REMAINING KWH
                                          '${remaining.toStringAsFixed(2)} kWh remaining before tier escalation',
                                          style: TextStyle(
                                            color: Colors.white.withValues(alpha: 0.95),
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
                      const SizedBox(height: 28),
                      Text(
                        'RATE BRACKETS',
                        style: TextStyle(
                          color: textDark,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 155,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 18.0),
                    physics: const BouncingScrollPhysics(),
                    children: [
                      _buildRateCard(
                        tierTitle: 'TIER 1',
                        range: 'Up to 200 kWh',
                        rate: '₱0.9803/kWh',
                        isActive: cumulativeEnergy <= 200, // DYNAMIC ACTIVE STATE
                      ),
                      _buildRateCard(
                        tierTitle: 'TIER 2',
                        range: '201 - 300 kWh',
                        rate: '₱1.2908/kWh',
                        isActive: cumulativeEnergy > 200 && cumulativeEnergy <= 300, 
                      ),
                      _buildRateCard(
                        tierTitle: 'TIER 3',
                        range: '301 - 400 kWh',
                        rate: '₱1.5837/kWh',
                        isActive: cumulativeEnergy > 300, 
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 60),
              ],
            ),
          );
        }
      ),
    );
  }

  Widget _buildRateCard({
    required String tierTitle,
    required String range,
    required String rate,
    required bool isActive,
  }) {
    final Color activeCardColor = const Color(0xFFFDB482);
    final Color inactiveCardColor = const Color(0xFFF6EDE2);
    final Color activeTextColor = const Color(0xFF432511);
    final Color inactiveTextColor = const Color(0xFF7A726A);

    return Container(
      width: 215,
      margin: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 4.0),
      padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 16.0),
      decoration: BoxDecoration(
        color: isActive ? activeCardColor : inactiveCardColor,
        borderRadius: BorderRadius.circular(20),
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
                  color: isActive ? activeTextColor.withValues(alpha: 0.8) : inactiveTextColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (isActive)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    border: Border.all(color: activeTextColor.withValues(alpha: 0.4), width: 1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '[ ACTIVE ]',
                    style: TextStyle(
                      color: activeTextColor,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            range,
            style: TextStyle(
              color: isActive ? activeTextColor : textDark,
              fontSize: 19,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'RATE',
            style: TextStyle(
              color: isActive ? activeTextColor.withValues(alpha: 0.6) : inactiveTextColor.withValues(alpha: 0.8),
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          Text(
            rate,
            style: TextStyle(
              color: isActive ? activeTextColor : textDark,
              fontSize: 19,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class CardWavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 28.0;

    final path1 = Path();
    path1.moveTo(-size.width * 0.2, size.height * 0.4);
    path1.cubicTo(
      size.width * 0.2, size.height * 0.2,
      size.width * 0.4, size.height * 0.8,
      size.width * 1.2, size.height * 0.7,
    );
    canvas.drawPath(path1, paint);

    final path2 = Path();
    path2.moveTo(-size.width * 0.1, size.height * 0.6);
    path2.cubicTo(
      size.width * 0.3, size.height * 0.4,
      size.width * 0.5, size.height * 1.1,
      size.width * 1.3, size.height * 0.9,
    );
    canvas.drawPath(path2, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}