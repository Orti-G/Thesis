import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

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

  // Same FastAPI VM used by Dashboard for historical, non-today data.
  static const String _apiBaseUrl = 'http://35.209.250.46:8000';

  // ── CLIENT-SIDE CACHE for finalized past days ───────────────────────────
  // 'static' so it survives navigating away from and back to this screen
  // within the same app session (a new State object is created each time,
  // but a static field is shared across all of them). Only ever populated
  // with SUCCESSFUL fetches for days that are fully in the past — today's
  // total is live and must never be cached, and a failed/404 fetch is
  // deliberately NOT cached, so a transient network error doesn't
  // permanently show 0 for that date for the rest of the session.
  // Keyed by 'yyyy-MM-dd'. Resets on app restart (in-memory only).
  static final Map<String, double> _dayTotalCache = {};

  final List<String> _weekDayLabels = const [
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'
  ];

  // ── LIVE WEEKLY DATA STATE ────────────────────────────────────────────
  // Index 0 = Monday ... 6 = Sunday, for both weeks.
  List<double> _thisWeek = List<double>.filled(7, 0.0);
  List<double> _lastWeek = List<double>.filled(7, 0.0);
  bool _isLoadingWeekly = true;
  String? _weeklyError;

  StreamSubscription<DatabaseEvent>? _todaySubscription;
  late DateTime _weekMonday; // Monday of the current week, midnight
  int _todayIndex = 0; // 0=Mon ... 6=Sun

  @override
  void initState() {
    super.initState();
    _loadWeeklyData();
  }

  @override
  void dispose() {
    _todaySubscription?.cancel();
    super.dispose();
  }

  // ── FETCH: whole week (this week's past days + all of last week) ───────
  Future<void> _loadWeeklyData() async {
    setState(() {
      _isLoadingWeekly = true;
      _weeklyError = null;
    });

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // DateTime.weekday: Mon=1 ... Sun=7, so this lines up with our 0-6 index.
    _weekMonday = today.subtract(Duration(days: today.weekday - 1));
    _todayIndex = today.weekday - 1;
    final lastWeekMonday = _weekMonday.subtract(const Duration(days: 7));

    try {
      final thisWeekResults = await Future.wait(
        List.generate(7, (i) {
          final date = _weekMonday.add(Duration(days: i));
          if (i == _todayIndex) {
            // Handled live by _attachTodayListener; leave as 0 for now.
            return Future.value(0.0);
          }
          if (date.isAfter(today)) {
            // Hasn't happened yet.
            return Future.value(0.0);
          }
          return _fetchDayTotal(date);
        }),
      );

      final lastWeekResults = await Future.wait(
        List.generate(
          7,
          (i) => _fetchDayTotal(lastWeekMonday.add(Duration(days: i))),
        ),
      );

      if (!mounted) return;
      setState(() {
        _thisWeek = thisWeekResults;
        _lastWeek = lastWeekResults;
        _isLoadingWeekly = false;
      });
    } catch (e) {
      debugPrint("🔴 ERROR LOADING WEEKLY DATA: $e");
      if (!mounted) return;
      setState(() {
        _isLoadingWeekly = false;
        _weeklyError = 'Failed to load weekly data';
      });
    }

    _attachTodayListener();
  }

  // ── FETCH: a single past day's total via FastAPI, cache-aware ──────────
  // Checks the static cache first; only writes to the cache on a confirmed
  // successful response, so transient errors/404s are retried next time
  // instead of being permanently remembered as 0.
  Future<double> _fetchDayTotal(DateTime date) async {
    final dateStr = DateFormat('yyyy-MM-dd').format(date);

    final cached = _dayTotalCache[dateStr];
    if (cached != null) {
      return cached;
    }

    try {
      final response = await http
          .get(Uri.parse('$_apiBaseUrl/history/$dateStr'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final List<dynamic> rows = body['data'] as List<dynamic>? ?? [];
        double total = 0.0;
        for (final row in rows) {
          final kwh = (row['total_kwh'] as num?)?.toDouble();
          if (kwh != null) total += kwh;
        }
        _dayTotalCache[dateStr] = total; // cache only on confirmed success
        return total;
      }
    } catch (e) {
      debugPrint("🔴 ERROR FETCHING DAY TOTAL for $dateStr: $e");
    }
    return 0.0; // 404 / no data / error → 0 for this call, but NOT cached
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

  // ── PLACEHOLDER: LOGS, shown as a real news feed (featured + list) ──────
  // 'image' is a placeholder network image until a real source/CDN is wired
  // up — swap for the actual advisory/report photo URL from the backend.
  // First entry is the "Breaking"-style featured item; the rest are the list.
  final List<Map<String, dynamic>> _logEntries = const [
    {
      'image': 'https://picsum.photos/seed/tier-warning/900/700',
      'category': 'Babala',
      'categoryColor': Color(0xFFE53935),
      'title': 'Papalapit ka na sa Tier 2 batay sa kasalukuyang paggamit',
      'source': 'EnergyWatch PH',
      'timestamp': '5m ago',
      'featured': true,
    },
    {
      'image': 'https://picsum.photos/seed/efficiency-report/500/500',
      'category': 'Ulat',
      'categoryColor': Color(0xFF2E7D32),
      'title': 'Bumuti ng 5% ang energy efficiency mo kahapon',
      'source': 'EnergyWatch PH',
      'timestamp': 'Kahapon',
    },
    {
      'image': 'https://picsum.photos/seed/unplug-tip/500/500',
      'category': 'Tip',
      'categoryColor': Color(0xFFF26E22),
      'title': 'I-unplug ang mga aparatong idle para makatipid',
      'source': 'EnergyWatch PH',
      'timestamp': 'Aug 12, 2026',
    },
    {
      'image': 'https://picsum.photos/seed/night-usage/500/500',
      'category': 'Babala',
      'categoryColor': Color(0xFFE53935),
      'title': 'Hindi pangkaraniwang paggamit noong gabi',
      'source': 'EnergyWatch PH',
      'timestamp': 'Aug 10, 2026',
    },
  ];

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

  @override
  Widget build(BuildContext context) {
    final isUp = _pctChange >= 0;
    final featured = _logEntries.firstWhere(
      (e) => e['featured'] == true,
      orElse: () => _logEntries.first,
    );
    final restLogs =
        _logEntries.where((e) => e != featured).toList(growable: false);

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

                  // ── LOGS: header ──────────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24.0, 16.0, 24.0, 12.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Logs',
                          style: TextStyle(
                            color: textDark,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'Tingnan Lahat',
                          style: TextStyle(
                            color: primaryOrange,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ── LOGS: featured card ──────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: _buildFeaturedLogCard(featured),
                  ),

                  const SizedBox(height: 20),

                  // ── LOGS: article-style list ─────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Column(
                      children: [
                        for (final entry in restLogs) _buildLogListItem(entry),
                      ],
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

  // ── Shared network-image loader with a spinner + graceful fallback ──────
  // url is nullable: real log entries may not have a photo yet, so a null
  // or empty url renders the same fallback tile instead of throwing.
  Widget _networkImage(String? url, {required double? width, required double? height, BoxFit fit = BoxFit.cover}) {
    if (url == null || url.isEmpty) {
      return Container(
        width: width,
        height: height,
        color: const Color(0xFFF4F5F7),
        child: const Center(
          child: Icon(Icons.image_outlined, color: Color(0xFFBDBDBD), size: 22),
        ),
      );
    }
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
      errorBuilder: (context, error, stack) {
        return Container(
          width: width,
          height: height,
          color: const Color(0xFFF4F5F7),
          child: const Center(
            child: Icon(Icons.image_not_supported_outlined,
                color: Color(0xFFBDBDBD), size: 22),
          ),
        );
      },
    );
  }

  // ── LOGS: "Breaking"-style featured card with a real photo background ───
  Widget _buildFeaturedLogCard(Map<String, dynamic> entry) {
    final categoryColor = entry['categoryColor'] as Color? ?? primaryOrange;
    final category = entry['category'] as String? ?? 'Log';
    final title = entry['title'] as String? ?? 'Walang pamagat';
    final source = entry['source'] as String? ?? 'EnergyWatch PH';
    final timestamp = entry['timestamp'] as String? ?? '';

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Stack(
        children: [
          _networkImage(
            entry['image'] as String?,
            width: double.infinity,
            height: 220,
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
                  Container(
                    width: 6,
                    height: 6,
                    decoration:
                        BoxDecoration(color: categoryColor, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    category,
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
                  title,
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
                  source: source,
                  timestamp: timestamp,
                  light: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Small circular source badge + name + verified check + timestamp ─────
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
        const SizedBox(width: 3),
        Icon(Icons.verified_rounded,
            color: light ? Colors.white : primaryOrange, size: 13),
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
    );
  }

  // ── LOGS: article row — square photo, category tag, title, byline ───────
  Widget _buildLogListItem(Map<String, dynamic> entry) {
    final categoryColor = entry['categoryColor'] as Color? ?? primaryOrange;
    final category = entry['category'] as String? ?? 'Log';
    final title = entry['title'] as String? ?? 'Walang pamagat';
    final source = entry['source'] as String? ?? 'EnergyWatch PH';
    final timestamp = entry['timestamp'] as String? ?? '';

    return Container(
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
              entry['image'] as String?,
              width: 72,
              height: 72,
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
                    category.toUpperCase(),
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
                  title,
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
                  source: source,
                  timestamp: timestamp,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── WEEKLY BAR CHART (now backed by real fetched data) ──────────────────
  Widget _buildWeeklyBarChart() {
    final maxVal =
        _thisWeek.isEmpty ? 0.0 : _thisWeek.reduce((a, b) => a > b ? a : b);
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