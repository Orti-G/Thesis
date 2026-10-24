import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart' hide TextDirection;
import 'package:lottie/lottie.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math';
import 'main.dart';
import 'rolling_number.dart';

// Bumped by main.dart when a `device` push is tapped: the dashboard shows
// the offline sheet if the GRID device is still offline.
final ValueNotifier<int> deviceStatusRequest = ValueNotifier(0);

// Wrapper class to store both the telemetry reading and its exact reception time
class ChartDataPoint {
  final DateTime timestamp;
  final double value;

  ChartDataPoint({required this.timestamp, required this.value});
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> with TickerProviderStateMixin {
  // Firebase Subscription (live feed cards)
  StreamSubscription<DatabaseEvent>? _dbSubscription;

  // --- HOURLY CHART (History + Live) STATE ---
  // Base URL of the FastAPI VM — used for any date that isn't today
  static const String _apiBaseUrl = 'http://35.209.250.46:8000';

  DateTime _selectedDate = DateTime.now();
  Map<int, double> _hourlyKwh = {}; // hour (0-23) -> total kWh for that hour
  // Day total straight from Firebase `history/today/total_kwh` (sibling of
  // `hourly`) — used for the in-chart "Total for This Day" label.
  double? _todayTotalKwh;
  bool _isLoadingHistory = false;
  String? _historyError;
  StreamSubscription<DatabaseEvent>? _historySubscription;
  DateTime? _lastHistoryUpdateTime;
  Timer? _demoTimer;
  bool _isTestMode = false;
  String _nickname = 'My Home';

  // --- PESO COST ESTIMATE ---
  // Sourced directly from the `estimated_cost` field on `live_reading` —
  // the backend/device computes this against the real Meralco rate
  // schedule and pushes it alongside the other telemetry, so there's no
  // separate /bill/breakdown fetch to make here.
  double _estimatedCostFromDevice = 0.0;

  // Estimated cost for a past (non-today) selected day, pulled from
  // `estimated_cost` in the GET /history/{date} response body — separate
  // from the live device-pushed figure above, which only applies to today.
  double? _pastDayEstimatedCost;

  // --- IOT CONNECTION STATE (driven by the real-time `sync` RTDB field) ---
  // `sync` lives at the root of the database. `false` means the device has
  // told the backend it's offline / lost connection; `true` (or any other
  // truthy value) means it's connected. This replaces the old
  // timeout-guessing watchdog with the device's own reported state.
  StreamSubscription<DatabaseEvent>? _syncSubscription;
  bool _isIotConnected = true;
  DateTime? _lastLiveDataTime;
  // Set when the device drops while the splash is still up; the sheet is
  // shown once the splash clears instead of landing on top of it.
  bool _offlineSheetQueued = false;
  // True while the offline sheet is up, so a push tap can't stack another.
  bool _offlineSheetOpen = false;

  // --- FIRST-LOAD READINESS ---
  // The dashboard is built behind the splash; the splash stays up until
  // each of these initial reads has answered once (see main.dart).
  final Set<String> _pendingFirstLoads = {'live', 'history', 'sync'};

  void _markFirstLoad(String part) {
    _pendingFirstLoads.remove(part);
    if (_pendingFirstLoads.isEmpty) dashboardReadyNotifier.value = true;
  }

  bool get _isTodaySelected {
    final now = DateTime.now();
    return _selectedDate.year == now.year &&
        _selectedDate.month == now.month &&
        _selectedDate.day == now.day;
  }

  // Total kWh for whatever day is currently selected: live cumulative
  // reading for "today", otherwise the sum of that day's hourly buckets.
  double get _displayedTotal {
    if (_isTodaySelected) return _cumulativeEnergy;
    return _hourlySum;
  }

  double get _hourlySum => _hourlyKwh.values.fold(0.0, (sum, v) => sum + v);

  // kWh used from midnight through the end of [hour] (only real readings).
  double _cumulativeThrough(int hour) => _hourlyKwh.entries
      .where((e) => e.key <= hour)
      .fold(0.0, (sum, e) => sum + e.value);

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  // --- HOURLY CHART: scrub + swipe ---
  // The header chart is painted by _HourlyChartPainter. Holding a finger on
  // it scrubs hour by hour (the header cards re-read for that hour); a
  // horizontal swipe moves to the previous/next day. The line morphs between
  // _curveFrom and _curveTo whenever the data changes, live or by day.
  _DayCurve _curveFrom = _DayCurve.empty;
  _DayCurve _curveTo = _DayCurve.empty;
  late final AnimationController _morph = AnimationController(
    vsync: this,
    value: 1,
  );
  late final CurvedAnimation _morphCurve = CurvedAnimation(
    parent: _morph,
    curve: Curves.easeOutCubic,
  );
  // Cursor position in hours (unbounded so the release spring can settle
  // past the end) and its visibility.
  late final AnimationController _cursorX = AnimationController.unbounded(
    vsync: this,
  );
  late final AnimationController _cursorFade = AnimationController(vsync: this);
  // Horizontal offset of the curve, in pixels, while it follows a swipe or
  // slides between days.
  late final AnimationController _swipeX = AnimationController.unbounded(
    vsync: this,
  );
  static const _cursorSpring = SpringDescription(
    mass: 1,
    stiffness: 300,
    damping: 30,
  );
  static const _swipeSpring = SpringDescription(
    mass: 1,
    stiffness: 420,
    damping: 36,
  );

  int? _scrubHour; // hour under the finger; null when not scrubbing
  Timer? _peekTimer; // releases a tap-to-peek after a moment
  double _chartWidth = 0;
  bool _dragging = false;
  bool _reduceMotion = false;

  // Day-change choreography: the old curve slides out (_exitDone), the new
  // day's data lands (_arrivedCurve), then the new curve slides in.
  int _dayDirection = 0; // -1 = earlier day, 1 = later day
  bool _awaitingDay = false;
  bool _exitDone = true;
  _DayCurve? _arrivedCurve;

  // First-run hint on the chart, hidden for good after the first scrub.
  static const String _scrubHintKey = 'dashboard_scrub_hint_seen';
  bool _showScrubHint = false;

  // State for collapsible Advanced Metrics
  bool _isAdvancedMetricsExpanded = false;

  // Live numeric values from Firebase
  double _currentWatts = 0.0;
  double _cumulativeEnergy = 0.0;
  double _currentAmps = 0.0;
  double _frequency = 0.0;
  double _powerFactor = 0.0;
  double _currentVoltage = 0.0;

  // Chart History Arrays storing timed data objects
  final int maxDataPoints = 20;

  late List<ChartDataPoint> _wattsHistory;
  late List<ChartDataPoint> _ampsHistory;
  late List<ChartDataPoint> _voltageHistory;

  // Colors matching your system design
  final Color primaryOrange = const Color(0xFFF26E22);
  final Color topCardColor = const Color(0xFFFA8B39);
  final Color bgColor = const Color(0xFFFAFAFA);
  final Color cardColor = Colors.white;

  @override
  void initState() {
    super.initState();

    _wattsHistory = <ChartDataPoint>[];
    _ampsHistory = <ChartDataPoint>[];
    _voltageHistory = <ChartDataPoint>[];

    _isTestMode = testModeNotifier.value;
    _nickname = nicknameNotifier.value;

    testModeNotifier.addListener(_onTestModeChanged);
    nicknameNotifier.addListener(_onNicknameChanged);
    splashDoneNotifier.addListener(_onSplashDone);
    deviceStatusRequest.addListener(_onDeviceStatusRequest);

    if (_isTestMode) {
      _startDemoMode();
    } else {
      _setupFirebaseListener();
      _attachTodayHistoryListener();
      _setupSyncListener();
    }

    _loadScrubHint();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
  }

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

  void _onNicknameChanged() {
    if (!mounted) return;
    setState(() => _nickname = nicknameNotifier.value);
  }

  void _onSplashDone() {
    if (!splashDoneNotifier.value || !_offlineSheetQueued) return;
    _offlineSheetQueued = false;
    if (mounted && !_isIotConnected) _showNoConnectionDialog();
  }

  // When the device is back online the "Connected" badge already says so.
  void _onDeviceStatusRequest() {
    if (mounted && !_isIotConnected) _showNoConnectionDialog();
  }

  void _onTestModeChanged() {
    if (!mounted) return;
    final newValue = testModeNotifier.value;
    if (newValue == _isTestMode) return;

    setState(() => _isTestMode = newValue);

    if (_isTestMode) {
      _dbSubscription?.cancel();
      _historySubscription?.cancel();
      _syncSubscription?.cancel();
      setState(() => _isIotConnected = true);
      _startDemoMode();
    } else {
      _demoTimer?.cancel();
      _setupFirebaseListener();
      _attachTodayHistoryListener();
      _setupSyncListener();
    }
  }

  void _startDemoMode() {
    final rand = Random();

    final now = DateTime.now();
    final Map<int, double> fakeHourly = {};
    for (int h = 0; h <= now.hour; h++) {
      fakeHourly[h] = double.parse(
        (0.1 + rand.nextDouble() * 0.5).toStringAsFixed(3),
      );
    }

    setState(() {
      _hourlyKwh = fakeHourly;
      _isLoadingHistory = false;
      _historyError = null;
      _lastHistoryUpdateTime = DateTime.now();
      _cumulativeEnergy = 145.0;
      _estimatedCostFromDevice = _cumulativeEnergy * 12.0;
    });
    _retargetCurve();

    _demoTimer?.cancel();
    _demoTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      // Demo data is all local — ready as soon as the live values exist.
      dashboardReadyNotifier.value = true;
      setState(() {
        _currentWatts = 800 + rand.nextInt(400).toDouble();
        _currentAmps = double.parse((_currentWatts / 220).toStringAsFixed(2));
        _currentVoltage = double.parse(
          (218 + rand.nextDouble() * 4).toStringAsFixed(1),
        );
        _frequency = 59.8 + rand.nextDouble() * 0.4;
        _powerFactor = 0.9 + rand.nextDouble() * 0.1;
        _cumulativeEnergy += 0.005;
        _estimatedCostFromDevice = _cumulativeEnergy * 12.0;

        final timestamp = DateTime.now();
        _lastLiveDataTime = timestamp;

        if (_wattsHistory.length >= maxDataPoints) _wattsHistory.removeAt(0);
        _wattsHistory.add(
          ChartDataPoint(
            timestamp: timestamp,
            value: double.parse(_currentWatts.toStringAsFixed(0)),
          ),
        );

        if (_ampsHistory.length >= maxDataPoints) _ampsHistory.removeAt(0);
        _ampsHistory.add(
          ChartDataPoint(timestamp: timestamp, value: _currentAmps),
        );

        if (_voltageHistory.length >= maxDataPoints) {
          _voltageHistory.removeAt(0);
        }
        _voltageHistory.add(
          ChartDataPoint(timestamp: timestamp, value: _currentVoltage),
        );

        // Fake hours only belong to today; leave a viewed past day alone.
        if (_isTodaySelected) {
          final currentHour = DateTime.now().hour;
          _hourlyKwh[currentHour] = (_hourlyKwh[currentHour] ?? 0.1) + 0.002;
          _lastHistoryUpdateTime = DateTime.now();
        }
      });
      if (_isTodaySelected) _retargetCurve();
    });
  }

  void _setupFirebaseListener() {
    DatabaseReference ref = FirebaseDatabase.instance.ref('live_reading');

    _dbSubscription = ref.onValue.listen((event) {
      _markFirstLoad('live');
      if (event.snapshot.value != null) {
        try {
          final data = Map<String, dynamic>.from(event.snapshot.value as Map);

          setState(() {
            _currentWatts = double.tryParse(data['power'].toString()) ?? 0.0;
            _cumulativeEnergy =
                double.tryParse(data['cumul_kwh'].toString()) ?? 0.0;
            _currentAmps = double.tryParse(data['current'].toString()) ?? 0.0;
            _frequency = double.tryParse(data['frequency'].toString()) ?? 0.0;
            _powerFactor =
                double.tryParse(data['power_factor'].toString()) ?? 0.0;
            _currentVoltage =
                double.tryParse(data['voltage'].toString()) ?? 0.0;
            _estimatedCostFromDevice =
                double.tryParse(data['estimated_cost'].toString()) ??
                _estimatedCostFromDevice;

            final timestamp = DateTime.now();

            // Track the most recent reading time for display in the
            // "no connection" sheet. Actual connection state now comes
            // from the `sync` listener below, not from staleness here.
            _lastLiveDataTime = timestamp;

            // Round to match display precision so "no visible change"
            // actually means "no chart update" — prevents the chart from
            // moving on invisible sub-decimal fluctuations.
            final roundedWatts = double.parse(_currentWatts.toStringAsFixed(0));
            final roundedAmps = double.parse(_currentAmps.toStringAsFixed(2));
            final roundedVoltage = double.parse(
              _currentVoltage.toStringAsFixed(1),
            );

            // --- WATTS: only append if rounded value actually changed ---
            if (_wattsHistory.isEmpty) {
              // Seed with 2 identical points so a flat line renders immediately
              _wattsHistory.add(
                ChartDataPoint(timestamp: timestamp, value: roundedWatts),
              );
              _wattsHistory.add(
                ChartDataPoint(timestamp: timestamp, value: roundedWatts),
              );
            } else if (_wattsHistory.last.value != roundedWatts) {
              if (_wattsHistory.length >= maxDataPoints) {
                _wattsHistory.removeAt(0);
              }
              _wattsHistory.add(
                ChartDataPoint(timestamp: timestamp, value: roundedWatts),
              );
            }

            // --- AMPS: only append if rounded value actually changed ---
            if (_ampsHistory.isEmpty) {
              _ampsHistory.add(
                ChartDataPoint(timestamp: timestamp, value: roundedAmps),
              );
              _ampsHistory.add(
                ChartDataPoint(timestamp: timestamp, value: roundedAmps),
              );
            } else if (_ampsHistory.last.value != roundedAmps) {
              if (_ampsHistory.length >= maxDataPoints) {
                _ampsHistory.removeAt(0);
              }
              _ampsHistory.add(
                ChartDataPoint(timestamp: timestamp, value: roundedAmps),
              );
            }

            // --- VOLTAGE: only append if rounded value actually changed ---
            if (_voltageHistory.isEmpty) {
              _voltageHistory.add(
                ChartDataPoint(timestamp: timestamp, value: roundedVoltage),
              );
              _voltageHistory.add(
                ChartDataPoint(timestamp: timestamp, value: roundedVoltage),
              );
            } else if (_voltageHistory.last.value != roundedVoltage) {
              if (_voltageHistory.length >= maxDataPoints) {
                _voltageHistory.removeAt(0);
              }
              _voltageHistory.add(
                ChartDataPoint(timestamp: timestamp, value: roundedVoltage),
              );
            }
          });
        } catch (e) {
          debugPrint("🔴 ERROR PARSING DATA: $e");
        }
      }
    });
  }

  // --- HOURLY CHART: LIVE (today) via Firebase `/history/today` ---
  // Matches backend's Option C hybrid: current hour is always live-updating,
  // previous hours are finalized once the hour changes.
  void _attachTodayHistoryListener() {
    _historySubscription?.cancel();
    setState(() {
      _isLoadingHistory = true;
      _historyError = null;
      _pastDayEstimatedCost = null;
    });

    final ref = FirebaseDatabase.instance.ref('history/today');
    _historySubscription = ref.onValue.listen((event) {
      if (!mounted) return;
      _markFirstLoad('history');
      if (event.snapshot.value == null) {
        setState(() {
          _hourlyKwh = {};
          _todayTotalKwh = null;
          _isLoadingHistory = false;
        });
        _retargetCurve();
        return;
      }
      try {
        final data = Map<String, dynamic>.from(event.snapshot.value as Map);
        final hourlyRaw = data['hourly'];
        final Map<int, double> parsed = {};

        if (hourlyRaw is Map) {
          hourlyRaw.forEach((key, value) {
            if (value == null) return; // skip nulls just in case
            final hour = int.tryParse(key.toString());
            final kwh = double.tryParse(value.toString());
            if (hour != null && kwh != null) {
              parsed[hour] = kwh;
            }
          });
        } else if (hourlyRaw is List) {
          for (int i = 0; i < hourlyRaw.length; i++) {
            final value = hourlyRaw[i];
            if (value == null) continue; // RTDB pads missing hours with null
            final kwh = double.tryParse(value.toString());
            if (kwh != null) {
              parsed[i] = kwh;
            }
          }
        }

        final totalKwhRaw = data['total_kwh'];

        setState(() {
          _hourlyKwh = parsed;
          _todayTotalKwh = double.tryParse(totalKwhRaw.toString());
          _isLoadingHistory = false;
          _historyError = null;
          _lastHistoryUpdateTime = DateTime.now();
        });
        _retargetCurve();
      } catch (e) {
        debugPrint("🔴 ERROR PARSING HOURLY HISTORY: $e");
        setState(() => _isLoadingHistory = false);
        _retargetCurve();
      }
    });
  }

  // --- HOURLY CHART: PAST DATES via FastAPI GET /history/{date} ---
  Future<void> _fetchHistoryForDate(DateTime date) async {
    _historySubscription
        ?.cancel(); // stop live updates while viewing a past date

    setState(() {
      _isLoadingHistory = true;
      _historyError = null;
    });

    final dateStr = DateFormat('yyyy-MM-dd').format(date);

    try {
      final response = await http
          .get(Uri.parse('$_apiBaseUrl/history/$dateStr'))
          .timeout(const Duration(seconds: 10));

      // Swiping quickly fires several fetches; only the day still on screen
      // may land.
      if (!mounted || !_isSameDay(date, _selectedDate)) return;

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final List<dynamic> rows = body['data'] as List<dynamic>? ?? [];
        final Map<int, double> parsed = {};

        for (final row in rows) {
          final hour = row['hour'] as int?;
          final kwh = (row['total_kwh'] as num?)?.toDouble();
          if (hour != null && kwh != null) {
            parsed[hour] = kwh;
          }
        }

        setState(() {
          _hourlyKwh = parsed;
          _pastDayEstimatedCost = (body['estimated_cost'] as num?)?.toDouble();
          _isLoadingHistory = false;
        });
      } else {
        // e.g. 404 "No data found for {date}"
        setState(() {
          _hourlyKwh = {};
          _pastDayEstimatedCost = null;
          _isLoadingHistory = false;
          _historyError = 'No data for $dateStr';
        });
      }
      _retargetCurve();
    } catch (e) {
      debugPrint("🔴 ERROR FETCHING HISTORY: $e");
      if (!mounted || !_isSameDay(date, _selectedDate)) return;
      setState(() {
        _hourlyKwh = {};
        _isLoadingHistory = false;
        _pastDayEstimatedCost = null;
        _historyError = 'Failed to load history';
      });
      _retargetCurve();
    }
  }

  // --- HOURLY CHART: open a calendar to jump straight to any date ---
  Future<void> _pickDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2024, 1, 1),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(
              context,
            ).colorScheme.copyWith(primary: primaryOrange),
          ),
          child: child!,
        );
      },
    );

    if (picked == null || _isSameDay(picked, _selectedDate)) return;
    _transitionToDate(picked, picked.isBefore(_selectedDate) ? -1 : 1);
  }

  // --- HOURLY CHART: step one day back/forward (header arrows, swipes) ---
  void _changeDate(int dayOffset) {
    final newDate = _selectedDate.add(Duration(days: dayOffset));
    if (newDate.isAfter(DateTime.now())) return; // no future dates
    _transitionToDate(newDate, dayOffset.sign);
  }

  // Every day change (swipe, arrows, calendar) runs the same move: the
  // current curve slides out toward the gesture while the new day loads,
  // then slides in from the other side, reshaping into the new day.
  Future<void> _transitionToDate(DateTime date, int direction) async {
    _releaseScrub();
    setState(() {
      _selectedDate = date;
      _dayDirection = direction;
    });
    _awaitingDay = true;
    _exitDone = _reduceMotion;
    _arrivedCurve = null;

    if (_isSameDay(date, DateTime.now())) {
      _attachTodayHistoryListener();
    } else {
      _fetchHistoryForDate(date);
    }
    if (_reduceMotion) return;

    try {
      await _swipeX
          .animateTo(
            -direction * _chartWidth * 0.3,
            duration: const Duration(milliseconds: 170),
            curve: Curves.easeIn,
          )
          .orCancel;
    } on TickerCanceled {
      // A new drag caught the curve mid-exit; its release decides the rest.
    }
    _exitDone = true;
    _enterDay();
  }

  // Slides the arrived day in, once the old one is out and no finger is on
  // the chart.
  void _enterDay() {
    if (!mounted || _dragging || !_exitDone || _arrivedCurve == null) return;
    final next = _arrivedCurve!;
    _awaitingDay = false;
    _arrivedCurve = null;
    _morphTo(next, const Duration(milliseconds: 560));
    if (_reduceMotion) {
      _swipeX.value = 0;
      return;
    }
    _swipeX.value = _dayDirection * _chartWidth * 0.22;
    _swipeX.animateTo(
      0,
      duration: const Duration(milliseconds: 460),
      curve: Curves.easeOutCubic,
    );
  }

  // Called whenever `_hourlyKwh` changes: live updates reshape the line in
  // place; a pending day change hands the new curve to the slide-in.
  void _retargetCurve() {
    if (!mounted) return;
    final next = _DayCurve.fromHourly(_hourlyKwh, _selectedDate);
    if (_awaitingDay) {
      _arrivedCurve = next;
      _enterDay();
      return;
    }
    if (next.sameShape(_curveTo)) return;
    _morphTo(next, Duration(milliseconds: _curveTo.isEmpty ? 600 : 320));
  }

  void _morphTo(_DayCurve next, Duration duration) {
    setState(() {
      _curveFrom = _DayCurve.lerp(_curveFrom, _curveTo, _morphCurve.value);
      _curveTo = next;
    });
    if (_reduceMotion) {
      _morph.value = 1;
      return;
    }
    _morph.duration = duration;
    _morph.forward(from: 0);
  }

  // --- HOURLY CHART: scrubbing ---
  void _scrubAt(double dx, {bool begin = false}) {
    final curve = _curveTo;
    if (curve.isEmpty || _awaitingDay || _chartWidth <= 0) return;
    const span = _HourlyChartPainter.maxX - _HourlyChartPainter.minX;
    final x = dx / _chartWidth * span + _HourlyChartPainter.minX;
    final hour = x
        .round()
        .clamp(curve.first.ceil(), curve.last.floor())
        .toInt();

    if (begin) {
      _peekTimer?.cancel();
      _cursorX.value = hour.toDouble();
      if (_reduceMotion) {
        _cursorFade.value = 1;
      } else {
        _cursorFade.animateTo(
          1,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
        );
      }
      _dismissScrubHint();
    }
    if (hour == _scrubHour) return;

    HapticFeedback.selectionClick();
    if (!begin) {
      if (_reduceMotion) {
        _cursorX.value = hour.toDouble();
      } else {
        _cursorX.animateTo(
          hour.toDouble(),
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
        );
      }
    }
    setState(() => _scrubHour = hour);
  }

  // A tap shows that hour for a moment, for anyone who taps instead of
  // holding.
  void _peekAt(double dx) {
    _scrubAt(dx, begin: true);
    if (_scrubHour == null) return;
    _peekTimer = Timer(const Duration(milliseconds: 1800), _releaseScrub);
  }

  // Lifting the finger hands the cards back to the day's totals while the
  // cursor glides back to the latest reading and fades.
  void _releaseScrub() {
    _peekTimer?.cancel();
    if (_scrubHour == null) return;
    setState(() => _scrubHour = null);
    if (_reduceMotion) {
      _cursorFade.value = 0;
      return;
    }
    final rest = _curveTo.isEmpty ? _cursorX.value : _curveTo.last;
    _cursorX.animateWith(
      SpringSimulation(_cursorSpring, _cursorX.value, rest, 0),
    );
    _cursorFade.animateTo(
      0,
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeInCubic,
    );
  }

  // --- HOURLY CHART: swiping between days ---
  void _onSwipeStart(DragStartDetails details) {
    _releaseScrub();
    _dragging = true;
    _swipeX.stop();
  }

  void _onSwipeUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    final next = _swipeX.value + delta;
    // Dragging left asks for the next day. On today there is none, so the
    // curve only gives a little, like pulling against a stop.
    if (next < 0 && _isTodaySelected) {
      _swipeX.value = max(_swipeX.value + delta * 0.15, -_chartWidth * 0.08);
    } else {
      _swipeX.value = _swipeX.value + delta * 0.6;
    }
  }

  void _onSwipeEnd(DragEndDetails details) {
    _dragging = false;
    final x = _swipeX.value;
    final velocity = details.primaryVelocity ?? 0;
    final direction = x > 0 ? -1 : 1; // dragged right → earlier day
    final flung = velocity.abs() > 550 && velocity.sign == x.sign;
    final canMove = direction < 0 || !_isTodaySelected;

    if (x != 0 && canMove && (x.abs() > _chartWidth * 0.12 || flung)) {
      HapticFeedback.lightImpact();
      _transitionToDate(
        _selectedDate.add(Duration(days: direction)),
        direction,
      );
      return;
    }
    if (_awaitingDay && _arrivedCurve != null) {
      _enterDay();
      return;
    }
    if (_reduceMotion) {
      _swipeX.value = 0;
      return;
    }
    _swipeX.animateWith(SpringSimulation(_swipeSpring, x, 0, velocity));
  }

  // "By 4 PM" — the running total runs through the end of [hour]. The hour
  // still filling up today reads as of the latest update instead.
  String _byLabel(int hour) {
    if (hour == _liveHour && _lastHistoryUpdateTime != null) {
      return 'By ${DateFormat('h:mm a').format(_lastHistoryUpdateTime!)}';
    }
    final end = hour + 1;
    if (end == 24) return 'By midnight';
    if (end == 12) return 'By noon';
    return 'By ${_formatHourLabel(end.toDouble())}';
  }

  // Today's latest hour, which is still filling up; null on past days.
  int? get _liveHour =>
      _isTodaySelected && !_curveTo.isEmpty ? _curveTo.last.toInt() : null;

  // --- IOT CONNECTION: real-time listener on the root-level `sync` field ---
  // `sync == false` → device reported it's offline, show the disconnected
  // state and surface the "device went offline" sheet once per drop.
  // `sync == true` (or any other truthy value) → device is connected.
  void _setupSyncListener() {
    _syncSubscription?.cancel();

    final ref = FirebaseDatabase.instance.ref('sync');
    _syncSubscription = ref.onValue.listen((event) {
      if (!mounted) return;

      final bool isConnected = _parseSyncValue(event.snapshot.value);
      final bool wasConnected = _isIotConnected;

      setState(() => _isIotConnected = isConnected);
      _markFirstLoad('sync');

      // Only pop the sheet on the transition into "disconnected" so it
      // doesn't spam the user while `sync` stays false. While the splash
      // is still up it's queued for when the splash clears.
      if (!isConnected && wasConnected) {
        if (splashDoneNotifier.value) {
          _showNoConnectionDialog();
        } else {
          _offlineSheetQueued = true;
        }
      }
    });
  }

  // Treats missing/null data as disconnected, and accepts bool, numeric,
  // or string ("true"/"1") representations of `sync` just in case the
  // backend writes it in a slightly different shape.
  bool _parseSyncValue(Object? value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == 'true' || normalized == '1';
    }
    return false;
  }

  void _showNoConnectionDialog() {
    if (!mounted || _offlineSheetOpen) return;
    _offlineSheetOpen = true;

    final now = DateTime.now();
    final lastSeen = _lastLiveDataTime;
    final downtime = lastSeen != null
        ? now.difference(lastSeen)
        : Duration.zero;

    // Kept outside the builder so the sheet remembers whether the user has
    // moved on to the restart walkthrough across route rebuilds.
    bool showRestartGuide = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (_, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 20),
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // Overview ⇄ restart walkthrough. The incoming view alone sets
                // the height (the outgoing one is positioned), and
                // AnimatedSize eases the sheet between the two.
                AnimatedSize(
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.topCenter,
                      children: [
                        for (final child in previous)
                          Positioned(top: 0, left: 0, right: 0, child: child),
                        ?current,
                      ],
                    ),
                    child: showRestartGuide
                        ? _RestartGuide(
                            key: const ValueKey('restart-guide'),
                            accent: primaryOrange,
                            onBack: () =>
                                setSheetState(() => showRestartGuide = false),
                            onDone: () => Navigator.of(sheetContext).pop(),
                          )
                        : Column(
                            key: const ValueKey('offline-overview'),
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Badge
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.red.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  'NO CONNECTION',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.5,
                                    color: Colors.red[700],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),

                              // Timestamp
                              Text(
                                DateFormat('MMM d, yyyy · HH:mm').format(now),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey[500],
                                ),
                              ),
                              const SizedBox(height: 12),

                              // Title
                              const Text(
                                'Device Went Offline',
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                  height: 1.15,
                                  color: Colors.black,
                                ),
                              ),
                              const SizedBox(height: 20),

                              // Stats row
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                  horizontal: 16,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.grey[100],
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Last Reading',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey[500],
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            lastSeen != null
                                                ? DateFormat(
                                                    'h:mm a',
                                                  ).format(lastSeen)
                                                : '—',
                                            style: const TextStyle(
                                              fontSize: 17,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Container(
                                      width: 1,
                                      height: 32,
                                      color: Colors.grey[300],
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Downtime',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey[500],
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            lastSeen != null
                                                ? '${downtime.inMinutes}m ${downtime.inSeconds % 60}s'
                                                : '—',
                                            style: const TextStyle(
                                              fontSize: 17,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 24),

                              const Text(
                                'Would you like to restart the device?',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.black,
                                ),
                              ),
                              const SizedBox(height: 16),

                              // Primary action — opens the step-by-step guide
                              // (there's no remote-restart command yet).
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 16,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(30),
                                    ),
                                    elevation: 0,
                                  ),
                                  onPressed: () => setSheetState(
                                    () => showRestartGuide = true,
                                  ),
                                  child: const Text(
                                    'Restart Manually',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),

                              // Secondary action
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 16,
                                    ),
                                    side: BorderSide(color: Colors.grey[300]!),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(30),
                                    ),
                                  ),
                                  onPressed: () =>
                                      Navigator.of(sheetContext).pop(),
                                  child: const Text(
                                    'Dismiss',
                                    style: TextStyle(
                                      color: Colors.black,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(() => _offlineSheetOpen = false);
  }

  // --- METRICS EXPLAINER ---
  // Bottom sheet that walks a household owner through what each number
  // on the dashboard means and why it's worth paying attention to.
  void _showMetricsInfoDialog() {
    if (!mounted) return;

    final metrics = <_MetricInfo>[
      _MetricInfo(
        icon: Icons.bolt_rounded,
        title: 'Power (W)',
        description:
            'How much electricity your home is drawing right now, in watts. '
            'A sudden jump usually means a big appliance (aircon, water '
            'heater, iron) just switched on — useful for spotting what\'s '
            'actually running up your bill in real time.',
      ),
      _MetricInfo(
        icon: Icons.electric_bolt_rounded,
        title: 'Current (A)',
        description:
            'The amount of electric current flowing through your wiring, '
            'in amps. Keeping this within your circuit\'s rated capacity '
            'matters for safety — sustained high current is a common cause '
            'of overheating wires and tripped breakers.',
      ),
      _MetricInfo(
        icon: Icons.flash_on_rounded,
        title: 'Voltage (V)',
        description:
            'The strength of the electrical supply coming into your home. '
            'Philippine households normally run close to 220V — voltage '
            'that drifts far from that can signal a utility supply problem '
            'or a wiring issue, and can shorten the life of your appliances.',
      ),
      _MetricInfo(
        icon: Icons.graphic_eq_rounded,
        title: 'Frequency (Hz)',
        description:
            'How steadily the power supply is oscillating (normally 60Hz '
            'locally). It\'s mostly a grid-health indicator — large swings '
            'are rare, but can point to instability from the utility side '
            'rather than anything inside your home.',
      ),
      _MetricInfo(
        icon: Icons.speed_rounded,
        title: 'Power Factor (PF)',
        description:
            'How efficiently your appliances are using the electricity '
            'supplied to them, from 0 to 1. A lower PF means more power is '
            'being wasted rather than doing useful work — often a sign of '
            'older motors or poorly matched appliances.',
      ),
      _MetricInfo(
        icon: Icons.show_chart_rounded,
        title: 'Total Used (kWh)',
        description:
            'Your running electricity consumption for the day, in '
            'kilowatt-hours — the same unit your utility bills you in. '
            'This is the number that most directly drives your monthly bill.',
      ),
      _MetricInfo(
        icon: Icons.payments_rounded,
        title: 'Est. Bill (₱)',
        description:
            'A peso estimate of today\'s cost so far, reported directly by '
            'the device against the current Meralco rate schedule. It '
            'gives you an early sense of where your bill is headed, before '
            'the actual reading arrives at month\'s end.',
      ),
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (context, scrollController) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              const Text(
                'Understanding Your Metrics',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'What each reading means for your household',
                style: TextStyle(fontSize: 13, color: Colors.grey[500]),
              ),
              const SizedBox(height: 8),

              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  itemCount: metrics.length,
                  separatorBuilder: (_, _) => Divider(
                    height: 32,
                    thickness: 1,
                    color: Colors.grey[200],
                  ),
                  itemBuilder: (context, index) =>
                      _buildMetricInfoRow(metrics[index]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetricInfoRow(_MetricInfo metric) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(metric.icon, color: primaryOrange, size: 18),
            const SizedBox(width: 8),
            Text(
              metric.title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Colors.black,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          metric.description,
          style: TextStyle(fontSize: 13, height: 1.5, color: Colors.grey[600]),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _dbSubscription?.cancel();
    _historySubscription?.cancel();
    _syncSubscription?.cancel();
    _demoTimer?.cancel();
    _peekTimer?.cancel();
    _morphCurve.dispose();
    _morph.dispose();
    _cursorX.dispose();
    _cursorFade.dispose();
    _swipeX.dispose();
    testModeNotifier.removeListener(_onTestModeChanged);
    nicknameNotifier.removeListener(_onNicknameChanged);
    splashDoneNotifier.removeListener(_onSplashDone);
    deviceStatusRequest.removeListener(_onDeviceStatusRequest);
    super.dispose();
  }

  // Generates FlSpots mapping list indexes on X axis against read values on Y axis
  List<FlSpot> _generateChartSpots(List<ChartDataPoint> history) {
    return history.asMap().entries.map((e) {
      return FlSpot(e.key.toDouble(), e.value.value);
    }).toList();
  }

  // minRange = the smallest allowed span between minY and maxY.
  // This is what keeps small, real fluctuations from being stretched
  // into dramatic-looking spikes — the chart won't zoom in tighter
  // than this floor, no matter how flat the actual data is.
  double _getMinY(List<ChartDataPoint> history, {double minRange = 0}) {
    if (history.isEmpty) return 0;
    final values = history.map((e) => e.value);
    double min = values.reduce((a, b) => a < b ? a : b);
    double max = values.reduce((a, b) => a > b ? a : b);
    double range = max - min;

    if (range < minRange) {
      double mid = (min + max) / 2;
      min = mid - minRange / 2;
      max = mid + minRange / 2;
      range = minRange;
    }

    double padding = range * 0.1;
    return (min - padding).clamp(0, double.infinity);
  }

  double _getMaxY(List<ChartDataPoint> history, {double minRange = 0}) {
    if (history.isEmpty) return 1;
    final values = history.map((e) => e.value);
    double min = values.reduce((a, b) => a < b ? a : b);
    double max = values.reduce((a, b) => a > b ? a : b);
    double range = max - min;

    if (range < minRange) {
      double mid = (min + max) / 2;
      min = mid - minRange / 2;
      max = mid + minRange / 2;
      range = minRange;
    }

    double padding = range * 0.1;
    return max + padding;
  }

  // Used only by the main hourly chart's tooltip — converts an x-value
  // (0-24, representing hour of day) into a readable "3 AM" style label.
  String _formatHourLabel(double xValue) {
    int hour = xValue.round();
    if (hour == 24) hour = 0; // wrap midnight edge case
    final period = hour < 12 ? 'AM' : 'PM';
    int displayHour = hour % 12;
    if (displayHour == 0) displayHour = 12;
    return '$displayHour $period';
  }

  String _formatWithCommas(double value) {
    RegExp reg = RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))');
    String mathFunc(Match match) => '${match[1]},';
    return value.toStringAsFixed(1).replaceAllMapped(reg, mathFunc);
  }

  @override
  Widget build(BuildContext context) {
    // Get total screen height for our 70% calculation
    final screenHeight = MediaQuery.of(context).size.height;

    // While scrubbing, the header cards re-read for the hour under the
    // finger: the running total so far, and that total's share of the day.
    final int? scrubHour = _scrubHour;
    final bool scrubbing = scrubHour != null;
    final double leftValue = scrubbing
        ? _cumulativeThrough(scrubHour)
        : _displayedTotal;
    final int sharePercent = scrubbing && _hourlySum > 0
        ? (_cumulativeThrough(scrubHour) / _hourlySum * 100).round()
        : 0;
    final String dateLabel = _isTodaySelected
        ? 'Today'
        : DateFormat('EEE MMM d').format(_selectedDate);
    final Duration swapDuration = _reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 180);
    const headerValueStyle = TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w800,
      color: Colors.white,
      letterSpacing: -0.5,
    );
    const headerUnitStyle = TextStyle(
      fontSize: 13,
      color: Colors.white,
      fontWeight: FontWeight.w600,
    );
    final headerLabelStyle = TextStyle(
      fontSize: 13,
      color: Colors.white.withValues(alpha: 0.9),
      fontWeight: FontWeight.w600,
    );

    return Scaffold(
      backgroundColor: bgColor,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- HEADER SECTION ---
            Container(
              height: screenHeight * 0.70,
              width: double.infinity,
              color: topCardColor,
              child: SafeArea(
                bottom: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 1. Top Bar: Title (Left) & Date Navigator Pill (Right)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Text(
                                _nickname,
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              _Glass(
                                radius: 24,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    GestureDetector(
                                      onTap: () => _changeDate(-1),
                                      child: const Icon(
                                        Icons.chevron_left,
                                        color: Colors.white,
                                        size: 18,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    GestureDetector(
                                      onTap: () => _pickDate(context),
                                      // The date slides the same way the chart does.
                                      child: AnimatedSize(
                                        duration: swapDuration,
                                        curve: Curves.easeOutCubic,
                                        child: AnimatedSwitcher(
                                          duration: _reduceMotion
                                              ? Duration.zero
                                              : const Duration(
                                                  milliseconds: 260,
                                                ),
                                          switchInCurve: Curves.easeOutCubic,
                                          switchOutCurve: Curves.easeInCubic,
                                          layoutBuilder: (current, previous) =>
                                              Stack(
                                                alignment: Alignment.center,
                                                children: [
                                                  ...previous,
                                                  ?current,
                                                ],
                                              ),
                                          transitionBuilder:
                                              (child, animation) {
                                                final incoming =
                                                    child.key ==
                                                    ValueKey(dateLabel);
                                                final begin = Offset(
                                                  (incoming ? 1 : -1) *
                                                      _dayDirection *
                                                      0.6,
                                                  0,
                                                );
                                                return FadeTransition(
                                                  opacity: animation,
                                                  child: SlideTransition(
                                                    position: Tween(
                                                      begin: begin,
                                                      end: Offset.zero,
                                                    ).animate(animation),
                                                    child: child,
                                                  ),
                                                );
                                              },
                                          child: Text(
                                            dateLabel,
                                            key: ValueKey(dateLabel),
                                            style: const TextStyle(
                                              fontSize: 14,
                                              color: Colors.white,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    GestureDetector(
                                      onTap: _isTodaySelected
                                          ? null
                                          : () => _changeDate(1),
                                      child: Icon(
                                        Icons.chevron_right,
                                        color: Colors.white.withValues(
                                          alpha: _isTodaySelected ? 0.3 : 1.0,
                                        ),
                                        size: 18,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 16),

                          // 2. Two Side-by-Side Metric Cards
                          Row(
                            children: [
                              // Left Card: Total Used
                              Expanded(
                                child: _Glass(
                                  radius: 20,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 18,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.bolt_rounded,
                                            color: Colors.white,
                                            size: 20,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: SwapText(
                                              mode: scrubbing,
                                              duration: swapDuration,
                                              text: scrubbing
                                                  ? _byLabel(scrubHour)
                                                  : 'Total Used',
                                              style: headerLabelStyle,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.baseline,
                                        textBaseline: TextBaseline.alphabetic,
                                        children: [
                                          RollingNumber(
                                            _formatWithCommas(leftValue),
                                            style: headerValueStyle,
                                          ),
                                          const SizedBox(width: 4),
                                          const Text(
                                            'kWh',
                                            style: headerUnitStyle,
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),

                              const SizedBox(width: 12),

                              // Right Card: Est. Total Bill
                              Expanded(
                                child: _Glass(
                                  radius: 20,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 18,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          AnimatedSwitcher(
                                            duration: swapDuration,
                                            child: Icon(
                                              scrubbing
                                                  ? Icons.donut_large_rounded
                                                  : Icons.payments_rounded,
                                              key: ValueKey(scrubbing),
                                              color: Colors.white,
                                              size: 20,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: SwapText(
                                              mode: scrubbing,
                                              duration: swapDuration,
                                              text: scrubbing
                                                  ? 'Share of day'
                                                  : _isTodaySelected
                                                  ? 'Est. Total Bill'
                                                  : 'Total Bill',
                                              style: headerLabelStyle,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      // No hourly peso data exists, so a scrubbed hour
                                      // reads as a share of the day instead of a bill.
                                      AnimatedSwitcher(
                                        duration: swapDuration,
                                        layoutBuilder: (current, previous) =>
                                            Stack(
                                              alignment: Alignment.centerLeft,
                                              children: [...previous, ?current],
                                            ),
                                        child: scrubbing
                                            ? Row(
                                                key: const ValueKey('share'),
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.baseline,
                                                textBaseline:
                                                    TextBaseline.alphabetic,
                                                children: [
                                                  RollingNumber(
                                                    '$sharePercent',
                                                    style: headerValueStyle,
                                                  ),
                                                  const SizedBox(width: 2),
                                                  const Text(
                                                    '%',
                                                    style: headerUnitStyle,
                                                  ),
                                                ],
                                              )
                                            : RollingNumber(
                                                '₱${_formatWithCommas(_isTodaySelected ? _estimatedCostFromDevice : (_pastDayEstimatedCost ?? 0.0))}',
                                                key: const ValueKey('bill'),
                                                style: headerValueStyle,
                                              ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 20),

                          // 3. Section Header Row: "Energy Usage" (Left) + Today Pill (Right)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Text(
                                'Energy Usage',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                              if (_isTodaySelected && _todayTotalKwh != null)
                                _Glass(
                                  radius: 20,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.calendar_month_rounded,
                                        color: Colors.white,
                                        size: 16,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        'Today: ${_formatWithCommas(_todayTotalKwh!)} kWh',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // DAILY CHART — hold to read any hour, swipe for other days
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            _chartWidth = constraints.maxWidth;
                            return _buildHourlyChart(dateLabel);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 0),
                  ],
                ),
              ),
            ),

            // --- BOTTOM FEED SECTION ---
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 20.0,
                vertical: 20.0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Text(
                            'LIVE FEED',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: _showMetricsInfoDialog,
                            child: Icon(
                              Icons.info_outline_rounded,
                              size: 18,
                              color: Colors.grey[500],
                            ),
                          ),
                        ],
                      ),
                      Icon(Icons.menu, color: Colors.grey[800]),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // --- LIVE connection status, driven by the real-time
                  // `sync` field in Firebase RTDB (root level). Green +
                  // "Connected" when `sync` is true/truthy, red +
                  // "Disconnected" when `sync` is false.
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _buildConnectionStatusBadge(),
                  ),

                  const SizedBox(height: 8),

                  _buildLiveFeedCard(
                    title: 'Power',
                    value: _currentWatts.toStringAsFixed(0),
                    unit: 'W',
                    subtitle: 'Live Power',
                    spots: _generateChartSpots(_wattsHistory),
                    history: _wattsHistory,
                    minRange: 50, // won't zoom tighter than a 50W window
                  ),
                  const SizedBox(height: 12),

                  _buildLiveFeedCard(
                    title: 'Current',
                    value: _currentAmps.toStringAsFixed(2),
                    unit: 'A',
                    subtitle: 'Live Amperage',
                    spots: _generateChartSpots(_ampsHistory),
                    history: _ampsHistory,
                    minRange: 0.3, // won't zoom tighter than a 0.3A window
                  ),
                  const SizedBox(height: 12),

                  _buildLiveFeedCard(
                    title: 'Voltage',
                    value: _currentVoltage.toStringAsFixed(1),
                    unit: 'V',
                    subtitle: 'Mains Voltage',
                    spots: _generateChartSpots(_voltageHistory),
                    history: _voltageHistory,
                    minRange: 4, // won't zoom tighter than a 4V window
                  ),
                  const SizedBox(height: 30),

                  // Advanced Metrics Toggle
                  GestureDetector(
                    onTap: () => setState(
                      () => _isAdvancedMetricsExpanded =
                          !_isAdvancedMetricsExpanded,
                    ),
                    child: Container(
                      color: Colors.transparent,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'ADVANCED METRICS',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                          AnimatedRotation(
                            turns: _isAdvancedMetricsExpanded ? 0.5 : 0,
                            duration: const Duration(milliseconds: 300),
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.expand_more_rounded,
                              color: Colors.grey[800],
                              size: 24,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    alignment: Alignment.topCenter,
                    // Fixed full-width wrapper so only height animates —
                    // otherwise width snaps in from the left, making the
                    // reveal look like it's growing out of the top-left corner.
                    child: SizedBox(
                      width: double.infinity,
                      child: _isAdvancedMetricsExpanded
                          ? Column(
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: _buildMetricCard(
                                        'Frequency',
                                        _frequency.toStringAsFixed(1),
                                        'Hz',
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: _buildMetricCard(
                                        'Power Factor',
                                        _powerFactor.toStringAsFixed(2),
                                        'PF',
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 20),
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  const SizedBox(height: 80),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- HOURLY CHART ---
  // Hold (or tap) to read any hour; swipe sideways for other days. Screen
  // readers get the day's total and previous/next-day actions instead.
  Widget _buildHourlyChart(String dateLabel) {
    final bool hintVisible =
        _showScrubHint &&
        _hourlyKwh.isNotEmpty &&
        !_isLoadingHistory &&
        _scrubHour == null;

    return Semantics(
      container: true,
      label: 'Hourly energy use, $dateLabel',
      value: _hourlyKwh.isEmpty
          ? 'No data'
          : '${_formatWithCommas(_hourlySum)} kilowatt-hours',
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Previous day'): () =>
            _changeDate(-1),
        if (!_isTodaySelected)
          const CustomSemanticsAction(label: 'Next day'): () => _changeDate(1),
      },
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          // Holding still briefly starts a scrub; moving first is a swipe.
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(
                  duration: const Duration(milliseconds: 160),
                ),
                (r) {
                  r
                    ..onLongPressStart = (d) {
                      _scrubAt(d.localPosition.dx, begin: true);
                    }
                    ..onLongPressMoveUpdate = (d) {
                      _scrubAt(d.localPosition.dx);
                    }
                    ..onLongPressEnd = (_) => _releaseScrub();
                },
              ),
          HorizontalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                HorizontalDragGestureRecognizer
              >(
                () => HorizontalDragGestureRecognizer(),
                (r) => r
                  ..onStart = _onSwipeStart
                  ..onUpdate = _onSwipeUpdate
                  ..onEnd = _onSwipeEnd
                  ..onCancel = () => _onSwipeEnd(DragEndDetails()),
              ),
          TapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                () => TapGestureRecognizer(),
                (r) => r..onTapUp = (d) => _peekAt(d.localPosition.dx),
              ),
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: CustomPaint(
                painter: _HourlyChartPainter(
                  from: _curveFrom,
                  to: _curveTo,
                  morph: _morphCurve,
                  swipeX: _swipeX,
                  cursorX: _cursorX,
                  cursorFade: _cursorFade,
                  liveHour: _liveHour,
                  textScaler: MediaQuery.textScalerOf(context),
                ),
              ),
            ),

            // Loading / empty-state overlay for the hourly chart
            if (_isLoadingHistory)
              const Positioned.fill(
                top: _HourlyChartPainter.topPad,
                child: Center(
                  child: SizedBox(
                    height: 24,
                    width: 24,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  ),
                ),
              )
            else if (_hourlyKwh.isEmpty)
              Positioned.fill(
                top: _HourlyChartPainter.topPad,
                child: Center(
                  child: Text(
                    _historyError ?? 'No data yet',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),

            // First-run hint, gone for good after the first scrub.
            Positioned(
              left: 16,
              right: 16,
              top: _HourlyChartPainter.topPad + 8,
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
                              'Hold to see each hour · swipe for other days',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: _HourlyChartPainter.chipInk,
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
      ),
    );
  }

  // --- SUB CARD WIDGET UI HELPERS ---

  // Small pill showing live device connection state, sourced from the
  // real-time `sync` RTDB field via _setupSyncListener().
  Widget _buildConnectionStatusBadge() {
    final Color statusColor = _isIotConnected ? Colors.green : Colors.red;
    final String label = _isIotConnected ? 'Connected' : 'Disconnected';
    final IconData icon = _isIotConnected
        ? Icons.wifi_rounded
        : Icons.wifi_off_rounded;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Icon(icon, size: 13, color: statusColor),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: statusColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveFeedCard({
    required String title,
    required String value,
    required String unit,
    required String subtitle,
    required List<FlSpot> spots,
    required List<ChartDataPoint> history,
    double minRange = 0,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
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
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  color: Colors.black,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    unit,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[500],
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
          SizedBox(
            height: 60,
            width: 110,
            child: LineChart(
              LineChartData(
                gridData: const FlGridData(show: false),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                minY: _getMinY(history, minRange: minRange),
                maxY: _getMaxY(history, minRange: minRange),
                lineTouchData: LineTouchData(
                  enabled: true,
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipItems: (touchedSpots) {
                      return touchedSpots.map((spot) {
                        return LineTooltipItem(
                          '${spot.y.toStringAsFixed(1)} $unit',
                          const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        );
                      }).toList();
                    },
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    curveSmoothness: 0.35,
                    color: primaryOrange,
                    barWidth: 2.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          primaryOrange.withValues(alpha: 0.35),
                          primaryOrange.withValues(alpha: 0.08),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.6, 1.0],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ],
              ),
              duration: Duration.zero,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricCard(String title, String value, String unit) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.grey.withValues(alpha: 0.35),
          width: 1,
        ),
        boxShadow: [
          // Small subtle shadow for depth
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
          // Slightly larger shadow for layered effect
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
            title,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey[700],
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  color: Colors.black,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                unit,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[600],
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Simple data holder for a single row in the metrics-explainer sheet.
class _MetricInfo {
  final IconData icon;
  final String title;
  final String description;

  const _MetricInfo({
    required this.icon,
    required this.title,
    required this.description,
  });
}

/// Two-step manual-restart walkthrough shown inside the "device went
/// offline" sheet: spot the switch on the meter, then flip it.
/// Both Lottie files are drawn on the same 1080×1080 canvas, so they're
/// stacked in one stage and cross-faded — the device stays in place
/// between steps and only the highlight / switch motion changes.
class _RestartGuide extends StatefulWidget {
  final Color accent;
  final VoidCallback onBack;
  final VoidCallback onDone;

  const _RestartGuide({
    super.key,
    required this.accent,
    required this.onBack,
    required this.onDone,
  });

  @override
  State<_RestartGuide> createState() => _RestartGuideState();
}

class _RestartGuideState extends State<_RestartGuide>
    with TickerProviderStateMixin {
  static const _steps = [
    (
      asset: 'assets/locate restart.json',
      title: 'Locate the switch',
      body:
          'Find the power switch on your GRID device. '
          "It's outlined in orange above.",
      action: 'I found it',
    ),
    (
      asset: 'assets/restart.json',
      title: 'Restart the device',
      body:
          'Flip the switch off, wait a few seconds, then flip it back on. '
          'The status will change to Connected once the device is back online.',
      action: 'Done',
    ),
  ];

  late final List<AnimationController> _controllers = [
    for (var i = 0; i < _steps.length; i++) AnimationController(vsync: this),
  ];
  int _step = 0;

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  // The visible step's clip loops from its first frame; hidden ones pause.
  void _goTo(int step) {
    setState(() => _step = step);
    for (var i = 0; i < _controllers.length; i++) {
      final c = _controllers[i];
      if (i != step) {
        c.stop();
      } else if (c.duration != null) {
        c
          ..reset()
          ..repeat();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isLast = _step == _steps.length - 1;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Step progress
        Row(
          children: [
            Text(
              'STEP ${_step + 1} OF ${_steps.length}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: widget.accent,
              ),
            ),
            const SizedBox(width: 12),
            for (var i = 0; i < _steps.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  height: 4,
                  decoration: BoxDecoration(
                    color: i <= _step ? widget.accent : Colors.grey[200],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),

        // Stage — every clip fills the same box with the same fit, so the
        // illustration lines up exactly when the steps cross-fade. The art
        // spans the canvas width and sits low with an empty band above it,
        // so a slightly wide box with `cover` anchored to the bottom sizes
        // it to the full sheet width and trims only that top band.
        AspectRatio(
          aspectRatio: 1.05,
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                for (var i = 0; i < _steps.length; i++)
                  AnimatedOpacity(
                    opacity: i == _step ? 1 : 0,
                    duration: const Duration(milliseconds: 220),
                    child: Lottie.asset(
                      _steps[i].asset,
                      controller: _controllers[i],
                      fit: BoxFit.cover,
                      alignment: Alignment.bottomCenter,
                      onLoaded: (composition) {
                        if (!mounted) return;
                        _controllers[i].duration = composition.duration;
                        if (i == _step) _controllers[i].repeat();
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        // The canvas keeps a little air below the box, so less gap here.
        const SizedBox(height: 8),

        // Copy for every step is laid out at once so the block keeps the
        // tallest step's height and the buttons below never jump.
        Stack(
          children: [
            for (var i = 0; i < _steps.length; i++)
              ExcludeSemantics(
                excluding: i != _step,
                child: AnimatedOpacity(
                  opacity: i == _step ? 1 : 0,
                  duration: const Duration(milliseconds: 220),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _steps[i].title,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _steps[i].body,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.45,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),

        // Primary action
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
              elevation: 0,
            ),
            onPressed: isLast ? widget.onDone : () => _goTo(_step + 1),
            child: Text(
              _steps[_step].action,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Secondary action — first step goes back to the offline summary
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              side: BorderSide(color: Colors.grey[300]!),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
            ),
            onPressed: _step == 0 ? widget.onBack : () => _goTo(_step - 1),
            child: const Text(
              'Back',
              style: TextStyle(
                color: Colors.black,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Frosted-glass surface used by the header pills and cards: blurred
/// backdrop, translucent white gradient fill and a light edge.
class _Glass extends StatelessWidget {
  final double radius;
  final EdgeInsetsGeometry padding;
  final Widget child;

  const _Glass({
    required this.radius,
    required this.padding,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
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
          child: child,
        ),
      ),
    );
  }
}

/// One day's hourly kWh line, resolved into the 24 hour slots the header
/// chart morphs between. Missing hours inside the day are bridged straight
/// across (the line joins neighbouring readings), and slots outside
/// [first]–[last] hold the end values so a shorter day can stretch into a
/// longer one.
class _DayCurve {
  const _DayCurve({
    required this.values,
    required this.present,
    required this.first,
    required this.last,
    required this.maxY,
    required this.leftRidge,
    required this.rightRidge,
    required this.leftEdge,
    required this.rightEdge,
    required this.opacity,
  });

  final List<double> values;
  final List<bool> present; // slots holding a real reading
  final double first; // drawn run, in hours
  final double last;
  final double maxY;
  // Muted lead-in/lead-out drawn in the side margins (x < 0, x > 24) so the
  // line runs edge to edge from the baseline: height factors of the end
  // value, and how visible each side is (0–1).
  final List<double> leftRidge;
  final List<double> rightRidge;
  final double leftEdge;
  final double rightEdge;
  final double opacity;

  bool get isEmpty => opacity == 0;

  static const List<double> _noRidge = [0, 0, 0, 0, 0, 0, 0];

  static final _DayCurve empty = _DayCurve(
    values: List.filled(24, 0.0),
    present: List.filled(24, false),
    first: 0,
    last: 0,
    maxY: 1,
    leftRidge: _noRidge,
    rightRidge: _noRidge,
    leftEdge: 0,
    rightEdge: 0,
    opacity: 0,
  );

  factory _DayCurve.fromHourly(Map<int, double> hourly, DateTime day) {
    final hours = hourly.keys.where((h) => h >= 0 && h < 24).toList()..sort();
    if (hours.isEmpty) return empty;

    final present = List<bool>.filled(24, false);
    for (final h in hours) {
      present[h] = true;
    }
    final values = List<double>.filled(24, 0);
    for (var h = 0; h < 24; h++) {
      if (present[h]) {
        values[h] = hourly[h]!;
        continue;
      }
      final prev = hours.lastWhere((k) => k < h, orElse: () => -1);
      final next = hours.firstWhere((k) => k > h, orElse: () => -1);
      if (prev < 0) {
        values[h] = hourly[next]!;
      } else if (next < 0) {
        values[h] = hourly[prev]!;
      } else {
        values[h] = lerpDouble(
          hourly[prev]!,
          hourly[next]!,
          (h - prev) / (next - prev),
        )!;
      }
    }
    final peak = hours.map((h) => hourly[h]!).reduce(max);

    // A side's ridge only shows when the readings reach that edge (first by
    // 1 AM, last from 11 PM), so offline gaps near midnight aren't bridged.
    // Seeded by the day so the ridges stay put across rebuilds.
    final rng = Random(day.year * 10000 + day.month * 100 + day.day);
    List<double> ridge() => [
      for (var i = 1; i < 8; i++)
        (0.12 + 0.4 * (i / 8) * (i / 8)) * (0.7 + 0.6 * rng.nextDouble()),
    ];
    final hasLeft = hours.first <= 1;
    final leftRidge = hasLeft ? ridge() : _noRidge;
    final hasRight = hours.last >= 23;
    final rightRidge = hasRight ? ridge() : _noRidge;

    return _DayCurve(
      values: values,
      present: present,
      first: hours.first.toDouble(),
      last: hours.last.toDouble(),
      maxY: peak == 0 ? 1 : peak * 1.3,
      leftRidge: leftRidge,
      rightRidge: rightRidge,
      leftEdge: hasLeft ? 1 : 0,
      rightEdge: hasRight ? 1 : 0,
      opacity: 1,
    );
  }

  double valueAt(double hour) {
    final x = hour.clamp(0.0, 23.0);
    final i = x.floor();
    return lerpDouble(values[i], values[min(i + 1, 23)], x - i)!;
  }

  bool sameShape(_DayCurve other) =>
      opacity == other.opacity &&
      first == other.first &&
      last == other.last &&
      maxY == other.maxY &&
      listEquals(values, other.values) &&
      listEquals(present, other.present) &&
      listEquals(leftRidge, other.leftRidge) &&
      listEquals(rightRidge, other.rightRidge);

  // The same run lying flat on the baseline, invisible: what an empty day
  // rises from or sinks into.
  _DayCurve _flattened() => _DayCurve(
    values: List.filled(24, 0.0),
    present: present,
    first: first,
    last: last,
    maxY: 1,
    leftRidge: leftRidge,
    rightRidge: rightRidge,
    leftEdge: leftEdge,
    rightEdge: rightEdge,
    opacity: 0,
  );

  static _DayCurve lerp(_DayCurve a, _DayCurve b, double t) {
    if (t >= 1) return b;
    if (t <= 0) return a;
    if (a.isEmpty && b.isEmpty) return b;
    if (a.isEmpty) a = b._flattened();
    if (b.isEmpty) b = a._flattened();

    List<double> mix(List<double> x, List<double> y) => [
      for (var i = 0; i < x.length; i++) lerpDouble(x[i], y[i], t)!,
    ];
    return _DayCurve(
      values: mix(a.values, b.values),
      present: b.present,
      first: lerpDouble(a.first, b.first, t)!,
      last: lerpDouble(a.last, b.last, t)!,
      maxY: lerpDouble(a.maxY, b.maxY, t)!,
      leftRidge: mix(
        a.leftEdge > 0 ? a.leftRidge : b.leftRidge,
        b.leftEdge > 0 ? b.leftRidge : a.leftRidge,
      ),
      rightRidge: mix(
        a.rightEdge > 0 ? a.rightRidge : b.rightRidge,
        b.rightEdge > 0 ? b.rightRidge : a.rightRidge,
      ),
      leftEdge: lerpDouble(a.leftEdge, b.leftEdge, t)!,
      rightEdge: lerpDouble(a.rightEdge, b.rightEdge, t)!,
      opacity: lerpDouble(a.opacity, b.opacity, t)!,
    );
  }
}

/// Paints the header's hourly kWh chart on its fixed 12 AM–12 AM grid: the
/// day's line (mid-morph while data changes), the muted ridges in the side
/// margins, and the scrub cursor with its hour chip. While scrubbing, the
/// line up to the cursor stays bright and the rest steps back, matching the
/// running total the header cards show.
class _HourlyChartPainter extends CustomPainter {
  _HourlyChartPainter({
    required this.from,
    required this.to,
    required this.morph,
    required this.swipeX,
    required this.cursorX,
    required this.cursorFade,
    required this.liveHour,
    required this.textScaler,
  }) : super(repaint: Listenable.merge([morph, swipeX, cursorX, cursorFade]));

  // Hours run 0–24; the margins either side hold the ridges.
  static const double minX = -4;
  static const double maxX = 28;
  // Room above the plot for the top scale label and the hour chip, and
  // below it for the hour labels.
  static const double topPad = 24;
  static const double bottomPad = 24;
  static const Color chipInk = Color(0xFF2B1A10);
  static const Color _chipInkSoft = Color(0xFF6B4A35);
  static const Color _ridgeColor = Color(0x99FFE3C4);
  static const Color _accent = Color(0xFFF26E22);
  static const _axisLabels = [
    (0.0, '12 AM'),
    (6.0, '6 AM'),
    (12.0, '12 PM'),
    (18.0, '6 PM'),
    (24.0, '12 AM'),
  ];

  final _DayCurve from;
  final _DayCurve to;
  final Animation<double> morph;
  final Animation<double> swipeX;
  final Animation<double> cursorX;
  final Animation<double> cursorFade;
  final int? liveHour; // today's hour that is still filling up
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    final curve = _DayCurve.lerp(from, to, morph.value);
    final plot = Rect.fromLTRB(0, topPad, size.width, size.height - bottomPad);
    if (plot.height <= 0 || size.width <= 0) return;
    double px(double x) => (x - minX) / (maxX - minX) * size.width;
    double py(double y) => plot.bottom - y / curve.maxY * plot.height;
    final fade = cursorFade.value.clamp(0.0, 1.0);

    _paintGrid(canvas, size, plot, px, py, curve.maxY, fade);

    // The curve follows a swipe sideways and fades as it goes.
    final slide = swipeX.value;
    final alpha =
        curve.opacity *
        (1 - (slide.abs() / (size.width * 0.3)).clamp(0.0, 1.0));
    if (alpha > 0.005) {
      canvas.save();
      canvas.clipRect(Offset.zero & size);
      canvas.translate(slide, 0);
      _paintCurve(canvas, plot, px, py, curve, alpha, fade);
      canvas.restore();
    }

    if (fade > 0.005 && !to.isEmpty) {
      _paintCursor(canvas, size, plot, px, py, curve, fade);
    }
  }

  void _paintGrid(
    Canvas canvas,
    Size size,
    Rect plot,
    double Function(double) px,
    double Function(double) py,
    double maxY,
    double fade,
  ) {
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.2)
      ..strokeWidth = 1;
    for (final (x, _) in _axisLabels) {
      canvas.drawLine(
        Offset(px(x), plot.top),
        Offset(px(x), plot.bottom),
        grid,
      );
    }
    canvas.drawLine(
      Offset(0, py(maxY / 2)),
      Offset(size.width, py(maxY / 2)),
      grid,
    );

    // Scale labels hang just under their lines at the right edge; they step
    // back while scrubbing so the chip reads first.
    final scaleStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.8 * (1 - 0.7 * fade)),
      fontSize: 10,
      fontWeight: FontWeight.w600,
    );
    for (final (y, label) in [
      (maxY / 2, (maxY / 2).toStringAsFixed(2)),
      (maxY, '${maxY.toStringAsFixed(2)} kWh'),
    ]) {
      final tp = _layout(TextSpan(text: label, style: scaleStyle));
      tp.paint(canvas, Offset(size.width - 4 - tp.width, py(y) + 2));
      tp.dispose();
    }

    final axisStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.8),
      fontSize: 10,
      fontWeight: FontWeight.bold,
    );
    for (final (x, label) in _axisLabels) {
      final tp = _layout(TextSpan(text: label, style: axisStyle));
      tp.paint(canvas, Offset(px(x) - tp.width / 2, plot.bottom + 8));
      tp.dispose();
    }
  }

  void _paintCurve(
    Canvas canvas,
    Rect plot,
    double Function(double) px,
    double Function(double) py,
    _DayCurve curve,
    double alpha,
    double fade,
  ) {
    final points = <Offset>[
      Offset(px(curve.first), py(curve.valueAt(curve.first))),
      for (var h = curve.first.floor() + 1; h < curve.last; h++)
        Offset(px(h.toDouble()), py(curve.values[h])),
      if (curve.last > curve.first)
        Offset(px(curve.last), py(curve.valueAt(curve.last))),
    ];

    final startY = curve.valueAt(curve.first);
    final endY = curve.valueAt(curve.last);
    final leftRidge = [
      Offset(px(minX), plot.bottom),
      for (var i = 1; i <= 7; i++)
        Offset(px(minX + 0.5 * i), py(startY * curve.leftRidge[i - 1])),
      points.first,
    ];
    final rightRidge = [
      points.last,
      for (var i = 7; i >= 1; i--)
        Offset(px(maxX - 0.5 * i), py(endY * curve.rightRidge[i - 1])),
      Offset(px(maxX), plot.bottom),
    ];

    final line = Path()..addPolygon(points, false);
    final area = _areaUnder(points, plot.bottom);
    final areaTop = points.map((p) => p.dy).reduce(min);
    final areaRect = Rect.fromLTRB(plot.left, areaTop, plot.right, plot.bottom);

    void draw(double a) {
      if (curve.leftEdge > 0.005) {
        _paintRidge(canvas, plot, leftRidge, a * curve.leftEdge);
      }
      if (curve.rightEdge > 0.005) {
        _paintRidge(canvas, plot, rightRidge, a * curve.rightEdge);
      }
      if (points.length == 1) {
        canvas.drawCircle(
          points.first,
          2.5,
          Paint()..color = Colors.white.withValues(alpha: a),
        );
        return;
      }
      canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: 0.20 * a),
              Colors.white.withValues(alpha: 0.05 * a),
              Colors.white.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.5, 1.0],
          ).createShader(areaRect),
      );
      // Soft aura, then the line itself.
      canvas.drawPath(
        line,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white.withValues(alpha: 0.25 * a)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.8),
      );
      canvas.drawPath(
        line,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = Colors.white.withValues(alpha: a),
      );
    }

    if (fade <= 0.005) {
      draw(alpha);
      return;
    }
    // Up to the cursor is what the running total counts; the rest of the
    // day steps back.
    final cut = px(cursorX.value.clamp(curve.first, curve.last));
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(-1e4, -1e4, cut, 1e4));
    draw(alpha);
    canvas.restore();
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(cut, -1e4, 1e4, 1e4));
    draw(alpha * (1 - 0.62 * fade));
    canvas.restore();
  }

  void _paintRidge(Canvas canvas, Rect plot, List<Offset> points, double a) {
    final top = points.map((p) => p.dy).reduce(min);
    canvas.drawPath(
      _areaUnder(points, plot.bottom),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.10 * a),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromLTRB(plot.left, top, plot.right, plot.bottom)),
    );
    canvas.drawPath(
      Path()..addPolygon(points, false),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = _ridgeColor.withValues(alpha: _ridgeColor.a * a),
    );
  }

  void _paintCursor(
    Canvas canvas,
    Size size,
    Rect plot,
    double Function(double) px,
    double Function(double) py,
    _DayCurve curve,
    double fade,
  ) {
    final hours = cursorX.value.clamp(curve.first, curve.last);
    final x = px(hours);
    final y = py(curve.valueAt(hours));
    final hour = hours.round().clamp(0, 23);

    // Chip: the hour and what it used, centred over the cursor but kept on
    // screen. Hours with no reading say so instead of showing a bridged value.
    final when = hour == liveHour ? '${_clock(hour)} – now' : _hourRange(hour);
    final reading = to.present[hour]
        ? '${to.values[hour].toStringAsFixed(2)} kWh'
        : 'No reading';
    final tp = _layout(
      TextSpan(
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: chipInk.withValues(alpha: fade),
        ),
        children: [
          TextSpan(text: when),
          TextSpan(
            text: '  ·  $reading',
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: _chipInkSoft.withValues(alpha: fade),
            ),
          ),
        ],
      ),
    );
    final chipSize = Size(tp.width + 20, tp.height + 10);
    final chipLeft = (x - chipSize.width / 2)
        .clamp(4.0, max(4.0, size.width - chipSize.width - 4))
        .toDouble();
    final chip = RRect.fromRectAndRadius(
      Offset(chipLeft, 0) & chipSize,
      const Radius.circular(12),
    );

    canvas.drawLine(
      Offset(x, chip.bottom),
      Offset(x, plot.bottom),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.85 * fade)
        ..strokeWidth = 1.5,
    );

    canvas.drawRRect(
      chip.shift(const Offset(0, 3)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.16 * fade)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawRRect(
      chip,
      Paint()..color = Colors.white.withValues(alpha: fade),
    );
    tp.paint(canvas, Offset(chip.left + 10, chip.top + 5));
    tp.dispose();

    // Marker riding the line.
    canvas.drawCircle(
      Offset(x, y + 2),
      7,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.18 * fade)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(
      Offset(x, y),
      7,
      Paint()..color = Colors.white.withValues(alpha: fade),
    );
    canvas.drawCircle(
      Offset(x, y),
      4,
      Paint()..color = _accent.withValues(alpha: fade),
    );
  }

  Path _areaUnder(List<Offset> points, double baseline) => Path()
    ..addPolygon([
      ...points,
      Offset(points.last.dx, baseline),
      Offset(points.first.dx, baseline),
    ], true);

  TextPainter _layout(TextSpan span) => TextPainter(
    text: span,
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
  )..layout();

  static String _clock(int hour) =>
      '${hour % 12 == 0 ? 12 : hour % 12} ${hour % 24 < 12 ? 'AM' : 'PM'}';

  // "3–4 PM", or "11 AM–12 PM" when the hour crosses noon/midnight.
  static String _hourRange(int hour) {
    String period(int h) => h % 24 < 12 ? 'AM' : 'PM';
    String number(int h) => '${h % 12 == 0 ? 12 : h % 12}';
    final end = hour + 1;
    return period(hour) == period(end)
        ? '${number(hour)}–${number(end)} ${period(hour)}'
        : '${_clock(hour)}–${_clock(end)}';
  }

  @override
  bool shouldRepaint(_HourlyChartPainter old) =>
      old.from != from ||
      old.to != to ||
      old.liveHour != liveHour ||
      old.textScaler != textScaler;
}
