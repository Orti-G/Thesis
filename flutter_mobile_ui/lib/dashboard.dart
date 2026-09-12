import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'dart:math';
import 'main.dart';

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

class _DashboardState extends State<Dashboard> {
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
    if (_hourlyKwh.isEmpty) return 0.0;
    return _hourlyKwh.values.fold(0.0, (sum, v) => sum + v);
  }

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

    if (_isTestMode) {
      _startDemoMode();
    } else {
      _setupFirebaseListener();
      _attachTodayHistoryListener();
      _setupSyncListener();
    }
  }

  void _onNicknameChanged() {
    if (!mounted) return;
    setState(() => _nickname = nicknameNotifier.value);
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

    _demoTimer?.cancel();
    _demoTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
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

        if (_voltageHistory.length >= maxDataPoints)
          _voltageHistory.removeAt(0);
        _voltageHistory.add(
          ChartDataPoint(timestamp: timestamp, value: _currentVoltage),
        );

        final currentHour = DateTime.now().hour;
        _hourlyKwh[currentHour] = (_hourlyKwh[currentHour] ?? 0.1) + 0.002;
        _lastHistoryUpdateTime = DateTime.now();
      });
    });
  }

  void _setupFirebaseListener() {
    DatabaseReference ref = FirebaseDatabase.instance.ref('live_reading');

    _dbSubscription = ref.onValue.listen((event) {
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
      if (event.snapshot.value == null) {
        setState(() {
          _hourlyKwh = {};
          _todayTotalKwh = null;
          _isLoadingHistory = false;
        });
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
      } catch (e) {
        debugPrint("🔴 ERROR PARSING HOURLY HISTORY: $e");
        setState(() => _isLoadingHistory = false);
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

      if (!mounted) return;

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
    } catch (e) {
      debugPrint("🔴 ERROR FETCHING HISTORY: $e");
      if (!mounted) return;
      setState(() {
        _isLoadingHistory = false;
        _pastDayEstimatedCost = null;
        _historyError = 'Failed to load history';
      });
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

    if (picked == null) return;

    setState(() => _selectedDate = picked);

    final now = DateTime.now();
    final isPickedToday =
        picked.year == now.year &&
        picked.month == now.month &&
        picked.day == now.day;

    if (isPickedToday) {
      _attachTodayHistoryListener();
    } else {
      _fetchHistoryForDate(picked);
    }
  }

  // --- HOURLY CHART: date navigation (placeholder UI, arrows in header) ---
  void _changeDate(int dayOffset) {
    final newDate = _selectedDate.add(Duration(days: dayOffset));
    if (newDate.isAfter(DateTime.now())) return; // no future dates

    setState(() => _selectedDate = newDate);

    final now = DateTime.now();
    final isNewDateToday =
        newDate.year == now.year &&
        newDate.month == now.month &&
        newDate.day == now.day;

    if (isNewDateToday) {
      _attachTodayHistoryListener();
    } else {
      _fetchHistoryForDate(newDate);
    }
  }

  List<FlSpot> _generateHourlySpots() {
    if (_hourlyKwh.isEmpty) return const [];
    final hours = _hourlyKwh.keys.toList()..sort();
    return hours.map((h) => FlSpot(h.toDouble(), _hourlyKwh[h]!)).toList();
  }

  double _getHourlyMaxY() {
    if (_hourlyKwh.isEmpty) return 1.0;
    final maxVal = _hourlyKwh.values.reduce((a, b) => a > b ? a : b);
    return maxVal == 0 ? 1.0 : maxVal * 1.3;
  }

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

      // Only pop the sheet on the transition into "disconnected" so it
      // doesn't spam the user while `sync` stays false.
      if (!isConnected && wasConnected) {
        _showNoConnectionDialog();
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
    if (!mounted) return;

    final now = DateTime.now();
    final lastSeen = _lastLiveDataTime;
    final downtime = lastSeen != null ? now.difference(lastSeen) : Duration.zero;

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
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
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

              // Badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                style: TextStyle(fontSize: 13, color: Colors.grey[500]),
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
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Last Reading',
                            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            lastSeen != null
                                ? DateFormat('h:mm a').format(lastSeen)
                                : '—',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(width: 1, height: 32, color: Colors.grey[300]),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Downtime',
                            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
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
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    // TODO: hook this up to an actual remote-restart command
                    // if/when the firmware supports one.
                  },
                  child: const Text(
                    'Restart Device',
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
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    side: BorderSide(color: Colors.grey[300]!),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  onPressed: () => Navigator.of(sheetContext).pop(),
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
    );
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
                  separatorBuilder: (_, __) => Divider(
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
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: Colors.grey[600],
          ),
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
    testModeNotifier.removeListener(_onTestModeChanged);
    nicknameNotifier.removeListener(_onNicknameChanged);
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

    final double chartMaxY = _getHourlyMaxY();
    final double chartMidY = chartMaxY / 2;

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
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 6.0, sigmaY: 6.0),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.35),
                            width: 0.8,
                          ),
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
                              child: Text(
                                _isTodaySelected
                                    ? 'Today'
                                    : DateFormat('EEE MMM d').format(_selectedDate),
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: _isTodaySelected ? null : () => _changeDate(1),
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
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 18,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.25),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                                child: Text(
                                  _isTodaySelected ? 'Total Used' : 'Total Used',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.white.withValues(alpha: 0.9),
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                _formatWithCommas(_displayedTotal),
                                style: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Text(
                                'kWh',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
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
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 18,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.25),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.payments_rounded,
                                color: Colors.white,
                                size: 20,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  _isTodaySelected ? 'Est. Total Bill' : 'Total Bill',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.white.withValues(alpha: 0.9),
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '₱${_formatWithCommas(_isTodaySelected ? _estimatedCostFromDevice : (_pastDayEstimatedCost ?? 0.0))}',
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: -0.5,
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
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.25),
                          width: 0.8,
                        ),
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
                    // DAILY CHART WITH SUBTLE GLOW EFFECT
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: SizedBox(
                          width: double.infinity,
                          child: Padding(
                            padding: const EdgeInsets.only(
                              top: 24.0,
                              bottom: 0.0,
                            ),
                            child: Stack(
                              children: [
                                LineChart(
                                  LineChartData(
                                    minX: -2,
                                    maxX: 26,
                                    minY: 0,
                                    maxY: chartMaxY,
                                    gridData: FlGridData(
                                      show: true,
                                      drawVerticalLine: true,
                                      horizontalInterval: chartMidY == 0
                                          ? 1
                                          : chartMidY,
                                      verticalInterval: 6,
                                      getDrawingHorizontalLine: (value) =>
                                          FlLine(
                                            color: Colors.white.withValues(
                                              alpha: 0.2,
                                            ),
                                            strokeWidth: 1,
                                          ),
                                      getDrawingVerticalLine: (value) => FlLine(
                                        color: Colors.white.withValues(
                                          alpha: 0.2,
                                        ),
                                        strokeWidth: 1,
                                      ),
                                    ),
                                    borderData: FlBorderData(show: false),

                                    // --- Tooltip: shows hour (12-hr + AM/PM) and kWh on touch ---
                                    lineTouchData: LineTouchData(
                                      enabled: true,
                                      touchTooltipData: LineTouchTooltipData(
                                        fitInsideHorizontally: true,
                                        fitInsideVertically: true,
                                        getTooltipItems: (touchedSpots) {
                                          final latestHour =
                                              _hourlyKwh.keys.isEmpty
                                              ? null
                                              : _hourlyKwh.keys.reduce(
                                                  (a, b) => a > b ? a : b,
                                                );

                                          return touchedSpots.map((spot) {
                                            final hour = spot.x.round();
                                            final isLatestHour =
                                                _isTodaySelected &&
                                                latestHour != null &&
                                                hour == latestHour;

                                            if (isLatestHour &&
                                                _lastHistoryUpdateTime !=
                                                    null) {
                                              final timeStr =
                                                  DateFormat('h:mma')
                                                      .format(
                                                        _lastHistoryUpdateTime!,
                                                      )
                                                      .toLowerCase();
                                              return LineTooltipItem(
                                                'As of $timeStr\n${spot.y.toStringAsFixed(3)}kWh',
                                                const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 12,
                                                ),
                                              );
                                            }

                                            return LineTooltipItem(
                                              '${_formatHourLabel(spot.x)}\n${spot.y.toStringAsFixed(2)} kWh',
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

                                    extraLinesData: ExtraLinesData(
                                      horizontalLines: [
                                        HorizontalLine(
                                          y: chartMidY,
                                          color: Colors.transparent,
                                          label: HorizontalLineLabel(
                                            show: true,
                                            alignment: Alignment.bottomRight,
                                            padding: const EdgeInsets.only(
                                              right: 4,
                                              bottom: 4,
                                            ),
                                            style: TextStyle(
                                              color: Colors.white.withValues(
                                                alpha: 0.8,
                                              ),
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                            ),
                                            labelResolver: (line) =>
                                                chartMidY.toStringAsFixed(2),
                                          ),
                                        ),
                                        HorizontalLine(
                                          y: chartMaxY,
                                          color: Colors.transparent,
                                          label: HorizontalLineLabel(
                                            show: true,
                                            alignment: Alignment.bottomRight,
                                            padding: const EdgeInsets.only(
                                              right: 4,
                                              bottom: 4,
                                            ),
                                            style: TextStyle(
                                              color: Colors.white.withValues(
                                                alpha: 0.8,
                                              ),
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                            ),
                                            labelResolver: (line) =>
                                                '${chartMaxY.toStringAsFixed(2)} kWh',
                                          ),
                                        ),
                                      ],
                                    ),

                                    titlesData: FlTitlesData(
                                      topTitles: const AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: false,
                                        ),
                                      ),
                                      leftTitles: const AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: false,
                                        ),
                                      ),
                                      rightTitles: const AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: false,
                                        ),
                                      ),
                                      bottomTitles: AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: true,
                                          reservedSize: 24,
                                          interval: 6,
                                          getTitlesWidget: (value, meta) {
                                            String label = '';
                                            if (value == 0) label = '12 AM';
                                            if (value == 6) label = '6 AM';
                                            if (value == 12) label = '12 PM';
                                            if (value == 18) label = '6 PM';
                                            if (value == 24) label = '12 AM';

                                            if (label.isEmpty) {
                                              return const SizedBox.shrink();
                                            }

                                            final textWidget = Text(
                                              label,
                                              style: TextStyle(
                                                color: Colors.white.withValues(
                                                  alpha: 0.8,
                                                ),
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            );

                                            // The "12 AM" ticks sit exactly at the left
                                            // (x = 0) and right (x = 24) edges of the
                                            // chart, so their centered labels get
                                            // clipped. Nudge them inward instead of
                                            // centering on the tick.
                                            if (value == 0) {
                                              return SideTitleWidget(
                                                meta: meta,
                                                space: 8,
                                                child: Transform.translate(
                                                  offset: const Offset(16, 0),
                                                  child: textWidget,
                                                ),
                                              );
                                            }

                                            if (value == 24) {
                                              return SideTitleWidget(
                                                meta: meta,
                                                space: 8,
                                                child: Transform.translate(
                                                  offset: const Offset(-16, 0),
                                                  child: textWidget,
                                                ),
                                              );
                                            }

                                            return SideTitleWidget(
                                              meta: meta,
                                              space: 8,
                                              child: textWidget,
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                    lineBarsData: [
                                      LineChartBarData(
                                        spots: _generateHourlySpots(),
                                        isCurved: false,
                                        color: Colors.white,
                                        barWidth: 2.0,
                                        isStrokeCapRound: true,
                                        dotData: const FlDotData(show: false),
                                        // Softened neon line aura
                                        shadow: Shadow(
                                          blurRadius: 4,
                                          color: Colors.white.withValues(
                                            alpha: 0.25,
                                          ),
                                          offset: Offset.zero,
                                        ),
                                        // Much lighter, cleaner fade underneath the bar
                                        belowBarData: BarAreaData(
                                          show: true,
                                          gradient: LinearGradient(
                                            colors: [
                                              Colors.white.withValues(
                                                alpha: 0.20,
                                              ),
                                              Colors.white.withValues(
                                                alpha: 0.05,
                                              ),
                                              Colors.white.withValues(
                                                alpha: 0.0,
                                              ),
                                            ],
                                            stops: const [0.0, 0.5, 1.0],
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                // Loading / empty-state overlay for the hourly chart
                                if (_isLoadingHistory)
                                  const Positioned.fill(
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
                                    child: Center(
                                      child: Text(
                                        _historyError ?? 'No data yet',
                                        style: TextStyle(
                                          color: Colors.white.withValues(
                                            alpha: 0.8,
                                          ),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
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