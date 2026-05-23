import 'package:flutter/material.dart';

class BillingScreen extends StatelessWidget {
  const BillingScreen({super.key});

  final Color primaryOrange = const Color(0xFFF26E22);
  final Color lightOrangeBg = const Color(0xFFFA8B39);
  final Color creamBg = const Color(0xFFFFFDF9); 
  final Color textDark = const Color(0xFF1E1E1E);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: creamBg,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── TOP GRADIENT HERO SECTION ────────────────────────────────────
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    lightOrangeBg,
                    lightOrangeBg.withOpacity(0.7),
                    creamBg,
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
                  child: Column(
                    children: [
                      const SizedBox(height: 10),
                      Text(
                        'ESTIMATED MONTHLY BILL:',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.85),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '₱2,610.75',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 42,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '(Based on current consumption trajectory)',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.8),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 30),
                      
                      // Consumption Trajectory Split Row
                      Row(
                        children: [
                          Expanded(
                            child: _buildTrajectoryMetric(
                              icon: Icons.trending_up_rounded,
                              iconColor: Colors.greenAccent,
                              title: 'Current Consumption',
                              value: '165.20 kWh',
                            ),
                          ),
                          Container(
                            height: 35,
                            width: 1,
                            color: Colors.white.withOpacity(0.25),
                          ),
                          Expanded(
                            child: _buildTrajectoryMetric(
                              icon: Icons.trending_down_rounded,
                              iconColor: Colors.redAccent,
                              title: 'Projected Consumption',
                              value: '245.50 kWh',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 25),

                      // ── TIER 1 STATUS CARD WITH THE EXACT WAVE BACKGROUND ──
                      ClipRRect(
                        borderRadius: BorderRadius.circular(28),
                        child: Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: primaryOrange,
                            boxShadow: [
                              BoxShadow(
                                color: primaryOrange.withOpacity(0.25),
                                blurRadius: 15,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: CustomPaint(
                            painter: CardWavePainter(), // Draws the background curves
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
                                          color: Colors.white.withOpacity(0.9),
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
                                        text: const TextSpan(
                                          style: TextStyle(color: Colors.white),
                                          children: [
                                            TextSpan(
                                              text: '165.20 ',
                                              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                                            ),
                                            TextSpan(
                                              text: '/ 200',
                                              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const Text(
                                        '82.6%',
                                        style: TextStyle(
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
                                      color: Colors.white.withOpacity(0.75),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: LinearProgressIndicator(
                                      value: 0.826,
                                      backgroundColor: Colors.white.withOpacity(0.25),
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
                                          '34.80 kWh remaining before tier escalation',
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(0.95),
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
                    ],
                  ),
                ),
              ),
            ),

            // ── RATE BRACKETS SECTION ────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.only(left: 24.0, top: 16.0, bottom: 12.0),
              child: Text(
                'RATE BRACKETS',
                style: TextStyle(
                  color: textDark,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ),

            SizedBox(
              height: 145,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 18.0),
                physics: const BouncingScrollPhysics(),
                children: [
                  _buildRateCard(
                    tierTitle: 'TIER 1',
                    range: 'Up to 200 kWh',
                    rate: '₱0.9803/kWh',
                    isActive: true,
                  ),
                  _buildRateCard(
                    tierTitle: 'TIER 2',
                    range: '201–300 kWh',
                    rate: '₱1.2908/kWh',
                    isActive: false,
                  ),
                  _buildRateCard(
                    tierTitle: 'TIER 3',
                    range: '301–400 kWh',
                    rate: '₱1.5837/kWh',
                    isActive: false,
                  ),
                  _buildRateCard(
                    tierTitle: 'TIER 4',
                    range: 'Above 400 kWh',
                    rate: '₱2.0941/kWh',
                    isActive: false,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 120),
          ],
        ),
      ),
    );
  }

  Widget _buildTrajectoryMetric({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String value,
  }) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: iconColor, size: 14),
            const SizedBox(width: 4),
            Text(
              title,
              style: TextStyle(
                color: Colors.white.withOpacity(0.9),
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _buildRateCard({
    required String tierTitle,
    required String range,
    required String rate,
    required bool isActive,
  }) {
    final Color activeCardColor = const Color(0xFFFDB482); 
    final Color inactiveCardColor = const Color(0xFFEFE8DE); 

    return Container(
      width: 215,
      margin: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 4.0),
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      decoration: BoxDecoration(
        color: isActive ? activeCardColor : inactiveCardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.015),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
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
                  color: isActive ? Colors.white.withOpacity(0.9) : Colors.grey[600],
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (isActive)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.35),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '[ ACTIVE ]',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            range,
            style: TextStyle(
              color: isActive ? Colors.white : textDark.withOpacity(0.85),
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'RATE',
            style: TextStyle(
              color: isActive ? Colors.white.withOpacity(0.75) : Colors.grey[500],
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          Text(
            rate,
            style: TextStyle(
              color: isActive ? Colors.white : textDark,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

// ── CUSTOM PAINTER FOR BACKGROUND WAVES ──────────────────────────────────────
class CardWavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.06) // Smooth subtle light lines matching the image
      ..style = PaintingStyle.stroke
      ..strokeWidth = 28.0; // Thick smooth vector strokes

    // Path 1: Inner Wave running from left to bottom right
    final path1 = Path();
    path1.moveTo(-size.width * 0.2, size.height * 0.4);
    path1.cubicTo(
      size.width * 0.2, size.height * 0.2,
      size.width * 0.4, size.height * 0.8,
      size.width * 1.2, size.height * 0.7,
    );
    canvas.drawPath(path1, paint);

    // Path 2: Outer parallel shifting wave
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