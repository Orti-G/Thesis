import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

class AlertsScreen extends StatelessWidget {
  AlertsScreen({super.key});

  final Color primaryOrange = const Color(0xFFF26E22);
  final Color lightOrangeBg = const Color(0xFFFA8B39);
  final Color creamBg = const Color(0xFFFFFDF9);
  final Color textDark = const Color(0xFF1E1E1E);
  final Color criticalText = const Color(0xFFE53935);
  final Color criticalBg = const Color(0xFFFFEBEE);
  final Color safeText = const Color(0xFF2E7D32);
  final Color safeBg = const Color(0xFFE8F5E9);

  // Reference to the 'anomaly_alert' node in Firebase Realtime Database
  final DatabaseReference _anomalyRef =
      FirebaseDatabase.instance.ref().child('anomaly_alert');

  @override
  Widget build(BuildContext context) {
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
                              'Alerts & Anomalies',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Real-time system deviations',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 24),

                            // ── FIREBASE STREAM BUILDER ──────────────────
                            StreamBuilder<DatabaseEvent>(
                              stream: _anomalyRef.onValue,
                              builder: (context, snapshot) {
                                if (snapshot.connectionState ==
                                    ConnectionState.waiting) {
                                  return const Center(
                                    child: Padding(
                                      padding: EdgeInsets.all(20.0),
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                      ),
                                    ),
                                  );
                                }

                                if (snapshot.hasError ||
                                    !snapshot.hasData ||
                                    snapshot.data?.snapshot.value == null) {
                                  return _buildSafeCard(); // Default to safe if no data
                                }

                                // Parse Firebase Data
                                final data = snapshot.data!.snapshot.value
                                    as Map<dynamic, dynamic>;
                                final bool isAnomaly =
                                    data['is_anomaly'] ?? false;
                                
                                if (isAnomaly) {
                                  return _buildCriticalCard(data);
                                } else {
                                  return _buildSafeCard();
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // ── NOTIFICATIONS FEED LIST SECTION ────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24.0, vertical: 8.0),
                    child: Container(
                      width: double.infinity,
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
                          Padding(
                            padding: const EdgeInsets.only(
                                left: 20.0,
                                right: 20.0,
                                top: 22.0,
                                bottom: 6.0),
                            child: Text(
                              'Notifications Feed',
                              style: TextStyle(
                                color: textDark,
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          _buildNotificationItem(
                            icon: Icons.trending_up_rounded,
                            title: 'Babala sa Pagtaas ng Tier',
                            timestamp: '5m',
                            description:
                                'Papalapit ka na sa Tier 2 batay sa kasalukuyang paggamit.',
                          ),
                          _buildNotificationItem(
                            icon: Icons.eco_outlined,
                            title: 'Araw-araw na Ulat',
                            timestamp: 'Kahapon',
                            description:
                                'Bumuti ng 5% ang iyong energy efficiency kahapon kumpara sa lingguhang average.',
                          ),
                          Divider(
                              color: Colors.grey[100],
                              height: 1,
                              thickness: 1),
                          InkWell(
                            onTap: () {},
                            borderRadius: const BorderRadius.only(
                              bottomLeft: Radius.circular(24),
                              bottomRight: Radius.circular(24),
                            ),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(vertical: 18),
                              alignment: Alignment.center,
                              child: Text(
                                'View All History',
                                style: TextStyle(
                                  color: textDark,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
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

  // ── CRITICAL ANOMALY WIDGET (is_anomaly == true) ────────────────────────
  Widget _buildCriticalCard(Map<dynamic, dynamic> data) {
    final powerAvg = data['power_avg'] ?? 0;
    final score = data['score'] ?? 0.0;
    
    // Attempt to format timestamp safely
    String timeString = "Just now";
    if (data['timestamp'] != null) {
      try {
        DateTime parsedTime = DateTime.parse(data['timestamp'].toString());
        timeString = "${parsedTime.hour}:${parsedTime.minute.toString().padLeft(2, '0')}";
      } catch (e) {
        timeString = "Just now";
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFFFE0B2), width: 1),
            ),
            child: Icon(
              Icons.warning_amber_rounded,
              color: primaryOrange,
              size: 24,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: criticalBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'CRITICAL',
                  style: TextStyle(
                    color: criticalText,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                timeString,
                style: TextStyle(
                  color: Colors.grey[500],
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Critical Anomaly Detected',
            style: TextStyle(
              color: textDark,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          // Mapping real-time database variables here
          Text(
            'A deviation has been detected outside typical operating patterns.\nPower Avg: $powerAvg W\nAnomaly Score: ${score.toStringAsFixed(2)}',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 14,
              height: 1.4,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FA),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Was this expected?',
                  style: TextStyle(
                    color: textDark,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: ElevatedButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.search_rounded, size: 18),
                    label: const Text('No, investigate'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryOrange,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: OutlinedButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.check_circle_outline_rounded,
                        size: 18),
                    label: const Text('Yes, it was me'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: textDark,
                      side: BorderSide(color: Colors.grey[300]!, width: 1.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      backgroundColor: Colors.white,
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── SAFE WIDGET (is_anomaly == false) ──────────────────────────────────
  Widget _buildSafeCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: safeBg,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.check_circle_rounded,
              color: safeText,
              size: 32,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'All Clear',
            style: TextStyle(
              color: textDark,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'No anomalies detected for now.\nSystem is operating optimally.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 14,
              height: 1.4,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotificationItem({
    required IconData icon,
    required String title,
    required String timestamp,
    required String description,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0xFFF8F9FA), width: 1.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              color: Color(0xFFF4F5F7),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: const Color(0xFF5F6368), size: 18),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: textDark,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      timestamp,
                      style: TextStyle(
                        color: Colors.grey[400],
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontSize: 12.5,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}