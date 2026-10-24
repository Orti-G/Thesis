import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart' hide TextDirection;
import 'alerts_guide.dart';
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

  // Whether the "How alerts work" sheet is up, so a tapped notification
  // can close it and show the inbox underneath.
  bool _infoOpen = false;

  // One entry per anomaly event (flagged readings ≤ 10 min apart), newest
  // first. `open` events are still happening and can't be answered yet.
  List<Map<String, dynamic>> _events = [];
  bool _loadingEvents = true;
  String? _eventsError;

  // Rows swiped away as "unsure" while their Undo toast is up; the answer
  // is sent once the toast closes. `index` is where Undo puts the row back.
  static const Duration _undoWindow = Duration(seconds: 4);
  final Map<int, ({Map<String, dynamic> event, int index})> _pendingUnsure =
      {};

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
    // Leaving mid-Undo still counts as the swipe: send those answers now.
    for (final eventId in _pendingUnsure.keys) {
      _postReview(eventId, 'unsure').ignore();
    }
    _pendingUnsure.clear();
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

    if (request.showInbox && _infoOpen) Navigator.of(context).pop();
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
      // Rows still in their Undo window stay hidden until it ends.
      final data = (body['data'] as List)
          .cast<Map<String, dynamic>>()
          .where((e) => !_pendingUnsure.containsKey(e['event_id']))
          .toList();

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
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>
      _showGlassmorphicToast(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    return messenger.showSnackBar(
      SnackBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        duration: duration,
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
                  if (actionLabel != null && onAction != null)
                    TextButton(
                      onPressed: () {
                        messenger.hideCurrentSnackBar(
                          reason: SnackBarClosedReason.action,
                        );
                        onAction();
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: primaryOrange,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        actionLabel,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
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
    await _submitReview(eventId, answer);
  }

  Future<http.Response> _postReview(int eventId, String answer) {
    return http
        .post(
          Uri.parse('$kApiBaseUrl/anomaly-events/$eventId/review'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'answer': answer}),
        )
        .timeout(const Duration(seconds: 10));
  }

  // A swipe already showed its own toast, so it passes toastOnSuccess: false
  // and only hears back when something went wrong.
  Future<void> _submitReview(
    int eventId,
    String answer, {
    bool toastOnSuccess = true,
  }) async {
    String? toast;
    try {
      final res = await _postReview(eventId, answer);

      if (res.statusCode == 200) {
        final status = (jsonDecode(res.body) as Map<String, dynamic>)['status'];
        if (status == 'already_reviewed') {
          toast = 'Already answered on another phone.';
        } else if (toastOnSuccess) {
          toast = 'Answer saved. Thank you!';
        }
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

  Map<String, dynamic>? _unsureOption(Map<String, dynamic> event) {
    return ((event['options'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .where((o) => o['answer'] == 'unsure')
        .firstOrNull;
  }

  // Swiping a row away answers "unsure", like clearing a notification. The
  // answer goes out when the Undo toast closes, unless Undo was tapped.
  void _dismissAsUnsure(int eventId) {
    final index = _events.indexWhere((e) => e['event_id'] == eventId);
    if (index < 0) return;
    setState(() {
      _pendingUnsure[eventId] = (event: _events.removeAt(index), index: index);
    });

    _showGlassmorphicToast(
      context,
      'Marked as not sure.',
      actionLabel: 'Undo',
      onAction: () => _undoUnsure(eventId),
      duration: _undoWindow,
    ).closed.then((reason) {
      if (reason == SnackBarClosedReason.action) return;
      // Already sent if the screen was disposed in the meantime.
      if (_pendingUnsure.remove(eventId) == null || !mounted) return;
      _submitReview(eventId, 'unsure', toastOnSuccess: false);
    });
  }

  void _undoUnsure(int eventId) {
    final pending = _pendingUnsure.remove(eventId);
    if (pending == null || !mounted) return;
    if (_events.any((e) => e['event_id'] == eventId)) return;
    setState(() {
      _events.insert(min(pending.index, _events.length), pending.event);
    });
  }

  // Event times are Philippine local time with no zone, so they are used
  // exactly as written; never convert them from UTC.
  static final DateFormat _clockFormat = DateFormat('h:mm a');

  // Every event wears the same bolt. For "higher than usual" events the
  // shade says how strong it was, darkest for severe. Sudden rises and
  // drops carry no strength level, so each gets its own clear colour
  // instead: golden yellow going up, blue going down.
  Color _eventColor(Map<String, dynamic> event) {
    switch (event['kind']) {
      case 'rise':
        return const Color(0xFFF5B000);
      case 'drop':
        return const Color(0xFF3B82F6);
    }
    switch (event['severity']) {
      case 'severe':
        return const Color(0xFFC2410C);
      case 'moderate':
        return primaryOrange;
      case 'mild':
        return const Color(0xFFF39456);
      default:
        return const Color(0xFF64748B);
    }
  }

  // The backend's title_tl is "<kind> · <day>", e.g. "Anomalya · Okt 18".
  // The day heads the list's groups, so titles leave it out.
  static const String _daySeparator = ' · ';

  String? _eventDay(Map<String, dynamic> event) {
    final sent = event['title_tl'] as String?;
    final dot = sent?.lastIndexOf(_daySeparator) ?? -1;
    if (dot < 0) return null;
    final day = sent!.substring(dot + _daySeparator.length);
    return day.isEmpty ? null : day[0].toUpperCase() + day.substring(1);
  }

  // The backend's "Anomalya" titles read as jargon to households, so the
  // title is rebuilt here in plain words. Unknown kinds fall back to the
  // backend's own title, minus its day.
  String? _eventTitle(Map<String, dynamic> event) {
    final sent = event['title_tl'] as String?;
    final String? plain;
    switch (event['kind']) {
      case 'rise':
        plain = 'Biglang tumaas ang konsumo';
      case 'drop':
        plain = 'Biglang bumaba ang konsumo';
      case 'hour':
        switch (event['severity']) {
          case 'severe':
            plain = 'Napakataas na konsumo';
          case 'moderate':
            plain = 'Mas mataas na konsumo kaysa karaniwan';
          case 'mild':
            plain = 'Bahagyang mataas na konsumo';
          default:
            plain = null;
        }
      default:
        plain = null;
    }
    if (plain != null) return plain;
    final dot = sent?.lastIndexOf(_daySeparator) ?? -1;
    return dot < 0 ? sent : sent!.substring(0, dot);
  }

  static final NumberFormat _wattFormat = NumberFormat('#,##0');

  // The card's one supporting line: when, and how high it went. Drops skip
  // the peak, since what matters there is how low it fell.
  String? _eventDetail(Map<String, dynamic> event) {
    final start = DateTime.tryParse(event['start'] as String? ?? '');
    final end = DateTime.tryParse(event['end'] as String? ?? '');
    if (start == null || end == null) return event['time_tl'] as String?;
    final span = '${_clockFormat.format(start)}–${_clockFormat.format(end)}';
    final peak = event['peak_power_w'] as num?;
    if (event['kind'] == 'drop' || peak == null) return span;
    return '$span · hanggang ${_wattFormat.format(peak)} W';
  }

  // Answers to "Normal ba ang paggamit na ito?" read as a yes/no reply,
  // keyed on the stable `answer` value rather than the backend's label.
  String _answerLabel(Map<String, dynamic> option) {
    switch (option['answer']) {
      case 'normal':
        return 'Oo, normal ito';
      case 'real':
        return 'Hindi, kakaiba ito';
      case 'unsure':
        return 'Hindi ko alam';
      default:
        return (option['label_tl'] as String?) ?? '';
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
                      // The guide lives in a sheet, so the page itself is
                      // only the events to review.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                        child: Row(
                          children: [
                            Expanded(
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
                            IconButton(
                              onPressed: () => _showInfo(context),
                              tooltip: 'How alerts work',
                              iconSize: 26,
                              color: textDark,
                              style: IconButton.styleFrom(
                                backgroundColor: cardColor,
                                fixedSize: const Size(48, 48),
                              ),
                              icon: const Icon(Icons.info_outline_rounded),
                            ),
                          ],
                        ),
                      ),

                      // ── SUMMARY CARD ── the one place the count is said,
                      // in orange so a backlog reads as something to do.
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
                                      '$_closedCount to review',
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
                                          ? 'events waiting for your answer · $_openCount ongoing'
                                          : 'events waiting for your answer',
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
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20.0),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: _buildAnomaliesListContent(),
                        ),
                      ),
                      const SizedBox(height: 100),
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

  // The guide floats as a card over the inbox rather than rising from the
  // bottom like an event, so reading it never feels like opening an alert.
  void _showInfo(BuildContext context) {
    setState(() => _infoOpen = true);
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      // A plain dim, not a blur: the guide animates nonstop, and re-blurring
      // the page every frame stutters on budget phones.
      barrierColor: Colors.black.withValues(alpha: 0.4),
      transitionDuration:
          reduceMotion ? Duration.zero : const Duration(milliseconds: 260),
      pageBuilder: (dialogContext, _, _) {
        final size = MediaQuery.of(dialogContext).size;
        return RepaintBoundary(
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 520,
                    maxHeight: size.height * 0.82,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 32,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                      clipBehavior: Clip.antiAlias,
                      // A fixed header keeps Close clear of the text
                      // scrolling underneath it.
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(24, 12, 12, 12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'How alerts work',
                                    style: TextStyle(
                                      color: textDark,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  onPressed: () =>
                                      Navigator.of(dialogContext).pop(),
                                  tooltip: 'Close',
                                  color: textDark,
                                  style: IconButton.styleFrom(
                                    backgroundColor: const Color(0xFFF1F3F4),
                                  ),
                                  icon: const Icon(Icons.close_rounded),
                                ),
                              ],
                            ),
                          ),
                          Divider(
                            height: 1,
                            thickness: 1,
                            color: Colors.grey.withValues(alpha: 0.15),
                          ),
                          Flexible(
                            child: AlertsGuide(
                              onDone: () => Navigator.of(dialogContext).pop(),
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
      transitionBuilder: (_, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    ).whenComplete(() {
      if (mounted) setState(() => _infoOpen = false);
    });
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
      // Events arrive newest first, so each day's events sit together and
      // a heading starts wherever the day changes.
      return Column(
        key: const ValueKey('list'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _events.length; i++) ...[
            if (i == 0 || _eventDay(_events[i]) != _eventDay(_events[i - 1]))
              _buildDayHeading(_eventDay(_events[i]))
            else
              Divider(
                height: 1,
                thickness: 1,
                color: Colors.grey.withValues(alpha: 0.15),
              ),
            _buildAnomalyItem(context, event: _events[i]),
          ],
        ],
      );
    }
  }

  Widget _buildDayHeading(String? day) {
    if (day == null) return const SizedBox(height: 12);
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 2),
      child: Text(
        day,
        style: TextStyle(
          color: Colors.grey[600],
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
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
    final title = _eventTitle(event);
    final detail = _eventDetail(event);
    final accent = _eventColor(event);
    final eventId = event['event_id'] as int?;
    final unsure = _unsureOption(event);

    final row = InkWell(
      onTap: () => _showAnomalyDetail(context, event),
      splashColor: Colors.grey.withValues(alpha: 0.1),
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BoltBadge(color: accent, diameter: 56),
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
                  if (detail != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      detail,
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 14,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // Only finished events can be answered, so ongoing ones don't swipe.
    if (event['status'] != 'closed' || eventId == null || unsure == null) {
      return row;
    }
    final unsureLabel = _answerLabel(unsure);
    return Dismissible(
      key: ValueKey('event-$eventId'),
      direction: DismissDirection.horizontal,
      background: _buildSwipeBackground(unsureLabel, Alignment.centerLeft),
      secondaryBackground:
          _buildSwipeBackground(unsureLabel, Alignment.centerRight),
      onDismissed: (_) => _dismissAsUnsure(eventId),
      child: row,
    );
  }

  // Shown behind a row as it's swiped, so the gesture says what it answers.
  Widget _buildSwipeBackground(String label, Alignment alignment) {
    return Container(
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.close_rounded, color: Colors.grey[700], size: 20),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: Colors.grey[700],
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
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

  // ── GLASSMORPHIC MODAL ──
  void _showAnomalyDetail(BuildContext context, Map<String, dynamic> entry) {
    _showSheet(context, _buildActionPanel(entry));
  }

  // The frosted sheet an event's details open in.
  Future<void> _showSheet(BuildContext context, Widget child) {
    return showModalBottomSheet(
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
                        child,
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
    final title = _eventTitle(event);
    final message = event['message_tl'] as String?;
    final summary = event['summary_tl'] as String?;
    final prompt = event['prompt_tl'] as String?;
    final chart = event['chart'] as Map<String, dynamic>?;
    final options = ((event['options'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    // "Unsure" is a small X under the real answers, not a third big button.
    // "Oo" goes first, as a yes/no reply would.
    final mainOptions = options.where((o) => o['answer'] != 'unsure').toList()
      ..sort((a, b) =>
          (b['answer'] == 'normal' ? 1 : 0) - (a['answer'] == 'normal' ? 1 : 0));
    final unsure = _unsureOption(event);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The title already says how strong it was, and the message says
        // when, so the only marker left up here is "Ongoing".
        if (!isClosed) ...[
          _buildOngoingPill(),
          const SizedBox(height: 12),
        ],
        if (title != null) ...[
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
          for (var i = 0; i < mainOptions.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _buildAnswerButton(
              label: _answerLabel(mainOptions[i]),
              filled: i == 0,
              onPressed: () =>
                  _reviewEvent(eventId, mainOptions[i]['answer'] as String),
            ),
          ],
          if (unsure != null) ...[
            const SizedBox(height: 12),
            Center(
              child: TextButton.icon(
                onPressed: () => _reviewEvent(eventId, 'unsure'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.grey[600],
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
                icon: const Icon(Icons.close_rounded, size: 18),
                label: Text(
                  _answerLabel(unsure),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
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
