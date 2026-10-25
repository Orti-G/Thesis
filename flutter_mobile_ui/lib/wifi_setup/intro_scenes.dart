import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'setup_ui.dart';

/// The intro's three scenes: small animations drawn in code that show what
/// GRID does (live power, the bill in pesos, a tip that lowers use) so the
/// page needs only a few words. Everything is bare off-white on the orange
/// field, with white only for the one tip chip. Numbers are samples and say
/// so. Reduce-motion shows each scene finished.

const List<BoxShadow> _kChipShadow = [BoxShadow(color: Color(0x337A2E05), blurRadius: 20, offset: Offset(0, 8))];

const TextStyle _kNumber = TextStyle(
  fontFamily: kSetupFont,
  fontSize: 40,
  height: 1.08,
  fontWeight: FontWeight.w400,
  letterSpacing: -1.2,
  color: kSetupOnField,
  fontFeatures: [FontFeature.tabularFigures()],
);
const TextStyle _kSmall = TextStyle(
  fontFamily: kSetupFont,
  fontSize: 13,
  height: 1.45,
  fontWeight: FontWeight.w600,
  color: kSetupOnField,
);

/// Drives one scene: [t] runs 0 to 1 over [duration], once or looping, and is
/// parked at 1 under reduce-motion.
class _Scene extends StatefulWidget {
  final Duration duration;
  final Widget Function(BuildContext context, double t) builder;
  const _Scene({required this.duration, required this.builder});

  @override
  State<_Scene> createState() => _SceneState();
}

class _SceneState extends State<_Scene> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.duration);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.value = 1;
    } else {
      // A short beat so the page has settled before the scene starts.
      Future<void>.delayed(const Duration(milliseconds: 350), () {
        if (!mounted) return;
        _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: _c, builder: (context, _) => widget.builder(context, _c.value));
}

// ── 1. Live power ───────────────────────────────────────────────────────────

/// A power line draws itself across the page while the watt figure follows
/// its head.
class LiveScene extends StatelessWidget {
  const LiveScene({super.key});

  static double _v(double x) =>
      0.5 + 0.20 * math.sin(x * 2 * math.pi * 1.4) + 0.10 * math.sin(x * 2 * math.pi * 3.3 + 1.2) + 0.08 * math.sin(x * 2 * math.pi * 7 + 0.4);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Sample animation: a live power line rising and falling.',
      child: ExcludeSemantics(
        child: _Scene(
          // Draws once and holds its finished line.
          duration: const Duration(milliseconds: 1500),
          builder: (context, t) {
            final reduce = MediaQuery.disableAnimationsOf(context);
            final p = reduce ? 1.0 : Curves.easeInOut.transform(t);
            final watts = (150 + _v(p) * 700).round();
            return Stack(
              children: [
                Positioned.fill(child: CustomPaint(painter: _LinePainter(p: p, ring: reduce || t >= 1 ? 0 : (t * 3) % 1))),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('$watts', style: _kNumber),
                    const SizedBox(width: 8),
                    const Padding(padding: EdgeInsets.only(bottom: 6), child: Text('watts · sample', style: _kSmall)),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  final double p;
  final double ring;
  const _LinePainter({required this.p, required this.ring});

  @override
  void paint(Canvas canvas, Size size) {
    final top = 96.0;
    final bottom = size.height - 8;
    if (bottom <= top) return;
    double y(double x) => bottom - LiveScene._v(x) * (bottom - top);

    canvas.drawLine(
      Offset(0, bottom),
      Offset(size.width, bottom),
      Paint()
        ..color = const Color(0x4DFAFAFA)
        ..strokeWidth = 1.5,
    );

    final headX = p * size.width;
    final line = Path()..moveTo(0, y(0));
    for (var x = 4.0; x < headX; x += 4) {
      line.lineTo(x, y(x / size.width));
    }
    line.lineTo(headX, y(p));

    final fill = Path.from(line)
      ..lineTo(headX, bottom)
      ..lineTo(0, bottom)
      ..close();
    canvas.drawPath(fill, Paint()..color = const Color(0x1FFAFAFA));
    canvas.drawPath(
      line,
      Paint()
        ..color = kSetupOnField
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    final head = Offset(headX, y(p));
    if (ring > 0) {
      canvas.drawCircle(
        head,
        8 + 22 * ring,
        Paint()
          ..color = kSetupOnField.withValues(alpha: 0.5 * (1 - ring))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    canvas.drawCircle(head, 7, Paint()..color = kSetupOnField);
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.p != p || old.ring != ring;
}

// ── 2. The bill ─────────────────────────────────────────────────────────────

/// A gauge fills around a peso figure that counts up to its value.
class BillScene extends StatelessWidget {
  const BillScene({super.key});

  static const double _amount = 1850;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Sample animation: an estimated monthly bill counting up in pesos.',
      child: ExcludeSemantics(
        child: _Scene(
          duration: const Duration(milliseconds: 2400),
          builder: (context, t) {
            final p = Curves.easeOutCubic.transform(t);
            final shown = (_amount * p).round();
            return Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(child: CustomPaint(painter: _GaugePainter(p: p * 0.72))),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('₱${_withCommas(shown)}', style: _kNumber),
                    const SizedBox(height: 4),
                    const Text('this month · sample', style: _kSmall),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static String _withCommas(int v) {
    final s = v.toString();
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
      out.write(s[i]);
    }
    return out.toString();
  }
}

class _GaugePainter extends CustomPainter {
  final double p; // 0..1 of the full 270° sweep
  const _GaugePainter({required this.p});

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width, size.height) / 2 - 16;
    if (r <= 0) return;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: r);
    const start = 0.75 * math.pi;
    const sweep = 1.5 * math.pi;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, start, sweep, false, stroke..color = const Color(0x4DFAFAFA));
    if (p > 0) canvas.drawArc(rect, start, sweep * p, false, stroke..color = kSetupOnField);
  }

  @override
  bool shouldRepaint(_GaugePainter old) => old.p != p;
}

// ── 3. An unusual spike ─────────────────────────────────────────────────────

/// Bars for the week rise evenly; then one shoots far above the rest, a ring
/// pulses off its top, and a warning chip pops in and gives a little shake.
class AlertScene extends StatelessWidget {
  const AlertScene({super.key});

  static const List<double> _base = [0.45, 0.52, 0.40, 0.55, 0.50, 0.46, 0.42];
  static const int _spike = 4;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Sample animation: one usage bar jumps far above the rest and a warning appears.',
      child: ExcludeSemantics(
        child: _Scene(
          duration: const Duration(milliseconds: 4200),
          builder: (context, t) {
            final chip = Curves.easeOutBack.transform(((t - 0.64) / 0.14).clamp(0.0, 1.0));
            // A short side-to-side shake right after the chip lands.
            final shakeT = ((t - 0.78) / 0.14).clamp(0.0, 1.0);
            final shake = math.sin(shakeT * math.pi * 6) * (1 - shakeT) * 5;
            return Stack(
              children: [
                Positioned.fill(child: CustomPaint(painter: _BarsPainter(t: t))),
                Align(
                  alignment: Alignment.topLeft,
                  child: Transform.translate(
                    offset: Offset(shake, 0),
                    child: Transform.scale(
                      scale: chip,
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(14, 10, 20, 10),
                        decoration: BoxDecoration(color: kSetupPanel, borderRadius: BorderRadius.circular(9999), boxShadow: _kChipShadow),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.warning_amber_rounded, size: 24, color: kSetupDanger),
                            SizedBox(width: 10),
                            Text(
                              'Usage looks unusual',
                              style: TextStyle(fontFamily: kSetupFont, fontSize: 16, height: 1.3, fontWeight: FontWeight.w600, color: kSetupInk),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final double t;
  const _BarsPainter({required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    const count = 7;
    const gap = 10.0;
    final area = Rect.fromLTRB(0, 72, size.width, size.height - 8);
    if (area.height <= 0) return;
    final w = (area.width - gap * (count - 1)) / count;
    final spike = Curves.easeOutBack.transform(((t - 0.48) / 0.16).clamp(0.0, 1.0));

    canvas.drawLine(
      Offset(0, area.bottom),
      Offset(size.width, area.bottom),
      Paint()
        ..color = const Color(0x4DFAFAFA)
        ..strokeWidth = 1.5,
    );

    for (var i = 0; i < count; i++) {
      final grow = Curves.easeOutBack.transform(((t - 0.02 * i) / 0.3).clamp(0.0, 1.0));
      final isSpike = i == AlertScene._spike;
      var f = AlertScene._base[i];
      if (isSpike) f = f + (1.0 - f) * spike;
      final h = math.min(area.height * f * grow, area.height);
      final x = i * (w + gap);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, area.bottom - h, w, h), const Radius.circular(8)),
        Paint()..color = isSpike ? kSetupOnField : const Color(0x80FAFAFA),
      );

      // A ring pulses off the top of the spike once it has landed.
      if (isSpike && t > 0.62) {
        final ring = ((t - 0.62) / 0.3).clamp(0.0, 1.0);
        canvas.drawCircle(
          Offset(x + w / 2, area.bottom - h),
          10 + 26 * ring,
          Paint()
            ..color = kSetupOnField.withValues(alpha: 0.6 * (1 - ring))
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.t != t;
}
