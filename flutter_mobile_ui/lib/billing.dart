import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;
import 'package:lottie/lottie.dart';
import 'package:custom_refresh_indicator/custom_refresh_indicator.dart';

enum _BillMode { endOfMonth, current }

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
    }
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

  List<_BillLineItem> _buildBreakdownItems(Map<String, dynamic> data) {
    double num_(dynamic v) => (v as num?)?.toDouble() ?? 0.0;
    Map<String, dynamic> map_(dynamic v) =>
        (v is Map) ? v.cast<String, dynamic>() : const {};

    List<_BillLineItem> sub(Map<String, dynamic> m, Map<String, String> labels) {
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

  // ── 3D Ticket Receipt Modal Bottom Sheet ─────────────────────────────────

  void _showBillBreakdown(
    BuildContext context, {
    required double kwh,
    required String tierTitle,
    required String tierRate,
    required double tierMax,
    required double tierEnergy,
    required double tierPercentage,
    required String tierRemainingText,
  }) {
    bool isClosing = false;
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
                  child: SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    child: RepaintBoundary(
                      child: Stack(
                        alignment: Alignment.topCenter,
                        clipBehavior: Clip.none,
                        children: [
                        // Outer 3D Drop Shadow
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _TicketShadowPainter(
                              clipper: _TicketReceiptClipper(
                                notchRadius: 16,
                                notchPositionRatio: 0.24,
                              ),
                            ),
                          ),
                        ),

                        // Ticket Card Container with Glassmorphic Fill
                        ClipPath(
                          clipper: _TicketReceiptClipper(
                            notchRadius: 16,
                            notchPositionRatio: 0.24,
                          ),
                          child: Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.92),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.5),
                                width: 1.5,
                              ),
                            ),
                            padding: const EdgeInsets.fromLTRB(28, 54, 28, 40),
                            child: FutureBuilder<Map<String, dynamic>>(
                              future: _fetchBillBreakdownCached(kwh),
                              builder: (context, snapshot) {
                                if (snapshot.connectionState !=
                                    ConnectionState.done) {
                                  return const Padding(
                                    padding:
                                        EdgeInsets.symmetric(vertical: 90),
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
  }) {
    final items = _buildBreakdownItems(data);
    final double total = (data['total_energy_amount'] as num?)?.toDouble() ??
        items.fold(0.0, (sum, item) => sum + item.amount);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Lead element: Total ────────────────────────────────────
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

        // ── Tier status ─────────────────────────────────────────────
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

        // ── Itemized breakdown ──────────────────────────────────────
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
        const SizedBox(height: 4),
        _TicketDashedTearLine(color: textDark.withValues(alpha: 0.15)),
        const SizedBox(height: 20),

        // ── Total, reiterated ───────────────────────────────────────
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
        const SizedBox(height: 28),

        // ── Done (text-only, dismisses the sheet) ───────────────────
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
    if (item.amount == 0 && item.subItems.isEmpty) return const SizedBox.shrink();

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
                  alignment: isEom ? Alignment.centerLeft : Alignment.centerRight,
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
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.visible,
            ),
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

          if (snapshot.hasData && snapshot.data?.snapshot.value != null) {
            final data = snapshot.data!.snapshot.value as Map<dynamic, dynamic>;

            final forecastData = data['forecast'] as Map<dynamic, dynamic>?;
            if (forecastData != null) {
              estimatedMonthEnd =
                  (forecastData['projected_eom_kWh'] ?? 0).toDouble();
              predictedDayTotal =
                  (forecastData['predicted_day_total_kWh'] ?? 0).toDouble();
            }

            final liveReading = data['live_reading'] as Map<dynamic, dynamic>?;
            if (liveReading != null) {
              cumulativeEnergy =
                  (liveReading['cumul_kWh'] ?? liveReading['cumul_kwh'] ?? 0)
                      .toDouble();
              estimatedCostLive =
                  (liveReading['estimated_cost'] ?? 0).toDouble();
              todayKwh = cumulativeEnergy;
            }

            rates = _parseRates(data['meralco_rates']);
            effectivePeriod = _parseEffectivePeriod(data['meralco_rates']);
          }

          final bool isCurrentMode = _mode == _BillMode.current;
          final double heroKwh = isCurrentMode ? todayKwh : estimatedMonthEnd;
          final String heroKwhLabel =
              isCurrentMode ? "TODAY'S USAGE" : 'PROJECTED END OF MONTH';
          final String heroBillLabel =
              isCurrentMode ? 'EST. TOTAL BILL' : 'ESTIMATED BILL';

          final double tierCardEnergy = isCurrentMode ? cumulativeEnergy : estimatedMonthEnd;

          String currentTierTitle = 'TIER 1 STATUS';
          String currentTierRate = _formatRate(rates, '0-200');
          double currentTierMax = 200.0;
          String remainingText = '';

          if (tierCardEnergy <= 200) {
            currentTierTitle = 'TIER 1 STATUS';
            currentTierRate = _formatRate(rates, '0-200');
            currentTierMax = 200.0;
            double remaining = (200.0 - tierCardEnergy).clamp(0.0, 200.0);
            remainingText =
                '${remaining.toStringAsFixed(2)} kWh na lang bago umakyat ang tier';
          } else if (tierCardEnergy <= 300) {
            currentTierTitle = 'TIER 2 STATUS';
            currentTierRate = _formatRate(rates, '201-300');
            currentTierMax = 300.0;
            double remaining = (300.0 - tierCardEnergy).clamp(0.0, 100.0);
            remainingText =
                '${remaining.toStringAsFixed(2)} kWh na lang bago umakyat ang tier';
          } else if (tierCardEnergy <= 400) {
            currentTierTitle = 'TIER 3 STATUS';
            currentTierRate = _formatRate(rates, '301-400');
            currentTierMax = 400.0;
            double remaining = (400.0 - tierCardEnergy).clamp(0.0, 100.0);
            remainingText =
                '${remaining.toStringAsFixed(2)} kWh na lang bago umakyat ang tier';
          } else {
            currentTierTitle = 'TIER 4 STATUS';
            currentTierRate = _formatRate(rates, 'over-400');
            currentTierMax = 400.0;
            remainingText = 'Naabot na ang pinakamataas na tier';
          }

          final double percentage = (tierCardEnergy / currentTierMax).clamp(
            0.0,
            1.0,
          );

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
                parent: BouncingScrollPhysics(),
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
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Flexible(
                                          child: Text(
                                            'END OF DAY CONSUMPTION',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: brandOrangeText.withValues(
                                                alpha: 0.85,
                                              ),
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
                                                borderRadius: BorderRadius.vertical(
                                                  top: Radius.circular(20),
                                                ),
                                              ),
                                              builder: (context) => Padding(
                                                padding: const EdgeInsets.all(24.0),
                                                child: Column(
                                                  mainAxisSize: MainAxisSize.min,
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      children: [
                                                        Icon(
                                                          Icons.refresh_rounded,
                                                          color: brandOrangeText,
                                                          size: 18,
                                                        ),
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
                                                        color: textDark.withValues(
                                                          alpha: 0.7,
                                                        ),
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
                                          },
                                          child: Icon(
                                            Icons.info_outline_rounded,
                                            size: 14,
                                            color: brandOrangeText.withValues(
                                              alpha: 0.5,
                                            ),
                                          ),
                                        ),
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
                                        color: Colors.white.withValues(alpha: 0.95),
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
                                        color: Colors.white.withValues(alpha: 0.95),
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
                                          (billSnapshot.data?['total_energy_amount']
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
                                      color: const Color(0xFFE27B66)
                                          .withValues(alpha: 0.18),
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
                                                color: const Color(0xFF2B2C36)
                                                    .withValues(alpha: 0.65),
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
                                                  color: const Color(0xFFD36852)
                                                      .withValues(alpha: 0.35),
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
                                                        .withValues(alpha: 0.15),
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
                  SizedBox(
                    height: 170,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 18.0),
                      physics: const BouncingScrollPhysics(),
                      children: [
                        _buildRateCard(
                          tierTitle: 'TIER 1',
                          range: 'Up to 200 kWh',
                          rate: _formatRate(rates, '0-200'),
                          isActive: cumulativeEnergy <= 200,
                        ),
                        _buildRateCard(
                          tierTitle: 'TIER 2',
                          range: '201 - 300 kWh',
                          rate: _formatRate(rates, '201-300'),
                          isActive:
                              cumulativeEnergy > 200 && cumulativeEnergy <= 300,
                        ),
                        _buildRateCard(
                          tierTitle: 'TIER 3',
                          range: '301 - 400 kWh',
                          rate: _formatRate(rates, '301-400'),
                          isActive:
                              cumulativeEnergy > 300 && cumulativeEnergy <= 400,
                        ),
                        _buildRateCard(
                          tierTitle: 'TIER 4',
                          range: 'Over 400 kWh',
                          rate: _formatRate(rates, 'over-400'),
                          isActive: cumulativeEnergy > 400,
                        ),
                      ],
                    ),
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

  Widget _buildRateCard({
    required String tierTitle,
    required String range,
    required String rate,
    required bool isActive,
  }) {
    final Color activeCardColor = const Color(0xFFFA8B39);
    final Color inactiveCardColor = const Color(0xFFFAEEDA);
    final Color activeTextColor = Colors.white;
    final Color activeSubTextColor = Colors.white.withValues(alpha: 0.85);
    final Color inactiveTextColor = const Color(0xFF7A3712);
    final Color inactiveSubTextColor = const Color(
      0xFF7A3712,
    ).withValues(alpha: 0.55);

    return Container(
      width: 200,
      margin: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 4.0),
      padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 18.0),
      decoration: BoxDecoration(
        color: isActive ? activeCardColor : inactiveCardColor,
        borderRadius: BorderRadius.circular(20),
        border: isActive
            ? null
            : Border.all(
                color: const Color(0xFFFA8B39).withValues(alpha: 0.15),
                width: 1,
              ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                tierTitle,
                style: TextStyle(
                  color: isActive ? activeSubTextColor : inactiveSubTextColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
              if (isActive)
                Container(
                  width: 20,
                  height: 20,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.bolt_rounded,
                    size: 13,
                    color: activeCardColor,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            range,
            style: TextStyle(
              color: isActive ? activeTextColor : inactiveTextColor,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            height: 1,
            color: isActive
                ? Colors.white.withValues(alpha: 0.25)
                : const Color(0xFFFA8B39).withValues(alpha: 0.15),
          ),
          const SizedBox(height: 12),
          Text(
            'RATE',
            style: TextStyle(
              color: isActive ? activeSubTextColor : inactiveSubTextColor,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            rate,
            style: TextStyle(
              color: isActive ? activeTextColor : inactiveTextColor,
              fontSize: 18,
              fontWeight: FontWeight.w900,
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

// ── Realistic Dashed Tear Line ──────────────────────────────────────────────
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxWidth = constraints.constrainWidth();
        final dashCount = (boxWidth / (dashWidth + dashSpace)).floor();
        return Flex(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          direction: Axis.horizontal,
          children: List.generate(dashCount, (_) {
            return SizedBox(
              width: dashWidth,
              height: height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

// ── Custom Ticket Clipper (Side Notches + Top Rounded + Bottom Serrated) ───
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

    // Top-Left Corner
    path.moveTo(0, cornerRadius);
    path.quadraticBezierTo(0, 0, cornerRadius, 0);

    // Top Edge
    path.lineTo(size.width - cornerRadius, 0);

    // Top-Right Corner
    path.quadraticBezierTo(size.width, 0, size.width, cornerRadius);

    // Right Edge down to notch
    path.lineTo(size.width, notchY - notchRadius);

    // Right Notch cutout
    path.arcToPoint(
      Offset(size.width, notchY + notchRadius),
      radius: Radius.circular(notchRadius),
      clockwise: false,
    );

    // Right Edge down to bottom
    path.lineTo(size.width, size.height - zigHeight);

    // Bottom Serrated/Scalloped Edge
    double x = size.width;
    bool atPeak = true;
    while (x > 0) {
      final nextX = (x - zigWidth).clamp(0.0, size.width);
      final y = atPeak ? size.height : size.height - zigHeight;
      path.lineTo(nextX, y);
      atPeak = !atPeak;
      x = nextX;
    }

    // Left Edge up to notch
    path.lineTo(0, notchY + notchRadius);

    // Left Notch cutout
    path.arcToPoint(
      Offset(0, notchY - notchRadius),
      radius: Radius.circular(notchRadius),
      clockwise: false,
    );

    // Left Edge up to top corner
    path.lineTo(0, cornerRadius);

    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant _TicketReceiptClipper oldClipper) =>
      oldClipper.notchRadius != notchRadius ||
      oldClipper.notchPositionRatio != notchPositionRatio;
}

// ── Layered 3D Drop Shadow Painter for the Ticket ──────────────────────────
class _TicketShadowPainter extends CustomPainter {
  final CustomClipper<Path> clipper;

  _TicketShadowPainter({required this.clipper});

  @override
  void paint(Canvas canvas, Size size) {
    final path = clipper.getClip(size);

    // Soft Ambient 3D Shadow
    canvas.drawShadow(
      path,
      Colors.black.withValues(alpha: 0.18),
      20.0,
      true,
    );

    // Directional Depth Shadow
    canvas.drawShadow(
      path,
      const Color(0xFFE25319).withValues(alpha: 0.12),
      8.0,
      false,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}