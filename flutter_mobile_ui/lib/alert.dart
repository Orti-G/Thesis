import 'dart:convert';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart' hide TextDirection;
import 'bakit_expander.dart';

const String kApiBaseUrl = 'http://35.209.250.46:8000';

/// Sent by push handling in main.dart: refresh the review list and, when
/// [focusEventId] is set, open that event's card once it's loaded. A push
/// that merely arrives (no tap) refreshes without [showInbox].
class AnomalyReviewRequest {
  final int? focusEventId;
  final bool showInbox;

  AnomalyReviewRequest({this.focusEventId, this.showInbox = true});
}

final ValueNotifier<AnomalyReviewRequest?> anomalyReviewRequest =
    ValueNotifier(null);

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen>
    with WidgetsBindingObserver {
  // Brand Colors
  final Color primaryOrange = const Color(0xFFF26E22);
  final Color topCardColor = const Color(0xFFFA8B39);
  final Color bgColor = const Color(0xFFFAFAFA);
  final Color cardColor = Colors.white;
  final Color textDark = const Color(0xFF111418);
  final Color criticalText = const Color(0xFFD32F2F);

  // Tab state for toggling between Inbox and Info
  int _selectedTab = 0;

  // One entry per anomaly event (flagged readings ≤ 10 min apart), newest
  // first. `open` events are still happening and can't be answered yet.
  List<Map<String, dynamic>> _events = [];
  bool _loadingEvents = true;
  String? _eventsError;

  int get _closedCount => _events.where((e) => e['status'] == 'closed').length;
  int get _openCount => _events.length - _closedCount;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    anomalyReviewRequest.addListener(_onReviewRequest);
    _fetchEvents();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    anomalyReviewRequest.removeListener(_onReviewRequest);
    super.dispose();
  }

  // Open events may have closed while the app was in the background.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _fetchEvents();
  }

  Future<void> _onReviewRequest() async {
    final request = anomalyReviewRequest.value;
    if (request == null || !mounted) return;

    if (request.showInbox) setState(() => _selectedTab = 0);
    await _fetchEvents();

    final focusId = request.focusEventId;
    if (focusId == null || !mounted) return;
    final event = _events.where((e) => e['event_id'] == focusId).firstOrNull;
    if (event == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showAnomalyDetail(context, event);
    });
  }

  Future<void> _fetchEvents() async {
    if (!mounted) return;
    setState(() {
      _loadingEvents = true;
      _eventsError = null;
    });

    try {
      final res = await http
          .get(Uri.parse('$kApiBaseUrl/anomaly-events/pending'))
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) {
        throw Exception('Server returned ${res.statusCode}');
      }

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = (body['data'] as List).cast<Map<String, dynamic>>();

      if (!mounted) return;
      setState(() {
        _events = data;
        _loadingEvents = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _eventsError = 'Failed to load anomalies: $e';
        _loadingEvents = false;
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

  // One answer covers the whole event. The card leaves right away; the
  // refresh afterwards brings it back if the answer didn't stick.
  Future<void> _reviewEvent(int eventId, String answer) async {
    Navigator.of(context).pop();
    setState(() => _events.removeWhere((e) => e['event_id'] == eventId));

    String? toast;
    try {
      final res = await http
          .post(
            Uri.parse('$kApiBaseUrl/anomaly-events/$eventId/review'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'answer': answer}),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final status = (jsonDecode(res.body) as Map<String, dynamic>)['status'];
        toast = status == 'already_reviewed'
            ? 'Already answered on another phone.'
            : 'Answer saved. Thank you!';
      } else if (res.statusCode != 404) {
        // 404 means the event no longer exists; the refresh sorts it out.
        throw Exception('Server returned ${res.statusCode}');
      }
    } catch (e) {
      toast = "Couldn't save your answer. Please try again.";
    }

    if (!mounted) return;
    if (toast != null) _showGlassmorphicToast(context, toast);
    await _fetchEvents();
  }

  // Event times are Philippine local time with no zone, so they are used
  // exactly as written; never convert them from UTC.
  static final DateFormat _clockFormat = DateFormat('h:mm a');

  Color _severityColor(String? severity) {
    switch (severity) {
      case 'severe':
        return criticalText;
      case 'moderate':
        return primaryOrange;
      case 'mild':
        return const Color(0xFFE0A000);
      default: // pattern
        return const Color(0xFF64748B);
    }
  }

  String _severityLabel(String? severity) {
    switch (severity) {
      case 'severe':
        return 'SEVERE';
      case 'moderate':
        return 'MODERATE';
      case 'mild':
        return 'MILD';
      default:
        return 'UNUSUAL PATTERN';
    }
  }

  // hour = high for this time of day, rise/drop = sudden change.
  IconData _kindIcon(String? kind) {
    switch (kind) {
      case 'rise':
        return Icons.arrow_upward_rounded;
      case 'drop':
        return Icons.arrow_downward_rounded;
      default:
        return Icons.schedule_rounded;
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
                onRefresh: _fetchEvents,
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
                              hasBadge: _events.isNotEmpty,
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
                                        '$_closedCount Pending',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 22,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: -0.5,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        _openCount > 0
                                            ? 'events awaiting your review · $_openCount ongoing'
                                            : 'events awaiting your review',
                                        style: TextStyle(
                                          color: Colors.white.withValues(alpha: 0.85),
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (_loadingEvents)
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
                                'PENDING EVENTS',
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              if (!_loadingEvents && _events.isNotEmpty)
                                Text(
                                  '${_events.length}',
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
    if (_eventsError != null) {
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
                _eventsError!,
                style: TextStyle(color: criticalText, fontSize: 14),
              ),
            ),
          ],
        ),
      );
    } else if (!_loadingEvents && _events.isEmpty) {
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
        children: _events
            .map((event) => _buildAnomalyItem(context, event: event))
            .toList(),
      );
    }
  }

  Widget _buildOngoingPill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: primaryOrange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'Ongoing',
        style: TextStyle(
          color: primaryOrange,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildAnomalyItem(
    BuildContext context, {
    required Map<String, dynamic> event,
  }) {
    final title = event['title_tl'] as String?;
    final time = event['time_tl'] as String?;
    final message = event['message_tl'] as String?;
    final accent = _severityColor(event['severity'] as String?);

    return InkWell(
      onTap: () => _showAnomalyDetail(context, event),
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
                color: accent.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _kindIcon(event['kind'] as String?),
                color: accent,
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (title != null)
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              color: textDark,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (event['status'] == 'open') ...[
                        const SizedBox(width: 8),
                        _buildOngoingPill(),
                      ],
                    ],
                  ),
                  if (time != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      time,
                      style: TextStyle(
                        color: Colors.grey[500],
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (message != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      message,
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 14,
                        height: 1.35,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
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
                initialChildSize: 0.8,
                minChildSize: 0.4,
                maxChildSize: 0.95,
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

  Widget _buildActionPanel(Map<String, dynamic> event) {
    final eventId = event['event_id'] as int?;
    final isClosed = event['status'] == 'closed';
    final severity = event['severity'] as String?;
    final accent = _severityColor(severity);
    final time = event['time_tl'] as String?;
    final title = event['title_tl'] as String?;
    final message = event['message_tl'] as String?;
    final summary = event['summary_tl'] as String?;
    final prompt = event['prompt_tl'] as String?;
    final chart = event['chart'] as Map<String, dynamic>?;
    final options = ((event['options'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _kindIcon(event['kind'] as String?),
                    color: accent,
                    size: 14,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _severityLabel(severity),
                    style: TextStyle(
                      color: accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            if (!isClosed) ...[
              const SizedBox(width: 8),
              _buildOngoingPill(),
            ],
          ],
        ),
        if (time != null) ...[
          const SizedBox(height: 14),
          Text(
            time,
            style: TextStyle(
              color: Colors.grey[500],
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (title != null) ...[
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              color: textDark,
              fontSize: 26,
              height: 1.15,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.8,
            ),
          ),
        ],
        if (message != null) ...[
          const SizedBox(height: 14),
          Text(
            message,
            style: TextStyle(
              color: Colors.grey[800],
              fontSize: 15,
              height: 1.45,
            ),
          ),
        ],
        if (summary != null) ...[
          const SizedBox(height: 8),
          Text(
            summary,
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ],
        if (chart != null) ...[
          const SizedBox(height: 20),
          _buildEventChart(chart),
        ],
        const SizedBox(height: 8),
        BakitExpander(
          text: event['explain_tl'] as String?,
          accent: primaryOrange,
        ),
        // Open events are still happening, so there's nothing to answer yet.
        if (isClosed && eventId != null && options.isNotEmpty) ...[
          const SizedBox(height: 28),
          if (prompt != null) ...[
            Text(
              prompt,
              style: TextStyle(
                color: textDark,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 16),
          ],
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _buildAnswerButton(
              label: (options[i]['label_tl'] as String?) ?? '',
              filled: i == 0,
              onPressed: () =>
                  _reviewEvent(eventId, options[i]['answer'] as String),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildAnswerButton({
    required String label,
    required bool filled,
    required VoidCallback onPressed,
  }) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(100),
    );
    const textStyle = TextStyle(fontSize: 16, fontWeight: FontWeight.w700);

    return SizedBox(
      width: double.infinity,
      height: 58,
      child: filled
          ? FilledButton(
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                backgroundColor: textDark,
                shape: shape,
              ),
              child: Text(label, style: textStyle),
            )
          : OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: textDark,
                side: BorderSide(color: Colors.grey[300]!, width: 1.5),
                shape: shape,
              ),
              child: Text(label, style: textStyle),
            ),
    );
  }

  // Power around the event: flagged readings get a red dot, and the usual
  // power for the past hour is a dashed line.
  Widget _buildEventChart(Map<String, dynamic> chart) {
    final points = ((chart['points'] as List?) ?? const []).cast<Map>();

    DateTime? origin;
    final spots = <FlSpot>[];
    final flaggedX = <double>{};
    for (final p in points) {
      final t = DateTime.tryParse('${p['t']}');
      final w = (p['w'] as num?)?.toDouble();
      if (t == null || w == null) continue;
      origin ??= t;
      final x = t.difference(origin).inSeconds / 60.0;
      spots.add(FlSpot(x, w));
      if (p['flagged'] == true) flaggedX.add(x);
    }
    if (origin == null) return const SizedBox.shrink();
    final start = origin;

    final baselineLabel = chart['baseline_label_tl'] as String?;
    final baseline = baselineLabel == null
        ? null
        : (chart['baseline_w'] as num?)?.toDouble();

    final peak = [for (final s in spots) s.y, ?baseline].reduce(max);
    final step = _niceStep(peak / 3);
    final maxY = step * (peak * 1.1 / step).ceil();
    final minX = spots.first.x;
    final maxX = spots.last.x > minX ? spots.last.x : minX + 1;

    String clockAt(double x) =>
        _clockFormat.format(start.add(Duration(seconds: (x * 60).round())));
    final axisStyle = TextStyle(
      color: Colors.grey[500],
      fontSize: 10.5,
      fontWeight: FontWeight.w600,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 18, 16, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F8F6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 170,
            child: LineChart(
              LineChartData(
                minX: minX,
                maxX: maxX,
                minY: 0,
                maxY: maxY,
                gridData: FlGridData(
                  drawVerticalLine: false,
                  horizontalInterval: step,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: Colors.grey.withValues(alpha: 0.15),
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 48,
                      interval: step,
                      getTitlesWidget: (value, meta) => SideTitleWidget(
                        meta: meta,
                        child: Text('${value.round()} W', style: axisStyle),
                      ),
                    ),
                  ),
                  // Only the first and last times, so labels never collide.
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 24,
                      interval: maxX - minX,
                      getTitlesWidget: (value, meta) => SideTitleWidget(
                        meta: meta,
                        space: 6,
                        fitInside: SideTitleFitInsideData.fromTitleMeta(meta),
                        child: Text(clockAt(value), style: axisStyle),
                      ),
                    ),
                  ),
                ),
                extraLinesData: ExtraLinesData(
                  horizontalLines: [
                    if (baseline != null)
                      HorizontalLine(
                        y: baseline,
                        color: Colors.grey[600],
                        strokeWidth: 1.5,
                        dashArray: const [6, 4],
                      ),
                  ],
                ),
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) => textDark,
                    getTooltipItems: (touched) => touched
                        .map(
                          (s) => LineTooltipItem(
                            '${clockAt(s.x)}\n${s.y.round()} W',
                            const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    color: primaryOrange,
                    barWidth: 2.5,
                    isStrokeCapRound: true,
                    belowBarData: BarAreaData(
                      show: true,
                      color: primaryOrange.withValues(alpha: 0.08),
                    ),
                    dotData: FlDotData(
                      checkToShowDot: (spot, _) => flaggedX.contains(spot.x),
                      getDotPainter: (spot, percent, bar, index) =>
                          FlDotCirclePainter(
                        radius: 5,
                        color: criticalText,
                        strokeWidth: 2,
                        strokeColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                _buildLegendDot(criticalText, 'Flagged'),
                if (baseline != null && baselineLabel != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 18,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: List.generate(
                            3,
                            (_) => Container(
                              width: 4,
                              height: 2,
                              color: Colors.grey[600],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        baselineLabel,
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Rounds a raw gridline spacing up to a readable step (50, 100, 250 W...).
  double _niceStep(double raw) {
    for (final step in const [50.0, 100.0, 200.0, 250.0, 500.0, 1000.0, 2000.0]) {
      if (raw <= step) return step;
    }
    return 5000.0;
  }
}
