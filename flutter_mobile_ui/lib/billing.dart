import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;
import 'package:lottie/lottie.dart';
import 'package:custom_refresh_indicator/custom_refresh_indicator.dart';

class BillingScreen extends StatelessWidget {
  BillingScreen({super.key});

  final Color primaryOrange = const Color(0xFFFCB775); // Jaffa 300 — main fill
  final Color tierCardBorder = const Color(0xFFFA8B39);
  final Color creamBg = const Color(0xFFFFFDF9);
  final Color textDark = const Color(0xFF1E1E1E);
  final Color brandOrangeText = const Color(0xFFE25319);
  final Color tierTextColor = const Color(0xFF7A3712); // Jaffa 700

  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();

  // Same FastAPI VM used elsewhere (dashboard, advisories) for backend calls.
  static const String _apiBaseUrl = 'http://35.209.250.46:8000';

  // ── In-memory cache for /bill/breakdown calls ───────────────────────────
  // Keyed on kWh rounded to the nearest whole number so the ESTIMATED BILL
  // figure (which reads this on every RTDB tick via estimatedMonthEnd)
  // doesn't hammer the backend every time the stream emits a near-identical
  // value. Cleared implicitly on widget rebuild (new BillingScreen instance)
  // — this is a per-session cache, not persisted.
  final Map<int, Future<Map<String, dynamic>>> _breakdownCache = {};

  Future<Map<String, dynamic>> _fetchBillBreakdownCached(double kwh) {
    final key = kwh.round();
    return _breakdownCache.putIfAbsent(key, () => _fetchBillBreakdown(kwh));
  }

  // ── FALLBACK RATES ───────────────────────────────────────────────────
  // Used only if `meralco_rates/brackets` hasn't loaded yet (e.g. first
  // frame before the stream emits, or the node is briefly missing) so the
  // UI never flashes ₱0.0000/kWh. Once the DB value arrives, these are
  // fully overridden — they are not a permanent rate source.
  static const Map<String, double> _fallbackRates = {
    '0-200': 0.9803,
    '201-300': 1.2908,
    '301-400': 1.5837,
    'over 400': 2.0941,
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

  // ── Parse `meralco_rates/brackets` into a clean rate map ────────────────
  // Falls back per-key to _fallbackRates if a specific bracket is missing
  // or unparsable, rather than failing the whole map.
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

  // ── Tiered bill calculation using live bracket rates ────────────────────
  // Used ONLY as a placeholder for the always-visible "ESTIMATED BILL" figure
  // at the top of the screen, while the real /bill/breakdown call for
  // `estimatedMonthEnd` is in flight or hasn't resolved yet. As soon as that
  // fetch resolves, its `total_energy_amount` fully overrides this local
  // estimate — see the FutureBuilder in build() below. The detailed
  // breakdown modal also uses the real backend computation.
  double _calculateBill(double kwh, Map<String, double> rates) {
    if (kwh <= 0) return 0.0;

    final r1 = rates['0-200'] ?? _fallbackRates['0-200']!;
    final r2 = rates['201-300'] ?? _fallbackRates['201-300']!;
    final r3 = rates['301-400'] ?? _fallbackRates['301-400']!;
    final r4 = rates['over 400'] ?? _fallbackRates['over 400']!;

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

  // ── FETCH: real bill breakdown from the backend's rate-schedule engine ──
  // Returns the raw JSON map from GET /bill/breakdown?kwh=<kwh>. The
  // backend resolves the correct narrow rate bracket (e.g. "51 TO 70 KWH")
  // from the current rate-schedule PDF and returns the itemized charges —
  // this is the single source of truth for both the top-of-screen
  // ESTIMATED BILL figure and the detailed breakdown modal.
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

  // ── Map the /bill/breakdown JSON onto display line items ────────────────
  // Only fields actually present in the API response are shown — this is
  // deliberately not a full reproduction of the Meralco SOA's line items,
  // just the subset the backend computes. Zero-valued sub-items are
  // skipped so brackets that don't touch a particular charge (e.g. no
  // senior citizen subsidy) don't clutter the sheet.
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

  // ── Receipt-style bottom sheet showing the bill breakdown ───────────────
  // Opens immediately with a spinner, then fetches the real breakdown for
  // `kwh` from the backend (via the shared cache) and renders it once it
  // arrives.
  void _showBillBreakdown(BuildContext context, {required double kwh}) {
    final headerStyle = TextStyle(
      color: textDark.withValues(alpha: 0.45),
      fontSize: 10,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.6,
    );

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: DraggableScrollableSheet(
            initialChildSize: 0.62,
            minChildSize: 0.4,
            maxChildSize: 0.9,
            expand: false,
            builder: (context, scrollController) {
              return ClipPath(
                clipper: _ReceiptEdgeClipper(),
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
                  child: FutureBuilder<Map<String, dynamic>>(
                    future: _fetchBillBreakdownCached(kwh),
                    builder: (context, snapshot) {
                      return SingleChildScrollView(
                        controller: scrollController,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
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
                            const SizedBox(height: 24),
                            Text(
                              'BILL BREAKDOWN',
                              style: TextStyle(
                                color: brandOrangeText,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Based on your projected end-of-month usage',
                              style: TextStyle(
                                color: textDark.withValues(alpha: 0.5),
                                fontSize: 11.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 24),
                            if (snapshot.connectionState != ConnectionState.done)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 40),
                                child: Center(
                                  child: SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  ),
                                ),
                              )
                            else if (snapshot.hasError || snapshot.data == null)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 24),
                                child: Text(
                                  'Unable to load bill breakdown.',
                                  style: TextStyle(
                                    color: textDark.withValues(alpha: 0.5),
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              )
                            else
                              ..._buildBreakdownContent(snapshot.data!, headerStyle),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  // ── Assembles the header row, itemized charges, and total for the sheet.
  List<Widget> _buildBreakdownContent(
    Map<String, dynamic> data,
    TextStyle headerStyle,
  ) {
    final kwh = (data['kwh'] as num?)?.toDouble() ?? 0.0;
    final tier = data['tier'] as String? ?? '';
    final sourceFile = data['source_file'] as String?;
    final totalEnergyAmount =
        (data['total_energy_amount'] as num?)?.toDouble() ?? 0.0;
    final items = _buildBreakdownItems(data);

    return [
      if (tier.isNotEmpty || kwh > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (tier.isNotEmpty)
                Text(
                  tier,
                  style: TextStyle(
                    color: tierTextColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              Text(
                '${kwh.toStringAsFixed(0)} kWh',
                style: TextStyle(
                  color: textDark.withValues(alpha: 0.6),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      Row(
        children: [
          Expanded(flex: 6, child: Text('CHARGE', style: headerStyle)),
          Expanded(
            flex: 4,
            child: Text('AMOUNT', textAlign: TextAlign.right, style: headerStyle),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Divider(color: textDark.withValues(alpha: 0.08), thickness: 1, height: 1),
      for (final item in items) _buildLineItemRow(item),
      const SizedBox(height: 8),
      Divider(color: textDark.withValues(alpha: 0.08), thickness: 1, height: 1),
      const SizedBox(height: 16),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'TOTAL ENERGY AMOUNT',
            style: TextStyle(
              color: textDark,
              fontSize: 14,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.4,
            ),
          ),
          Text(
            '₱${totalEnergyAmount.toStringAsFixed(2)}',
            style: TextStyle(
              color: brandOrangeText,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
      if (sourceFile != null && sourceFile.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(
          'Rate schedule: $sourceFile',
          style: TextStyle(
            color: textDark.withValues(alpha: 0.35),
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    ];
  }

  // ── A single charge row, with its (optional) itemized sub-charges
  // indented beneath it in a muted style. ─────────────────────────────────
  Widget _buildLineItemRow(_BillLineItem item) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
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
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '₱${item.amount.toStringAsFixed(2)}',
                style: TextStyle(
                  color: textDark,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          for (final subItem in item.subItems)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      subItem.label,
                      style: TextStyle(
                        color: textDark.withValues(alpha: 0.55),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Text(
                    '₱${subItem.amount.toStringAsFixed(2)}',
                    style: TextStyle(
                      color: textDark.withValues(alpha: 0.55),
                      fontSize: 11.5,
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

          Map<String, double> rates = Map.of(_fallbackRates);
          String effectivePeriod = '';

          // New forecast-node fields (not yet wired into the UI, available if needed):
          // double accumulatedPast = 0.0;
          // double avgDaily = 0.0;
          // String billingCycleStart = '';
          // double combinedKWh = 0.0;
          // int daysRemaining = 0;
          // int daysSoFar = 0;
          // String forecastStatus = '';

          if (snapshot.hasData && snapshot.data?.snapshot.value != null) {
            final data = snapshot.data!.snapshot.value as Map<dynamic, dynamic>;

            final forecastData = data['forecast'] as Map<dynamic, dynamic>?;
            if (forecastData != null) {
              estimatedMonthEnd =
                  (forecastData['projected_eom_kWh'] ?? 0).toDouble();
              predictedDayTotal =
                  (forecastData['predicted_day_total_kWh'] ?? 0).toDouble();

              // accumulatedPast = (forecastData['accumulated_past_kWh'] ?? 0).toDouble();
              // avgDaily = (forecastData['avg_daily_kWh'] ?? 0).toDouble();
              // billingCycleStart = forecastData['billing_cycle_start'] ?? '';
              // combinedKWh = (forecastData['combined_kWh'] ?? 0).toDouble();
              // daysRemaining = (forecastData['days_remaining'] ?? 0).toInt();
              // daysSoFar = (forecastData['days_so_far'] ?? 0).toInt();
              // forecastStatus = forecastData['status'] ?? '';
            }

            final liveReading = data['live_reading'] as Map<dynamic, dynamic>?;
            if (liveReading != null) {
              cumulativeEnergy =
                  (liveReading['cumul_kWh'] ?? liveReading['cumul_kwh'] ?? 0)
                      .toDouble();
              // NOTE: live_reading/estimated_cost is intentionally NOT read
              // anymore. The ESTIMATED BILL figure below now always comes
              // from GET /bill/breakdown?kwh=<estimatedMonthEnd> — the same
              // backend rate-schedule engine the breakdown modal uses —
              // instead of a value written into RTDB.
            }

            rates = _parseRates(data['meralco_rates']);
            effectivePeriod = _parseEffectivePeriod(data['meralco_rates']);
          }

          String currentTierTitle = 'TIER 1 STATUS';
          String currentTierRate = _formatRate(rates, '0-200');
          double currentTierMax = 200.0;
          String remainingText = '';

          if (cumulativeEnergy <= 200) {
            currentTierTitle = 'TIER 1 STATUS';
            currentTierRate = _formatRate(rates, '0-200');
            currentTierMax = 200.0;
            double remaining = (200.0 - cumulativeEnergy).clamp(0.0, 200.0);
            remainingText =
                '${remaining.toStringAsFixed(2)} kWh na lang bago umakyat ang tier';
          } else if (cumulativeEnergy <= 300) {
            currentTierTitle = 'TIER 2 STATUS';
            currentTierRate = _formatRate(rates, '201-300');
            currentTierMax = 300.0;
            double remaining = (300.0 - cumulativeEnergy).clamp(0.0, 100.0);
            remainingText =
                '${remaining.toStringAsFixed(2)} kWh na lang bago umakyat ang tier';
          } else if (cumulativeEnergy <= 400) {
            currentTierTitle = 'TIER 3 STATUS';
            currentTierRate = _formatRate(rates, '301-400');
            currentTierMax = 400.0;
            double remaining = (400.0 - cumulativeEnergy).clamp(0.0, 100.0);
            remainingText =
                '${remaining.toStringAsFixed(2)} kWh na lang bago umakyat ang tier';
          } else {
            currentTierTitle = 'TIER 4 STATUS';
            currentTierRate = _formatRate(rates, 'over 400');
            currentTierMax = 400.0;
            remainingText = 'Naabot na ang pinakamataas na tier';
          }

          final double percentage = (cumulativeEnergy / currentTierMax).clamp(
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
                                children: [
                                  Text(
                                    'END OF DAY CONSUMPTION',
                                    style: TextStyle(
                                      color: brandOrangeText.withValues(
                                        alpha: 0.85,
                                      ),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.6,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
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
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
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
                                                      fontWeight:
                                                          FontWeight.w800,
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
                              const SizedBox(height: 2),
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
                        left: 24.0, // Added left padding anchor
                        right: 24.0, // Added right padding anchor
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            // LEFT SIDE: PROJECTED END OF MONTH
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start, // Align to left
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
                                      'PROJECTED END OF MONTH',
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
                                  '${estimatedMonthEnd.toStringAsFixed(2)} kWh',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            // RIGHT SIDE: ESTIMATED BILL
                            // ── Now sourced from GET /bill/breakdown, NOT
                            // from RTDB `live_reading/estimated_cost`. The
                            // FutureBuilder fetches (via the shared cache)
                            // the same backend rate-schedule computation the
                            // breakdown modal uses, keyed off the live
                            // `estimatedMonthEnd` value streaming from
                            // `forecast/projected_eom_kWh`. While that fetch
                            // is in flight (or before estimatedMonthEnd has
                            // arrived), it falls back to the local flat-tier
                            // `_calculateBill` estimate so the figure never
                            // flashes ₱0.00.
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end, // Align to right
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
                                      'ESTIMATED BILL',
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.95),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
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
                                                    '${cumulativeEnergy.toStringAsFixed(2)} ',
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
                        // ── View bill breakdown button ───────────────────
                        InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => _showBillBreakdown(
                            context,
                            kwh: estimatedMonthEnd,
                          ),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              vertical: 14,
                              horizontal: 18,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: tierCardBorder.withValues(alpha: 0.25),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.receipt_long_rounded,
                                      color: brandOrangeText,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      'View bill breakdown',
                                      style: TextStyle(
                                        color: textDark,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  color: textDark.withValues(alpha: 0.35),
                                  size: 20,
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
                          rate: _formatRate(rates, 'over 400'),
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
    final Color activeCardColor = const Color(0xFFFA8B39); // Jaffa 400
    final Color inactiveCardColor = const Color(0xFFFAEEDA); // soft cream
    final Color activeTextColor = Colors.white;
    final Color activeSubTextColor = Colors.white.withValues(alpha: 0.85);
    final Color inactiveTextColor = const Color(0xFF7A3712); // Jaffa 700
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

// ── Simple value holder for a bill breakdown row, with optional nested
// sub-charges (e.g. Distribution → metering, supply, AWAT, etc.).
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

// ── Clips the top edge of the breakdown sheet into a torn-receipt zigzag,
// matching the ticket aesthetic from the reference design (minus the
// barcode).
class _ReceiptEdgeClipper extends CustomClipper<Path> {
  static const double _zigWidth = 16;
  static const double _zigDepth = 9;

  @override
  Path getClip(Size size) {
    final path = Path();

    // Start at the bottom-left, run straight up the left edge, then zigzag
    // across the top from left to right (peak, valley, peak, ...).
    path.moveTo(0, size.height);
    path.lineTo(0, _zigDepth);

    double x = 0;
    bool atValley = true; // first point after the corner is a valley
    while (x < size.width) {
      final double nextX = (x + _zigWidth).clamp(0, size.width).toDouble();
      final double y = atValley ? _zigDepth : 0;
      path.lineTo(nextX, y);
      atValley = !atValley;
      x = nextX;
    }

    path.lineTo(size.width, size.height);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}