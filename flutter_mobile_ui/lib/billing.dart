import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;
import 'package:lottie/lottie.dart';
import 'package:custom_refresh_indicator/custom_refresh_indicator.dart';

enum _BillMode { endOfMonth, current }

/// Bounces at the top (so pull-to-refresh still feels natural) but clamps
/// hard at the bottom edge so the page can't be pulled past the end.
class TopBounceBottomClampPhysics extends BouncingScrollPhysics {
  const TopBounceBottomClampPhysics({super.parent});

  @override
  TopBounceBottomClampPhysics applyTo(ScrollPhysics? ancestor) {
    return TopBounceBottomClampPhysics(parent: buildParent(ancestor));
  }

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    // Already at/after the bottom edge and pushing further down.
    if (position.maxScrollExtent <= position.pixels &&
        position.pixels < value) {
      return value - position.pixels;
    }
    // Crossing the bottom edge in this single update.
    if (position.pixels < position.maxScrollExtent &&
        position.maxScrollExtent < value) {
      return value - position.maxScrollExtent;
    }
    // Top edge: no clamping, so it keeps the bounce.
    return 0.0;
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    // Flinging toward the bottom, or resting at/past it: use clamping
    // behavior so it stops dead at the end.
    if (velocity > 0.0 || position.pixels >= position.maxScrollExtent) {
      return const ClampingScrollPhysics().createBallisticSimulation(
        position,
        velocity,
      );
    }
    // Otherwise (top side) keep the normal bouncing spring.
    return super.createBallisticSimulation(position, velocity);
  }
}

/// Input mode for the manual bill calculator.
/// [kwh]   — user types consumption, we hit /calculator/convert with kwh.
/// [pesos] — user types a budget, we hit /calculator/convert with peso to
///           get the equivalent kWh.
enum _CalcInput { kwh, pesos }

/// Tier metadata for a given consumption figure, so the live tier card and
/// the calculator resolve tiers through one code path.
class _TierInfo {
  final String title;
  final String rate;
  final double max;
  final double energy;
  final double percentage;
  final String remainingText;

  const _TierInfo({
    required this.title,
    required this.rate,
    required this.max,
    required this.energy,
    required this.percentage,
    required this.remainingText,
  });
}

class BillingScreen extends StatefulWidget {
  const BillingScreen({super.key});

  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends State<BillingScreen> {
  _BillMode _mode = _BillMode.endOfMonth;
  // 1 = new content enters from the right (to Current), -1 = from the left.
  int _slideDir = 1;

  final Color primaryOrange = const Color(0xFFFCB775);
  final Color tierCardBorder = const Color(0xFFFA8B39);
  final Color creamBg = const Color(0xFFFFFDF9);
  final Color textDark = const Color(0xFF1E1E1E);
  final Color brandOrangeText = const Color(0xFFE25319);
  final Color tierTextColor = const Color(0xFF7A3712);

  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();
  static const String _apiBaseUrl = 'http://35.209.250.46:8000';

  final Map<int, Future<Map<String, dynamic>>> _breakdownCache = {};

  // Timestamp for tracking when the billing forecast was last refreshed
  DateTime? _lastRefreshedAt;

  // Shared clipper instance for the ticket sheet
  static final _TicketReceiptClipper _ticketClipper = _TicketReceiptClipper(
    notchRadius: 16,
    notchPositionRatio: 0.24,
  );

  @override
  void initState() {
    super.initState();
    // Auto-refresh the billing page every time this screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleRefresh();
    });
  }

  Future<Map<String, dynamic>> _fetchBillBreakdownCached(double kwh) {
    final key = kwh.round();
    return _breakdownCache.putIfAbsent(key, () => _fetchBillBreakdown(kwh));
  }

  static const Map<String, double> _fallbackRates = {
    '0-200': 0.9803,
    '201-300': 1.2908,
    '301-400': 1.5837,
    'over-400': 2.0941,
  };

  Future<void> _handleRefresh() async {
    final url = Uri.parse('$_apiBaseUrl/forecast');
    try {
      final response = await http.post(url);
      if (response.statusCode == 200) {
        debugPrint('Forecast successfully refreshed via API.');
      } else {
        debugPrint('API server returned an error: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error sending refresh request: $e');
    } finally {
      if (mounted) {
        setState(() {
          _lastRefreshedAt = DateTime.now();
        });
      }
    }
  }

  String _formatLastRefreshed(DateTime dateTime) {
    final hour = dateTime.hour == 0
        ? 12
        : (dateTime.hour > 12 ? dateTime.hour - 12 : dateTime.hour);
    final minute = dateTime.minute.toString().padLeft(2, '0');
    final period = dateTime.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  Map<String, double> _parseRates(dynamic meralcoRatesNode) {
    final Map<String, double> rates = Map.of(_fallbackRates);
    if (meralcoRatesNode is Map) {
      final bracketsRaw = meralcoRatesNode['brackets'];
      if (bracketsRaw is Map) {
        bracketsRaw.forEach((key, value) {
          final parsed = double.tryParse(value.toString());
          if (parsed != null) {
            rates[key.toString()] = parsed;
          }
        });
      }
    }
    return rates;
  }

  String _parseEffectivePeriod(dynamic meralcoRatesNode) {
    if (meralcoRatesNode is Map) {
      final period = meralcoRatesNode['effective_period'];
      if (period != null && period.toString().isNotEmpty) {
        return period.toString();
      }
    }
    return '';
  }

  double _parseFixedCharge(dynamic meralcoRatesNode) {
    if (meralcoRatesNode is Map) {
      final raw = meralcoRatesNode['fixed_charge'];
      if (raw is num) return raw.toDouble();
      final parsed = double.tryParse(raw?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return 0.0;
  }

  String _parseSourceFile(dynamic meralcoRatesNode) {
    if (meralcoRatesNode is Map) {
      final file = meralcoRatesNode['source_file'];
      if (file != null && file.toString().isNotEmpty) {
        return file.toString();
      }
    }
    return '';
  }

  String _formatRate(Map<String, double> rates, String key) {
    final value = rates[key] ?? _fallbackRates[key] ?? 0.0;
    return '₱${value.toStringAsFixed(4)}/kWh';
  }

  double _calculateBill(double kwh, Map<String, double> rates) {
    if (kwh <= 0) return 0.0;

    final r1 = rates['0-200'] ?? _fallbackRates['0-200']!;
    final r2 = rates['201-300'] ?? _fallbackRates['201-300']!;
    final r3 = rates['301-400'] ?? _fallbackRates['301-400']!;
    final r4 = rates['over-400'] ?? _fallbackRates['over-400']!;

    double bill = 0.0;

    final tier1Kwh = kwh > 200 ? 200 : kwh;
    bill += tier1Kwh * r1;

    if (kwh > 200) {
      final tier2Kwh = (kwh > 300 ? 300 : kwh) - 200;
      bill += tier2Kwh * r2;
    }
    if (kwh > 300) {
      final tier3Kwh = (kwh > 400 ? 400 : kwh) - 300;
      bill += tier3Kwh * r3;
    }
    if (kwh > 400) {
      final tier4Kwh = kwh - 400;
      bill += tier4Kwh * r4;
    }

    return bill;
  }

  Future<Map<String, dynamic>> _fetchBillBreakdown(double kwh) async {
    final url = Uri.parse(
      '$_apiBaseUrl/bill/breakdown?kwh=${kwh.toStringAsFixed(2)}',
    );
    final response = await http.get(url).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// GET /calculator/convert — pass exactly one of [kwh] or [peso].
  /// kwh  -> same itemized JSON as /bill/breakdown.
  /// peso -> {"peso": ..., "period": ..., "kwh": ...}
  Future<Map<String, dynamic>> _fetchCalculatorConvert({
    required String period,
    double? kwh,
    double? peso,
  }) async {
    final url = Uri.parse('$_apiBaseUrl/calculator/convert').replace(
      queryParameters: {
        'period': period,
        if (kwh != null) 'kwh': kwh.toStringAsFixed(2),
        if (peso != null) 'peso': peso.toStringAsFixed(2),
      },
    );
    final response = await http.get(url).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// There is no "list schedules" endpoint, so probe /calculator/convert for
  /// each candidate month (12 back, 2 ahead) and keep the ones the backend
  /// can answer. Returns {label: filename}, oldest first.
  Future<Map<String, String>> _fetchRatePeriods() async {
    const names = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final now = DateTime.now();
    final candidates = <(String, String)>[];
    for (var offset = -12; offset <= 2; offset++) {
      final d = DateTime(now.year, now.month + offset);
      final file =
          '${d.month.toString().padLeft(2, '0')}-${d.year}_rate_schedule.pdf';
      candidates.add(('${names[d.month - 1]} ${d.year}', file));
    }

    final results = await Future.wait(
      candidates.map((c) async {
        try {
          await _fetchCalculatorConvert(period: c.$2, kwh: 1);
          return c;
        } catch (_) {
          return null;
        }
      }),
    );
    return {
      for (final r in results)
        if (r != null) r.$1: r.$2,
    };
  }

  bool _sameMap(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  List<_BillLineItem> _buildBreakdownItems(Map<String, dynamic> data) {
    double num_(dynamic v) => (v as num?)?.toDouble() ?? 0.0;
    Map<String, dynamic> map_(dynamic v) =>
        (v is Map) ? v.cast<String, dynamic>() : const {};

    List<_BillLineItem> sub(
      Map<String, dynamic> m,
      Map<String, String> labels,
    ) {
      final items = <_BillLineItem>[];
      labels.forEach((key, label) {
        final amt = num_(m[key]);
        if (amt != 0) items.add(_BillLineItem(label, amt));
      });
      return items;
    }

    final distribution = map_(data['distribution_breakdown']);
    final seniorCitizen = map_(data['senior_citizen_breakdown']);
    final universal = map_(data['universal_charges_breakdown']);
    final rpt = map_(data['rpt_breakdown']);
    final lft = map_(data['lft_breakdown']);
    final vat = map_(data['vat_breakdown']);

    return [
      _BillLineItem('Generation', num_(data['generation'])),
      _BillLineItem('Transmission', num_(data['transmission'])),
      _BillLineItem('Ancillary Service', num_(data['ancillary_service'])),
      _BillLineItem('System Loss', num_(data['system_loss'])),
      _BillLineItem(
        'Distribution (Meralco)',
        num_(data['distribution']),
        sub(distribution, {
          'distribution_charge': 'Distribution Charge',
          'metering_fixed': 'Metering Charge (Fixed)',
          'metering_perkwh': 'Metering Charge (per kWh)',
          'supply_fixed': 'Supply Charge (Fixed)',
          'supply_perkwh': 'Supply Charge (per kWh)',
          'awat_1': 'AWAT (Refund)/Collect 1',
          'awat_2': 'AWAT (Refund)/Collect 2',
          'regulatory_reset_adj': 'Regulatory Reset Fee Adj',
        }),
      ),
      _BillLineItem(
        'Senior Citizen',
        num_(data['senior_citizen']),
        sub(seniorCitizen, {
          'senior_citizen_subsidy': 'Senior Citizen Subsidy',
          'lifeline_rate_adj': 'Lifeline Rate Adj',
        }),
      ),
      _BillLineItem(
        'Universal Charges',
        num_(data['universal_charges']),
        sub(universal, {
          'spug': 'Missionary Elec (SPUG)',
          'redci': 'Missionary Elec (REDCI)',
          'environmental_fund': 'Environmental Fund',
          'npc_stranded_debt': 'NPC Stranded Debt',
        }),
      ),
      _BillLineItem('FiT-All (Renewable)', num_(data['fit_all'])),
      _BillLineItem('Lifeline', num_(data['lifeline'])),
      _BillLineItem(
        'RPT',
        num_(data['rpt']),
        sub(rpt, {'charge': 'RPT Charge', 'adj': 'RPT Adj'}),
      ),
      _BillLineItem(
        'LFT',
        num_(data['lft']),
        sub(lft, {'charge': 'LFT Charge', 'adj': 'LFT Adj'}),
      ),
      _BillLineItem(
        'VAT',
        num_(data['vat']),
        sub(vat, {
          'generation': 'VAT on Generation',
          'transmission': 'VAT on Transmission',
          'ancillary_service': 'VAT on Ancillary Service',
          'system_loss': 'VAT on System Loss',
          'distribution': 'VAT on Distribution',
          'senior_citizen': 'VAT on Senior Citizen',
        }),
      ),
      _BillLineItem('Non-VAT', num_(data['non_vat'])),
    ];
  }

  _TierInfo _tierInfoFor(double kwh, Map<String, double> rates) {
    String title;
    String rate;
    double max;
    String remainingText;

    if (kwh <= 200) {
      title = 'TIER 1 STATUS';
      rate = _formatRate(rates, '0-200');
      max = 200.0;
      final remaining = (200.0 - kwh).clamp(0.0, 200.0);
      remainingText =
          '${remaining.toStringAsFixed(2)} kWh na lang bago umakyat ang tier';
    } else if (kwh <= 300) {
      title = 'TIER 2 STATUS';
      rate = _formatRate(rates, '201-300');
      max = 300.0;
      final remaining = (300.0 - kwh).clamp(0.0, 100.0);
      remainingText =
          '${remaining.toStringAsFixed(2)} kWh na lang bago umakyat ang tier';
    } else if (kwh <= 400) {
      title = 'TIER 3 STATUS';
      rate = _formatRate(rates, '301-400');
      max = 400.0;
      final remaining = (400.0 - kwh).clamp(0.0, 100.0);
      remainingText =
          '${remaining.toStringAsFixed(2)} kWh na lang bago umakyat ang tier';
    } else {
      title = 'TIER 4 STATUS';
      rate = _formatRate(rates, 'over-400');
      max = 400.0;
      remainingText = 'Naabot na ang pinakamataas na tier';
    }

    return _TierInfo(
      title: title,
      rate: rate,
      max: max,
      energy: kwh,
      percentage: (kwh / max).clamp(0.0, 1.0),
      remainingText: remainingText,
    );
  }

  void _showBillCalculator(
    BuildContext context,
    Map<String, double> rates, {
    required double fixedCharge,
    required String sourceFile,
  }) {
    final controller = TextEditingController();
    _CalcInput inputType = _CalcInput.kwh;
    String? error;
    bool loading = false;
    double? pesoResultKwh;
    double? pesoResultAmount;

    // --- RATE MONTH STATE ---
    // Seeded with a fallback, then replaced by the backend's list (and kept
    // fresh while the sheet is open) so new schedules show up automatically.
    Map<String, String> monthPeriods = {
      'August 2026': '08-2026_rate_schedule.pdf',
      'September 2026': '09-2026_rate_schedule.pdf',
    };
    String selectedMonth = monthPeriods.keys.last;
    StateSetter? sheetSetState;
    bool sheetOpen = true;

    Future<void> refreshPeriods() async {
      try {
        final fetched = await _fetchRatePeriods();
        if (!sheetOpen || fetched.isEmpty) return;
        if (_sameMap(fetched, monthPeriods)) return;
        void apply() {
          monthPeriods = fetched;
          if (!monthPeriods.containsKey(selectedMonth)) {
            selectedMonth = monthPeriods.keys.last;
            pesoResultKwh = null;
          }
        }

        if (sheetSetState != null) {
          sheetSetState!(apply);
        } else {
          apply();
        }
      } catch (_) {
        // Keep the current list if the backend is unreachable.
      }
    }

    refreshPeriods();
    final periodsTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => refreshPeriods(),
    );
    // ------------------------

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (innerContext, setSheetState) {
            sheetSetState = setSheetState;
            final List<String> availableMonths = monthPeriods.keys.toList();
            Future<void> compute() async {
              if (loading) return;

              final value = double.tryParse(controller.text.trim());
              if (value == null || value <= 0) {
                setSheetState(() => error = 'Enter a valid number.');
                return;
              }

              final period = monthPeriods[selectedMonth]!;

              if (inputType == _CalcInput.kwh) {
                Navigator.of(sheetContext).pop();

                final tier = _tierInfoFor(value, rates);
                _showBillBreakdown(
                  context,
                  kwh: value,
                  tierTitle: tier.title,
                  tierRate: tier.rate,
                  tierMax: tier.max,
                  tierEnergy: tier.energy,
                  tierPercentage: tier.percentage,
                  tierRemainingText: tier.remainingText,
                  fixedCharge: fixedCharge,
                  sourceFile: sourceFile,
                  period: period,
                );
                return;
              }

              // Peso -> kWh
              setSheetState(() {
                loading = true;
                error = null;
                pesoResultKwh = null;
              });
              try {
                final data = await _fetchCalculatorConvert(
                  period: period,
                  peso: value,
                );
                final kwhResult = (data['kwh'] as num?)?.toDouble();
                if (kwhResult == null) {
                  throw Exception('Missing kwh in response');
                }
                if (!innerContext.mounted) return;
                setSheetState(() {
                  loading = false;
                  pesoResultKwh = kwhResult;
                  pesoResultAmount = value;
                });
              } catch (e) {
                debugPrint('Peso -> kWh conversion failed: $e');
                if (!innerContext.mounted) return;
                setSheetState(() {
                  loading = false;
                  error = 'Unable to convert right now. Please try again.';
                });
              }
            }

            Widget segmented() {
              final isKwh = inputType == _CalcInput.kwh;
              Widget label(String text, _CalcInput value) {
                final selected = inputType == value;
                return Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setSheetState(() {
                      inputType = value;
                      error = null;
                      pesoResultKwh = null;
                    }),
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            text,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: selected
                                  ? Colors.white
                                  : textDark.withValues(alpha: 0.55),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }

              return Container(
                height: 54,
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: tierCardBorder.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(40),
                ),
                child: Stack(
                  children: [
                    AnimatedAlign(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      alignment: isKwh
                          ? Alignment.centerLeft
                          : Alignment.centerRight,
                      child: FractionallySizedBox(
                        widthFactor: 0.5,
                        heightFactor: 1,
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(40),
                            gradient: LinearGradient(
                              colors: [
                                tierCardBorder,
                                tierCardBorder.withValues(alpha: 0.85),
                              ],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: tierCardBorder.withValues(alpha: 0.35),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        label('Usage (kWh)', _CalcInput.kwh),
                        label('Budget (\u20b1)', _CalcInput.pesos),
                      ],
                    ),
                  ],
                ),
              );
            }

            final bool isPesoMode = inputType == _CalcInput.pesos;

            Widget caption(String text) => Text(
              text,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
                color: textDark.withValues(alpha: 0.5),
              ),
            );

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(innerContext).viewInsets.bottom,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: creamBg,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(36),
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 26),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: textDark.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                caption('BILL CALCULATOR'),
                                const SizedBox(height: 3),
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 180),
                                  child: Text(
                                    isPesoMode
                                        ? 'What is your electricity budget?'
                                        : 'How many kWh will you use?',
                                    key: ValueKey(isPesoMode),
                                    style: TextStyle(
                                      fontSize: 22,
                                      height: 1.2,
                                      fontWeight: FontWeight.w900,
                                      color: textDark,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      segmented(),
                      const SizedBox(height: 16),
                      Focus(
                        child: Builder(
                          builder: (fctx) {
                            final focused = Focus.of(fctx).hasFocus;
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              padding: const EdgeInsets.fromLTRB(
                                26,
                                18,
                                26,
                                16,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(32),
                                border: Border.all(
                                  color: focused
                                      ? tierCardBorder
                                      : tierCardBorder.withValues(alpha: 0.18),
                                  width: focused ? 1.8 : 1,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: tierCardBorder.withValues(
                                      alpha: focused ? 0.18 : 0.06,
                                    ),
                                    blurRadius: 18,
                                    offset: const Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  caption(
                                    isPesoMode ? 'YOUR BUDGET' : 'YOUR USAGE',
                                  ),
                                  TextField(
                                    controller: controller,
                                    autofocus: true,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    cursorColor: tierCardBorder,
                                    style: TextStyle(
                                      fontSize: 38,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: -1,
                                      color: brandOrangeText,
                                    ),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      prefixText: isPesoMode ? '\u20b1 ' : null,
                                      prefixStyle: TextStyle(
                                        fontSize: 38,
                                        fontWeight: FontWeight.w900,
                                        color: tierCardBorder,
                                      ),
                                      suffixText: isPesoMode ? null : 'kWh',
                                      suffixStyle: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w800,
                                        color: textDark.withValues(alpha: 0.4),
                                      ),
                                      hintText: isPesoMode ? '2500' : '250',
                                      hintStyle: TextStyle(
                                        fontSize: 38,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: -1,
                                        color: textDark.withValues(alpha: 0.14),
                                      ),
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      contentPadding: const EdgeInsets.only(
                                        top: 6,
                                        bottom: 2,
                                      ),
                                    ),
                                    onChanged: (_) {
                                      if (pesoResultKwh != null) {
                                        setSheetState(
                                          () => pesoResultKwh = null,
                                        );
                                      }
                                    },
                                    onSubmitted: (_) => compute(),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFFB3261E,
                            ).withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  error!,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFFB3261E),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      if (isPesoMode && pesoResultKwh != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 16,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(30),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                tierCardBorder.withValues(alpha: 0.16),
                                tierCardBorder.withValues(alpha: 0.06),
                              ],
                            ),
                            border: Border.all(
                              color: tierCardBorder.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    caption('EQUIVALENT USAGE'),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${pesoResultKwh!.toStringAsFixed(2)} kWh',
                                      style: TextStyle(
                                        fontSize: 28,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: -0.5,
                                        color: brandOrangeText,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'for \u20b1${pesoResultAmount!.toStringAsFixed(2)} ($selectedMonth rate)',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: textDark.withValues(alpha: 0.5),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      const SizedBox(height: 18),
                      caption('RATE MONTH'),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.fromLTRB(24, 8, 18, 8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(40),
                          border: Border.all(
                            color: tierCardBorder.withValues(alpha: 0.18),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: selectedMonth,
                                  isExpanded: true,
                                  borderRadius: BorderRadius.circular(24),
                                  dropdownColor: Colors.white,
                                  icon: Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    color: textDark.withValues(alpha: 0.5),
                                  ),
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                    color: textDark,
                                  ),
                                  items: availableMonths.map((String month) {
                                    return DropdownMenuItem<String>(
                                      value: month,
                                      child: Text('$month Rate'),
                                    );
                                  }).toList(),
                                  onChanged: (String? newValue) {
                                    if (newValue != null) {
                                      setSheetState(() {
                                        selectedMonth = newValue;
                                        pesoResultKwh = null;
                                      });
                                    }
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              isPesoMode
                                  ? 'Checks how many kWh fit within this budget.'
                                  : 'Shows the full itemized breakdown for this usage.',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: textDark.withValues(alpha: 0.5),
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      GestureDetector(
                        onTap: compute,
                        child: Container(
                          height: 56,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(40),
                            gradient: LinearGradient(
                              colors: [
                                tierCardBorder.withValues(alpha: 0.9),
                                tierCardBorder,
                              ],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: tierCardBorder.withValues(alpha: 0.4),
                                blurRadius: 16,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: loading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text(
                                  'Compute',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.3,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      sheetOpen = false;
      periodsTimer.cancel();
    });
  }

  void _showBillBreakdown(
    BuildContext context, {
    required double kwh,
    required String tierTitle,
    required String tierRate,
    required double tierMax,
    required double tierEnergy,
    required double tierPercentage,
    required String tierRemainingText,
    required double fixedCharge,
    required String sourceFile,
    String? period,
  }) {
    bool isClosing = false;
    // Calculator flow: fetch once from /calculator/convert for the chosen
    // rate period. Otherwise fall back to the cached /bill/breakdown call.
    final Future<Map<String, dynamic>>? calcFuture = period == null
        ? null
        : _fetchCalculatorConvert(period: period, kwh: kwh);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (sheetContext) {
        return RepaintBoundary(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
            ),
            child: Stack(
              children: [
                Container(
                  padding: EdgeInsets.only(
                    top: MediaQuery.of(sheetContext).padding.top + 32,
                    bottom: 32,
                    left: 24,
                    right: 24,
                  ),
                  child: Center(
                    child: NotificationListener<ScrollUpdateNotification>(
                      onNotification: (notification) {
                        final dragDetails = notification.dragDetails;
                        if (!isClosing &&
                            notification.metrics.pixels <= 0 &&
                            dragDetails != null &&
                            dragDetails.delta.dy > 6) {
                          isClosing = true;
                          Navigator.of(sheetContext).pop();
                        }
                        return false;
                      },
                      child: RepaintBoundary(
                        child: Stack(
                          alignment: Alignment.topCenter,
                          clipBehavior: Clip.none,
                          children: [
                            Positioned.fill(
                              child: RepaintBoundary(
                                child: CustomPaint(
                                  isComplex: true,
                                  willChange: false,
                                  painter: _TicketShadowPainter(
                                    clipper: _ticketClipper,
                                  ),
                                ),
                              ),
                            ),
                            ClipPath(
                              clipper: _ticketClipper,
                              child: Container(
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFFFFF),
                                ),
                                padding: const EdgeInsets.fromLTRB(
                                  28,
                                  54,
                                  28,
                                  40,
                                ),
                                child: FutureBuilder<Map<String, dynamic>>(
                                  future:
                                      calcFuture ??
                                      _fetchBillBreakdownCached(kwh),
                                  builder: (context, snapshot) {
                                    if (snapshot.connectionState !=
                                        ConnectionState.done) {
                                      return const Padding(
                                        padding: EdgeInsets.symmetric(
                                          vertical: 90,
                                        ),
                                        child: Center(
                                          child: RepaintBoundary(
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2.5,
                                            ),
                                          ),
                                        ),
                                      );
                                    }

                                    if (snapshot.hasError ||
                                        snapshot.data == null) {
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 70,
                                        ),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.error_outline_rounded,
                                              size: 44,
                                              color: textDark.withValues(
                                                alpha: 0.3,
                                              ),
                                            ),
                                            const SizedBox(height: 16),
                                            Text(
                                              'Unable to load bill breakdown',
                                              style: TextStyle(
                                                color: textDark.withValues(
                                                  alpha: 0.6,
                                                ),
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    }

                                    return RepaintBoundary(
                                      child: _buildTicketContent(
                                        context,
                                        snapshot.data!,
                                        kwh,
                                        tierTitle: tierTitle,
                                        tierRate: tierRate,
                                        tierMax: tierMax,
                                        tierEnergy: tierEnergy,
                                        tierPercentage: tierPercentage,
                                        tierRemainingText: tierRemainingText,
                                        fixedCharge: fixedCharge,
                                        sourceFile: sourceFile,
                                      ),
                                    );
                                  },
                                ),
                              ),
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
        );
      },
    );
  }

  Widget _buildTicketContent(
    BuildContext context,
    Map<String, dynamic> data,
    double kwh, {
    required String tierTitle,
    required String tierRate,
    required double tierMax,
    required double tierEnergy,
    required double tierPercentage,
    required String tierRemainingText,
    required double fixedCharge,
    required String sourceFile,
  }) {
    final items = _buildBreakdownItems(data);
    final double total =
        (data['total_energy_amount'] as num?)?.toDouble() ??
        items.fold(0.0, (sum, item) => sum + item.amount);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Column(
            children: [
              Text(
                'TOTAL BILL',
                style: TextStyle(
                  color: textDark.withValues(alpha: 0.55),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '₱${total.toStringAsFixed(2)}',
                style: TextStyle(
                  color: brandOrangeText,
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Based on ${kwh.toStringAsFixed(2)} kWh',
                style: TextStyle(
                  color: textDark.withValues(alpha: 0.55),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _TicketDashedTearLine(color: textDark.withValues(alpha: 0.15)),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              tierTitle,
              style: TextStyle(
                color: textDark,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
            Text(
              tierRate,
              style: TextStyle(
                color: textDark.withValues(alpha: 0.6),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: LinearProgressIndicator(
            value: tierPercentage,
            backgroundColor: textDark.withValues(alpha: 0.08),
            valueColor: AlwaysStoppedAnimation<Color>(brandOrangeText),
            minHeight: 7,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${tierEnergy.toStringAsFixed(2)} / ${tierMax.toStringAsFixed(0)} kWh',
              style: TextStyle(
                color: textDark.withValues(alpha: 0.6),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '${(tierPercentage * 100).toStringAsFixed(1)}%',
              style: TextStyle(
                color: textDark.withValues(alpha: 0.6),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          tierRemainingText,
          style: TextStyle(
            color: textDark.withValues(alpha: 0.55),
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 20),
        _TicketDashedTearLine(color: textDark.withValues(alpha: 0.15)),
        const SizedBox(height: 20),
        Flexible(
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'BILL BREAKDOWN',
                  style: TextStyle(
                    color: brandOrangeText,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 16),
                for (final item in items) ...[
                  _buildLineItemRow(item),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        _TicketDashedTearLine(color: textDark.withValues(alpha: 0.15)),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'TOTAL',
              style: TextStyle(
                color: textDark,
                fontSize: 16,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
              ),
            ),
            Text(
              '₱${total.toStringAsFixed(2)}',
              style: TextStyle(
                color: brandOrangeText,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        if (fixedCharge > 0) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Fixed Charge',
                style: TextStyle(
                  color: textDark.withValues(alpha: 0.6),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '₱${fixedCharge.toStringAsFixed(4)}',
                style: TextStyle(
                  color: textDark.withValues(alpha: 0.75),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
        if (sourceFile.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.description_outlined,
                size: 13,
                color: textDark.withValues(alpha: 0.4),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Source: $sourceFile',
                  style: TextStyle(
                    color: textDark.withValues(alpha: 0.45),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 28),
        _TicketDashedTearLine(color: textDark.withValues(alpha: 0.15)),
        const SizedBox(height: 16),
        Center(
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Text(
              'Done',
              style: TextStyle(
                color: brandOrangeText,
                fontSize: 14,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                decoration: TextDecoration.underline,
                decorationColor: brandOrangeText,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLineItemRow(_BillLineItem item) {
    if (item.amount == 0 && item.subItems.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                item.label,
                style: TextStyle(
                  color: textDark,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              '₱${item.amount.toStringAsFixed(2)}',
              style: TextStyle(
                color: textDark,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        for (final subItem in item.subItems)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    '• ${subItem.label}',
                    style: TextStyle(
                      color: textDark.withValues(alpha: 0.5),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Text(
                  '₱${subItem.amount.toStringAsFixed(2)}',
                  style: TextStyle(
                    color: textDark.withValues(alpha: 0.6),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  void _showRefreshInfo(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.refresh_rounded, color: brandOrangeText, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Refresh forecast',
                  style: TextStyle(
                    color: textDark,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Pull down on this screen anytime to recalculate your forecast based on current consumption trajectory.',
              style: TextStyle(
                color: textDark.withValues(alpha: 0.7),
                fontSize: 13,
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _heroStat(String label, String value, {bool alignEnd = false}) {
    const shadow = [
      Shadow(color: Color(0x40000000), blurRadius: 6, offset: Offset(0, 1)),
    ];
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            shadows: shadow,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 19,
            fontWeight: FontWeight.w700,
            shadows: shadow,
          ),
        ),
      ],
    );
  }

  /// Hero: headline in the sky, the house as the focal object, and the month
  /// laid along the ground as a track from "used so far" to "projected".
  Widget _buildBillingHero({
    required BuildContext context,
    required bool isCurrentMode,
    required double predictedDayTotal,
    required double cumulativeEnergy,
    required double estimatedMonthEnd,
    required double estimatedCostLive,
    required Map<String, double> rates,
  }) {
    final double heroKwh = isCurrentMode ? cumulativeEnergy : estimatedMonthEnd;

    return FutureBuilder<Map<String, dynamic>>(
      future: !isCurrentMode && estimatedMonthEnd > 0
          ? _fetchBillBreakdownCached(estimatedMonthEnd)
          : null,
      builder: (context, billSnapshot) {
        final double billPeso = isCurrentMode
            ? estimatedCostLive
            : ((billSnapshot.data?['total_energy_amount'] as num?)
                      ?.toDouble() ??
                  _calculateBill(estimatedMonthEnd, rates));

        final String headline = isCurrentMode
            ? "Here's your usage so far"
            : "Your month is shaping up";

        return Stack(
          children: [
            Image.asset(
              'assets/billingbg.png',
              width: double.infinity,
              fit: BoxFit.fitWidth,
            ),
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _showRefreshInfo(context),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    _lastRefreshedAt != null
                                        ? 'Updated ${_formatLastRefreshed(_lastRefreshedAt!)}'
                                        : 'About this forecast',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: brandOrangeText.withValues(
                                        alpha: 0.8,
                                      ),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Icon(
                                  Icons.info_outline_rounded,
                                  size: 15,
                                  color: brandOrangeText.withValues(alpha: 0.6),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildModeToggle(),
                      ],
                    ),
                    const SizedBox(height: 24),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: Text(
                        headline,
                        key: ValueKey(headline),
                        style: TextStyle(
                          color: brandOrangeText,
                          fontSize: 28,
                          height: 1.15,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Expecting ${predictedDayTotal.toStringAsFixed(2)} kWh by end of day',
                      style: TextStyle(
                        color: brandOrangeText.withValues(alpha: 0.85),
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 24,
              right: 24,
              bottom: 10,
              child: _ModeSlide(
                modeKey: _mode,
                direction: _slideDir,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _heroStat(
                      isCurrentMode ? "Today's usage" : 'Projected this month',
                      '${heroKwh.toStringAsFixed(2)} kWh',
                    ),
                    _heroStat(
                      'Estimated bill',
                      '₱${billPeso.toStringAsFixed(2)}',
                      alignEnd: true,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildModeToggle() {
    final bool isEom = _mode == _BillMode.endOfMonth;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          height: 34,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.65),
              width: 1,
            ),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  alignment: isEom
                      ? Alignment.centerLeft
                      : Alignment.centerRight,
                  child: FractionallySizedBox(
                    widthFactor: 0.5,
                    heightFactor: 1.0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.90),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: brandOrangeText.withValues(alpha: 0.12),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildModeSegment('End of Month', _BillMode.endOfMonth),
                  _buildModeSegment('Current', _BillMode.current),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModeSegment(String label, _BillMode mode) {
    final bool selected = _mode == mode;

    return GestureDetector(
      onTap: () {
        if (_mode != mode) {
          setState(() {
            _slideDir = mode == _BillMode.current ? 1 : -1;
            _mode = mode;
          });
        }
      },
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 80,
        child: Center(
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              color: selected
                  ? brandOrangeText
                  : brandOrangeText.withValues(alpha: 0.80),
              fontSize: 10,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              letterSpacing: 0.1,
            ),
            child: Text(label, maxLines: 1, overflow: TextOverflow.visible),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: creamBg,
      body: StreamBuilder<DatabaseEvent>(
        stream: _dbRef.onValue,
        builder: (context, snapshot) {
          double estimatedMonthEnd = 0.0;
          double predictedDayTotal = 0.0;
          double cumulativeEnergy = 0.0;
          double todayKwh = 0.0;
          double estimatedCostLive = 0.0;

          Map<String, double> rates = Map.of(_fallbackRates);
          String effectivePeriod = '';
          double fixedCharge = 0.0;
          String sourceFile = '';

          if (snapshot.hasData && snapshot.data?.snapshot.value != null) {
            final data = snapshot.data!.snapshot.value as Map<dynamic, dynamic>;

            final forecastData = data['forecast'] as Map<dynamic, dynamic>?;
            if (forecastData != null) {
              estimatedMonthEnd = (forecastData['projected_eom_kWh'] ?? 0)
                  .toDouble();
              predictedDayTotal = (forecastData['predicted_day_total_kWh'] ?? 0)
                  .toDouble();
            }

            final liveReading = data['live_reading'] as Map<dynamic, dynamic>?;
            if (liveReading != null) {
              cumulativeEnergy =
                  (liveReading['cumul_kWh'] ?? liveReading['cumul_kwh'] ?? 0)
                      .toDouble();
              estimatedCostLive = (liveReading['estimated_cost'] ?? 0)
                  .toDouble();
              todayKwh = cumulativeEnergy;
            }

            rates = _parseRates(data['meralco_rates']);
            effectivePeriod = _parseEffectivePeriod(data['meralco_rates']);
            fixedCharge = _parseFixedCharge(data['meralco_rates']);
            sourceFile = _parseSourceFile(data['meralco_rates']);
          }

          final bool isCurrentMode = _mode == _BillMode.current;

          final double tierCardEnergy = isCurrentMode
              ? cumulativeEnergy
              : estimatedMonthEnd;

          final _TierInfo liveTier = _tierInfoFor(tierCardEnergy, rates);

          final String currentTierTitle = liveTier.title;
          final String currentTierRate = liveTier.rate;
          final double currentTierMax = liveTier.max;
          final String remainingText = liveTier.remainingText;
          final double percentage = liveTier.percentage;

          Widget tierCard(
            double energy,
            _TierInfo t, {
            Color? color,
            Color? ringColor,
          }) {
            return ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Container(
                width: double.infinity,
                color: color ?? primaryOrange,
                child: CustomPaint(
                  painter: ringColor == null
                      ? const CardCirclePainter()
                      : CardCirclePainter(ringColor: ringColor),
                  isComplex: true,
                  willChange: false,
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              t.title,
                              style: TextStyle(
                                color: tierTextColor,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                            Text(
                              t.rate,
                              style: TextStyle(
                                color: tierTextColor.withValues(alpha: 0.95),
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
                              text: TextSpan(
                                style: TextStyle(color: tierTextColor),
                                children: [
                                  TextSpan(
                                    text: '${energy.toStringAsFixed(2)} ',
                                    style: const TextStyle(
                                      fontSize: 26,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  TextSpan(
                                    text: '/ ${t.max.toStringAsFixed(0)}',
                                    style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '${(t.percentage * 100).toStringAsFixed(1)}%',
                              style: TextStyle(
                                color: tierTextColor,
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
                            color: tierTextColor.withValues(alpha: 0.75),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 16),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: LinearProgressIndicator(
                            value: t.percentage,
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.4,
                            ),
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                            minHeight: 7,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              color: tierTextColor,
                              size: 15,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                t.remainingText,
                                style: TextStyle(
                                  color: tierTextColor.withValues(alpha: 0.95),
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
            );
          }

          return CustomMaterialIndicator(
            onRefresh: _handleRefresh,
            backgroundColor: Colors.white,
            indicatorBuilder: (context, controller) {
              return Padding(
                padding: const EdgeInsets.all(6.0),
                child: Lottie.asset(
                  'assets/spark loading.json',
                  width: 30,
                  height: 30,
                  fit: BoxFit.contain,
                ),
              );
            },
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: TopBounceBottomClampPhysics(),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildBillingHero(
                    context: context,
                    isCurrentMode: isCurrentMode,
                    predictedDayTotal: predictedDayTotal,
                    cumulativeEnergy: cumulativeEnergy,
                    estimatedMonthEnd: estimatedMonthEnd,
                    estimatedCostLive: estimatedCostLive,
                    rates: rates,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 20),
                        Text(
                          'TIER',
                          style: TextStyle(
                            color: brandOrangeText,
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _TierCardPager(
                          isCurrent: isCurrentMode,
                          onSwipe: (toCurrent) {
                            final target = toCurrent
                                ? _BillMode.current
                                : _BillMode.endOfMonth;
                            if (_mode != target) {
                              setState(() {
                                _slideDir = toCurrent ? 1 : -1;
                                _mode = target;
                              });
                            }
                          },
                          eomCard: tierCard(
                            estimatedMonthEnd,
                            _tierInfoFor(estimatedMonthEnd, rates),
                            color: const Color(0xFFFCC089),
                            ringColor: const Color(0xFFF59A48),
                          ),
                          currentCard: tierCard(
                            cumulativeEnergy,
                            _tierInfoFor(cumulativeEnergy, rates),
                          ),
                        ),
                        const SizedBox(height: 14),

                        // View Bill Breakdown Button
                        _PromoBanner(
                          title: 'View bill breakdown',
                          subtitle:
                              'See detailed itemized charges and breakdown!',
                          art: _PromoArt.receipt,
                          gradient: const [
                            Color(0xFFFFDCD2),
                            Color(0xFFF7A793),
                          ],
                          swoosh: const Color(0xFFFFFFFF),
                          textColor: const Color(0xFF4A2018),
                          onTap: () => _showBillBreakdown(
                            context,
                            kwh: isCurrentMode ? todayKwh : estimatedMonthEnd,
                            tierTitle: currentTierTitle,
                            tierRate: currentTierRate,
                            tierMax: currentTierMax,
                            tierEnergy: tierCardEnergy,
                            tierPercentage: percentage,
                            tierRemainingText: remainingText,
                            fixedCharge: fixedCharge,
                            sourceFile: sourceFile,
                          ),
                        ),
                        const SizedBox(height: 12),

                        // Bill Calculator Button
                        _PromoBanner(
                          title: 'Bill calculator',
                          subtitle: 'Enter your own usage and see the bill.',
                          art: _PromoArt.calculator,
                          gradient: const [
                            Color(0xFFFFF0D6),
                            Color(0xFFFFC27A),
                          ],
                          swoosh: const Color(0xFFFFFFFF),
                          textColor: const Color(0xFF5A3410),
                          onTap: () => _showBillCalculator(
                            context,
                            rates,
                            fixedCharge: fixedCharge,
                            sourceFile: sourceFile,
                          ),
                        ),

                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24.0),
                          child: Divider(
                            color: textDark.withValues(alpha: 0.08),
                            thickness: 1,
                            height: 1,
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              'RATE BRACKETS',
                              style: TextStyle(
                                color: textDark,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                            if (effectivePeriod.isNotEmpty)
                              Text(
                                'Effective $effectivePeriod',
                                style: TextStyle(
                                  color: textDark.withValues(alpha: 0.45),
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildStackedRateCards(
                    rates: rates,
                    cumulativeEnergy: tierCardEnergy,
                    projected: !isCurrentMode,
                  ),
                  const SizedBox(height: 120),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Tier rate cards ──────────────────────────────────────────────────
  static const List<String> _tierTitles = [
    'TIER 1',
    'TIER 2',
    'TIER 3',
    'TIER 4',
  ];
  static const List<String> _tierBands = [
    'First 200 kWh',
    '201 - 300 kWh',
    '301 - 400 kWh',
    'Over 400 kWh',
  ];
  static const List<String> _tierRateKeys = [
    '0-200',
    '201-300',
    '301-400',
    'over-400',
  ];

  int _activeTierIndex(double kwh) {
    if (kwh <= 200) return 0;
    if (kwh <= 300) return 1;
    if (kwh <= 400) return 2;
    return 3;
  }

  double _tierRate(Map<String, double> rates, int i) =>
      rates[_tierRateKeys[i]] ?? _fallbackRates[_tierRateKeys[i]] ?? 0.0;

  String _tierCaption(double kwh, Map<String, double> rates, bool projected) {
    final i = _activeTierIndex(kwh);
    final rate = _tierRate(rates, i).toStringAsFixed(2);
    final used = kwh.toStringAsFixed(kwh >= 100 ? 0 : 1);
    final who = projected
        ? "You're projected to use $used kWh by month end."
        : "You've used $used kWh so far.";
    final String scope;
    if (i == 0) {
      scope = 'Each of your first 200 kWh costs ₱$rate.';
    } else if (i == 3) {
      scope = 'Each kWh over 400 costs ₱$rate.';
    } else {
      scope =
          'Each kWh from ${i * 100 + 101} to ${i * 100 + 200} costs ₱$rate.';
    }
    return '$who $scope';
  }

  void _openTierCardsHero(
    BuildContext context,
    double cumulativeEnergy,
    Map<String, double> rates,
    bool projected,
  ) {
    final int activeIndex = _activeTierIndex(cumulativeEnergy);
    final int initialPage = activeIndex;
    final ValueNotifier<int> currentPage = ValueNotifier<int>(initialPage);
    final String caption = _tierCaption(cumulativeEnergy, rates, projected);

    final double screenWidth = MediaQuery.of(context).size.width;
    final double viewportFraction = (screenWidth - 20) / screenWidth;

    double dragDy = 0;
    final PageController pageController = PageController(
      initialPage: initialPage,
      viewportFraction: viewportFraction,
    );

    Navigator.of(context)
        .push(
          PageRouteBuilder(
            opaque: false,
            barrierDismissible: true,
            barrierColor: Colors.transparent,
            transitionDuration: const Duration(milliseconds: 350),
            reverseTransitionDuration: const Duration(milliseconds: 300),
            pageBuilder: (context, animation, secondaryAnimation) {
              return Scaffold(
                backgroundColor: Colors.transparent,
                body: Stack(
                  children: [
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => Navigator.of(context).pop(),
                        child: AnimatedBuilder(
                          animation: animation,
                          builder: (context, _) {
                            final t = Curves.easeOut.transform(animation.value);
                            return BackdropFilter(
                              filter: ImageFilter.blur(
                                sigmaX: 14 * t,
                                sigmaY: 14 * t,
                              ),
                              child: Container(
                                color: Colors.black.withValues(alpha: 0.40 * t),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    Align(
                      alignment: const Alignment(0, 0.5),
                      child: SafeArea(
                        child: FadeTransition(
                          opacity: CurvedAnimation(
                            parent: animation,
                            curve: const Interval(
                              0.3,
                              1.0,
                              curve: Curves.easeOut,
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(22, 0, 4, 6),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.only(top: 12),
                                        child: Text(
                                          caption,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                            height: 1.35,
                                          ),
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Close',
                                      onPressed: () =>
                                          Navigator.of(context).pop(),
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              GestureDetector(
                                behavior: HitTestBehavior.translucent,
                                onVerticalDragUpdate: (d) {
                                  dragDy += d.delta.dy;
                                },
                                onVerticalDragEnd: (d) {
                                  if (dragDy > 50 ||
                                      (d.primaryVelocity ?? 0) > 400) {
                                    Navigator.of(context).pop();
                                  }
                                  dragDy = 0;
                                },
                                child: SizedBox(
                                  height: (screenWidth - 36) / 1.586 + 40,
                                  child: PageView.builder(
                                    controller: pageController,
                                    physics: const BouncingScrollPhysics(),
                                    onPageChanged: (p) => currentPage.value = p,
                                    itemCount: _tierTitles.length,
                                    itemBuilder: (context, index) {
                                      Widget card = Container(
                                        height: (screenWidth - 36) / 1.586,
                                        width: double.infinity,
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            22,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withValues(
                                                alpha: 0.12,
                                              ),
                                              blurRadius: 20,
                                              spreadRadius: -4,
                                              offset: const Offset(0, 10),
                                            ),
                                          ],
                                        ),
                                        child: _buildRateCard(
                                          tierTitle: _tierTitles[index],
                                          isActive: index == activeIndex,
                                          index: index,
                                          rates: rates,
                                        ),
                                      );

                                      if (index == initialPage) {
                                        card = Hero(
                                          tag: 'tier_card_hero',
                                          child: Material(
                                            type: MaterialType.transparency,
                                            child: card,
                                          ),
                                        );
                                      }

                                      return AnimatedBuilder(
                                        animation: pageController,
                                        builder: (context, child) {
                                          double value = 1.0;
                                          if (pageController
                                              .position
                                              .haveDimensions) {
                                            value =
                                                pageController.page! - index;
                                            value = (1 - (value.abs() * 0.12))
                                                .clamp(0.85, 1.0);
                                          }
                                          return Center(
                                            child: Transform.scale(
                                              scale: value,
                                              child: child,
                                            ),
                                          );
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8.0,
                                          ),
                                          child: card,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                              ValueListenableBuilder<int>(
                                valueListenable: currentPage,
                                builder: (context, page, _) {
                                  return Semantics(
                                    label:
                                        'Tier ${page + 1} of ${_tierTitles.length}',
                                    child: ExcludeSemantics(
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          for (
                                            var i = 0;
                                            i < _tierTitles.length;
                                            i++
                                          )
                                            Container(
                                              margin:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 3,
                                                  ),
                                              width: i == page ? 20 : 8,
                                              height: 8,
                                              decoration: BoxDecoration(
                                                color: i == page
                                                    ? Colors.white
                                                    : Colors.white.withValues(
                                                        alpha: 0.45,
                                                      ),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                            ),
                                          const SizedBox(width: 10),
                                          Text(
                                            '${page + 1} / ${_tierTitles.length}',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
                  return child;
                },
          ),
        )
        .then((_) {
          pageController.dispose();
          currentPage.dispose();
        });
  }

  Widget _buildStackedRateCards({
    required Map<String, double> rates,
    required double cumulativeEnergy,
    required bool projected,
  }) {
    final frontIndex = _activeTierIndex(cumulativeEnergy);

    const double stackHeight = 107.0;
    const double maskTop = 88.0;

    return Padding(
      padding: const EdgeInsets.only(top: 24.0, left: 18.0, right: 18.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Same aspect ratio as the expanded card so the Hero flight scales
          // uniformly instead of stretching.
          final double cardHeight = constraints.maxWidth / 1.586;
          return SizedBox(
            height: stackHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // The original angled ghost card, repeated for the other three
                // tiers so the deck reads as four cards (back to front).
                // Solid tints (lighter toward the back) so each card reads as
                // its own layer; each also sits a little higher and tilts a
                // little more than the one in front.
                for (var k = _tierTitles.length - 1; k >= 1; k--)
                  Positioned(
                    top: const [0.0, 16.0, 6.0, -4.0][k],
                    left: 6.0 * k,
                    right: 6.0 * k,
                    child: ExcludeSemantics(
                      child: Transform.rotate(
                        angle: -const [0.0, 0.02, 0.035, 0.05][k],
                        alignment: Alignment.topRight,
                        child: Container(
                          height: cardHeight,
                          decoration: BoxDecoration(
                            color: const [
                              Colors.transparent,
                              Color(0xFFF59A4D),
                              Color(0xFFF8B07A),
                              Color(0xFFFAC8A0),
                            ][k],
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.14),
                                blurRadius: 12,
                                spreadRadius: -2,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 26,
                  left: 0,
                  right: 0,
                  child: Semantics(
                    button: true,
                    hint: 'Shows all four rate tiers',
                    child: GestureDetector(
                      onTap: () => _openTierCardsHero(
                        context,
                        cumulativeEnergy,
                        rates,
                        projected,
                      ),
                      child: Hero(
                        tag: 'tier_card_hero',
                        flightShuttleBuilder:
                            (
                              flightContext,
                              animation,
                              flightDirection,
                              fromHeroContext,
                              toHeroContext,
                            ) {
                              return Material(
                                type: MaterialType.transparency,
                                child: toHeroContext.widget,
                              );
                            },
                        child: Material(
                          type: MaterialType.transparency,
                          child: Container(
                            height: cardHeight,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(22),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.22),
                                  blurRadius: 28,
                                  spreadRadius: -4,
                                  offset: const Offset(0, 14),
                                ),
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.08),
                                  blurRadius: 8,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: _buildRateCard(
                              tierTitle: _tierTitles[frontIndex],
                              isActive: true,
                              index: frontIndex,
                              rates: rates,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: maskTop,
                  left: -18,
                  right: -18,
                  bottom: -500,
                  child: Container(
                    decoration: BoxDecoration(
                      color: creamBg,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(24),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 18,
                          spreadRadius: 2,
                          offset: const Offset(0, -6),
                        ),
                      ],
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

  Widget _buildRateCard({
    required String tierTitle,
    required bool isActive,
    required int index,
    required Map<String, double> rates,
  }) {
    final tier = index % _tierTitles.length;
    final rateValue = _tierRate(rates, tier);
    final rate = '₱ ${rateValue.toStringAsFixed(4)}';
    final subtext = _tierBands[tier];

    // Mid orange between the brand FA8B39 and the old dark D4620C: light
    // enough to feel on-brand, deep enough that white text still reads.
    final bgColor = isActive ? const Color(0xFFEF7A22) : Colors.white;
    final textColor = isActive ? Colors.white : const Color(0xFF2D3142);
    final subtitleColor = isActive ? Colors.white : const Color(0xFF5F6368);
    final shapeColor = isActive
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.black.withValues(alpha: 0.04);

    return Semantics(
      container: true,
      label:
          '$tierTitle, $subtext, ${rateValue.toStringAsFixed(2)} pesos per '
          'kWh${isActive ? ', your current tier' : ''}',
      selected: isActive,
      child: ExcludeSemantics(
        child: Container(
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(22),
            border: isActive
                ? null
                : Border.all(color: Colors.grey.shade200, width: 1.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              if (index % 4 == 0) ...[
                Positioned(
                  top: -30,
                  right: -20,
                  child: CircleAvatar(radius: 75, backgroundColor: shapeColor),
                ),
                Positioned(
                  bottom: -40,
                  left: -10,
                  child: CircleAvatar(radius: 50, backgroundColor: shapeColor),
                ),
              ] else if (index % 4 == 1) ...[
                Positioned(
                  top: 30,
                  right: -30,
                  child: Transform.rotate(
                    angle: 0.4,
                    child: Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        color: shapeColor,
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                  ),
                ),
              ] else if (index % 4 == 2) ...[
                Positioned(
                  top: -40,
                  left: -20,
                  child: CircleAvatar(radius: 80, backgroundColor: shapeColor),
                ),
                Positioned(
                  top: 10,
                  left: 60,
                  child: CircleAvatar(radius: 40, backgroundColor: shapeColor),
                ),
              ] else ...[
                Positioned(
                  bottom: -60,
                  right: 10,
                  child: CircleAvatar(radius: 90, backgroundColor: shapeColor),
                ),
                Positioned(
                  top: 20,
                  right: 20,
                  child: Icon(Icons.bolt_rounded, size: 90, color: shapeColor),
                ),
              ],
              Padding(
                padding: const EdgeInsets.all(22.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: isActive
                                ? Colors.white.withValues(alpha: 0.22)
                                : Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            tierTitle,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: textColor,
                              letterSpacing: 0.5,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        if (isActive)
                          const Icon(
                            Icons.check_circle_rounded,
                            color: Colors.white,
                            size: 26,
                          ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          subtext,
                          style: TextStyle(
                            fontSize: 14,
                            color: subtitleColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              rate,
                              style: TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.w900,
                                color: textColor,
                                height: 1.1,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4.0),
                              child: Text(
                                '/ kWh',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: subtitleColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BillLineItem {
  final String label;
  final double amount;
  final List<_BillLineItem> subItems;
  const _BillLineItem(this.label, this.amount, [this.subItems = const []]);
}

class CardCirclePainter extends CustomPainter {
  final Color ringColor;

  const CardCirclePainter({this.ringColor = const Color(0xFFFA8B39)});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = ringColor.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final center1 = Offset(size.width * 1.05, size.height * 1.15);
    for (double radius in [50, 85, 120, 155, 190]) {
      canvas.drawCircle(center1, radius, paint);
    }

    final center2 = Offset(size.width * -0.1, size.height * -0.2);
    for (double radius in [40, 70, 100, 130]) {
      canvas.drawCircle(center2, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CardCirclePainter oldDelegate) =>
      oldDelegate.ringColor != ringColor;
}

class _TicketDashedTearLine extends StatelessWidget {
  final Color color;
  static const double height = 1.5;
  static const double dashWidth = 6;
  static const double dashSpace = 4;

  const _TicketDashedTearLine({this.color = const Color(0xFFE2E8F0)});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: height,
      child: CustomPaint(
        painter: _DashedLinePainter(
          color: color,
          dashWidth: dashWidth,
          dashSpace: dashSpace,
        ),
      ),
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  final Color color;
  final double dashWidth;
  final double dashSpace;

  const _DashedLinePainter({
    required this.color,
    required this.dashWidth,
    required this.dashSpace,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final dashCount = (size.width / (dashWidth + dashSpace)).floor();
    if (dashCount <= 0) return;

    final totalDashSpan = dashCount * dashWidth;
    final remaining = size.width - totalDashSpan;
    final gap = dashCount > 1 ? remaining / (dashCount - 1) : 0.0;

    double x = 0;
    for (int i = 0; i < dashCount; i++) {
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, 0, dashWidth, size.height),
        const Radius.circular(1),
      );
      canvas.drawRRect(rrect, paint);
      x += dashWidth + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.dashWidth != dashWidth ||
      oldDelegate.dashSpace != dashSpace;
}

class _TicketReceiptClipper extends CustomClipper<Path> {
  final double notchRadius;
  final double notchPositionRatio;

  _TicketReceiptClipper({
    this.notchRadius = 14.0,
    this.notchPositionRatio = 0.25,
  });

  @override
  Path getClip(Size size) {
    final path = Path();
    const cornerRadius = 24.0;
    const zigWidth = 10.0;
    const zigHeight = 7.0;

    final notchY = size.height * notchPositionRatio;

    path.moveTo(0, cornerRadius);
    path.quadraticBezierTo(0, 0, cornerRadius, 0);
    path.lineTo(size.width - cornerRadius, 0);
    path.quadraticBezierTo(size.width, 0, size.width, cornerRadius);
    path.lineTo(size.width, notchY - notchRadius);
    path.arcToPoint(
      Offset(size.width, notchY + notchRadius),
      radius: Radius.circular(notchRadius),
      clockwise: false,
    );
    path.lineTo(size.width, size.height - zigHeight);

    double x = size.width;
    bool atPeak = true;
    while (x > 0) {
      final nextX = (x - zigWidth).clamp(0.0, size.width);
      final y = atPeak ? size.height : size.height - zigHeight;
      path.lineTo(nextX, y);
      atPeak = !atPeak;
      x = nextX;
    }

    path.lineTo(0, notchY + notchRadius);
    path.arcToPoint(
      Offset(0, notchY - notchRadius),
      radius: Radius.circular(notchRadius),
      clockwise: false,
    );
    path.lineTo(0, cornerRadius);

    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant _TicketReceiptClipper oldClipper) =>
      oldClipper.notchRadius != notchRadius ||
      oldClipper.notchPositionRatio != notchPositionRatio;
}

class _TicketShadowPainter extends CustomPainter {
  final CustomClipper<Path> clipper;

  const _TicketShadowPainter({required this.clipper});

  @override
  void paint(Canvas canvas, Size size) {
    final path = clipper.getClip(size);

    canvas.save();
    canvas.translate(0, 6);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
    canvas.restore();

    canvas.save();
    canvas.translate(0, 3);
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFE25319).withValues(alpha: 0.12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Slides + fades its child out/in whenever [modeKey] changes, moving toward
/// [direction] (1 = new content from the right, -1 = from the left).
class _ModeSlide extends StatelessWidget {
  final Object modeKey;
  final int direction;
  static const double distance = 0.35;
  final Widget child;

  const _ModeSlide({
    required this.modeKey,
    required this.direction,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topLeft,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, animation) {
        final incoming = child.key == ValueKey(modeKey);
        final dx = (incoming ? direction : -direction) * distance;
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(dx, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: KeyedSubtree(key: ValueKey(modeKey), child: child),
    );
  }
}

/// Two tier cards side by side: the active one fills the width and the other
/// peeks in from the screen edge, so switching modes slides between real cards.
class _TierCardPager extends StatelessWidget {
  final bool isCurrent;
  final ValueChanged<bool> onSwipe;
  final Widget eomCard;
  final Widget currentCard;

  const _TierCardPager({
    required this.isCurrent,
    required this.onSwipe,
    required this.eomCard,
    required this.currentCard,
  });

  @override
  Widget build(BuildContext context) {
    const duration = Duration(milliseconds: 420);
    const curve = Curves.easeInOutCubic;
    const gap = 1.04; // card widths between centres (small gutter)

    Widget slot(Widget card, Offset offset, bool active) {
      return AnimatedSlide(
        offset: offset,
        duration: duration,
        curve: curve,
        child: AnimatedScale(
          scale: active ? 1.0 : 0.94,
          duration: duration,
          curve: curve,
          child: AnimatedOpacity(
            opacity: active ? 1.0 : 0.85,
            duration: duration,
            curve: curve,
            child: card,
          ),
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v < -200) {
          onSwipe(true);
        }
        if (v > 200) {
          onSwipe(false);
        }
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          slot(
            eomCard,
            isCurrent ? const Offset(-gap, 0) : Offset.zero,
            !isCurrent,
          ),
          slot(
            currentCard,
            isCurrent ? Offset.zero : const Offset(gap, 0),
            isCurrent,
          ),
        ],
      ),
    );
  }
}

enum _PromoArt { receipt, calculator }

/// Promo-style banner with layered, depth-shifted 3D art that moves with
/// the scroll position (parallax).
class _PromoBanner extends StatefulWidget {
  final String title;
  final String subtitle;
  final _PromoArt art;
  final List<Color> gradient;
  final Color swoosh;
  final Color textColor;
  final VoidCallback onTap;

  const _PromoBanner({
    required this.title,
    required this.subtitle,
    required this.art,
    required this.gradient,
    required this.swoosh,
    required this.textColor,
    required this.onTap,
  });

  @override
  State<_PromoBanner> createState() => _PromoBannerState();
}

class _PromoBannerState extends State<_PromoBanner> {
  ScrollPosition? _position;
  final ValueNotifier<double> _shift = ValueNotifier(0);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _position?.removeListener(_update);
    _position = Scrollable.maybeOf(context)?.position;
    _position?.addListener(_update);
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void dispose() {
    _position?.removeListener(_update);
    _shift.dispose();
    super.dispose();
  }

  // -1..1: where the banner sits relative to the viewport centre.
  void _update() {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    final screenH = MediaQuery.of(context).size.height;
    final cy = box.localToGlobal(Offset(0, box.size.height / 2)).dy;
    _shift.value = ((cy - screenH / 2) / (screenH / 2)).clamp(-1.0, 1.0);
  }

  Widget _layer(
    double depth,
    Widget child, {
    double? right,
    double? top,
    double? bottom,
  }) {
    return Positioned(
      right: right,
      top: top,
      bottom: bottom,
      child: ValueListenableBuilder<double>(
        valueListenable: _shift,
        builder: (_, v, c) => Transform.translate(
          offset: Offset(v * depth * 0.6, v * depth * 1.4),
          child: c,
        ),
        child: child,
      ),
    );
  }

  /// Fluent Emoji 3D image from assets/3d (MIT, github.com/microsoft/fluentui-emoji).
  Widget _art(String name, double size, {double angle = 0}) {
    return Transform.rotate(
      angle: angle,
      child: Image.asset(
        'assets/3d/${name}_3d.png',
        width: size,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isReceipt = widget.art == _PromoArt.receipt;
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: widget.gradient,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: widget.onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SizedBox(
              height: 96,
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  // back: swoosh circles (slowest)
                  _layer(
                    4,
                    Container(
                      width: 150,
                      height: 150,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.swoosh.withValues(alpha: 0.18),
                      ),
                    ),
                    right: -30,
                    top: -40,
                  ),
                  _layer(
                    6,
                    Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.swoosh.withValues(alpha: 0.12),
                      ),
                    ),
                    right: 40,
                    bottom: -60,
                  ),
                  // mid: small items
                  if (isReceipt) ...[
                    _layer(
                      10,
                      _art('coin', 24, angle: -0.3),
                      right: 96,
                      top: 8,
                    ),
                    _layer(
                      12,
                      _art('coin', 18, angle: 0.5),
                      right: 80,
                      bottom: 6,
                    ),
                  ] else ...[
                    _layer(
                      10,
                      _art('high_voltage', 24, angle: -0.3),
                      right: 96,
                      top: 8,
                    ),
                    _layer(
                      12,
                      _art('high_voltage', 20, angle: 0.4),
                      right: 80,
                      bottom: 6,
                    ),
                  ],
                  // front: hero 3D object (fastest)
                  _layer(
                    18,
                    _art(isReceipt ? 'receipt' : 'abacus', 68, angle: 0.08),
                    right: 26,
                    top: 12,
                  ),
                  _layer(
                    24,
                    isReceipt
                        ? _art('coin', 32, angle: 0.25)
                        : _art('high_voltage', 32, angle: 0.25),
                    right: 8,
                    bottom: 6,
                  ),
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 20, right: 130),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: widget.textColor,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: widget.textColor.withValues(alpha: 0.75),
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
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
      ),
    );
  }
}
