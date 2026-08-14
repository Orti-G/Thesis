import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const String kApiBaseUrl = 'http://35.209.250.46:8000';

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  final Color primaryOrange = const Color(0xFFF26E22);
  final Color lightOrangeBg = const Color(0xFFFA8B39);
  final Color creamBg = const Color(0xFFFFFDF9);
  final Color textDark = const Color(0xFF1E1E1E);
  final Color criticalText = const Color(0xFFE53935);
  final Color criticalBg = const Color(0xFFFFEBEE);
  final Color safeText = const Color(0xFF2E7D32);
  final Color safeBg = const Color(0xFFE8F5E9);

  // ── ANOMALIES: now sourced from GET /anomaly-logs/pending ───────────────
  List<Map<String, dynamic>> _anomalyEntries = [];
  bool _loadingAnomalies = true;
  String? _anomalyError;

  // Which log id is currently mid-acknowledge (disables its buttons/shows spinner).
  int? _acknowledgingId;

  // ── PLACEHOLDER: GENERAL NOTIFICATIONS LOG (no endpoint given yet) ──────
  final List<Map<String, dynamic>> _logEntries = const [
    {
      'icon': Icons.trending_up_rounded,
      'title': 'Babala sa Pagtaas ng Tier',
      'timestamp': '5m',
      'description':
          'Papalapit ka na sa Tier 2 batay sa kasalukuyang paggamit.',
    },
    {
      'icon': Icons.eco_outlined,
      'title': 'Araw-araw na Ulat',
      'timestamp': 'Kahapon',
      'description':
          'Bumuti ng 5% ang iyong energy efficiency kahapon kumpara sa lingguhang average.',
    },
  ];

  @override
  void initState() {
    super.initState();
    _fetchPendingAnomalies();
  }

  Future<void> _fetchPendingAnomalies() async {
    setState(() {
      _loadingAnomalies = true;
      _anomalyError = null;
    });

    try {
      final res = await http
          .get(Uri.parse('$kApiBaseUrl/anomaly-logs/pending'))
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) {
        throw Exception('Server returned ${res.statusCode}');
      }

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = (body['data'] as List).cast<Map<String, dynamic>>();

      setState(() {
        _anomalyEntries = data;
        _loadingAnomalies = false;
      });
    } catch (e) {
      setState(() {
        _anomalyError = 'Failed to load anomalies: $e';
        _loadingAnomalies = false;
      });
    }
  }

  /// acknowledged = true  -> real anomaly ("No, investigate")
  /// acknowledged = false -> false alarm  ("Yes, it was me")
  Future<void> _acknowledgeAnomaly(int logId, bool acknowledged) async {
    setState(() => _acknowledgingId = logId);

    try {
      final res = await http
          .patch(
            Uri.parse('$kApiBaseUrl/anomaly-logs/$logId/acknowledge'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'acknowledged': acknowledged}),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) {
        throw Exception('Server returned ${res.statusCode}');
      }

      // Acknowledged rows drop out of the /pending list, so remove locally.
      setState(() {
        _anomalyEntries.removeWhere((e) => e['id'] == logId);
        _acknowledgingId = null;
      });

      if (mounted) {
        Navigator.of(context).pop(); // close the modal sheet
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              acknowledged
                  ? 'Marked as a real anomaly.'
                  : 'Marked as a false alarm.',
            ),
          ),
        );
      }
    } catch (e) {
      setState(() => _acknowledgingId = null);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update: $e')),
        );
      }
    }
  }

  static const List<String> _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _formatFullDateTime(dynamic raw) {
    if (raw == null) return 'Just now';
    try {
      final parsed = DateTime.parse(raw.toString());
      final hh = parsed.hour.toString().padLeft(2, '0');
      final mm = parsed.minute.toString().padLeft(2, '0');
      final month = _monthNames[parsed.month - 1];
      return '$month ${parsed.day}, ${parsed.year} · $hh:$mm';
    } catch (_) {
      return raw.toString();
    }
  }

  String _formatTimestamp(dynamic raw) {
    if (raw == null) return '';
    try {
      final parsed = DateTime.parse(raw.toString());
      final now = DateTime.now();
      final sameDay = parsed.year == now.year &&
          parsed.month == now.month &&
          parsed.day == now.day;
      final hh = parsed.hour.toString().padLeft(2, '0');
      final mm = parsed.minute.toString().padLeft(2, '0');
      if (sameDay) return '$hh:$mm';
      final sameYear = parsed.year == now.year;
      final month = _monthNames[parsed.month - 1];
      return sameYear
          ? '$month ${parsed.day}'
          : '$month ${parsed.day}, ${parsed.year}';
    } catch (_) {
      return raw.toString();
    }
  }

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
            child: RefreshIndicator(
              onRefresh: _fetchPendingAnomalies,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics()),
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
                              const SizedBox(height: 8),
                            ],
                          ),
                        ),
                      ),
                    ),

                    // ── ANOMALIES LOG SECTION ────────────────────────────────
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
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Anomalies',
                                    style: TextStyle(
                                      color: textDark,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  if (_loadingAnomalies)
                                    SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: primaryOrange,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (_anomalyError != null)
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(20, 8, 20, 22),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        _anomalyError!,
                                        style: TextStyle(
                                          color: criticalText,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: _fetchPendingAnomalies,
                                      child: const Text('Retry'),
                                    ),
                                  ],
                                ),
                              )
                            else if (!_loadingAnomalies &&
                                _anomalyEntries.isEmpty)
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(20, 8, 20, 22),
                                child: Text(
                                  'No anomalies detected yet.',
                                  style: TextStyle(
                                    color: Colors.grey[500],
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              )
                            else
                              for (final entry in _anomalyEntries)
                                _buildAnomalyItem(context, entry: entry),
                            const SizedBox(height: 6),
                          ],
                        ),
                      ),
                    ),

                    // ── GENERAL LOGS SECTION ─────────────────────────────────
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
                                'Logs',
                                style: TextStyle(
                                  color: textDark,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            for (final entry in _logEntries)
                              _buildLogItem(entry: entry),
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
                                padding:
                                    const EdgeInsets.symmetric(vertical: 18),
                                alignment: Alignment.center,
                                child: Text(
                                  'View All Logs',
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
          ),
        ],
      ),
    );
  }

  // ── ANOMALIES LOG ITEM (tappable → opens modal) ──────────────────────────
  Widget _buildAnomalyItem(
    BuildContext context, {
    required Map<String, dynamic> entry,
  }) {
    final title = (entry['title'] as String?) ?? 'Critical Anomaly Detected';
    final powerAvg = entry['power_avg'] ?? 0;
    final score = (entry['score'] as num?) ?? 0.0;

    return InkWell(
      onTap: () => _showAnomalyDetail(context, entry),
      child: Container(
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
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFFFE0B2), width: 1),
              ),
              child: Icon(Icons.warning_amber_rounded,
                  color: primaryOrange, size: 18),
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
                        _formatTimestamp(entry['timestamp']),
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
                    'Power Avg: $powerAvg W  ·  Score: ${score.toStringAsFixed(2)}',
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
            Icon(Icons.chevron_right_rounded, color: Colors.grey[300], size: 20),
          ],
        ),
      ),
    );
  }

  // ── GENERAL LOG ITEM (non-anomaly notifications) ─────────────────────────
  Widget _buildLogItem({
    required Map<String, dynamic> entry,
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
            child: Icon(entry['icon'] as IconData,
                color: const Color(0xFF5F6368), size: 18),
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
                      entry['title'] as String,
                      style: TextStyle(
                        color: textDark,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      entry['timestamp'] as String,
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
                  entry['description'] as String,
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

  // ── MODAL BOTTOM SHEET: shows the tapped anomaly's detail card ──────────
  void _showAnomalyDetail(BuildContext context, Map<String, dynamic> entry) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
              ),
              child: DraggableScrollableSheet(
                initialChildSize: 0.55,
                minChildSize: 0.35,
                maxChildSize: 0.9,
                expand: false,
                builder: (context, scrollController) {
                  return SingleChildScrollView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    child: Column(
                      children: [
                        // Drag handle
                        Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: Colors.grey[300],
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        _buildCriticalCard(entry),
                      ],
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  // ── CRITICAL ANOMALY WIDGET (used inside the modal) ─────────────────────
  Widget _buildCriticalCard(Map<String, dynamic> data) {
    final logId = data['id'] as int?;
    final powerAvg = data['power_avg'] ?? 0;
    final score = (data['score'] as num?) ?? 0.0;
    final timeString = _formatFullDateTime(data['timestamp']);
    final isBusy = logId != null && _acknowledgingId == logId;

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
                    onPressed: (logId == null || isBusy)
                        ? null
                        : () => _acknowledgeAnomaly(logId, true),
                    icon: isBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.search_rounded, size: 18),
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
                    onPressed: (logId == null || isBusy)
                        ? null
                        : () => _acknowledgeAnomaly(logId, false),
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
}