import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show lerpDouble;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'bakit_expander.dart';
import 'rolling_number.dart';

class AdvisoriesScreen extends StatefulWidget {
  const AdvisoriesScreen({super.key});

  @override
  State<AdvisoriesScreen> createState() => _AdvisoriesScreenState();
}

// What one header tile shows: the week's summary, or the day being scrubbed.
typedef _TileData = ({String label, String value, String? unit, IconData? icon});

class _AdvisoriesScreenState extends State<AdvisoriesScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final Color primaryOrange = const Color(0xFFF26E22);
  final Color topCardColor = const Color(0xFFFA8B39);
  final Color bgColor = const Color(0xFFFAFAFA);
  final Color textDark = const Color(0xFF1E1E1E);
  // #F26E22 is only ~2.9:1 on white, so orange text on white uses this.
  final Color orangeInk = const Color(0xFFC2501A);
  final Color hairline = const Color(0xFFECECEC);
  final Color upText = const Color(0xFFE53935);
  final Color downText = const Color(0xFF2E7D32);

  // Same FastAPI VM used by Dashboard for historical, non-today data.
  static const String _apiBaseUrl = 'http://35.209.250.46:8000';

  // Chart runs Sunday -> Saturday.
  static const List<String> _weekDayLabels = [
    'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat',
  ];

  static const List<String> _weekDayNames = [
    'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday',
    'Saturday',
  ];

  static const List<String> _monthAbbr = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  // ── WEEKLY DATA STATE ─────────────────────────────────────────────────
  // Index 0 = Sunday ... 6 = Saturday, for both weeks. `_apiThisWeek` is
  // the API snapshot; today's slot is overlaid live from Firebase.
  List<double> _apiThisWeek = List<double>.filled(7, 0.0);
  List<double> _lastWeek = List<double>.filled(7, 0.0);
  bool _isLoadingWeekly = true;
  bool _hasWeeklyData = false;
  String? _weeklyError;

  // The calendar day the loaded week belongs to. Checked every minute (and
  // on resume) so a screen left open past midnight reloads instead of
  // writing tomorrow's total into today's bar.
  DateTime _weekDay = _dateOnly(DateTime.now());
  int get _todayIndex => _weekDay.weekday % 7; // Sun=0 ... Sat=6

  StreamSubscription<DatabaseEvent>? _todaySubscription;
  double? _liveToday;
  DateTime? _liveTodayDate;

  // ── CHART STATE ───────────────────────────────────────────────────────
  bool _showLastWeek = true;
  int? _scrubDay; // day under the finger; null when not scrubbing
  Timer? _peekTimer;
  static const String _scrubHintKey = 'advisories_scrub_hint_seen';
  bool _showScrubHint = false;
  bool _reduceMotion = false;

  // Bars rise once when the week first arrives; last week's bars slide in
  // and out with the "Last week" chip.
  late final AnimationController _barsRise = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  late final Animation<double> _barsRiseCurve = CurvedAnimation(
    parent: _barsRise,
    curve: Curves.easeOutCubic,
  );
  late final AnimationController _lastWeekReveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1,
  );
  late final Animation<double> _lastWeekRevealCurve = CurvedAnimation(
    parent: _lastWeekReveal,
    curve: Curves.easeInOutCubic,
  );

  // ── ADVISORIES + NEWS FEED (Firebase, written only by the backend) ─────
  // Both arrive in Tagalog, ready to show; the app never rewrites them.
  StreamSubscription<DatabaseEvent>? _advisoriesSubscription;
  StreamSubscription<DatabaseEvent>? _newsSubscription;
  List<Map<String, dynamic>> _advisories = [];
  bool _isLoadingAdvisories = true;
  String? _advisoriesError;
  List<Map<String, dynamic>> _newsItems = [];
  bool _isLoadingNews = true;
  String? _newsError;

  // Firebase never errors while offline, it just waits, so the desks watch
  // `.info/connected` instead of spinning forever. It reads false for a
  // moment on every launch, hence the grace period before saying so.
  StreamSubscription<DatabaseEvent>? _connectionSubscription;
  bool _isOnline = true;
  bool _connectionGraceOver = false;
  Timer? _connectionGrace;
  bool get _showOffline => !_isOnline && _connectionGraceOver;

  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(_onTabChanged);
  final ScrollController _scroll = ScrollController();
  final GlobalKey _headerKey = GlobalKey();
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadWeeklyData();
    _attachTodayListener();
    _attachAdvisoriesListener();
    _attachNewsListener();
    _attachConnectionListener();
    _loadScrubHint();
    // Keeps "2h ago" labels current and drops advisories past their window.
    _clock = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _tick();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
    _peekTimer?.cancel();
    _connectionGrace?.cancel();
    _connectionSubscription?.cancel();
    _todaySubscription?.cancel();
    _advisoriesSubscription?.cancel();
    _newsSubscription?.cancel();
    _barsRise.dispose();
    _lastWeekReveal.dispose();
    _tabs.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    if (!DateUtils.isSameDay(DateTime.now(), _weekDay)) {
      _loadWeeklyData();
    } else {
      setState(() {});
    }
  }

  static DateTime _dateOnly(DateTime t) => DateTime(t.year, t.month, t.day);

  // ── FETCH: single call to /history/weekly-comparison ────────────────────
  // The backend pre-aggregates both weeks server-side in one response, so
  // this is always exactly 1 HTTP call.
  Future<void> _loadWeeklyData() async {
    setState(() {
      _isLoadingWeekly = true;
      _weeklyError = null;
      _weekDay = _dateOnly(DateTime.now());
      _scrubDay = null;
    });

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

      final thisWeekData = _parseWeekData(
        currentWeek['data'] as List<dynamic>? ?? [],
        _thisWeekStart,
      );
      final lastWeekData = _parseWeekData(
        lastWeek['data'] as List<dynamic>? ?? [],
        _lastWeekStart,
      );

      if (!mounted) return;
      setState(() {
        _apiThisWeek = thisWeekData;
        _lastWeek = lastWeekData;
        _isLoadingWeekly = false;
        _hasWeeklyData = true;
      });
      if (_reduceMotion) {
        _barsRise.value = 1;
      } else if (_barsRise.value == 0) {
        _barsRise.forward();
      }
    } catch (e) {
      debugPrint("🔴 ERROR LOADING WEEKLY COMPARISON: $e");
      if (!mounted) return;
      setState(() {
        _apiThisWeek = List<double>.filled(7, 0.0);
        _lastWeek = List<double>.filled(7, 0.0);
        _isLoadingWeekly = false;
        _hasWeeklyData = false;
        _weeklyError = "Couldn't load this week's usage";
      });
    }
  }

  // ── Map the API's {date, daily_kwh} rows onto a fixed Sun..Sat array ────
  // Rows are placed by their calendar date relative to [weekStart], not by
  // list position; rows outside that week are ignored and missing days
  // (e.g. days that haven't happened yet) stay at 0.0.
  List<double> _parseWeekData(List<dynamic> rows, DateTime weekStart) {
    final result = List<double>.filled(7, 0.0);
    for (final row in rows) {
      if (row is! Map) continue;
      final dateStr = row['date'] as String?;
      final kwh = (row['daily_kwh'] as num?)?.toDouble();
      if (dateStr == null || kwh == null) continue;
      final date = DateTime.tryParse(dateStr);
      if (date == null) continue;
      final index = _dateOnly(date).difference(weekStart).inHours ~/ 24;
      if (index >= 0 && index < 7) {
        result[index] = kwh;
      }
    }
    return result;
  }

  // ── LIVE: today's running total via Firebase `history/today`, same
  // node Dashboard listens to for its hourly chart. The node carries its
  // own date, so a total is only ever placed on the day it belongs to. ───
  void _attachTodayListener() {
    _todaySubscription?.cancel();
    final ref = FirebaseDatabase.instance.ref('history/today');
    _todaySubscription = ref.onValue.listen((event) {
      if (!mounted) return;
      double total = 0.0;
      DateTime? date;

      if (event.snapshot.value != null) {
        try {
          final data = Map<String, dynamic>.from(event.snapshot.value as Map);
          date = DateTime.tryParse('${data['date'] ?? ''}');
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
        _liveToday = total;
        _liveTodayDate = _dateOnly(date ?? DateTime.now());
      });
      // Midnight passed: the device is on the phone's new day, but the
      // loaded week is still yesterday's.
      if (_liveTodayDate!.isAfter(_weekDay) &&
          DateUtils.isSameDay(_liveTodayDate, DateTime.now())) {
        _loadWeeklyData();
      }
    });
  }

  List<double> get _thisWeek {
    final values = List<double>.of(_apiThisWeek);
    final live = _liveToday;
    final liveDate = _liveTodayDate;
    if (live != null &&
        liveDate != null &&
        DateUtils.isSameDay(liveDate, _weekDay)) {
      values[_todayIndex] = live;
    }
    return values;
  }

  // ── ADVISORIES: `/advisories/{category}` holds the latest message per
  // topic. anomaly and review are answered on the Alerts tab and device
  // lives on the Dashboard, so only these are shown here. ─────────────────
  static const Set<String> _advisoryCategories = {
    'bracket', 'cycle', 'daily', 'rates', 'weekly',
  };

  void _attachAdvisoriesListener() {
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
      setState(() {
        _advisories = records;
        _isLoadingAdvisories = false;
        _advisoriesError = null;
      });
    }, onError: (Object e) {
      debugPrint("🔴 ERROR LOADING ADVISORIES: $e");
      if (mounted) {
        setState(() {
          _isLoadingAdvisories = false;
          _advisoriesError = "Couldn't load advisories";
        });
      }
    });
  }

  void _attachNewsListener() {
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
        _newsError = null;
      });
    }, onError: (Object e) {
      debugPrint("🔴 ERROR LOADING NEWS FEED: $e");
      if (mounted) {
        setState(() {
          _isLoadingNews = false;
          _newsError = "Couldn't load news";
        });
      }
    });
  }

  void _attachConnectionListener() {
    _connectionGrace = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _connectionGraceOver = true);
    });
    _connectionSubscription = FirebaseDatabase.instance
        .ref('.info/connected')
        .onValue
        .listen((event) {
      if (!mounted) return;
      final online = event.snapshot.value == true;
      final reconnected = online && !_isOnline;
      setState(() => _isOnline = online);
      // Back online after a failed week load: fetch it without a tap.
      if (reconnected && _weeklyError != null) _loadWeeklyData();
    });
  }

  void _retryAdvisories() {
    setState(() {
      _isLoadingAdvisories = true;
      _advisoriesError = null;
    });
    _attachAdvisoriesListener();
  }

  void _retryNews() {
    setState(() {
      _isLoadingNews = true;
      _newsError = null;
    });
    _attachNewsListener();
  }

  int _priorityOf(dynamic raw) =>
      raw is num ? raw.toInt() : int.tryParse('$raw') ?? 99;

  // Advisory and feed timestamps carry a zone (+08:00 / UTC), so they're
  // converted to the phone's local time. Unparseable values sort last.
  DateTime _parseInstant(dynamic raw) =>
      DateTime.tryParse('${raw ?? ''}')?.toLocal() ??
      DateTime.fromMillisecondsSinceEpoch(0);

  // ── FRESHNESS: each topic only holds while what it describes does ──────
  // Meralco bills this household from the 28th to the 27th, the window the
  // backend's cycle and bracket advisories describe.
  static const int _cycleStartDay = 28;

  DateTime _cycleStart(DateTime day) => day.day >= _cycleStartDay
      ? DateTime(day.year, day.month, _cycleStartDay)
      : DateTime(day.year, day.month - 1, _cycleStartDay);

  bool _isFresh(Map<String, dynamic> advisory, DateTime now) {
    final t = DateTime.tryParse('${advisory['timestamp'] ?? ''}')?.toLocal();
    if (t == null) return false;
    final today = _dateOnly(now);
    switch (advisory['category']) {
      case 'daily': // about today only
        return !t.isBefore(today);
      case 'weekly': // about this Sunday-to-Saturday week
        return !t.isBefore(today.subtract(Duration(days: today.weekday % 7)));
      case 'cycle': // a projection, rewritten every morning
        return now.difference(t) <= const Duration(hours: 48);
      default: // bracket, rates: true for the rest of the billing cycle
        return !t.isBefore(_cycleStart(today));
    }
  }

  List<Map<String, dynamic>> get _freshAdvisories {
    final now = DateTime.now();
    return _advisories.where((a) => _isFresh(a, now)).toList();
  }

  String _formatAge(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (DateUtils.isSameDay(t, now)) return '${diff.inHours}h ago';
    if (DateUtils.isSameDay(t, now.subtract(const Duration(days: 1)))) {
      return 'Yesterday';
    }
    if (diff.inDays < 7) return _weekDayLabels[t.weekday % 7];
    return _formatDate(t);
  }

  // ── DERIVED STATS ────────────────────────────────────────────────────
  // Week-over-week only counts days that are over. Today is still running,
  // so comparing it with a full day last week would understate this week;
  // the backend's weekly advisory uses the same rule, so the two agree.
  int get _completedDays => _todayIndex;

  double _sumOf(List<double> values, int days) =>
      values.take(days).fold(0.0, (sum, v) => sum + v);

  double? get _dailyAverage => _completedDays == 0
      ? null
      : _sumOf(_thisWeek, _completedDays) / _completedDays;

  double? get _weekChangePct {
    if (_completedDays == 0) return null;
    final last = _sumOf(_lastWeek, _completedDays);
    if (last <= 0) return null;
    return (_sumOf(_thisWeek, _completedDays) - last) / last * 100;
  }

  // ── WEEK DATE SPANS ──────────────────────────────────────────────────
  DateTime get _thisWeekStart =>
      _weekDay.subtract(Duration(days: _todayIndex));

  DateTime get _lastWeekStart =>
      _thisWeekStart.subtract(const Duration(days: 7));

  String _formatDate(DateTime d) => '${_monthAbbr[d.month - 1]} ${d.day}';

  String _formatDayDate(DateTime d) =>
      '${_weekDayLabels[d.weekday % 7]}, ${_formatDate(d)}';

  String _formatWeekSpan(DateTime start) {
    final end = start.add(const Duration(days: 6));
    // Skip the repeated month when the span stays within one month.
    if (start.month == end.month) {
      return '${_monthAbbr[start.month - 1]} ${start.day}–${end.day}';
    }
    return '${_formatDate(start)} – ${_formatDate(end)}';
  }

  String _formatKwh(double v) => v.toStringAsFixed(2);

  // ── HEADER TILES: the week's summary, or the day under the finger ──────
  (_TileData, _TileData) _tileData() {
    const none = '—';
    final day = _scrubDay;
    final thisWeek = _thisWeek;

    if (!_hasWeeklyData) {
      return (
        (label: 'Daily average', value: none, unit: null, icon: null),
        (label: 'vs last week', value: none, unit: null, icon: null),
      );
    }

    if (day == null) {
      if (_completedDays == 0) {
        // Sunday: no finished day to average or compare yet.
        return (
          (
            label: 'Today so far',
            value: _formatKwh(thisWeek[_todayIndex]),
            unit: 'kWh',
            icon: null,
          ),
          (label: 'vs last week', value: none, unit: 'from Mon', icon: null),
        );
      }
      final span = _completedDays == 1
          ? _weekDayLabels[0]
          : '${_weekDayLabels[0]}–${_weekDayLabels[_completedDays - 1]}';
      return (
        (
          label: 'Daily average',
          value: _formatKwh(_dailyAverage!),
          unit: 'kWh',
          icon: null,
        ),
        _changeTile('vs last $span', _weekChangePct),
      );
    }

    final date = _thisWeekStart.add(Duration(days: day));
    final lastDate = date.subtract(const Duration(days: 7));
    final isToday = day == _todayIndex;
    final isFuture = day > _todayIndex;
    final left = (
      label: isToday ? 'Today so far' : _formatDayDate(date),
      value: isFuture ? none : _formatKwh(thisWeek[day]),
      unit: isFuture ? 'not yet' : 'kWh',
      icon: null,
    );
    // Only a finished day is compared; today and later show last week's
    // figure as it was.
    if (isToday || isFuture || _lastWeek[day] <= 0) {
      return (
        left,
        (
          label: _formatDayDate(lastDate),
          value: _lastWeek[day] > 0 ? _formatKwh(_lastWeek[day]) : none,
          unit: _lastWeek[day] > 0 ? 'kWh' : null,
          icon: null,
        ),
      );
    }
    return (
      left,
      _changeTile(
        'vs ${_formatDayDate(lastDate)}',
        (thisWeek[day] - _lastWeek[day]) / _lastWeek[day] * 100,
      ),
    );
  }

  _TileData _changeTile(String label, double? pct) {
    if (pct == null) {
      return (label: label, value: '—', unit: null, icon: null);
    }
    final rounded = pct.abs().round();
    if (rounded == 0) {
      return (label: label, value: '0%', unit: 'no change', icon: null);
    }
    return (
      label: label,
      value: '$rounded%',
      unit: pct > 0 ? 'more' : 'less',
      icon: pct > 0
          ? Icons.arrow_upward_rounded
          : Icons.arrow_downward_rounded,
    );
  }

  // ── SCRUB: hold or tap a day to read it against last week ─────────────
  Future<void> _loadScrubHint() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _showScrubHint = !(prefs.getBool(_scrubHintKey) ?? false));
  }

  void _dismissScrubHint() {
    if (!_showScrubHint) return;
    setState(() => _showScrubHint = false);
    SharedPreferences.getInstance().then((p) => p.setBool(_scrubHintKey, true));
  }

  void _scrubTo(int day, {bool begin = false}) {
    if (!_hasWeeklyData) return;
    if (begin) {
      _peekTimer?.cancel();
      _dismissScrubHint();
    }
    if (day == _scrubDay) return;
    HapticFeedback.selectionClick();
    setState(() => _scrubDay = day);
  }

  // A tap shows that day for a moment, for anyone who taps instead of
  // holding.
  void _peekAt(int day) {
    _scrubTo(day, begin: true);
    if (_scrubDay == null) return;
    _peekTimer = Timer(const Duration(milliseconds: 1800), _releaseScrub);
  }

  void _releaseScrub() {
    _peekTimer?.cancel();
    if (_scrubDay == null) return;
    setState(() => _scrubDay = null);
  }

  void _toggleLastWeek() {
    setState(() => _showLastWeek = !_showLastWeek);
    final target = _showLastWeek ? 1.0 : 0.0;
    if (_reduceMotion) {
      _lastWeekReveal.value = target;
    } else {
      _lastWeekReveal.animateTo(target);
    }
  }

  // Switching desks keeps the tabs pinned but starts the new one at its top.
  void _onTabChanged() {
    setState(() {});
    final headerHeight = _headerKey.currentContext?.size?.height;
    if (headerHeight != null &&
        _scroll.hasClients &&
        _scroll.offset > headerHeight) {
      _scroll.jumpTo(headerHeight);
    }
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final advisories = _freshAdvisories;

    return Scaffold(
      backgroundColor: bgColor,
      body: Column(
        children: [
          // Status bar band: the header scrolls up underneath it, and the
          // tabs pin directly below it.
          Container(height: topInset, color: topCardColor),
          Expanded(
            child: CustomScrollView(
              controller: _scroll,
              slivers: [
                SliverToBoxAdapter(child: _buildHeader()),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _TabBarHeader(
                    tabBar: _buildTabBar(advisories.length),
                    rule: hairline,
                  ),
                ),
                if (_tabs.index == 0)
                  _buildAdvisoriesDesk(advisories)
                else
                  _buildNewsDesk(),
                const SliverToBoxAdapter(child: SizedBox(height: 120)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── HEADER: week tiles over the painted week ────────────────────────────
  Widget _buildHeader() {
    final scrubbing = _scrubDay != null;
    final (left, right) = _tileData();

    return Container(
      key: _headerKey,
      width: double.infinity,
      color: topCardColor,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: const Text(
                    'Advisories',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
              ),
              _buildLastWeekChip(),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _buildGlassTile(left, scrubbing)),
              const SizedBox(width: 12),
              Expanded(child: _buildGlassTile(right, scrubbing)),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(height: 150, child: _buildWeekChart()),
          const SizedBox(height: 8),
          _buildDayLabels(),
          // No key for bars that aren't there.
          if (_hasWeeklyData) ...[
            const SizedBox(height: 12),
            _buildLegend(),
          ],
        ],
      ),
    );
  }

  // Same translucent tile as the Dashboard header, without its backdrop
  // blur: over a flat orange the blur shows nothing and costs a full pass.
  Widget _buildGlassTile(_TileData data, bool scrubbing) {
    final swapDuration =
        _reduceMotion ? Duration.zero : const Duration(milliseconds: 180);
    const valueStyle = TextStyle(
      fontSize: 26,
      fontWeight: FontWeight.w800,
      color: Colors.white,
      letterSpacing: -0.5,
    );
    const unitStyle = TextStyle(
      fontSize: 13,
      color: Colors.white,
      fontWeight: FontWeight.w600,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.30),
            Colors.white.withValues(alpha: 0.08),
          ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.40),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwapText(
            mode: scrubbing,
            duration: swapDuration,
            text: data.label,
            style: const TextStyle(
              fontSize: 13,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                if (data.icon != null) ...[
                  Icon(data.icon, color: Colors.white, size: 22),
                  const SizedBox(width: 2),
                ],
                RollingNumber(data.value, style: valueStyle),
                if (data.unit != null) ...[
                  const SizedBox(width: 4),
                  Text(data.unit!, style: unitStyle),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Material filter chip for last week's bars, themed for the orange
  // header. The chip keeps its padded 48dp tap target.
  Widget _buildLastWeekChip() {
    final on = _showLastWeek;
    // The chip's Material layer is canvas-coloured by default, which would
    // turn the translucent unselected fill into an opaque off-white.
    return Theme(
      data: Theme.of(context).copyWith(canvasColor: Colors.transparent),
      child: _buildLastWeekFilterChip(on),
    );
  }

  Widget _buildLastWeekFilterChip(bool on) {
    return FilterChip(
      selected: on,
      onSelected: (_) => _toggleLastWeek(),
      label: const Text('Last week'),
      tooltip: on ? 'Hide last week' : 'Show last week',
      // The check replaces this when selected; an avatar left in place
      // gets Material's dark selection scrim painted over it.
      avatar: on
          ? null
          : const Icon(Icons.add_rounded, size: 18, color: Colors.white),
      showCheckmark: true,
      checkmarkColor: orangeInk,
      labelStyle: TextStyle(
        color: on ? orangeInk : Colors.white,
        fontSize: 13,
        fontWeight: FontWeight.w700,
      ),
      color: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : Colors.white.withValues(alpha: 0.18),
      ),
      elevation: 0,
      pressElevation: 0,
      side: BorderSide(color: Colors.white.withValues(alpha: on ? 1 : 0.55)),
      shape: const StadiumBorder(),
    );
  }

  String _chartSemanticsValue() {
    final thisWeek = _thisWeek;
    final parts = <String>[];
    for (var i = 0; i <= _todayIndex; i++) {
      final day = i == _todayIndex ? 'today so far' : _weekDayNames[i];
      var part = '$day ${thisWeek[i].toStringAsFixed(1)} kilowatt-hours';
      if (_showLastWeek && _lastWeek[i] > 0) {
        part += ', last week ${_lastWeek[i].toStringAsFixed(1)}';
      }
      parts.add(part);
    }
    return parts.join('; ');
  }

  Widget _buildWeekChart() {
    final hintVisible = _showScrubHint &&
        _hasWeeklyData &&
        !_isLoadingWeekly &&
        _scrubDay == null;

    return Semantics(
      container: true,
      label: _showLastWeek
          ? 'Daily energy use, this week and last week'
          : 'Daily energy use this week',
      value: _hasWeeklyData ? _chartSemanticsValue() : 'No data',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final slot = constraints.maxWidth / 7;
          int dayAt(double dx) => (dx / slot).floor().clamp(0, 6);

          return RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              // Holding still briefly starts a scrub; moving first scrolls.
              LongPressGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    LongPressGestureRecognizer
                  >(
                    () => LongPressGestureRecognizer(
                      duration: const Duration(milliseconds: 160),
                    ),
                    (r) {
                      r
                        ..onLongPressStart = (d) {
                          _scrubTo(dayAt(d.localPosition.dx), begin: true);
                        }
                        ..onLongPressMoveUpdate = (d) {
                          _scrubTo(dayAt(d.localPosition.dx));
                        }
                        ..onLongPressEnd = (_) => _releaseScrub();
                    },
                  ),
              TapGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                    () => TapGestureRecognizer(),
                    (r) => r
                      ..onTapUp = (d) => _peekAt(dayAt(d.localPosition.dx)),
                  ),
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                  child: CustomPaint(
                    painter: _WeekBarsPainter(
                      thisWeek: _thisWeek,
                      lastWeek: _lastWeek,
                      todayIndex: _todayIndex,
                      selectedDay: _scrubDay,
                      hasData: _hasWeeklyData,
                      rise: _barsRiseCurve,
                      reveal: _lastWeekRevealCurve,
                    ),
                  ),
                ),
                if (_isLoadingWeekly && !_hasWeeklyData)
                  const Center(
                    child: SizedBox(
                      height: 24,
                      width: 24,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    ),
                  )
                else if (_weeklyError != null)
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _weeklyError!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          onPressed: _loadWeeklyData,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            minimumSize: const Size(48, 48),
                            side: const BorderSide(color: Colors.white),
                            shape: const StadiumBorder(),
                            textStyle: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),

                // First-run hint, gone for good after the first scrub.
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: hintVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 250),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.12),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.touch_app_rounded,
                                size: 16,
                                color: primaryOrange,
                              ),
                              const SizedBox(width: 6),
                              const Flexible(
                                child: Text(
                                  'Hold a day to compare it with last week',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF2B1A10),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildDayLabels() {
    return ExcludeSemantics(
      child: Row(
        children: [
          for (var i = 0; i < 7; i++)
            Expanded(
              child: Text(
                _weekDayLabels[i],
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: i == _todayIndex
                      ? FontWeight.w900
                      : i == _scrubDay
                      ? FontWeight.w800
                      : FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Labelled with each week's calendar span rather than generic text.
  Widget _buildLegend() {
    const labelStyle = TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontWeight: FontWeight.w600,
    );

    Widget item(Widget swatch, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        swatch,
        const SizedBox(width: 6),
        Text(label, style: labelStyle),
      ],
    );

    Widget solid(double alpha) => Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: alpha),
        borderRadius: BorderRadius.circular(3),
      ),
    );

    return ExcludeSemantics(
      child: Wrap(
        spacing: 16,
        runSpacing: 6,
        children: [
          if (_showLastWeek)
            item(solid(0.38), _formatWeekSpan(_lastWeekStart)),
          item(solid(1), _formatWeekSpan(_thisWeekStart)),
          item(
            const SizedBox(
              width: 10,
              height: 10,
              child: CustomPaint(painter: _HatchSwatchPainter()),
            ),
            'Today so far',
          ),
        ],
      ),
    );
  }

  // ── TABS: one desk per job ──────────────────────────────────────────────
  TabBar _buildTabBar(int advisoryCount) {
    return TabBar(
      controller: _tabs,
      labelColor: orangeInk,
      unselectedLabelColor: const Color(0xFF5F6368),
      labelStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
      unselectedLabelStyle: const TextStyle(
        fontSize: 14.5,
        fontWeight: FontWeight.w600,
      ),
      indicatorSize: TabBarIndicatorSize.label,
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(width: 3, color: primaryOrange),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
      ),
      dividerColor: Colors.transparent,
      overlayColor: WidgetStatePropertyAll(
        primaryOrange.withValues(alpha: 0.08),
      ),
      tabs: [
        Tab(
          height: 52,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Flexible(
                child: Text('This week', overflow: TextOverflow.ellipsis),
              ),
              if (advisoryCount > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  constraints: const BoxConstraints(minWidth: 20),
                  decoration: BoxDecoration(
                    color: orangeInk,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$advisoryCount',
                    textAlign: TextAlign.center,
                    semanticsLabel: '$advisoryCount advisories',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const Tab(
          height: 52,
          child: Text('News & Tips', overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }

  // ── DESK 1: this week's advisories ──────────────────────────────────────
  Widget _buildAdvisoriesDesk(List<Map<String, dynamic>> advisories) {
    final Widget content;
    if (_isLoadingAdvisories && _showOffline) {
      content = _buildStateCard(
        icon: Icons.wifi_off_rounded,
        title: "You're offline",
        body: 'Advisories will appear once your phone is back online.',
      );
    } else if (_isLoadingAdvisories) {
      content = _buildLoadingState();
    } else if (_advisoriesError != null && advisories.isEmpty) {
      content = _buildStateCard(
        icon: Icons.cloud_off_rounded,
        title: _advisoriesError!,
        body: 'Check your internet connection, then try again.',
        onRetry: _retryAdvisories,
      );
    } else if (advisories.isEmpty) {
      content = _buildStateCard(
        icon: Icons.check_circle_outline_rounded,
        title: 'No advisories right now',
        body:
            "GRID posts here when your usage, your bill estimate or "
            "Meralco's rates change.",
      );
    } else {
      return SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        sliver: SliverList.list(
          children: [
            for (final advisory in advisories) _buildAdvisoryCard(advisory),
          ],
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      sliver: SliverToBoxAdapter(child: content),
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
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: hairline),
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
                  color: accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: accent, size: 17),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text(
                    title ?? '',
                    style: TextStyle(
                      color: textDark,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      height: 1.3,
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
                      color: Colors.grey[600],
                      fontSize: 12,
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
              style: const TextStyle(
                color: Color(0xFF444444),
                fontSize: 14,
                height: 1.45,
              ),
            ),
          ],
          BakitExpander(
            text: advisory['explain_tl'] as String?,
            accent: orangeInk,
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
        return (Icons.calendar_month_rounded, orangeInk);
      case 'daily':
        return (Icons.today_rounded, orangeInk);
      case 'rates':
        return (Icons.price_change_rounded, orangeInk);
      default: // weekly
        return (Icons.date_range_rounded, orangeInk);
    }
  }

  // ── DESK STATES: loading, empty and error ───────────────────────────────
  Widget _buildLoadingState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: primaryOrange,
          ),
        ),
      ),
    );
  }

  Widget _buildStateCard({
    required IconData icon,
    required String title,
    required String body,
    VoidCallback? onRetry,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              color: Color(0xFFF1F3F4),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: const Color(0xFF5F6368), size: 22),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: TextStyle(
              color: textDark,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: TextStyle(
              color: Colors.grey[700],
              fontSize: 14,
              height: 1.45,
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 6),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: orangeInk,
                padding: EdgeInsets.zero,
                minimumSize: const Size(48, 48),
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              child: const Text('Try again'),
            ),
          ],
        ],
      ),
    );
  }

  // ── DESK 2: News & Tips ─────────────────────────────────────────────────
  Widget _buildNewsDesk() {
    final Widget content;
    if (_newsItems.isEmpty) {
      if (_isLoadingNews && _showOffline) {
        content = _buildStateCard(
          icon: Icons.wifi_off_rounded,
          title: "You're offline",
          body: 'News and tips will appear once your phone is back online.',
        );
      } else if (_isLoadingNews) {
        content = _buildLoadingState();
      } else if (_newsError != null) {
        content = _buildStateCard(
          icon: Icons.cloud_off_rounded,
          title: _newsError!,
          body: 'Check your internet connection, then try again.',
          onRetry: _retryNews,
        );
      } else {
        content = _buildStateCard(
          icon: Icons.newspaper_rounded,
          title: 'No news yet',
          body:
              'Meralco announcements and tips from the GRID team will '
              'appear here.',
        );
      }
    } else {
      content = Column(
        children: [
          _buildFeaturedNewsCard(_newsItems.first),
          const SizedBox(height: 16),
          for (final item in _newsItems.skip(1)) _buildNewsListItem(item),
        ],
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      sliver: SliverToBoxAdapter(child: content),
    );
  }

  // ── NEWS & TIPS: kind → the plain word the byline uses ─────────────────
  String _newsKind(String? kind) {
    switch (kind) {
      case 'rate_change':
        return 'Rate change';
      case 'news':
        return 'News';
      case 'advisory':
        return 'Advisory';
      case 'maintenance':
        return 'Maintenance';
      default: // note: GRID's own
        return 'Tip';
    }
  }

  // The source's own date when there is one, otherwise when GRID published.
  String _newsDate(Map<String, dynamic> item) {
    final raw = item['source_date'] ?? item['published_at'];
    final parsed = DateTime.tryParse('${raw ?? ''}')?.toLocal();
    return parsed == null ? '' : _formatDate(parsed);
  }

  String? _imageUrlOf(Map<String, dynamic> item) {
    final url = item['image_url'] as String?;
    return url == null || url.isEmpty ? null : url;
  }

  // ── Shared network image: spinner while loading, nothing on failure ────
  // Feed images may not be set up in Firebase Storage yet, so a missing or
  // broken image leaves the item text-only rather than painting stand-in art.
  Widget _networkImage(
    String url, {
    required double? width,
    required double height,
  }) {
    return Image.network(
      url,
      width: width,
      height: height,
      fit: BoxFit.cover,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Container(
          width: width,
          height: height,
          color: const Color(0xFFF4F5F7),
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: primaryOrange,
              ),
            ),
          ),
        );
      },
      errorBuilder: (context, error, stack) => const SizedBox.shrink(),
    );
  }

  // ── A rate change's own figures (e.g. "+₱0.3191/kWh"), coloured by
  // direction: up red, down green, flat grey. Null when there are none. ───
  Widget? _buildRateFigures(Map<String, dynamic> item) {
    if (item['kind'] != 'rate_change') return null;
    final card = item['card'] as Map?;
    final change = card?['change_tl'] as String?;
    if (change == null) return null;
    final rateNew = card?['rate_new_tl'] as String?;
    final direction = card?['direction'];
    final color = switch (direction) {
      'up' => upText,
      'down' => downText,
      _ => const Color(0xFF5F6368),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (direction == 'up' || direction == 'down')
              Icon(
                direction == 'up'
                    ? Icons.arrow_upward_rounded
                    : Icons.arrow_downward_rounded,
                color: color,
                size: 26,
              ),
            Flexible(
              child: Text(
                change,
                style: TextStyle(
                  color: color,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
            ),
          ],
        ),
        if (rateNew != null)
          Text(
            rateNew,
            style: TextStyle(
              color: Colors.grey[700],
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }

  // ── Byline: source, kind and date in one plain line; a pin when pinned ─
  Widget _buildByline(Map<String, dynamic> item) {
    final line = [
      item['source_name'] as String? ?? 'GRID',
      _newsKind(item['kind'] as String?),
      _newsDate(item),
    ].where((part) => part.isNotEmpty).join(' · ');

    return Row(
      children: [
        if (item['pinned'] == true) ...[
          Icon(
            Icons.push_pin_rounded,
            size: 14,
            color: orangeInk,
            semanticLabel: 'Pinned',
          ),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            line,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.grey[700],
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  ShapeBorder get _newsCardShape => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(20),
    side: BorderSide(color: hairline),
  );

  // ── NEWS: featured item (pinned or newest), photo only when it has one ──
  Widget _buildFeaturedNewsCard(Map<String, dynamic> item) {
    final imageUrl = _imageUrlOf(item);
    final figures = _buildRateFigures(item);
    final body = item['body_tl'] as String?;

    return Material(
      color: Colors.white,
      shape: _newsCardShape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showNewsDetail(item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (imageUrl != null)
              _networkImage(imageUrl, width: double.infinity, height: 180),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (figures != null) ...[
                    figures,
                    const SizedBox(height: 12),
                  ],
                  Text(
                    item['title_tl'] as String? ?? '',
                    style: TextStyle(
                      color: textDark,
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                    ),
                  ),
                  if (body != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      body,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF444444),
                        fontSize: 14,
                        height: 1.45,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _buildByline(item),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── NEWS: article row — thumbnail only when there's a photo ────────────
  Widget _buildNewsListItem(Map<String, dynamic> item) {
    final imageUrl = _imageUrlOf(item);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white,
        shape: _newsCardShape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _showNewsDetail(item),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (imageUrl != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: _networkImage(imageUrl, width: 64, height: 64),
                  ),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item['title_tl'] as String? ?? '',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: textDark,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _buildByline(item),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: Colors.grey[500]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── NEWS: full item in a bottom sheet, with a link to the source ───────
  void _showNewsDetail(Map<String, dynamic> item) {
    final imageUrl = _imageUrlOf(item);
    final imageCredit = item['image_credit'] as String?;
    final figures = _buildRateFigures(item);
    final body = item['body_tl'] as String?;
    final adminNote = item['admin_note_tl'] as String?;
    final attribution = item['attribution_tl'] as String?;
    final sourceUrl = item['source_url'] as String?;
    final sourceName = item['source_name'] as String? ?? 'Meralco';

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
              if (imageUrl != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: _networkImage(
                    imageUrl,
                    width: double.infinity,
                    height: 180,
                  ),
                ),
                if (imageCredit != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    imageCredit,
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
                ],
                const SizedBox(height: 18),
              ],
              if (figures != null) ...[
                figures,
                const SizedBox(height: 14),
              ],
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
              const SizedBox(height: 8),
              _buildByline(item),
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
                      Icon(Icons.bolt_rounded, color: orangeInk, size: 18),
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
                    color: Colors.grey[600],
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
}

// Keeps the tab bar pinned under the status bar band once the header has
// scrolled away.
class _TabBarHeader extends SliverPersistentHeaderDelegate {
  _TabBarHeader({required this.tabBar, required this.rule});

  final TabBar tabBar;
  final Color rule;

  @override
  double get minExtent => tabBar.preferredSize.height + 1;

  @override
  double get maxExtent => tabBar.preferredSize.height + 1;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    // Fills the full extent; a pinned header that paints less than it
    // reserves is invalid sliver geometry.
    return SizedBox.expand(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: rule)),
        ),
        child: tabBar,
      ),
    );
  }

  @override
  bool shouldRebuild(_TabBarHeader oldDelegate) =>
      oldDelegate.tabBar != tabBar || oldDelegate.rule != rule;
}

/// This week's bars in white over last week's translucent ones, painted
/// straight onto the orange header. Today is still running, so its bar is
/// striped; days still to come show a stub on the baseline.
class _WeekBarsPainter extends CustomPainter {
  _WeekBarsPainter({
    required this.thisWeek,
    required this.lastWeek,
    required this.todayIndex,
    required this.selectedDay,
    required this.hasData,
    required this.rise,
    required this.reveal,
  }) : super(repaint: Listenable.merge([rise, reveal]));

  final List<double> thisWeek;
  final List<double> lastWeek;
  final int todayIndex;
  final int? selectedDay;
  final bool hasData;
  final Animation<double> rise; // 0 → 1, bars growing in on first load
  final Animation<double> reveal; // 0 → 1, last week's bars sliding in

  static const double topPad = 42; // room for the first-run hint

  @override
  void paint(Canvas canvas, Size size) {
    final slot = size.width / 7;
    final baseY = size.height - 0.5;
    final plotH = baseY - topPad;
    final peak = [...thisWeek, ...lastWeek].fold<double>(0, max);
    final maxY = peak <= 0 ? 1.0 : peak;
    final t = reveal.value;
    final grow = rise.value;
    double heightOf(double v) => (v / maxY).clamp(0.0, 1.0) * plotH * grow;

    for (var i = 0; i < 7; i++) {
      final cx = slot * (i + 0.5);
      final selected = selectedDay == i;
      final fade = selectedDay == null || selected ? 1.0 : 0.45;

      if (selected) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(cx - slot * 0.46, topPad - 12, cx + slot * 0.46,
                baseY),
            const Radius.circular(10),
          ),
          Paint()..color = Colors.white.withValues(alpha: 0.16),
        );
      }

      // One wide bar alone; a narrow pair once last week slides in.
      final singleW = min(22.0, slot * 0.46);
      final pairW = min(12.0, slot * 0.28);
      final gap = 3.0 * t;
      final lastW = pairW * t;
      final thisW = lerpDouble(singleW, pairW, t)!;
      final left = cx - (lastW + gap + thisW) / 2;

      if (lastW > 0.5 && lastWeek[i] > 0) {
        final h = heightOf(lastWeek[i]);
        _drawBar(
          canvas,
          Rect.fromLTWH(left, baseY - h, lastW, h),
          Paint()..color = Colors.white.withValues(alpha: 0.38 * t * fade),
        );
      }

      final x = left + lastW + gap;
      if (i > todayIndex) {
        // Without a loaded week there is nothing to mark as still to come.
        if (!hasData) continue;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, baseY - 3, thisW, 3),
            const Radius.circular(1.5),
          ),
          Paint()..color = Colors.white.withValues(alpha: 0.3 * fade),
        );
        continue;
      }
      final h = heightOf(thisWeek[i]);
      if (h < 0.5) continue;
      final bar = Rect.fromLTWH(x, baseY - h, thisW, h);
      if (i == todayIndex) {
        paintHatched(canvas, _shape(bar), fade);
      } else {
        _drawBar(
          canvas,
          bar,
          Paint()..color = Colors.white.withValues(alpha: fade),
        );
      }
    }

    canvas.drawLine(
      Offset(0, baseY),
      Offset(size.width, baseY),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.5)
        ..strokeWidth = 1,
    );
  }

  static RRect _shape(Rect r) {
    final radius = Radius.circular(min(5.0, r.width / 2));
    return RRect.fromRectAndCorners(r, topLeft: radius, topRight: radius);
  }

  static void _drawBar(Canvas canvas, Rect r, Paint paint) =>
      canvas.drawRRect(_shape(r), paint);

  static void paintHatched(Canvas canvas, RRect shape, double fade) {
    final r = shape.outerRect;
    canvas.drawRRect(
      shape,
      Paint()..color = Colors.white.withValues(alpha: 0.45 * fade),
    );
    canvas.save();
    canvas.clipRRect(shape);
    final stripe = Paint()
      ..color = Colors.white.withValues(alpha: fade)
      ..strokeWidth = 2.5;
    for (var x = r.left - r.height; x < r.right; x += 6) {
      canvas.drawLine(Offset(x, r.bottom), Offset(x + r.height, r.top), stripe);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WeekBarsPainter old) =>
      !listEquals(old.thisWeek, thisWeek) ||
      !listEquals(old.lastWeek, lastWeek) ||
      old.todayIndex != todayIndex ||
      old.selectedDay != selectedDay ||
      old.hasData != hasData ||
      old.rise != rise ||
      old.reveal != reveal;
}

// Legend swatch for today's striped bar.
class _HatchSwatchPainter extends CustomPainter {
  const _HatchSwatchPainter();

  @override
  void paint(Canvas canvas, Size size) {
    _WeekBarsPainter.paintHatched(
      canvas,
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(3)),
      1,
    );
  }

  @override
  bool shouldRepaint(_HatchSwatchPainter old) => false;
}
