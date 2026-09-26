import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show Simulation;
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
    String selectedMonth = 'August';
    final Map<String, String> monthPeriods = {
      'August': '08-2026_rate_schedule.pdf',
      'September': '09-2026_rate_schedule.pdf',
    };
    final List<String> availableMonths = monthPeriods.keys.toList();
    // ------------------------

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (innerContext, setSheetState) {
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
                if (kwhResult == null) throw Exception('Missing kwh in response');
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

            Widget modeChip(String label, _CalcInput value) {
              final selected = inputType == value;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setSheetState(() {
                    inputType = value;
                    error = null;
                    pesoResultKwh = null;
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    decoration: BoxDecoration(
                      color: selected ? tierCardBorder : Colors.transparent,
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Center(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: selected
                              ? Colors.white
                              : textDark.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }

            final bool isPesoMode = inputType == _CalcInput.pesos;

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(innerContext).viewInsets.bottom,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: creamBg,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(28),
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(24, 14, 24, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 44,
                        height: 4,
                        decoration: BoxDecoration(
                          color: textDark.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'BILL CALCULATOR',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                        color: textDark.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      isPesoMode
                          ? 'What is your electricity budget?'
                          : 'How many kWh will you use?',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                        color: textDark,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(
                          color: tierCardBorder.withValues(alpha: 0.3),
                        ),
                        borderRadius: BorderRadius.circular(17),
                      ),
                      child: Row(
                        children: [
                          modeChip('Usage (kWh)', _CalcInput.kwh),
                          modeChip('Budget (₱)', _CalcInput.pesos),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        color: brandOrangeText,
                      ),
                      decoration: InputDecoration(
                        prefixText: isPesoMode ? '₱ ' : null,
                        prefixStyle: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          color: brandOrangeText,
                        ),
                        suffixText: isPesoMode ? null : 'kWh',
                        suffixStyle: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: textDark.withValues(alpha: 0.45),
                        ),
                        hintText: isPesoMode ? '2500' : '250',
                        hintStyle: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          color: textDark.withValues(alpha: 0.18),
                        ),
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 16,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: tierCardBorder),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(
                            color: tierCardBorder.withValues(alpha: 0.4),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(
                            color: tierCardBorder,
                            width: 1.6,
                          ),
                        ),
                      ),
                      onChanged: (_) {
                        if (pesoResultKwh != null) {
                          setSheetState(() => pesoResultKwh = null);
                        }
                      },
                      onSubmitted: (_) => compute(),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            size: 15,
                            color: Color(0xFFB3261E),
                          ),
                          const SizedBox(width: 6),
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
                    ],

                    if (isPesoMode && pesoResultKwh != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: tierCardBorder.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'EQUIVALENT USAGE',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.6,
                                color: textDark.withValues(alpha: 0.55),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${pesoResultKwh!.toStringAsFixed(2)} kWh',
                              style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w900,
                                color: brandOrangeText,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'for ₱${pesoResultAmount!.toStringAsFixed(2)} ($selectedMonth rate)',
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

                    // --- NEW MONTH SELECTOR UI START ---
                    const SizedBox(height: 18),
                    Text(
                      'RATE MONTH',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                        color: textDark.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: tierCardBorder.withValues(alpha: 0.4),
                        ),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: selectedMonth,
                          isExpanded: true,
                          icon: Icon(
                            Icons.calendar_month_rounded,
                            color: brandOrangeText,
                            size: 20,
                          ),
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
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
                    // --- NEW MONTH SELECTOR UI END ---

                    const SizedBox(height: 16),
                    Text(
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
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 52,
                      child: ElevatedButton(
                        onPressed: compute,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: tierCardBorder,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: const Text(
                          'Compute',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.3,
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
      },
    );
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
                              child: CustomPaint(
                                isComplex: true,
                                willChange: false,
                                painter: _TicketShadowPainter(
                                  clipper: _ticketClipper,
                                ),
                              ),
                            ),
                            ClipPath(
                              clipper: _ticketClipper,
                              child: Container(
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.92),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.5),
                                    width: 1.5,
                                  ),
                                ),
                                padding: const EdgeInsets.fromLTRB(
                                  28,
                                  54,
                                  28,
                                  40,
                                ),
                                child: FutureBuilder<Map<String, dynamic>>(
                                  future: calcFuture ?? _fetchBillBreakdownCached(kwh),
                                  builder: (context, snapshot) {
                                    if (snapshot.connectionState !=
                                        ConnectionState.done) {
                                      return const Padding(
                                        padding: EdgeInsets.symmetric(
                                          vertical: 90,
                                        ),
                                        child: Center(
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.5,
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

                                    return _buildTicketContent(
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
    if (item.amount == 0 && item.subItems.isEmpty)
      return const SizedBox.shrink();

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
          setState(() => _mode = mode);
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
          final double heroKwh = isCurrentMode ? todayKwh : estimatedMonthEnd;
          final String heroKwhLabel = isCurrentMode
              ? "TODAY'S USAGE"
              : 'PROJECTED END OF MONTH';
          final String heroBillLabel = isCurrentMode
              ? 'EST. TOTAL BILL'
              : 'ESTIMATED BILL';

          final double tierCardEnergy = isCurrentMode
              ? cumulativeEnergy
              : estimatedMonthEnd;

          final _TierInfo liveTier = _tierInfoFor(tierCardEnergy, rates);

          final String currentTierTitle = liveTier.title;
          final String currentTierRate = liveTier.rate;
          final double currentTierMax = liveTier.max;
          final String remainingText = liveTier.remainingText;
          final double percentage = liveTier.percentage;

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
                  Stack(
                    children: [
                      Image.asset(
                        'assets/billingbg.png',
                        width: double.infinity,
                        fit: BoxFit.fitWidth,
                      ),
                      SafeArea(
                        bottom: false,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24.0,
                            vertical: 20.0,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 5),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Flexible(
                                              child: Text(
                                                'END OF DAY CONSUMPTION',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: brandOrangeText
                                                      .withValues(alpha: 0.85),
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                  letterSpacing: 0.4,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            GestureDetector(
                                              onTap: () {
                                                showModalBottomSheet(
                                                  context: context,
                                                  backgroundColor: Colors.white,
                                                  shape: const RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.vertical(
                                                          top: Radius.circular(
                                                            20,
                                                          ),
                                                        ),
                                                  ),
                                                  builder: (context) => Padding(
                                                    padding:
                                                        const EdgeInsets.all(
                                                          24.0,
                                                        ),
                                                    child: Column(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Row(
                                                          children: [
                                                            Icon(
                                                              Icons
                                                                  .refresh_rounded,
                                                              color:
                                                                  brandOrangeText,
                                                              size: 18,
                                                            ),
                                                            const SizedBox(
                                                              width: 8,
                                                            ),
                                                            Text(
                                                              'Refresh forecast',
                                                              style: TextStyle(
                                                                color: textDark,
                                                                fontSize: 16,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w800,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                        const SizedBox(
                                                          height: 10,
                                                        ),
                                                        Text(
                                                          'Pull down on this screen anytime to recalculate your forecast based on current consumption trajectory.',
                                                          style: TextStyle(
                                                            color: textDark
                                                                .withValues(
                                                                  alpha: 0.7,
                                                                ),
                                                            fontSize: 13,
                                                            fontWeight:
                                                                FontWeight.w500,
                                                            height: 1.4,
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          height: 12,
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                );
                                              },
                                              child: Icon(
                                                Icons.info_outline_rounded,
                                                size: 14,
                                                color: brandOrangeText
                                                    .withValues(alpha: 0.5),
                                              ),
                                            ),
                                          ],
                                        ),
                                        // Last Refresh Timestamp Label
                                        if (_lastRefreshedAt != null) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            'Last refreshed: ${_formatLastRefreshed(_lastRefreshedAt!)}',
                                            style: TextStyle(
                                              color: brandOrangeText.withValues(
                                                alpha: 0.65,
                                              ),
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  _buildModeToggle(),
                                ],
                              ),
                              Text(
                                '${predictedDayTotal.toStringAsFixed(2)} kWh',
                                style: TextStyle(
                                  color: brandOrangeText,
                                  fontSize: 44,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 10.0,
                        left: 24.0,
                        right: 24.0,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.trending_up_rounded,
                                      color: Colors.greenAccent,
                                      size: 15,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      heroKwhLabel,
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.95,
                                        ),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${heroKwh.toStringAsFixed(2)} kWh',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.payments_rounded,
                                      color: Colors.greenAccent,
                                      size: 15,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      heroBillLabel,
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.95,
                                        ),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                if (isCurrentMode)
                                  Text(
                                    '₱${estimatedCostLive.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 19,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  )
                                else
                                  FutureBuilder<Map<String, dynamic>>(
                                    future: estimatedMonthEnd > 0
                                        ? _fetchBillBreakdownCached(
                                            estimatedMonthEnd,
                                          )
                                        : null,
                                    builder: (context, billSnapshot) {
                                      final totalEnergyAmount =
                                          (billSnapshot
                                                      .data?['total_energy_amount']
                                                  as num?)
                                              ?.toDouble();
                                      final double estimatedBillPeso =
                                          totalEnergyAmount ??
                                          _calculateBill(
                                            estimatedMonthEnd,
                                            rates,
                                          );
                                      return Text(
                                        '₱${estimatedBillPeso.toStringAsFixed(2)}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 19,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      );
                                    },
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
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
                        ClipRRect(
                          borderRadius: BorderRadius.circular(28),
                          child: Container(
                            width: double.infinity,
                            color: primaryOrange,
                            child: CustomPaint(
                              painter: CardCirclePainter(),
                              isComplex: true,
                              willChange: false,
                              child: Padding(
                                padding: const EdgeInsets.all(22),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          currentTierTitle,
                                          style: TextStyle(
                                            color: tierTextColor,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                        Text(
                                          currentTierRate,
                                          style: TextStyle(
                                            color: tierTextColor.withValues(
                                              alpha: 0.95,
                                            ),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 20),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.baseline,
                                      textBaseline: TextBaseline.alphabetic,
                                      children: [
                                        RichText(
                                          text: TextSpan(
                                            style: TextStyle(
                                              color: tierTextColor,
                                            ),
                                            children: [
                                              TextSpan(
                                                text:
                                                    '${tierCardEnergy.toStringAsFixed(2)} ',
                                                style: const TextStyle(
                                                  fontSize: 26,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                              TextSpan(
                                                text:
                                                    '/ ${currentTierMax.toStringAsFixed(0)}',
                                                style: const TextStyle(
                                                  fontSize: 20,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Text(
                                          '${(percentage * 100).toStringAsFixed(1)}%',
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
                                        color: tierTextColor.withValues(
                                          alpha: 0.75,
                                        ),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: LinearProgressIndicator(
                                        value: percentage,
                                        backgroundColor: Colors.white
                                            .withValues(alpha: 0.4),
                                        valueColor:
                                            const AlwaysStoppedAnimation<Color>(
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
                                            remainingText,
                                            style: TextStyle(
                                              color: tierTextColor.withValues(
                                                alpha: 0.95,
                                              ),
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
                        ),
                        const SizedBox(height: 14),

                        // View Bill Breakdown Button
                        InkWell(
                          borderRadius: BorderRadius.circular(20),
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
                          child: Container(
                            width: double.infinity,
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: const Color(0xFFFAC3B3),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Stack(
                              children: [
                                Positioned(
                                  right: -10,
                                  bottom: -20,
                                  child: Text(
                                    '₱',
                                    style: TextStyle(
                                      fontSize: 110,
                                      fontWeight: FontWeight.w900,
                                      color: const Color(
                                        0xFFE27B66,
                                      ).withValues(alpha: 0.18),
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20.0,
                                    vertical: 18.0,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              'View bill breakdown',
                                              style: TextStyle(
                                                color: Color(0xFF2B2C36),
                                                fontSize: 16,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: -0.2,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              'See detailed itemized charges and breakdown!',
                                              style: TextStyle(
                                                color: const Color(
                                                  0xFF2B2C36,
                                                ).withValues(alpha: 0.65),
                                                fontSize: 12,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Stack(
                                        alignment: Alignment.center,
                                        clipBehavior: Clip.none,
                                        children: [
                                          Container(
                                            width: 48,
                                            height: 48,
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFF79E87),
                                              shape: BoxShape.circle,
                                              boxShadow: [
                                                BoxShadow(
                                                  color: const Color(
                                                    0xFFD36852,
                                                  ).withValues(alpha: 0.35),
                                                  blurRadius: 10,
                                                  offset: const Offset(0, 4),
                                                ),
                                              ],
                                            ),
                                            child: const Icon(
                                              Icons.receipt_long_rounded,
                                              color: Colors.white,
                                              size: 24,
                                            ),
                                          ),
                                          Positioned(
                                            top: -6,
                                            right: -6,
                                            child: Container(
                                              padding: const EdgeInsets.all(4),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFFFFD56B),
                                                shape: BoxShape.circle,
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: Colors.black
                                                        .withValues(
                                                          alpha: 0.15,
                                                        ),
                                                    blurRadius: 4,
                                                    offset: const Offset(0, 2),
                                                  ),
                                                ],
                                              ),
                                              child: const Icon(
                                                Icons.payments_rounded,
                                                color: Color(0xFF8C5800),
                                                size: 14,
                                              ),
                                            ),
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
                        const SizedBox(height: 12),

                        // Bill Calculator Button
                        InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () => _showBillCalculator(
                            context,
                            rates,
                            fixedCharge: fixedCharge,
                            sourceFile: sourceFile,
                          ),
                          child: Container(
                            width: double.infinity,
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: const Color(0xFFFAEEDA),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: tierCardBorder.withValues(alpha: 0.18),
                                width: 1,
                              ),
                            ),
                            child: Stack(
                              children: [
                                Positioned(
                                  right: -12,
                                  bottom: -26,
                                  child: Icon(
                                    Icons.calculate_rounded,
                                    size: 120,
                                    color: tierCardBorder.withValues(
                                      alpha: 0.10,
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20.0,
                                    vertical: 18.0,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Bill calculator',
                                              style: TextStyle(
                                                color: tierTextColor,
                                                fontSize: 16,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: -0.2,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              'Enter your own usage and see the bill.',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: tierTextColor.withValues(
                                                  alpha: 0.65,
                                                ),
                                                fontSize: 12,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Container(
                                        width: 48,
                                        height: 48,
                                        decoration: BoxDecoration(
                                          color: tierCardBorder,
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(
                                              color: tierCardBorder.withValues(
                                                alpha: 0.32,
                                              ),
                                              blurRadius: 10,
                                              offset: const Offset(0, 4),
                                            ),
                                          ],
                                        ),
                                        child: const Icon(
                                          Icons.calculate_rounded,
                                          color: Colors.white,
                                          size: 24,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
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

  void _openTierCardsHero(
    BuildContext context,
    double cumulativeEnergy,
    Map<String, double> rates,
  ) {
    final tierData = [
      {'tierTitle': 'TIER 1', 'isActive': cumulativeEnergy <= 200},
      {
        'tierTitle': 'TIER 2',
        'isActive': cumulativeEnergy > 200 && cumulativeEnergy <= 300,
      },
      {
        'tierTitle': 'TIER 3',
        'isActive': cumulativeEnergy > 300 && cumulativeEnergy <= 400,
      },
      {'tierTitle': 'TIER 4', 'isActive': cumulativeEnergy > 400},
    ];

    final int activeIndex = tierData.indexWhere((t) => t['isActive'] as bool);
    final int initialPage = activeIndex == -1 ? 0 : activeIndex;

    final double screenWidth = MediaQuery.of(context).size.width;
    final double viewportFraction = (screenWidth - 20) / screenWidth;

    final PageController pageController = PageController(
      initialPage: initialPage,
      viewportFraction: viewportFraction,
    );

    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.black.withValues(alpha: 0.45),
        transitionDuration: const Duration(milliseconds: 350),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (context, animation, secondaryAnimation) {
          return Scaffold(
            backgroundColor: Colors.transparent,
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                decoration: BoxDecoration(
                  color: creamBg,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(28),
                  ),
                ),
                padding: const EdgeInsets.only(bottom: 32.0),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 12),
                      Center(
                        child: Container(
                          width: 44,
                          height: 4,
                          decoration: BoxDecoration(
                            color: textDark.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.close_rounded, size: 28),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                            Expanded(
                              child: Text(
                                'Rate Brackets',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: textDark,
                                ),
                              ),
                            ),
                            const SizedBox(width: 48),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),
                      SizedBox(
                        height: 200,
                        child: PageView.builder(
                          controller: pageController,
                          physics: const BouncingScrollPhysics(),
                          itemCount: tierData.length,
                          itemBuilder: (context, index) {
                            final tier = tierData[index];

                            Widget card = Container(
                              height: 160.0,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(22),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.12),
                                    blurRadius: 20,
                                    spreadRadius: -4,
                                    offset: const Offset(0, 10),
                                  ),
                                ],
                              ),
                              child: _buildRateCard(
                                tierTitle: tier['tierTitle'] as String,
                                isActive: tier['isActive'] as bool,
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
                                if (pageController.position.haveDimensions) {
                                  value = pageController.page! - index;
                                  value = (1 - (value.abs() * 0.12)).clamp(
                                    0.85,
                                    1.0,
                                  );
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
                    ],
                  ),
                ),
              ),
            ),
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  Widget _buildStackedRateCards({
    required Map<String, double> rates,
    required double cumulativeEnergy,
  }) {
    final tierData = [
      {'tierTitle': 'TIER 1', 'isActive': cumulativeEnergy <= 200},
      {
        'tierTitle': 'TIER 2',
        'isActive': cumulativeEnergy > 200 && cumulativeEnergy <= 300,
      },
      {
        'tierTitle': 'TIER 3',
        'isActive': cumulativeEnergy > 300 && cumulativeEnergy <= 400,
      },
      {'tierTitle': 'TIER 4', 'isActive': cumulativeEnergy > 400},
    ];

    final activeIndex = tierData.indexWhere((t) => t['isActive'] as bool);
    final frontIndex = activeIndex == -1 ? 0 : activeIndex;
    final frontTier = tierData[frontIndex];

    const double cardHeight = 160.0;
    const double stackHeight = 95.0;
    const double maskTop = 76.0;

    return Padding(
      padding: const EdgeInsets.only(top: 24.0, left: 18.0, right: 18.0),
      child: SizedBox(
        height: stackHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              top: -12,
              left: 12,
              right: 12,
              child: Transform.rotate(
                angle: -0.05,
                alignment: Alignment.topRight,
                child: Container(
                  height: cardHeight,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFA8B39).withValues(alpha: 0.50),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 20,
                        spreadRadius: -2,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 14,
              left: 0,
              right: 0,
              child: GestureDetector(
                onTap: () =>
                    _openTierCardsHero(context, cumulativeEnergy, rates),
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
                        tierTitle: frontTier['tierTitle'] as String,
                        isActive: frontTier['isActive'] as bool,
                        index: frontIndex,
                        rates: rates,
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
      ),
    );
  }

  Widget _buildRateCard({
    required String tierTitle,
    required bool isActive,
    required int index,
    required Map<String, double> rates,
  }) {
    const bracketKeys = ['0-200', '201-300', '301-400', 'over-400'];
    final dummySubtext = [
      'First 200 kWh',
      '201 - 300 kWh',
      '301 - 400 kWh',
      'Over 400 kWh',
    ];

    final rateKey = bracketKeys[index % bracketKeys.length];
    final rateValue = rates[rateKey] ?? _fallbackRates[rateKey] ?? 0.0;
    final rate = '₱ ${rateValue.toStringAsFixed(4)}';
    final subtext = dummySubtext[index % dummySubtext.length];

    final bgColor = isActive ? const Color(0xFFFA8B39) : Colors.white;
    final textColor = isActive ? Colors.white : const Color(0xFF2D3142);
    final subtitleColor = isActive
        ? Colors.white.withValues(alpha: 0.8)
        : Colors.grey.shade500;
    final shapeColor = isActive
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.black.withValues(alpha: 0.04);

    return Container(
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
                            ? Colors.white.withValues(alpha: 0.25)
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
    );
  }
}

class _BillLineItem {
  final String label;
  final double amount;
  final List<_BillLineItem> subItems;
  const _BillLineItem(this.label, this.amount, [this.subItems = const []]);
}

class _DiagonalHatchPainter extends CustomPainter {
  final Color color;
  final double lineSpacing;

  const _DiagonalHatchPainter({required this.color, this.lineSpacing = 12.0});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;

    for (double i = -size.height; i < size.width; i += lineSpacing) {
      canvas.drawLine(
        Offset(i, 0),
        Offset(i + size.height, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DiagonalHatchPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.lineSpacing != lineSpacing;
}

class CardCirclePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFA8B39).withValues(alpha: 0.5)
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
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _TicketDashedTearLine extends StatelessWidget {
  final Color color;
  final double height;
  final double dashWidth;
  final double dashSpace;

  const _TicketDashedTearLine({
    this.color = const Color(0xFFE2E8F0),
    this.height = 1.5,
    this.dashWidth = 6,
    this.dashSpace = 4,
  });

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