import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'bakit_expander.dart';

class AdvisoriesScreen extends StatefulWidget {
  const AdvisoriesScreen({super.key});

  @override
  State<AdvisoriesScreen> createState() => _AdvisoriesScreenState();
}

class _AdvisoriesScreenState extends State<AdvisoriesScreen> {
  final Color primaryOrange = const Color(0xFFF26E22);
  final Color lightOrangeBg = const Color(0xFFFA8B39);
  final Color creamBg = const Color(0xFFFFFDF9);
  final Color textDark = const Color(0xFF1E1E1E);
  final Color upText = const Color(0xFFE53935);
  final Color upBg = const Color(0xFFFFEBEE);
  final Color downText = const Color(0xFF2E7D32);
  final Color downBg = const Color(0xFFE8F5E9);
  // Muted slate used for the "Last Week" series when comparison mode is on.
  final Color lastWeekBar = const Color(0xFFB0B7C3);

  // Same FastAPI VM used by Dashboard for historical, non-today data.
  static const String _apiBaseUrl = 'http://35.209.250.46:8000';

  // Chart runs Sunday -> Saturday.
  final List<String> _weekDayLabels = const [
    'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'
  ];

  static const List<String> _monthAbbr = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  // ── LIVE WEEKLY DATA STATE ────────────────────────────────────────────
  // Index 0 = Sunday ... 6 = Saturday, for both weeks.
  List<double> _thisWeek = List<double>.filled(7, 0.0);
  List<double> _lastWeek = List<double>.filled(7, 0.0);
  bool _isLoadingWeekly = true;
  String? _weeklyError;

  // Toggle between the single-series "This Week" view and the grouped
  // side-by-side "Compare" view (this week vs. last week per day).
  bool _showComparison = false;

  StreamSubscription<DatabaseEvent>? _todaySubscription;
  int _todayIndex = 0; // 0=Sun ... 6=Sat

  // ── ADVISORIES + NEWS FEED (Firebase, written only by the backend) ─────
  // Both arrive in Tagalog, ready to show; the app never rewrites them.
  StreamSubscription<DatabaseEvent>? _advisoriesSubscription;
  StreamSubscription<DatabaseEvent>? _newsSubscription;
  List<Map<String, dynamic>> _advisories = [];
  List<Map<String, dynamic>> _newsItems = [];
  bool _isLoadingNews = true;

  @override
  void initState() {
    super.initState();
    _loadWeeklyData();
    _attachFeedListeners();
  }

  @override
  void dispose() {
    _todaySubscription?.cancel();
    _advisoriesSubscription?.cancel();
    _newsSubscription?.cancel();
    super.dispose();
  }

  // ── FETCH: single call to /history/weekly-comparison ────────────────────
  // Replaces the old approach of 7+7 individual GET /history/{date} calls
  // (up to 13 requests per load, since today was skipped and handled live).
  // The backend now pre-aggregates both weeks server-side in one response,
  // so this is always exactly 1 HTTP call regardless of how many days have
  // elapsed this week.
  Future<void> _loadWeeklyData() async {
    setState(() {
      _isLoadingWeekly = true;
      _weeklyError = null;
    });

    final now = DateTime.now();
    // DateTime.weekday: Mon=1 ... Sun=7. We want Sun=0 ... Sat=6,
    // so shift with modulo instead of a plain -1.
    _todayIndex = now.weekday % 7;

    try {
      final response = await http
          .get(Uri.parse('$_apiBaseUrl/history/weekly-comparison'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['status'] != 'ok') {
        throw Exception('API returned status: ${body['status']}');
      }

      final currentWeek = body['current_week'] as Map<String, dynamic>? ?? {};
      final lastWeek = body['last_week'] as Map<String, dynamic>? ?? {};

      final thisWeekData =
          _parseWeekData(currentWeek['data'] as List<dynamic>? ?? []);
      final lastWeekData =
          _parseWeekData(lastWeek['data'] as List<dynamic>? ?? []);

      if (!mounted) return;
      setState(() {
        _thisWeek = thisWeekData;
        _lastWeek = lastWeekData;
        _isLoadingWeekly = false;
      });
    } catch (e) {
      debugPrint("🔴 ERROR LOADING WEEKLY COMPARISON: $e");
      if (!mounted) return;
      setState(() {
        _isLoadingWeekly = false;
        _weeklyError = 'Failed to load weekly data';
      });
    }

    // Today's entry from the API may already be lagging (it's a snapshot),
    // so we still layer the live Firebase total for today's index on top —
    // this is the only piece that genuinely needs to be real-time.
    _attachTodayListener();
  }

  // ── Map the API's {date, daily_kwh} rows onto a fixed Sun..Sat array ────
  // Rows are keyed by actual calendar date, not by list position, so we
  // derive the index from the date itself rather than assuming order.
  // Missing days (e.g. days in the current week that haven't happened yet)
  // are left at 0.0.
  List<double> _parseWeekData(List<dynamic> rows) {
    final result = List<double>.filled(7, 0.0);
    for (final row in rows) {
      if (row is! Map) continue;
      final dateStr = row['date'] as String?;
      final kwh = (row['daily_kwh'] as num?)?.toDouble();
      if (dateStr == null || kwh == null) continue;
      final date = DateTime.tryParse(dateStr);
      if (date == null) continue;
      final index = date.weekday % 7; // Sun=0 ... Sat=6
      if (index >= 0 && index < 7) {
        result[index] = kwh;
      }
    }
    return result;
  }

  // ── LIVE: today's running total via Firebase `history/today`, same
  // node Dashboard listens to for its hourly chart. ──────────────────────
  void _attachTodayListener() {
    _todaySubscription?.cancel();
    final ref = FirebaseDatabase.instance.ref('history/today');
    _todaySubscription = ref.onValue.listen((event) {
      if (!mounted) return;
      double total = 0.0;

      if (event.snapshot.value != null) {
        try {
          final data = Map<String, dynamic>.from(event.snapshot.value as Map);
          final hourlyRaw = data['hourly'];

          if (hourlyRaw is Map) {
            hourlyRaw.forEach((key, value) {
              if (value == null) return;
              final kwh = double.tryParse(value.toString());
              if (kwh != null) total += kwh;
            });
          } else if (hourlyRaw is List) {
            for (final value in hourlyRaw) {
              if (value == null) continue;
              final kwh = double.tryParse(value.toString());
              if (kwh != null) total += kwh;
            }
          }
        } catch (e) {
          debugPrint("🔴 ERROR PARSING TODAY TOTAL: $e");
        }
      }

      setState(() {
        if (_todayIndex >= 0 && _todayIndex < _thisWeek.length) {
          _thisWeek[_todayIndex] = total;
        }
      });
    });
  }

  // `/advisories/{category}` holds the latest message per topic. anomaly and
  // review are answered on the Alerts tab and device lives on the Dashboard,
  // so only these are shown here.
  static const Set<String> _advisoryCategories = {
    'bracket', 'cycle', 'daily', 'rates', 'weekly',
  };

  void _attachFeedListeners() {
    _advisoriesSubscription?.cancel();
    _advisoriesSubscription =
        FirebaseDatabase.instance.ref('advisories').onValue.listen((event) {
      if (!mounted) return;
      final records = <Map<String, dynamic>>[];
      final raw = event.snapshot.value;
      if (raw is Map) {
        raw.forEach((category, value) {
          if (value is Map && _advisoryCategories.contains(category)) {
            records.add(Map<String, dynamic>.from(value));
          }
        });
      }
      // Most important first (priority 1), then newest.
      records.sort((a, b) {
        final byPriority =
            _priorityOf(a['priority']).compareTo(_priorityOf(b['priority']));
        if (byPriority != 0) return byPriority;
        return _parseInstant(b['timestamp'])
            .compareTo(_parseInstant(a['timestamp']));
      });
      setState(() => _advisories = records);
    });

    _newsSubscription?.cancel();
    _newsSubscription =
        FirebaseDatabase.instance.ref('cms/published').onValue.listen((event) {
      if (!mounted) return;
      final items = <Map<String, dynamic>>[];
      final raw = event.snapshot.value;
      if (raw is Map) {
        raw.forEach((id, value) {
          if (value is Map) items.add(Map<String, dynamic>.from(value));
        });
      }
      // Pinned items on top, then newest first.
      items.sort((a, b) {
        final byPinned =
            (b['pinned'] == true ? 1 : 0) - (a['pinned'] == true ? 1 : 0);
        if (byPinned != 0) return byPinned;
        final byPublished = _parseInstant(b['published_at'])
            .compareTo(_parseInstant(a['published_at']));
        if (byPublished != 0) return byPublished;
        return _parseInstant(b['source_date'])
            .compareTo(_parseInstant(a['source_date']));
      });
      setState(() {
        _newsItems = items;
        _isLoadingNews = false;
      });
    }, onError: (Object e) {
      debugPrint("🔴 ERROR LOADING NEWS FEED: $e");
      if (mounted) setState(() => _isLoadingNews = false);
    });
  }

  int _priorityOf(dynamic raw) =>
      raw is num ? raw.toInt() : int.tryParse('$raw') ?? 99;

  // Advisory and feed timestamps carry a zone (+08:00 / UTC), so they're
  // converted to the phone's local time. Unparseable values sort last.
  DateTime _parseInstant(dynamic raw) =>
      DateTime.tryParse('${raw ?? ''}')?.toLocal() ??
      DateTime.fromMillisecondsSinceEpoch(0);

  String _formatAge(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return _formatDate(t);
  }

  // ── DERIVED STATS ────────────────────────────────────────────────────
  // Only count days that have actually elapsed this week (today included)
  // — averaging in future zero-days would understate the daily average,
  // and comparing a partial week to a full previous week would be unfair.
  int get _daysElapsed => _todayIndex + 1;

  double get _thisWeekElapsedTotal =>
      _thisWeek.take(_daysElapsed).fold(0.0, (sum, v) => sum + v);

  double get _lastWeekComparableTotal =>
      _lastWeek.take(_daysElapsed).fold(0.0, (sum, v) => sum + v);

  double get _dailyAverage =>
      _daysElapsed == 0 ? 0 : _thisWeekElapsedTotal / _daysElapsed;

  double get _pctChange => _lastWeekComparableTotal == 0
      ? 0
      : ((_thisWeekElapsedTotal - _lastWeekComparableTotal) /
              _lastWeekComparableTotal) *
          100;

  // ── WEEK DATE SPANS: Sunday-of-this-week derived from today's index, so
  // the legend can show actual calendar ranges instead of generic labels.
  DateTime get _thisWeekStart {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: _todayIndex));
  }

  DateTime get _lastWeekStart =>
      _thisWeekStart.subtract(const Duration(days: 7));

  String _formatDate(DateTime d) => '${_monthAbbr[d.month - 1]} ${d.day}';

  String _formatWeekSpan(DateTime start) {
    final end = start.add(const Duration(days: 6));
    // Skip the repeated month when the span stays within one month.
    if (start.month == end.month) {
      return '${_monthAbbr[start.month - 1]} ${start.day}–${end.day}';
    }
    return '${_formatDate(start)} – ${_formatDate(end)}';
  }

  String get _thisWeekSpanLabel => _formatWeekSpan(_thisWeekStart);
  String get _lastWeekSpanLabel => _formatWeekSpan(_lastWeekStart);

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

                  // ── ADVISORY CARDS: latest backend message per topic ─────
                  if (_advisories.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24.0, 0, 24.0, 4.0),
                      child: Column(
                        children: [
                          for (final advisory in _advisories)
                            _buildAdvisoryCard(advisory),
                        ],
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
                            value: _dailyAverage.toStringAsFixed(1),
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
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
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
                                      _showComparison
                                          ? 'This week vs. last week'
                                          : 'Last 7 days',
                                      style: TextStyle(
                                        color: Colors.grey[500],
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              _buildChartModeToggle(),
                            ],
                          ),
                          if (_showComparison) ...[
                            const SizedBox(height: 12),
                            _buildChartLegend(),
                          ],
                          const SizedBox(height: 16),
                          SizedBox(
                            height: 180,
                            child: Stack(
                              children: [
                                _buildWeeklyBarChart(),
                                if (_isLoadingWeekly)
                                  const Positioned.fill(
                                    child: Center(
                                      child: SizedBox(
                                        height: 22,
                                        width: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    ),
                                  )
                                else if (_weeklyError != null)
                                  Positioned.fill(
                                    child: Center(
                                      child: Text(
                                        _weeklyError!,
                                        style: TextStyle(
                                          color: Colors.grey[500],
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  ),

                  // ── NEWS & TIPS: header ───────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24.0, 16.0, 24.0, 12.0),
                    child: Text(
                      'News & Tips',
                      style: TextStyle(
                        color: textDark,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),

                  // ── NEWS & TIPS: featured card + article-style list ──────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: _buildNewsContent(),
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

  // ── CHART TOGGLE: "This Week" / "Compare" pill switch ───────────────────
  Widget _buildChartModeToggle() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F5F7),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildToggleOption(label: 'This Week', selected: !_showComparison),
          _buildToggleOption(label: 'Compare', selected: _showComparison),
        ],
      ),
    );
  }

  Widget _buildToggleOption({required String label, required bool selected}) {
    return GestureDetector(
      onTap: () => setState(() => _showComparison = label == 'Compare'),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? primaryOrange : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.grey[600],
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  // ── CHART LEGEND: shown only in Compare mode, labeled with each week's
  // actual calendar span (e.g. "Aug 24–30") rather than generic text. ─────
  Widget _buildChartLegend() {
    return Row(
      children: [
        _legendDot(color: lastWeekBar, label: _lastWeekSpanLabel),
        const SizedBox(width: 16),
        _legendDot(color: primaryOrange, label: _thisWeekSpanLabel),
      ],
    );
  }

  Widget _legendDot({required Color color, required String label}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: Colors.grey[600],
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
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

  // ── ADVISORY CARD: backend title + message, "Bakit?" for the reasoning ──
  Widget _buildAdvisoryCard(Map<String, dynamic> advisory) {
    final title = advisory['title_tl'] as String?;
    final message = advisory['message_tl'] as String?;
    final timestamp = DateTime.tryParse('${advisory['timestamp']}')?.toLocal();
    final (icon, accent) = _advisoryStyle(advisory['category'] as String?);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: accent, size: 17),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    title ?? '',
                    style: TextStyle(
                      color: textDark,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                    ),
                  ),
                ),
              ),
              if (timestamp != null) ...[
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Text(
                    _formatAge(timestamp),
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (message != null) ...[
            const SizedBox(height: 10),
            Text(
              message,
              style: TextStyle(
                color: Colors.grey[700],
                fontSize: 13.5,
                height: 1.45,
              ),
            ),
          ],
          const SizedBox(height: 4),
          BakitExpander(
            text: advisory['explain_tl'] as String?,
            accent: primaryOrange,
          ),
        ],
      ),
    );
  }

  (IconData, Color) _advisoryStyle(String? category) {
    switch (category) {
      case 'bracket':
        return (Icons.speed_rounded, upText);
      case 'cycle':
        return (Icons.calendar_month_rounded, primaryOrange);
      case 'daily':
        return (Icons.today_rounded, primaryOrange);
      case 'rates':
        return (Icons.price_change_rounded, primaryOrange);
      default: // weekly
        return (Icons.date_range_rounded, primaryOrange);
    }
  }

  // ── NEWS & TIPS: kind → chip label, colour and icon ────────────────────
  String _newsLabel(String? kind) {
    switch (kind) {
      case 'rate_change':
        return 'RATES';
      case 'news':
        return 'NEWS';
      case 'advisory':
        return 'ADVISORY';
      case 'maintenance':
        return 'MAINTENANCE';
      default: // note: GRID's own
        return 'GRID TIP';
    }
  }

  Color _newsColor(String? kind) {
    switch (kind) {
      case 'rate_change':
        return primaryOrange;
      case 'news':
        return const Color(0xFF1E6FD9);
      case 'advisory':
      case 'maintenance':
        return const Color(0xFFB26A00);
      default:
        return downText;
    }
  }

  // Rate changes are coloured by direction: up red, down green, flat grey.
  Color _newsArtColor(Map<String, dynamic> item) {
    if (item['kind'] != 'rate_change') return _newsColor(item['kind'] as String?);
    switch ((item['card'] as Map?)?['direction']) {
      case 'up':
        return upText;
      case 'down':
        return downText;
      case 'flat':
        return const Color(0xFF78909C);
      default:
        return primaryOrange;
    }
  }

  IconData _newsIcon(Map<String, dynamic> item) {
    final card = item['card'] as Map?;
    switch (card?['icon'] ?? item['kind']) {
      case 'rate_change':
        switch (card?['direction']) {
          case 'up':
            return Icons.trending_up_rounded;
          case 'down':
            return Icons.trending_down_rounded;
          case 'flat':
            return Icons.trending_flat_rounded;
          default:
            return Icons.price_change_rounded;
        }
      case 'news':
        return Icons.newspaper_rounded;
      case 'advisory':
        return Icons.campaign_rounded;
      case 'maintenance':
        return Icons.engineering_rounded;
      default:
        return Icons.lightbulb_outline_rounded;
    }
  }

  // The source's own date when there is one, otherwise when GRID published.
  String _newsDate(Map<String, dynamic> item) {
    final raw = item['source_date'] ?? item['published_at'];
    final parsed = DateTime.tryParse('${raw ?? ''}')?.toLocal();
    return parsed == null ? '' : _formatDate(parsed);
  }

  // ── NEWS ART: drawn from the item's facts when it has no image ─────────
  // Large sizes show a rate change's figures (e.g. "+₱0.3191/kWh"); small
  // thumbnails just show the icon.
  Widget _buildNewsArt(
    Map<String, dynamic> item, {
    double? width,
    required double height,
    double factsTop = 52,
  }) {
    final color = _newsArtColor(item);
    final card = item['card'] as Map?;
    final change = card?['change_tl'] as String?;
    final rateNew = card?['rate_new_tl'] as String?;
    final direction = card?['direction'];
    final isThumbnail = height < 100;
    final showFacts =
        !isThumbnail && item['kind'] == 'rate_change' && change != null;

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color, Color.lerp(color, Colors.black, 0.3)!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: isThumbnail
          ? Center(child: Icon(_newsIcon(item), color: Colors.white, size: 30))
          : Stack(
              children: [
                Positioned(
                  right: -16,
                  top: -8,
                  child: Icon(
                    _newsIcon(item),
                    color: Colors.white.withValues(alpha: 0.16),
                    size: height * 0.75,
                  ),
                ),
                if (showFacts)
                  Positioned(
                    left: 18,
                    top: factsTop,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (direction == 'up' || direction == 'down')
                              Icon(
                                direction == 'up'
                                    ? Icons.arrow_upward_rounded
                                    : Icons.arrow_downward_rounded,
                                color: Colors.white,
                                size: 26,
                              ),
                            Text(
                              change,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.5,
                              ),
                            ),
                          ],
                        ),
                        if (rateNew != null)
                          Text(
                            rateNew,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  // ── Shared network-image loader with a spinner + graceful fallback ──────
  // A missing url or a failed load shows [fallback] (the drawn news art)
  // instead, since feed images may not be set up in Firebase Storage yet.
  Widget _networkImage(
    String? url, {
    required double? width,
    required double? height,
    required Widget fallback,
    BoxFit fit = BoxFit.cover,
  }) {
    if (url == null || url.isEmpty) return fallback;
    return Image.network(
      url,
      width: width,
      height: height,
      fit: fit,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Container(
          width: width,
          height: height,
          color: const Color(0xFFF4F5F7),
          child: const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      },
      errorBuilder: (context, error, stack) => fallback,
    );
  }

  Widget _buildNewsContent() {
    if (_newsItems.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 32),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Center(
          child: _isLoadingNews
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  'No news yet',
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
        ),
      );
    }

    return Column(
      children: [
        _buildFeaturedNewsCard(_newsItems.first),
        const SizedBox(height: 20),
        for (final item in _newsItems.skip(1)) _buildNewsListItem(item),
      ],
    );
  }

  // ── NEWS: featured card (pinned or newest), photo or drawn background ───
  Widget _buildFeaturedNewsCard(Map<String, dynamic> item) {
    final kind = item['kind'] as String?;

    return GestureDetector(
      onTap: () => _showNewsDetail(item),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            _networkImage(
              item['image_url'] as String?,
              width: double.infinity,
              height: 220,
              fallback: _buildNewsArt(
                item,
                width: double.infinity,
                height: 220,
              ),
            ),
            // Bottom gradient scrim so the white text stays legible.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.black.withValues(alpha: 0.0),
                      Colors.black.withValues(alpha: 0.75),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.3, 1.0],
                  ),
                ),
              ),
            ),
            // Category chip, top-left.
            Positioned(
              top: 14,
              left: 14,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (item['pinned'] == true) ...[
                      Icon(Icons.push_pin_rounded, color: textDark, size: 11),
                      const SizedBox(width: 4),
                    ] else ...[
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: _newsColor(kind),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      _newsLabel(kind),
                      style: TextStyle(
                        color: textDark,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Title + byline, bottom-left.
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item['title_tl'] as String? ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildByline(
                    source: item['source_name'] as String? ?? 'GRID',
                    timestamp: _newsDate(item),
                    light: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Small circular source badge + name + date ──────────────────────────
  Widget _buildByline({
    required String source,
    required String timestamp,
    bool light = false,
  }) {
    final textColor = light ? Colors.white : textDark;
    final mutedColor =
        light ? Colors.white.withValues(alpha: 0.75) : Colors.grey[500]!;

    return Row(
      children: [
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: primaryOrange,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 12),
        ),
        const SizedBox(width: 6),
        Text(
          source,
          style: TextStyle(
            color: textColor,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (timestamp.isNotEmpty) ...[
          const SizedBox(width: 6),
          Text('·', style: TextStyle(color: mutedColor, fontSize: 11)),
          const SizedBox(width: 6),
          Text(
            timestamp,
            style: TextStyle(
              color: mutedColor,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }

  // ── NEWS: article row — square image or drawn tile, tag, title, byline ──
  Widget _buildNewsListItem(Map<String, dynamic> item) {
    final kind = item['kind'] as String?;
    final categoryColor = _newsColor(kind);

    return GestureDetector(
      onTap: () => _showNewsDetail(item),
      child: Container(
        margin: const EdgeInsets.only(bottom: 14.0),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: _networkImage(
                item['image_url'] as String?,
                width: 72,
                height: 72,
                fallback: _buildNewsArt(item, width: 72, height: 72),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: categoryColor.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _newsLabel(kind),
                      style: TextStyle(
                        color: categoryColor,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    item['title_tl'] as String? ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textDark,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildByline(
                    source: item['source_name'] as String? ?? 'GRID',
                    timestamp: _newsDate(item),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── NEWS: full item in a bottom sheet, with a link to the source ───────
  void _showNewsDetail(Map<String, dynamic> item) {
    final kind = item['kind'] as String?;
    final imageUrl = item['image_url'] as String?;
    final imageCredit = item['image_credit'] as String?;
    final body = item['body_tl'] as String?;
    final adminNote = item['admin_note_tl'] as String?;
    final attribution = item['attribution_tl'] as String?;
    final sourceUrl = item['source_url'] as String?;
    final sourceName = item['source_name'] as String? ?? 'Meralco';
    final date = _newsDate(item);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 36),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: _networkImage(
                  imageUrl,
                  width: double.infinity,
                  height: 180,
                  fallback: _buildNewsArt(
                    item,
                    width: double.infinity,
                    height: 180,
                    factsTop: 58,
                  ),
                ),
              ),
              if (imageUrl != null && imageCredit != null) ...[
                const SizedBox(height: 6),
                Text(
                  imageCredit,
                  style: TextStyle(color: Colors.grey[500], fontSize: 11.5),
                ),
              ],
              const SizedBox(height: 18),
              Text(
                _newsLabel(kind),
                style: TextStyle(
                  color: _newsColor(kind),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                item['title_tl'] as String? ?? '',
                style: TextStyle(
                  color: textDark,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  height: 1.2,
                  letterSpacing: -0.4,
                ),
              ),
              if (date.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  date,
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (body != null) ...[
                const SizedBox(height: 16),
                Text(
                  body,
                  style: TextStyle(
                    color: Colors.grey[800],
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
              ],
              if (adminNote != null) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: primaryOrange.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.bolt_rounded, color: primaryOrange, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          adminNote,
                          style: TextStyle(
                            color: Colors.grey[800],
                            fontSize: 14,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (attribution != null) ...[
                const SizedBox(height: 16),
                Text(
                  attribution,
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ],
              if (sourceUrl != null) ...[
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: FilledButton.icon(
                    onPressed: () => _openSource(sourceUrl),
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: Text(
                      'Basahin sa $sourceName',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: textDark,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(100),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openSource(String url) async {
    final uri = Uri.tryParse(url);
    var opened = false;
    if (uri != null) {
      try {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (e) {
        debugPrint("🔴 ERROR OPENING SOURCE: $e");
      }
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't open the link.")),
      );
    }
  }

  // ── WEEKLY BAR CHART (backed by data from the weekly-comparison endpoint,
  // with today's slot kept live via the Firebase listener). Renders either
  // a single "This Week" series or, when _showComparison is on, grouped
  // bars per day so last week and this week can be read side by side. ─────
  Widget _buildWeeklyBarChart() {
    final maxThisWeek =
        _thisWeek.isEmpty ? 0.0 : _thisWeek.reduce((a, b) => a > b ? a : b);
    final maxLastWeek =
        _lastWeek.isEmpty ? 0.0 : _lastWeek.reduce((a, b) => a > b ? a : b);
    final maxVal = _showComparison
        ? (maxThisWeek > maxLastWeek ? maxThisWeek : maxLastWeek)
        : maxThisWeek;
    final maxY = maxVal == 0 ? 1.0 : maxVal * 1.3;
    final midY = maxY / 2;

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
              final day = _weekDayLabels[groupIndex];
              // In comparison mode rodIndex 0 = last week, 1 = this week.
              final seriesLabel = _showComparison
                  ? (rodIndex == 0 ? 'Last Week' : 'This Week')
                  : day;
              final label = _showComparison ? '$day · $seriesLabel' : day;
              return BarTooltipItem(
                '$label\n${rod.toY.toStringAsFixed(2)} kWh',
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
                final isToday = index == _todayIndex;
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
          if (_showComparison) {
            // Two rods per day: last week (muted) then this week (orange),
            // shown side by side so the two weeks are directly comparable.
            return BarChartGroupData(
              x: i,
              barsSpace: 4,
              barRods: [
                BarChartRodData(
                  toY: _lastWeek[i],
                  color: lastWeekBar,
                  width: 10,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(4),
                    topRight: Radius.circular(4),
                  ),
                ),
                BarChartRodData(
                  toY: _thisWeek[i],
                  color: primaryOrange,
                  width: 10,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(4),
                    topRight: Radius.circular(4),
                  ),
                ),
              ],
            );
          }

          final isToday = i == _todayIndex;
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