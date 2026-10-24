import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// "How alerts work": a short animated walkthrough, one idea per step, so
/// households learn the Alerts screen by watching instead of reading.
class AlertsGuide extends StatefulWidget {
  const AlertsGuide({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<AlertsGuide> createState() => _AlertsGuideState();
}

const Color _orange = Color(0xFFF26E22);
const Color _ink = Color(0xFF111418);
const Color _red = Color(0xFFD32F2F);
// Bolt shades, matching the inbox: deeper means a stronger event.
const Color _boltSevere = Color(0xFFC2410C);
const Color _boltMild = Color(0xFFF39456);
const Color _boltRise = Color(0xFFF5B000);
const Color _boltDrop = Color(0xFF3B82F6);
const Color _barGrey = Color(0xFFE2E8F0);
const Color _well = Color(0xFFF1F3F4);
const Color _hairline = Color(0xFFECECEC);

/// The anomaly bolt, drawn rather than taken from the icon font so its
/// corners can be rounded off. Straight sides, flat colour, no shading.
class RoundedBolt extends StatelessWidget {
  const RoundedBolt({super.key, required this.color, this.size = 24});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _RoundedBoltPainter(color),
    );
  }
}

class _RoundedBoltPainter extends CustomPainter {
  _RoundedBoltPainter(this.color);

  final Color color;

  // The bolt's corners on a 24-unit grid: a long upper arm, a step across
  // the middle, and a long lower arm. The top and bottom ends are cut flat
  // across a narrow width, so rounding their two corners gives a round tip
  // instead of a point. Sides are straight; only corners are eased off.
  // Listed so the inside of the bolt is always to the right of travel.
  static const _corners = [
    Offset(13.0, 1.8), // top, left
    Offset(4.6, 13.4),
    Offset(10.9, 13.4),
    Offset(8.3, 22.2), // bottom, left
    Offset(10.9, 22.2), // bottom, right
    Offset(19.4, 10.2),
    Offset(13.1, 10.2),
    Offset(16.6, 1.8), // top, right
  ];

  // How far from each corner the rounding starts, in grid units, in the
  // order of _corners. The tips ask for plenty and are held back by the
  // short flat end they sit on, which makes each end close to a semicircle.
  static const _cornerRadii = [4.0, 3.0, 3.0, 4.0, 4.0, 3.0, 3.0, 4.0];

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final n = _corners.length;

    // Walk the outline, stopping short of each corner and curving around
    // it, so the sides stay straight and only the corners soften. The
    // radius shrinks on short sides so neighbouring curves never overlap.
    final bolt = Path();
    for (var i = 0; i < n; i++) {
      final prev = _corners[(i + n - 1) % n];
      final cur = _corners[i];
      final next = _corners[(i + 1) % n];
      final toPrev = prev - cur;
      final toNext = next - cur;
      final r = [
        _cornerRadii[i],
        toPrev.distance * 0.55,
        toNext.distance * 0.55,
      ].reduce((a, b) => a < b ? a : b);
      final enter = (cur + toPrev / toPrev.distance * r) * s;
      final leave = (cur + toNext / toNext.distance * r) * s;
      if (i == 0) {
        bolt.moveTo(enter.dx, enter.dy);
      } else {
        bolt.lineTo(enter.dx, enter.dy);
      }
      bolt.quadraticBezierTo(cur.dx * s, cur.dy * s, leave.dx, leave.dy);
    }
    bolt.close();

    canvas.drawPath(
      bolt,
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_RoundedBoltPainter old) => old.color != color;
}

/// The bolt on its round badge: a plain tinted circle, as before.
class BoltBadge extends StatelessWidget {
  const BoltBadge({super.key, required this.color, this.diameter = 52});

  final Color color;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter,
      height: diameter,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: RoundedBolt(color: color, size: diameter * 0.80),
    );
  }
}

// Every scene is drawn at this size and scaled down to fit, so large system
// fonts shrink the picture instead of clipping the words under it.
const Size _sceneSize = Size(300, 220);

// Where a scene rests when motion is off: every beat has finished, before
// the loop's fade-out begins.
const double _restT = 0.9;

class _Step {
  const _Step(this.title, this.body, this.scene);

  final String title;
  final String body;
  final Widget Function(double t) scene;
}

final List<_Step> _steps = [
  const _Step(
    'GRID learns your usual use',
    'When power goes far from it, an event shows up here.',
    _barsScene,
  ),
  const _Step(
    'Three kinds of events',
    'Higher than usual for the hour, a sudden rise, or a sudden drop.',
    _kindsScene,
  ),
  const _Step(
    'The color shows how strong',
    'Darker orange means a bigger jump. Yellow is a rise, blue a drop.',
    _colorsScene,
  ),
  const _Step(
    'Tap to see what happened',
    'Each event shows a chart, the cost, and "Bakit?" for why.',
    _tapScene,
  ),
  const _Step(
    'Answer one question',
    'Your answer teaches GRID what is normal for your home.',
    _answerScene,
  ),
  const _Step(
    'Not sure? Swipe it away',
    'Tap Undo right after if you change your mind.',
    _swipeScene,
  ),
  const _Step(
    'One answer for the household',
    'It clears on every phone watching this GRID device.',
    _householdScene,
  ),
];

class _AlertsGuideState extends State<AlertsGuide>
    with SingleTickerProviderStateMixin {
  final PageController _pages = PageController();
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4200),
  );
  int _page = 0;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.of(context).disableAnimations;
    if (_reduceMotion) {
      _loop.stop();
    } else if (!_loop.isAnimating) {
      _loop.repeat();
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    _pages.dispose();
    super.dispose();
  }

  void _onPageChanged(int page) {
    setState(() => _page = page);
    if (!_reduceMotion) {
      _loop
        ..value = 0
        ..repeat();
    }
  }

  void _go(int delta) {
    final target = _page + delta;
    if (target >= _steps.length) {
      widget.onDone();
      return;
    }
    _pages.animateToPage(
      target,
      duration: _reduceMotion
          ? const Duration(milliseconds: 1)
          : const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _steps.length - 1;
    return LayoutBuilder(
      builder: (context, constraints) {
        final pageHeight = math.min(
          360.0,
          math.max(240.0, constraints.maxHeight - 88),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: pageHeight,
              child: PageView.builder(
                controller: _pages,
                itemCount: _steps.length,
                onPageChanged: _onPageChanged,
                itemBuilder: (context, i) => _buildPage(_steps[i]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 16, 16),
              child: Row(
                children: [
                  for (var i = 0; i < _steps.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.only(right: 6),
                      width: i == _page ? 18 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: i == _page ? _orange : _barGrey,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  const Spacer(),
                  if (_page > 0)
                    TextButton(
                      onPressed: () => _go(-1),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.grey[700],
                      ),
                      child: const Text(
                        'Back',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: () => _go(1),
                    style: FilledButton.styleFrom(
                      backgroundColor: _ink,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                    ),
                    child: Text(
                      isLast ? 'Got it' : 'Next',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPage(_Step step) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            // Its own layer, so each animation frame repaints only the
            // picture, not the words and buttons around it.
            child: ExcludeSemantics(
              child: RepaintBoundary(
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: SizedBox.fromSize(
                    size: _sceneSize,
                    child: AnimatedBuilder(
                      animation: _loop,
                      builder: (context, _) {
                        final t = _reduceMotion ? _restT : _loop.value;
                        // Fade in and out at the loop's ends so the restart
                        // never jumps.
                        final fade = _seg(t, 0, 0.05) * (1 - _seg(t, 0.93, 1));
                        return Opacity(opacity: fade, child: step.scene(t));
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            step.title,
            style: const TextStyle(
              color: _ink,
              fontSize: 21,
              height: 1.2,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            step.body,
            style: TextStyle(
              color: Colors.grey[700],
              fontSize: 15,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

// Progress of t through [a, b], eased.
double _seg(double t, double a, double b, {Curve curve = Curves.easeOutCubic}) {
  return curve.transform(((t - a) / (b - a)).clamp(0.0, 1.0));
}

// ── SHARED PIECES ──

Widget _tag(String text, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800),
    ),
  );
}

// A small stand-in for an inbox card.
Widget _mockEvent(Color color, String title, String detail) {
  return Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: _hairline),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 10,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: Row(
      children: [
        BoltBadge(color: color, diameter: 38),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

Widget _finger({double opacity = 1}) {
  return Opacity(
    opacity: opacity.clamp(0.0, 1.0),
    child: const Icon(Icons.touch_app_rounded, size: 34, color: _ink),
  );
}

// ── SCENES ── each draws one step at time t in [0, 1).

Widget _barsScene(double t) {
  const heights = [0.34, 0.48, 0.30, 0.40, 0.42, 0.34, 0.44];
  const flaggedIndex = 4;
  // Quick beats, then a long hold on the flagged bar: that end frame is
  // the point of the step.
  final grow = _seg(t, 0.04, 0.24);
  final spike = _seg(t, 0.30, 0.48);
  final flag = _seg(t, 0.48, 0.58);
  return Column(
    children: [
      Expanded(
        child: LayoutBuilder(
          builder: (context, c) {
            final room = c.maxHeight - 40; // headroom for the tag
            return Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < heights.length; i++)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            child: Container(
                              height: math.max(
                                6,
                                room *
                                    grow *
                                    (i == flaggedIndex
                                        ? lerpDouble(heights[i], 1, spike)!
                                        : heights[i]),
                              ),
                              decoration: BoxDecoration(
                                color: i == flaggedIndex
                                    ? Color.lerp(_barGrey, _orange, spike)
                                    : _barGrey,
                                borderRadius: BorderRadius.circular(100),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Align(
                  alignment: Alignment(
                    -1 + 2 * (flaggedIndex + 0.5) / heights.length,
                    -1,
                  ),
                  child: Opacity(
                    opacity: flag,
                    child: Transform.translate(
                      offset: Offset(0, 6 * (1 - flag)),
                      child: _tag('Flagged', _orange),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
      const SizedBox(height: 8),
      Container(height: 2, color: _barGrey),
    ],
  );
}

Widget _kindsScene(double t) {
  const rows = [
    (_orange, 'Mas mataas na konsumo', 'Higher than usual for the hour'),
    (_boltRise, 'Biglang tumaas ang konsumo', 'Sudden rise'),
    (_boltDrop, 'Biglang bumaba ang konsumo', 'Sudden drop'),
  ];
  return Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      for (var i = 0; i < rows.length; i++) ...[
        if (i > 0) const SizedBox(height: 8),
        Builder(
          builder: (context) {
            final p = _seg(t, 0.08 + i * 0.16, 0.30 + i * 0.16);
            return Opacity(
              opacity: p,
              child: Transform.translate(
                offset: Offset(28 * (1 - p), 0),
                child: _mockEvent(rows[i].$1, rows[i].$2, rows[i].$3),
              ),
            );
          },
        ),
      ],
    ],
  );
}

// Every bolt color the Alerts list uses, strongest first, then rise and
// drop. The words are the card titles' own, so a household can match a
// color to a title it has already seen.
Widget _colorsScene(double t) {
  const rows = [
    (_boltSevere, 'Napakataas'),
    (_orange, 'Mas mataas'),
    (_boltMild, 'Bahagyang mataas'),
    (_boltRise, 'Biglang tumaas'),
    (_boltDrop, 'Biglang bumaba'),
  ];
  return Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      for (var i = 0; i < rows.length; i++) ...[
        if (i > 0) SizedBox(height: i == 3 ? 12 : 4),
        Builder(
          builder: (context) {
            final p = _seg(t, 0.06 + i * 0.10, 0.22 + i * 0.10);
            return Opacity(
              opacity: p,
              child: Transform.translate(
                offset: Offset(20 * (1 - p), 0),
                child: Row(
                  children: [
                    BoltBadge(color: rows[i].$1, diameter: 34),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        rows[i].$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    ],
  );
}

Widget _tapScene(double t) {
  final move = _seg(t, 0.05, 0.28, curve: Curves.easeInOutCubic);
  final press = _seg(t, 0.28, 0.34) * (1 - _seg(t, 0.34, 0.42));
  final ripple = _seg(t, 0.30, 0.48);
  final sheet = _seg(t, 0.45, 0.68);
  const cardTop = 6.0;
  const cardCenterY = cardTop + 29;
  return LayoutBuilder(
    builder: (context, c) {
      final sheetHeight = c.maxHeight * 0.66;
      return ClipRect(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              top: cardTop,
              left: 0,
              right: 0,
              child: Transform.scale(
                scale: 1 - 0.03 * press,
                child: _mockEvent(
                  _boltSevere,
                  'Napakataas na konsumo',
                  '9:11 AM–9:21 AM · hanggang 1,343 W',
                ),
              ),
            ),
            if (ripple > 0 && ripple < 1)
              Positioned(
                left: c.maxWidth / 2 - 40 * ripple,
                top: cardCenterY - 40 * ripple,
                child: Container(
                  width: 80 * ripple,
                  height: 80 * ripple,
                  decoration: BoxDecoration(
                    color: _orange.withValues(alpha: 0.25 * (1 - ripple)),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            Positioned(
              left: lerpDouble(c.maxWidth * 0.78, c.maxWidth / 2 - 8, move),
              top: lerpDouble(c.maxHeight * 0.78, cardCenterY - 4, move),
              child: _finger(opacity: _seg(t, 0.02, 0.08) * (1 - sheet)),
            ),
            Positioned(
              left: 8,
              right: 8,
              height: sheetHeight,
              bottom: -sheetHeight * (1 - sheet),
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                  border: Border.all(color: _hairline),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.10),
                      blurRadius: 16,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 30,
                        height: 3,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: _MiniChartPainter(_seg(t, 0.62, 0.82)),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Row(
                      children: [
                        Text(
                          'Bakit?',
                          style: TextStyle(
                            color: _orange,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Icon(
                          Icons.expand_more_rounded,
                          size: 16,
                          color: _orange,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

// The event chart in miniature: a usual-level baseline and a line that
// spikes, drawn left to right as [progress] goes from 0 to 1.
class _MiniChartPainter extends CustomPainter {
  _MiniChartPainter(this.progress);

  final double progress;

  static const _points = [
    0.22,
    0.25,
    0.35,
    0.2,
    0.15,
    0.95,
    0.6,
    0.45,
    0.62,
    0.3,
    0.12,
  ];
  static const _flagged = {5, 6, 8};

  @override
  void paint(Canvas canvas, Size size) {
    final baseY = size.height * (1 - 0.3);
    final dash = Paint()
      ..color = Colors.grey.shade400
      ..strokeWidth = 1.2;
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, baseY), Offset(x + 4, baseY), dash);
    }

    Offset at(int i) => Offset(
      size.width * i / (_points.length - 1),
      size.height * (1 - _points[i]) * 0.92 + 2,
    );
    final visible = (progress * (_points.length - 1)).floor();
    final line = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i <= visible; i++) {
      line.lineTo(at(i).dx, at(i).dy);
    }
    canvas.drawPath(
      line,
      Paint()
        ..color = _orange
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );
    for (final i in _flagged) {
      if (i <= visible) canvas.drawCircle(at(i), 4, Paint()..color = _red);
    }
  }

  @override
  bool shouldRepaint(_MiniChartPainter old) => old.progress != progress;
}

Widget _pill(String label, {required bool filled, double scale = 1}) {
  return Transform.scale(
    scale: scale,
    child: Container(
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: filled ? _ink : Colors.white,
        borderRadius: BorderRadius.circular(100),
        border: filled ? null : Border.all(color: Colors.grey.shade300),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: filled ? Colors.white : _ink,
          fontSize: 15,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
  );
}

Widget _answerScene(double t) {
  final move = _seg(t, 0.08, 0.32, curve: Curves.easeInOutCubic);
  final press = _seg(t, 0.32, 0.38) * (1 - _seg(t, 0.38, 0.46));
  // The question leaves before the thank-you arrives, so the two never
  // overlap mid-fade.
  final leave = _seg(t, 0.48, 0.56);
  final done = _seg(t, 0.56, 0.70);
  return Stack(
    alignment: Alignment.center,
    children: [
      Opacity(
        opacity: 1 - leave,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Normal ba ang paggamit na ito?',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _ink,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 14),
            Stack(
              clipBehavior: Clip.none,
              children: [
                _pill('Oo, normal ito', filled: true, scale: 1 - 0.04 * press),
                Positioned(
                  right: lerpDouble(10, 110, move),
                  top: lerpDouble(70, 16, move),
                  child: _finger(opacity: _seg(t, 0.04, 0.1)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _pill('Hindi, kakaiba ito', filled: false),
          ],
        ),
      ),
      Opacity(
        opacity: done,
        child: Transform.scale(
          scale: lerpDouble(0.85, 1, done)!,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: _orange.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: _orange,
                  size: 36,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Answer saved. Thank you!',
                style: TextStyle(
                  color: _ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

Widget _swipeScene(double t) {
  final appear = _seg(t, 0.04, 0.12);
  final swipe = _seg(t, 0.18, 0.50, curve: Curves.easeInOutCubic);
  final collapse = _seg(t, 0.56, 0.68);
  final toast = _seg(t, 0.62, 0.76);
  return LayoutBuilder(
    builder: (context, c) {
      const rowHeight = 58.0;
      final rowTop = c.maxHeight * 0.22;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          // What the swipe answers, shown behind the moving card.
          Positioned(
            top: rowTop,
            left: 0,
            right: 0,
            height: rowHeight,
            child: Opacity(
              opacity: (1 - collapse) * _seg(t, 0.18, 0.24),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.close_rounded,
                      color: Colors.grey[700],
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Hindi ko alam',
                      style: TextStyle(
                        color: Colors.grey[700],
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: rowTop,
            left: c.maxWidth * 1.1 * swipe,
            width: c.maxWidth,
            child: Opacity(
              opacity: appear,
              child: _mockEvent(
                _boltMild,
                'Bahagyang mataas na konsumo',
                '8:10 AM–8:15 AM · hanggang 778 W',
              ),
            ),
          ),
          Positioned(
            top: rowTop + 18,
            left: lerpDouble(c.maxWidth * 0.30, c.maxWidth * 0.95, swipe),
            child: _finger(
              opacity: _seg(t, 0.08, 0.16) * (1 - _seg(t, 0.46, 0.54)),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: lerpDouble(-10, 14, toast),
            child: Opacity(
              opacity: toast,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: _hairline),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: _orange,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Marked as not sure.',
                        style: TextStyle(
                          color: _ink,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 10),
                      child: Text(
                        'Undo',
                        style: TextStyle(
                          color: _orange,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

Widget _householdScene(double t) {
  final tap = _seg(t, 0.10, 0.28, curve: Curves.easeInOutCubic);
  final answered = _seg(t, 0.30, 0.42);
  return Row(
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: [
      for (var i = 0; i < 3; i++)
        Builder(
          builder: (context) {
            // The answer lands on the middle phone first, then the others.
            final clear = _seg(
              t,
              0.46 + (i == 1 ? 0 : 0.08),
              0.62 + (i == 1 ? 0 : 0.08),
            );
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 76,
                  height: 136,
                  padding: const EdgeInsets.fromLTRB(8, 18, 8, 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _ink.withValues(alpha: 0.75),
                      width: 2.5,
                    ),
                  ),
                  child: Column(
                    children: [
                      Opacity(
                        opacity: 1 - clear,
                        child: Transform.scale(
                          scale: 1 - 0.2 * clear,
                          child: Container(
                            height: 30,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            decoration: BoxDecoration(
                              color: _well,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: i == 1
                                        ? Color.lerp(
                                            _orange,
                                            Colors.green.shade600,
                                            answered,
                                          )
                                        : _orange,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Container(
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: _barGrey,
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const Spacer(),
                      Opacity(
                        opacity: clear,
                        child: Icon(
                          Icons.check_circle_rounded,
                          color: Colors.green.shade600,
                          size: 26,
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
                if (i == 1)
                  Positioned(
                    left: lerpDouble(40, 22, tap),
                    top: lerpDouble(110, 26, tap),
                    child: _finger(
                      opacity: _seg(t, 0.04, 0.10) * (1 - _seg(t, 0.40, 0.48)),
                    ),
                  ),
              ],
            );
          },
        ),
    ],
  );
}
