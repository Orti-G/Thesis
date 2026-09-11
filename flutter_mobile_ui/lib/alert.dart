import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const String kApiBaseUrl = 'http://35.209.250.46:8000';

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  // Brand Colors
  final Color primaryOrange = const Color(0xFFF26E22);
  final Color topCardColor = const Color(0xFFFA8B39);
  final Color bgColor = const Color(0xFFFAFAFA);
  final Color cardColor = Colors.white;
  final Color textDark = const Color(0xFF111418);
  final Color criticalText = const Color(0xFFD32F2F);

  // Tab state for toggling between Inbox and Info
  int _selectedTab = 0;

  List<Map<String, dynamic>> _anomalyEntries = [];
  bool _loadingAnomalies = true;
  String? _anomalyError;
  int? _acknowledgingId;

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

  // Idea 1: Custom Floating Glassmorphic Toast Notification
  void _showGlassmorphicToast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        duration: const Duration(seconds: 3),
        content: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.white.withValues(alpha: 0.85),
                    const Color(0xFFF5F5F7).withValues(alpha: 0.70),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.8),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: primaryOrange,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      message,
                      style: TextStyle(
                        color: textDark,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

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

      setState(() {
        _anomalyEntries.removeWhere((e) => e['id'] == logId);
        _acknowledgingId = null;
      });

      if (mounted) {
        Navigator.of(context).pop();
        _showGlassmorphicToast(
          context,
          acknowledged
              ? 'Marked as a real anomaly.'
              : 'Marked as a false alarm.',
        );
      }
    } catch (e) {
      setState(() => _acknowledgingId = null);
      if (mounted) {
        _showGlassmorphicToast(context, 'Failed to update: $e');
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
      
      int hour = parsed.hour;
      final mm = parsed.minute.toString().padLeft(2, '0');
      final ampm = hour >= 12 ? 'PM' : 'AM';
      
      if (hour > 12) hour -= 12;
      if (hour == 0) hour = 12;
      
      final timeStr = '$hour:$mm $ampm';
      
      if (sameDay) return timeStr;
      return '${_monthNames[parsed.month - 1]} ${parsed.day}';
    } catch (_) {
      return raw.toString();
    }
  }

  BoxDecoration get _cardDecoration => BoxDecoration(
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
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      body: Stack(
        children: [
          Positioned.fill(
            child: Container(color: bgColor),
          ),
          Positioned(
            top: -140,
            right: -100,
            child: Container(
              width: 420,
              height: 420,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    topCardColor.withValues(alpha: 0.22),
                    topCardColor.withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 1.0],
                ),
              ),
            ),
          ),
          Positioned(
            top: 40,
            left: -160,
            child: Container(
              width: 360,
              height: 360,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    primaryOrange.withValues(alpha: 0.14),
                    primaryOrange.withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 1.0],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: SafeArea(
              bottom: false,
              child: RefreshIndicator(
                onRefresh: _fetchPendingAnomalies,
                color: primaryOrange,
                backgroundColor: Colors.white,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── HEADER ──
                      const Padding(
                        padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
                        child: SizedBox.shrink(),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                        child: Text(
                          'Alerts & Anomalies',
                          style: TextStyle(
                            color: textDark,
                            fontSize: 30,
                            height: 1.1,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1.0,
                          ),
                        ),
                      ),

                      // ── TOGGLE BAR ──
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20.0),
                        child: Row(
                          children: [
                            _buildTabButton(
                              index: 0,
                              title: 'Inbox',
                              icon: Icons.all_inbox_rounded,
                              hasBadge: _anomalyEntries.isNotEmpty,
                              isIconOnly: false,
                            ),
                            const SizedBox(width: 12),
                            _buildTabButton(
                              index: 1,
                              title: 'Info',
                              icon: Icons.info_outline_rounded,
                              hasBadge: false,
                              isIconOnly: true,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // ── TAB CONTENT: INBOX (ANOMALIES) ──
                      if (_selectedTab == 0) ...[
                        // SUMMARY CARD
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20.0),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: topCardColor,
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: topCardColor.withValues(alpha: 0.25),
                                  blurRadius: 16,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: const Icon(
                                    Icons.notifications_active_rounded,
                                    color: Colors.white,
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${_anomalyEntries.length} Pending',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 22,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: -0.5,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'anomalies awaiting your review',
                                        style: TextStyle(
                                          color: Colors.white.withValues(alpha: 0.85),
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (_loadingAnomalies)
                                  const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 28),

                        // ANOMALIES FEED
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'PENDING LOGS',
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              if (!_loadingAnomalies && _anomalyEntries.isNotEmpty)
                                Text(
                                  '${_anomalyEntries.length}',
                                  style: TextStyle(
                                    color: Colors.grey[500],
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20.0),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 300),
                            child: _buildAnomaliesListContent(),
                          ),
                        ),
                        const SizedBox(height: 100),
                      ],

                      // ── TAB CONTENT: INFO (INFOGRAPHIC) ──
                      if (_selectedTab == 1) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20.0),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(24),
                            decoration: _cardDecoration,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Anatomy of an Anomaly',
                                  style: TextStyle(
                                    color: textDark,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.6,
                                  ),
                                ),
                                const SizedBox(height: 28),
                                SizedBox(
                                  height: 110,
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      _buildBar(38, false),
                                      _buildBar(52, false),
                                      _buildBar(33, false),
                                      _buildBar(42, false),
                                      _buildBar(100, true),
                                      _buildBar(38, false),
                                      _buildBar(47, false),
                                    ],
                                  ),
                                ),
                                Container(
                                  height: 2,
                                  margin: const EdgeInsets.only(top: 8),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [Colors.grey[300]!, Colors.transparent],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Row(
                                  children: [
                                    _buildLegendDot(
                                      const Color(0xFFE2E8F0),
                                      'Normal Pattern',
                                    ),
                                    const Spacer(),
                                    _buildLegendDot(primaryOrange, 'Detected Spike'),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Divider(
                                  color: Colors.grey.withValues(alpha: 0.15),
                                  height: 40,
                                ),
                                _buildCauseRow(
                                  icon: Icons.bolt_rounded,
                                  title: 'Sudden Spike',
                                  description:
                                      'A large change in power draw over a short period.',
                                ),
                                _buildCauseRow(
                                  icon: Icons.schedule_rounded,
                                  title: 'Unusual Time',
                                  description:
                                      'Appliance use at a time that\'s not typical.',
                                ),
                                _buildCauseRow(
                                  icon: Icons.build_circle_rounded,
                                  title: 'Faulty Appliance',
                                  description:
                                      'Sustained high consumption signaling a malfunction.',
                                  isLast: true,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 100),
                      ]
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── HELPER WIDGETS ──

  Widget _buildTabButton({
    required int index,
    required String title,
    required IconData icon,
    required bool hasBadge,
    bool isIconOnly = false,
  }) {
    final isSelected = _selectedTab == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedTab = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(
          horizontal: isIconOnly ? 18 : 24,
          vertical: 14,
        ),
        decoration: BoxDecoration(
          color: isSelected ? cardColor : Colors.grey.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(100),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  )
                ]
              : [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: isSelected ? textDark : Colors.grey[600],
                ),
                if (hasBadge)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE57373),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? cardColor : bgColor,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (!isIconOnly) ...[
              const SizedBox(width: 10),
              Text(
                title,
                style: TextStyle(
                  color: isSelected ? textDark : Colors.grey[600],
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAnomaliesListContent() {
    if (_anomalyError != null) {
      return Container(
        key: const ValueKey('error'),
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: _cardDecoration,
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: criticalText, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _anomalyError!,
                style: TextStyle(color: criticalText, fontSize: 14),
              ),
            ),
          ],
        ),
      );
    } else if (!_loadingAnomalies && _anomalyEntries.isEmpty) {
      return Container(
        key: const ValueKey('empty'),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 36),
        decoration: _cardDecoration,
        child: Column(
          children: [
            Icon(
              Icons.check_circle_outline_rounded,
              color: Colors.grey[350],
              size: 32,
            ),
            const SizedBox(height: 12),
            Text(
              'No deviations currently detected.',
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    } else {
      return Column(
        key: const ValueKey('list'),
        children: _anomalyEntries
            .map((entry) => _buildAnomalyItem(context, entry: entry))
            .toList(),
      );
    }
  }

  Widget _buildAnomalyItem(
    BuildContext context, {
    required Map<String, dynamic> entry,
  }) {
    final title = (entry['title'] as String?) ?? 'System Alert';
    final powerAvg = entry['power_avg'] ?? 0;
    
    final description = 'Unexpected power pattern detected. Requires review.';

    return InkWell(
      onTap: () => _showAnomalyDetail(context, entry),
      splashColor: Colors.grey.withValues(alpha: 0.1),
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: primaryOrange.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.insights_rounded,
                color: primaryOrange.withValues(alpha: 0.6),
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: TextStyle(
                            color: textDark,
                            fontSize: 16.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '$powerAvg W',
                          style: TextStyle(
                            color: Colors.grey[700],
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _formatTimestamp(entry['timestamp']),
                        style: TextStyle(
                          color: Colors.grey[400],
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 14.5,
                      fontWeight: FontWeight.w400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBar(double height, bool isAnomaly) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6.0),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 500),
          height: height,
          decoration: BoxDecoration(
            color: isAnomaly ? primaryOrange : const Color(0xFFE2E8F0),
            borderRadius: BorderRadius.circular(100),
          ),
        ),
      ),
    );
  }

  Widget _buildLegendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            color: Colors.grey[600],
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildCauseRow({
    required IconData icon,
    required String title,
    required String description,
    bool isLast = false,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 20.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: const Color(0xFF94A3B8), size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: textDark,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontSize: 13.5,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── GLASSMORPHIC MODAL ──
  void _showAnomalyDetail(BuildContext context, Map<String, dynamic> entry) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.25),
      builder: (sheetContext) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.92),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withValues(alpha: 0.5),
                    width: 1.5,
                  ),
                ),
              ),
              child: DraggableScrollableSheet(
                initialChildSize: 0.6,
                minChildSize: 0.4,
                maxChildSize: 0.9,
                expand: false,
                builder: (context, scrollController) {
                  return SingleChildScrollView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(28, 16, 28, 36),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            margin: const EdgeInsets.only(bottom: 28),
                            decoration: BoxDecoration(
                              color: Colors.grey[300],
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                        _buildActionPanel(entry),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildActionPanel(Map<String, dynamic> data) {
    final logId = data['id'] as int?;
    final powerAvg = data['power_avg'] ?? 0;
    final score = (data['anomaly_score'] as num?) ?? 0.0;
    final isBusy = logId != null && _acknowledgingId == logId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: criticalText.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'CRITICAL ALERT',
                style: TextStyle(
                  color: criticalText,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          _formatFullDateTime(data['timestamp']),
          style: TextStyle(
            color: Colors.grey[500],
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Unusual Pattern\nDetected',
          style: TextStyle(
            color: textDark,
            fontSize: 32,
            height: 1.15,
            fontWeight: FontWeight.w900,
            letterSpacing: -1.0,
          ),
        ),
        const SizedBox(height: 20),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFF8F8F6),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Power Avg',
                      style: TextStyle(color: Colors.grey[500], fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$powerAvg W',
                      style: TextStyle(color: textDark, fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              Container(width: 1, height: 32, color: Colors.grey.withValues(alpha: 0.25)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Anomaly Score',
                      style: TextStyle(color: Colors.grey[500], fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      score.toStringAsFixed(2),
                      style: TextStyle(color: textDark, fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 36),
        Text(
          'Was this expected behavior?',
          style: TextStyle(color: textDark, fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 58,
          child: FilledButton(
            onPressed: (logId == null || isBusy)
                ? null
                : () => _acknowledgeAnomaly(logId, true),
            style: FilledButton.styleFrom(
              backgroundColor: textDark,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(100),
              ),
            ),
            child: isBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    'No, Investigate',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 58,
          child: OutlinedButton(
            onPressed: (logId == null || isBusy)
                ? null
                : () => _acknowledgeAnomaly(logId, false),
            style: OutlinedButton.styleFrom(
              foregroundColor: textDark,
              side: BorderSide(color: Colors.grey[300]!, width: 1.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(100),
              ),
            ),
            child: const Text(
              'Yes, It Was Me',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }
}