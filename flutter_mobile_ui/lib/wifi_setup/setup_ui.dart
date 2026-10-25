import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lottie/lottie.dart';

/// Shared look for the device setup flow (and the standalone Device ID
/// screen): a few calm sentences on a GRID-orange page.
///
/// * Field: full-bleed brand orange #FA8B39, shading very slightly deeper
///   toward the bottom. Light text on it is low contrast (about 2.3:1), a
///   trade the user chose for a softer orange.
/// * On the field everything is soft off-white #FAFAFA, never black. Small
///   text is semibold, since the field leaves it little contrast to spare.
/// * Type: Plus Jakarta Sans, held to 4 sizes (40 / 22 / 16 / 13) and 2
///   weights (400 / 600). Headlines are large, regular and left-aligned.
/// * White rounded panels appear only where something has to be read or
///   picked: lists, code cells, sheets. Text inside them is the GRID logo's
///   dark brown. No icon tiles, glows or labels above headings.
/// * Actions: a round #FAFAFA arrow for a simple "next", or a full-width
///   #FAFAFA pill with a deep-orange label and arrow. Inside white sheets
///   the pill flips to solid deep orange with #FAFAFA text.

// ── Tokens ──────────────────────────────────────────────────────────────────

const String kSetupFont = 'PlusJakartaSans';

/// GRID brand orange: the page field. #FAFAFA text on it is about 2.3:1 — below the usual
/// minimums, accepted by the user in exchange for a softer field (the
/// deeper #E06A17 read as too strong). Small text is semibold to help.
const Color kSetupField = Color(0xFFFA8B39);
const Color _kSetupFieldDeep = Color(0xFFF6843A);

/// Text, icons and controls on the orange field: soft off-white, never
/// black.
const Color kSetupOnField = Color(0xFFFAFAFA);

/// Deep orange for labels and arrows on #FAFAFA buttons, and focus rings
/// and carets in white fields (about 5:1 on white).
const Color kSetupAccent = Color(0xFFC2410C);

/// Soft orange tint behind the arrow on #FAFAFA buttons.
const Color _kSetupAccentTint = Color(0xFFFCE3D2);

/// Ink: the GRID logo's dark brown, for text on white panels only (lists,
/// code boxes, sheets).
const Color kSetupInk = Color(0xFF2B1309);

/// Body text on the orange field. Full #FAFAFA, never faded, since the
/// field gives it little contrast to spare; set semibold to help.
const Color kSetupBody = kSetupOnField;

/// Secondary text on white panels: ink at 64%.
const Color kSetupMuted = Color(0xA32B1309);

const Color kSetupPanel = Colors.white;
const Color kSetupHairline = Color(0xFFF2E7DF);
const Color kSetupDanger = Color(0xFFB42318);

/// Kept for screens that fall back to a plain page while state loads.
const Color kSetupBg = kSetupField;

/// Where the product photo of the monitor goes. Until the file exists, a
/// labeled placeholder is drawn in its place.
const String kSetupPhotoAsset = 'assets/setup/monitor.png';

/// A close-up of the monitor's screen, for the wide band on the pairing and
/// Device ID steps.
const String kSetupScreenPhotoAsset = 'assets/setup/monitor-screen.png';

/// Soft, warm-tinted elevation for white panels and ink buttons on the
/// orange field — never grey.
const List<BoxShadow> _kPanelShadow = [BoxShadow(color: Color(0x1F7A2E05), blurRadius: 24, offset: Offset(0, 8))];
const List<BoxShadow> _kButtonShadow = [BoxShadow(color: Color(0x337A2E05), blurRadius: 20, offset: Offset(0, 8))];

// Type scale: 40 / 22 / 16 / 13, weights 400 / 600.
const TextStyle _kDisplay = TextStyle(
  fontFamily: kSetupFont,
  fontSize: 40,
  height: 1.08,
  fontWeight: FontWeight.w400,
  letterSpacing: -1.2,
  color: kSetupOnField,
);
const TextStyle _kTitle = TextStyle(
  fontFamily: kSetupFont,
  fontSize: 22,
  height: 1.25,
  fontWeight: FontWeight.w600,
  letterSpacing: -0.3,
  color: kSetupInk,
);
const TextStyle _kBody = TextStyle(
  fontFamily: kSetupFont,
  fontSize: 16,
  height: 1.5,
  fontWeight: FontWeight.w600,
  color: kSetupBody,
);
const TextStyle _kLabel = TextStyle(
  fontFamily: kSetupFont,
  fontSize: 16,
  height: 1.3,
  fontWeight: FontWeight.w600,
  color: kSetupInk,
);
const TextStyle _kCaption = TextStyle(fontFamily: kSetupFont, fontSize: 13, height: 1.45, color: kSetupMuted);

enum SetupTone { brand, success, danger, neutral }

bool _reduceMotion(BuildContext context) => MediaQuery.disableAnimationsOf(context);

/// Applies the setup font to everything Material draws itself (text fields,
/// labels, errors, tooltips) so the whole page reads as one typeface.
Widget _withSetupFont(BuildContext context, Widget child) {
  final theme = Theme.of(context);
  return Theme(
    data: theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: kSetupFont),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: kSetupAccent,
        selectionColor: Color(0x40C2410C),
        selectionHandleColor: kSetupAccent,
      ),
    ),
    child: DefaultTextStyle.merge(
      style: const TextStyle(fontFamily: kSetupFont),
      child: child,
    ),
  );
}

// ── Routes & page scaffold ──────────────────────────────────────────────────

/// Route used between setup screens. The new screen fades in over the old
/// one: the orange field and header sit in the same place on every screen,
/// so the flow reads as one continuous page while only the words change.
Route<T> setupRoute<T>({required WidgetBuilder builder, String? name}) {
  return PageRouteBuilder<T>(
    settings: RouteSettings(name: name),
    transitionDuration: const Duration(milliseconds: 320),
    reverseTransitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (context, _, _) => builder(context),
    transitionsBuilder: (context, animation, _, child) {
      if (_reduceMotion(context)) return child;
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      );
    },
  );
}

/// Number of background arrangements [_BackdropPainter] knows (0–9).
const int _kBackdropVariants = 10;

/// How long the shapes take to drift through one full cycle.
const Duration _kDriftCycle = Duration(seconds: 28);

/// The orange page every setup screen sits on, with light system-bar icons
/// and a randomly chosen arrangement of soft background shapes.
///
/// The arrangement is picked once when the screen opens and kept while it
/// stays up, so states swapping in place don't reshuffle it. A new screen
/// never repeats the one before it.
class _SetupField extends StatefulWidget {
  final Widget child;

  /// Paints the soft background shapes behind [child].
  final bool backdrop;

  /// Fixes the arrangement (0–9) instead of picking one at random.
  final int? backdropStyle;

  /// Lets the shapes glide slowly. Skipped under reduce-motion.
  final bool drift;
  const _SetupField({required this.child, this.backdrop = true, this.backdropStyle, this.drift = false});

  @override
  State<_SetupField> createState() => _SetupFieldState();
}

class _SetupFieldState extends State<_SetupField> with SingleTickerProviderStateMixin {
  static final math.Random _random = math.Random();
  static int? _last;

  late final int _style = widget.backdropStyle ?? _pick();
  late final AnimationController _drift = AnimationController(vsync: this, duration: _kDriftCycle);

  static int _pick() {
    var style = _random.nextInt(_kBackdropVariants);
    if (style == _last) style = (style + 1 + _random.nextInt(_kBackdropVariants - 1)) % _kBackdropVariants;
    return _last = style;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Ticker mode (set by the navigator) pauses it while another screen
    // covers this one.
    if (widget.drift && widget.backdrop && !_reduceMotion(context)) {
      if (!_drift.isAnimating) _drift.repeat();
    } else {
      _drift.stop();
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animated = widget.drift && widget.backdrop && !_reduceMotion(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: _kSetupFieldDeep,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [kSetupField, _kSetupFieldDeep],
          ),
        ),
        child: widget.backdrop
            ? Stack(
                fit: StackFit.expand,
                children: [
                  // Its own layer, so the shapes repaint (or just sit
                  // cached) without touching the screen's content above.
                  RepaintBoundary(
                    child: CustomPaint(painter: _BackdropPainter(_style, animated ? _drift : null)),
                  ),
                  widget.child,
                ],
              )
            : widget.child,
      ),
    );
  }
}

/// Large, quiet shapes behind a screen's content: softened lightning bolts,
/// capsules, discs and rings. Tones sit within a few percent of the field so
/// they read as texture, never as content. [variant] picks the arrangement;
/// 0 is the approved one, 1–4 are alternatives under comparison.
class _BackdropPainter extends CustomPainter {
  final int variant;

  /// 0→1 over one drift cycle, or null to hold the shapes still. Repaints
  /// the painter whenever it ticks.
  final Animation<double>? drift;

  _BackdropPainter(this.variant, this.drift) : super(repaint: drift);

  static const _light = Color(0x14FAFAFA);

  // Per-paint scratch: the page width and how many shapes have been drawn,
  // so each shape gets its own drift.
  double _width = 0;
  int _shapeIndex = 0;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    _width = w;
    _shapeIndex = 0;

    switch (variant) {
      case 1:
        // Grid: a tilted lattice of rounded squares, nodding to the GRID
        // name, bleeding off the bottom right; a big disc off the top left.
        _disc(canvas, Offset(w * -0.05, h * 0.06), w * 0.5);
        _lattice(canvas, Offset(w * 0.9, h * 0.8), 0.2, w * 0.2, w * 0.05);
        _lattice(canvas, Offset(w * 0.88, h * 0.2), -0.3, w * 0.07, w * 0.02);
        _capsule(canvas, Offset(w * 0.02, h * 0.56), 0.9, w * 0.55, w * 0.14);
        _disc(canvas, Offset(w * 0.34, h * 0.9), w * 0.12);
        _disc(canvas, Offset(w * 0.56, h * 0.62), w * 0.035, deep: true);
      case 2:
        // Signal: thick arcs radiating from the bottom left corner, like a
        // connection coming online, with a dot at their source. A thinner
        // pair answers from the top right.
        for (final r in [0.5, 0.82, 1.14]) {
          _arc(canvas, Offset(0, h), w * r, w * 0.13);
        }
        for (final r in [0.28, 0.5]) {
          _arc(canvas, Offset(w, 0), w * r, w * 0.07, start: math.pi / 2);
        }
        _disc(canvas, Offset(w * 0.9, h * 0.1), w * 0.07);
        _disc(canvas, Offset(w * 0.74, h * 0.2), w * 0.035);
        _disc(canvas, Offset(w * 0.9, h * 0.58), w * 0.2, deep: true);
        _disc(canvas, Offset(w * 0.5, h * 0.48), w * 0.05);
        _dots(canvas, Offset(w * 0.08, h * 0.44), 3, 3, w * 0.07, w * 0.012);
      case 3:
        // Pebbles: soft overlapping circles of different sizes and tints.
        _disc(canvas, Offset(w * 0.1, h * 0.78), w * 0.55);
        _disc(canvas, Offset(w * 0.92, h * 0.52), w * 0.3, deep: true);
        _disc(canvas, Offset(w * 0.62, h * 0.9), w * 0.2);
        _disc(canvas, Offset(w * 0.8, h * 0.14), w * 0.12, deep: true);
        _disc(canvas, Offset(w * 0.22, h * 0.36), w * 0.08);
        _disc(canvas, Offset(w * 0.5, h * 0.7), w * 0.045, deep: true);
        _disc(canvas, Offset(w * 0.12, h * 0.1), w * 0.14);
        _capsule(canvas, Offset(w * 0.7, h * 0.34), -0.5, w * 0.4, w * 0.1);
        _dots(canvas, Offset(w * 0.62, h * 0.72), 4, 3, w * 0.06, w * 0.01);
      case 4:
        // Tide: a soft wave filling the bottom of the page, a second one
        // behind it, a patch of small dots above, and a low sun with a few
        // companions.
        _disc(canvas, Offset(w * 0.2, h * 0.5), w * 0.17, deep: true);
        _wave(canvas, size, h * 0.66, w * 0.07, deep: true);
        _wave(canvas, size, h * 0.74, w * 0.06, phase: 1.4);
        _dots(canvas, Offset(w * 0.58, h * 0.1), 6, 4, w * 0.075, w * 0.012);
        _disc(canvas, Offset(w * 0.86, h * 0.44), w * 0.05);
        _disc(canvas, Offset(w * 0.46, h * 0.56), w * 0.06);
        _disc(canvas, Offset(w * 0.1, h * 0.28), w * 0.04);
      case 5:
        // Orbit: arcs sweeping out of the top left corner around a deep
        // disc, a long capsule low down.
        _disc(canvas, Offset(w * 0.78, h * 0.34), w * 0.32, deep: true);
        for (final r in [0.45, 0.75, 1.05]) {
          _arc(canvas, Offset.zero, w * r, w * 0.11, start: 0);
        }
        _capsule(canvas, Offset(w * 0.5, h * 0.9), -0.25, w * 0.8, w * 0.18);
        _disc(canvas, Offset(w * 0.9, h * 0.8), w * 0.1);
        _lattice(canvas, Offset(w * 0.14, h * 0.7), 0.15, w * 0.09, w * 0.025);
        _dots(canvas, Offset(w * 0.62, h * 0.58), 3, 2, w * 0.06, w * 0.011);
      case 6:
        // Stacks: parallel bars of different lengths and weights down the
        // right, a big disc and a small lattice up top.
        _capsule(canvas, Offset(w * 0.8, h * 0.62), -0.6, w * 1.1, w * 0.12);
        _capsule(canvas, Offset(w * 0.86, h * 0.7), -0.6, w * 0.8, w * 0.16, deep: true);
        _capsule(canvas, Offset(w * 0.9, h * 0.8), -0.6, w * 1.2, w * 0.1);
        _capsule(canvas, Offset(w * 0.8, h * 0.9), -0.6, w * 0.9, w * 0.18, deep: true);
        _disc(canvas, Offset(w * 0.1, h * 0.14), w * 0.3);
        _lattice(canvas, Offset(w * 0.8, h * 0.16), 0.25, w * 0.1, w * 0.03);
        _disc(canvas, Offset(w * 0.3, h * 0.52), w * 0.06, deep: true);
        _dots(canvas, Offset(w * 0.1, h * 0.78), 4, 2, w * 0.06, w * 0.011);
      case 7:
        // Dunes: three waves of different heights and phases, a pale sun at
        // the top right and a tilted capsule at the left.
        _disc(canvas, Offset(w * 0.88, h * 0.14), w * 0.26);
        _wave(canvas, size, h * 0.58, w * 0.05, phase: 0.4, deep: true);
        _wave(canvas, size, h * 0.68, w * 0.07, phase: 2.0);
        _wave(canvas, size, h * 0.8, w * 0.05, phase: 3.6, deep: true);
        _capsule(canvas, Offset(w * 0.16, h * 0.3), 0.5, w * 0.5, w * 0.12);
        _disc(canvas, Offset(w * 0.4, h * 0.42), w * 0.05, deep: true);
        _dots(canvas, Offset(w * 0.08, h * 0.48), 5, 2, w * 0.06, w * 0.011);
      case 8:
        // Bloom: solid discs and arcs widening out of the bottom right
        // corner, a lattice and a capsule answering from the left.
        _disc(canvas, Offset(w, h), w * 0.5);
        _disc(canvas, Offset(w, h), w * 0.3, deep: true);
        for (final r in [0.8, 1.1]) {
          _arc(canvas, Offset(w, h), w * r, w * 0.1, start: math.pi);
        }
        _lattice(canvas, Offset(w * 0.16, h * 0.2), -0.2, w * 0.12, w * 0.03);
        _disc(canvas, Offset(w * 0.5, h * 0.3), w * 0.07);
        _capsule(canvas, Offset(w * 0.2, h * 0.6), 0.6, w * 0.5, w * 0.12);
        _disc(canvas, Offset(w * 0.12, h * 0.88), w * 0.12, deep: true);
      case 9:
        // Drift: a lattice at the bottom left, arcs in the top right corner,
        // a deep disc on the right edge, a capsule and a low wave.
        _lattice(canvas, Offset(w * 0.12, h * 0.82), 0.3, w * 0.16, w * 0.04);
        for (final r in [0.4, 0.7]) {
          _arc(canvas, Offset(w, 0), w * r, w * 0.1, start: math.pi / 2);
        }
        _disc(canvas, Offset(w * 0.92, h * 0.52), w * 0.22, deep: true);
        _disc(canvas, Offset(w * 0.68, h * 0.74), w * 0.12);
        _capsule(canvas, Offset(w * 0.3, h * 0.34), -0.5, w * 0.6, w * 0.14);
        _wave(canvas, size, h * 0.9, w * 0.04, phase: 1.0);
        _dots(canvas, Offset(w * 0.55, h * 0.46), 3, 3, w * 0.06, w * 0.011);
      default:
        // The approved one: capsule top left, disc top right, bolt in the
        // middle.
        _capsule(canvas, Offset(w * 0.18, h * 0.2), -0.62, w * 1.25, w * 0.46);
        _disc(canvas, Offset(w * 1.0, h * 0.04), w * 0.42);
        _bolt(canvas, Offset(w * 0.5, h * 0.5), w * 0.7, w * 0.8);
    }
  }

  static const _deepTint = Color(0x14C2410C);

  /// Runs [draw] shifted by this shape's slow drift. Every shape takes the
  /// next index, so each moves at its own amplitude, phase and speed (one or
  /// two loops per cycle, so the cycle repeats without a jump). Without a
  /// drift animation the shape is simply drawn in place.
  void _moved(Canvas canvas, VoidCallback draw, {bool horizontal = true}) {
    final t = drift?.value;
    if (t == null) {
      draw();
      return;
    }
    final i = _shapeIndex++;
    final turns = (t * (1 + i % 2) + i * 0.37) * 2 * math.pi;
    final amplitude = _width * (0.02 + 0.01 * (i % 3));
    canvas.save();
    canvas.translate(horizontal ? math.sin(turns) * amplitude : 0, math.cos(turns + 1) * amplitude * 0.8);
    draw();
    canvas.restore();
  }

  /// A 3 × 3 block of rounded squares, tilted by [angle] about [center],
  /// alternating the light and deep solid tints.
  void _lattice(Canvas canvas, Offset center, double angle, double cell, double gap) {
    _moved(canvas, () {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(angle);
      final span = cell * 3 + gap * 2;
      for (var row = 0; row < 3; row++) {
        for (var col = 0; col < 3; col++) {
          final rect = Rect.fromLTWH(col * (cell + gap) - span / 2, row * (cell + gap) - span / 2, cell, cell);
          final rrect = RRect.fromRectAndRadius(rect, Radius.circular(cell * 0.28));
          canvas.drawRRect(rrect, Paint()..color = (row + col).isEven ? _light : _deepTint);
        }
      }
      canvas.restore();
    });
  }

  /// A quarter-turn band of [thickness] at [radius] about [center], with
  /// rounded ends, starting at angle [start] (default: straight up).
  void _arc(Canvas canvas, Offset center, double radius, double thickness, {double start = -math.pi / 2}) {
    _moved(canvas, () {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        math.pi / 2,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = thickness
          ..strokeCap = StrokeCap.round
          ..color = _light,
      );
    });
  }

  /// A filled sine wave whose crest line sits at [top] and runs past the
  /// bottom of [size], so drifting up never shows a gap under it. It only
  /// drifts up and down, since it already spans the full width.
  void _wave(Canvas canvas, Size size, double top, double amplitude, {double phase = 0, bool deep = false}) {
    _moved(canvas, horizontal: false, () {
      final floor = size.height + size.width * 0.1;
      final path = Path()..moveTo(0, floor);
      const steps = 48;
      for (var i = 0; i <= steps; i++) {
        final x = size.width * i / steps;
        final y = top + math.sin(i / steps * math.pi * 2 + phase) * amplitude;
        path.lineTo(x, y);
      }
      path
        ..lineTo(size.width, floor)
        ..close();
      canvas.drawPath(path, Paint()..color = deep ? _deepTint : _light);
    });
  }

  /// A [columns] × [rows] patch of small dots, [pitch] apart.
  void _dots(Canvas canvas, Offset origin, int columns, int rows, double pitch, double radius) {
    _moved(canvas, () {
      final paint = Paint()..color = const Color(0x24FAFAFA);
      for (var row = 0; row < rows; row++) {
        for (var col = 0; col < columns; col++) {
          canvas.drawCircle(origin + Offset(col * pitch, row * pitch), radius, paint);
        }
      }
    });
  }

  void _capsule(Canvas canvas, Offset center, double angle, double length, double thickness, {bool deep = false}) {
    _moved(canvas, () {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(angle);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: length, height: thickness),
          Radius.circular(thickness / 2),
        ),
        Paint()..color = deep ? _deepTint : _light,
      );
      canvas.restore();
    });
  }

  void _disc(Canvas canvas, Offset center, double radius, {bool deep = false}) {
    _moved(canvas, () => canvas.drawCircle(center, radius, Paint()..color = deep ? _deepTint : _light));
  }


  /// Lightning bolt with softened corners, [width] × [height] with its
  /// top-left at [origin] (before [angle], which turns it about [origin]). A
  /// round-joined stroke rounds the points; fill and stroke are drawn in one
  /// opaque layer and composited at the shape's alpha so they don't double
  /// up where they overlap.
  void _bolt(Canvas canvas, Offset origin, double width, double height, {double angle = 0}) {
    Offset p(double x, double y) => Offset(x * width, y * height);
    final a = p(0.58, 0);
    final b = p(0.12, 0.56);
    final c = p(0.45, 0.56);
    final d = p(0.32, 1.0);
    final e = p(0.88, 0.4);
    final f = p(0.52, 0.4);
    final bolt = Path()
      ..moveTo(a.dx, a.dy)
      ..lineTo(b.dx, b.dy)
      ..lineTo(c.dx, c.dy)
      ..lineTo(d.dx, d.dy)
      ..lineTo(e.dx, e.dy)
      ..lineTo(f.dx, f.dy)
      ..close();
    final softness = width * 0.04 / 0.7;
    final solid = Paint()..color = const Color(0xFFC2410C);
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.rotate(angle);
    canvas.saveLayer(bolt.getBounds().inflate(softness), Paint()..color = const Color(0x14FFFFFF));
    canvas.drawPath(bolt, solid);
    canvas.drawPath(
      bolt,
      solid
        ..style = PaintingStyle.stroke
        ..strokeWidth = softness * 2
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BackdropPainter old) => old.variant != variant || old.drift != drift;
}

/// One layout for every setup screen: back arrow, an optional trailing
/// action and the progress bar in the header; a large left-aligned title
/// and subtitle, optional [hero] and scrolling content; the action pinned
/// at the bottom in the thumb zone (riding above the keyboard).
///
/// Pass [body] instead of [title] to lay out the middle yourself (the
/// swipeable intro does this) while keeping the same field and footer.
class SetupScaffold extends StatelessWidget {
  final int? step;
  final int? totalSteps;
  final Widget? hero;

  /// Draws [hero] above the title instead of below it, for the closing
  /// check mark.
  final bool heroAbove;
  final String? title;
  final String? subtitle;
  final List<Widget> content;
  final Widget? body;
  final Widget? bottom;
  final bool showBack;
  final Widget? trailing;

  /// Lets [body] run under the bottom system inset, for a photo that bleeds
  /// off the screen edge. The body then pads its own controls.
  final bool bleedBottom;

  /// Draws the soft background shapes. On by default; a screen can opt out.
  final bool backdrop;

  /// Fixes which arrangement of shapes [backdrop] draws (0–9). Null picks
  /// one at random each time the screen opens; Test Mode sets it to compare.
  final int? backdropStyle;

  /// Lets the backdrop shapes glide slowly. Only the Test Mode comparison
  /// pages turn this on for now.
  final bool drift;

  const SetupScaffold({
    super.key,
    this.step,
    this.totalSteps,
    this.hero,
    this.heroAbove = false,
    this.title,
    this.subtitle,
    this.content = const [],
    this.body,
    this.bottom,
    this.showBack = true,
    this.trailing,
    this.bleedBottom = false,
    this.backdrop = true,
    this.backdropStyle,
    this.drift = false,
  }) : assert((title == null) != (body == null), 'Pass either a title or a body.');

  @override
  Widget build(BuildContext context) {
    final hasSteps = step != null && totalSteps != null;
    final hasHeader = showBack || hasSteps || trailing != null;

    return _withSetupFont(
      context,
      Scaffold(
        backgroundColor: kSetupField,
        body: _SetupField(
          backdrop: backdrop,
          backdropStyle: backdropStyle,
          drift: drift,
          child: SafeArea(
            bottom: !bleedBottom,
            child: Column(
              children: [
                // An empty header row would only push the page down.
                if (hasHeader)
                  SizedBox(
                    height: 56,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          if (showBack) const _BackButton() else const SizedBox(width: 16),
                          const Spacer(),
                          ?trailing,
                          if (hasSteps) ...[
                            const SizedBox(width: 8),
                            _StepBar(step: step!, total: totalSteps!),
                            const SizedBox(width: 16),
                          ],
                        ],
                      ),
                    ),
                  )
                else
                  const SizedBox(height: 24),
                Expanded(
                  child:
                      body ??
                      SetupPageBody(
                        hero: hero,
                        heroAbove: heroAbove,
                        title: title!,
                        subtitle: subtitle,
                        content: content,
                      ),
                ),
                if (bottom != null) Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 24), child: bottom!),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The scrolling middle of a setup screen: title and subtitle, then the
/// optional [hero] and [content]. The hero folds away while the keyboard
/// is up so the field being typed into stays in view.
class SetupPageBody extends StatelessWidget {
  final Widget? hero;
  final bool heroAbove;
  final String title;
  final String? subtitle;
  final List<Widget> content;

  const SetupPageBody({
    super.key,
    this.hero,
    this.heroAbove = false,
    required this.title,
    this.subtitle,
    this.content = const [],
  });

  @override
  Widget build(BuildContext context) {
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    final reduceMotion = _reduceMotion(context);
    final heroBlock = hero == null
        ? null
        : AnimatedSize(
            duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topLeft,
            child: keyboardUp
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: EdgeInsets.only(top: heroAbove ? 0 : 32, bottom: heroAbove ? 32 : 0),
                    child: hero,
                  ),
          );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (heroAbove) ?heroBlock,
          // Crossfade when a screen swaps states in place
          // (e.g. "Enter the pairing code" → "Pairing…").
          AnimatedSwitcher(
            duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 220),
            layoutBuilder: (current, previous) =>
                Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
            child: SetupTitle(key: ValueKey(title), title: title, subtitle: subtitle),
          ),
          if (!heroAbove) ?heroBlock,
          if (content.isNotEmpty) const SizedBox(height: 32),
          ...content,
        ],
      ),
    );
  }
}

/// The large left-aligned headline and its supporting line.
class SetupTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  const SetupTitle({super.key, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(header: true, child: Text(title, style: _kDisplay)),
          if (subtitle != null) ...[const SizedBox(height: 12), Text(subtitle!, style: _kBody)],
        ],
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton();

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Back',
      onPressed: () => Navigator.of(context).maybePop(),
      icon: const Icon(Icons.arrow_back_rounded, color: kSetupOnField),
      style: IconButton.styleFrom(minimumSize: const Size(48, 48), highlightColor: const Color(0x1FFAFAFA)),
    );
  }
}

/// Segmented progress bar in #FAFAFA: finished steps are solid, and the current
/// step's segment fills in when its screen opens. Every screen draws it in
/// the same place, so across the crossfade it reads as one bar filling up.
class _StepBar extends StatelessWidget {
  final int step;
  final int total;
  const _StepBar({required this.step, required this.total});

  @override
  Widget build(BuildContext context) {
    final duration = _reduceMotion(context) ? Duration.zero : const Duration(milliseconds: 640);
    return Semantics(
      label: 'Step $step of $total',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 1; i <= total; i++) ...[
              if (i > 1) const SizedBox(width: 4),
              Container(
                width: 20,
                height: 4,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(color: const Color(0x4DFAFAFA), borderRadius: BorderRadius.circular(2)),
                alignment: Alignment.centerLeft,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: i < step ? 1 : 0, end: i <= step ? 1 : 0),
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  builder: (context, fill, _) => FractionallySizedBox(
                    widthFactor: fill,
                    heightFactor: 1,
                    child: const DecoratedBox(decoration: BoxDecoration(color: kSetupOnField)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Quiet #FAFAFA text action for the header's trailing slot (e.g. "Rescan").
class SetupHeaderAction extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const SetupHeaderAction({super.key, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.refresh_rounded, size: 18),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: kSetupOnField,
        minimumSize: const Size(48, 48),
        textStyle: _kCaption.copyWith(fontWeight: FontWeight.w600),
        shape: const StadiumBorder(),
      ),
    );
  }
}

// ── Photo ───────────────────────────────────────────────────────────────────

/// Product photo of the monitor. Until its file exists, a clearly labeled
/// placeholder holds the slot in the same shape, so the layout reads as it
/// will with the real photo.
///
/// [asset] picks the shot: [kSetupPhotoAsset] (the whole monitor, for the
/// welcome page) or [kSetupScreenPhotoAsset] (a close-up of its screen, for
/// the wide band on the pairing and Device ID steps, so the crop keeps the
/// code in view). [bleed] rounds only the top corners, for a photo that
/// runs off the bottom edge of the screen. Pass a [height], or leave it null
/// to fill the space the parent gives.
class SetupPhoto extends StatelessWidget {
  final String asset;
  final double? height;
  final bool bleed;
  const SetupPhoto({super.key, this.asset = kSetupPhotoAsset, this.height, this.bleed = false});

  @override
  Widget build(BuildContext context) {
    final radius = bleed ? const BorderRadius.vertical(top: Radius.circular(32)) : BorderRadius.circular(28);
    return SizedBox(
      width: double.infinity,
      height: height,
      child: ClipRRect(
        borderRadius: radius,
        child: Image.asset(
          asset,
          fit: BoxFit.cover,
          semanticLabel: 'Your GRID energy monitor',
          // The screen close-up falls back to a drawn, animated stand-in
          // until the real photo is added; any other shot keeps the labeled
          // placeholder.
          errorBuilder: (context, _, _) =>
              asset == kSetupScreenPhotoAsset ? const _ScreenIllustration() : _PhotoPlaceholder(asset: asset),
        ),
      ),
    );
  }
}

/// A drawn stand-in for the monitor-screen photo: the monitor's LCD with
/// "DEVICE ID" and a code whose frame pulses, showing where to look. Drops
/// out of the way by itself once `monitor-screen.png` exists. Still under
/// reduce-motion.
class _ScreenIllustration extends StatefulWidget {
  const _ScreenIllustration();

  @override
  State<_ScreenIllustration> createState() => _ScreenIllustrationState();
}

class _ScreenIllustrationState extends State<_ScreenIllustration> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (_reduceMotion(context)) {
      _pulse.value = 1;
    } else {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Illustration of the monitor screen, with its Device ID highlighted',
      child: ExcludeSemantics(
        child: Container(
          color: const Color(0x24FAFAFA),
          alignment: Alignment.center,
          child: LayoutBuilder(
            builder: (context, box) {
              final width = (box.maxWidth * 0.72).clamp(0.0, 300.0);
              return Container(
                width: width,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: kSetupPanel,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0x80FAFAFA), width: 4),
                  boxShadow: const [BoxShadow(color: Color(0x1F7A2E05), blurRadius: 20, offset: Offset(0, 8))],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('DEVICE ID', style: _kCaption.copyWith(fontWeight: FontWeight.w600, letterSpacing: 1.6)),
                    const SizedBox(height: 6),
                    AnimatedBuilder(
                      animation: _pulse,
                      builder: (context, child) {
                        final e = Curves.easeInOut.transform(_pulse.value);
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: kSetupAccent.withValues(alpha: 0.25 + 0.75 * e), width: 2),
                          ),
                          child: child,
                        );
                      },
                      child: const Text(
                        'XXXX-XXXX',
                        style: TextStyle(
                          fontFamily: kSetupFont,
                          fontSize: 22,
                          height: 1.25,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 4,
                          color: kSetupInk,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PhotoPlaceholder extends StatelessWidget {
  final String asset;
  const _PhotoPlaceholder({required this.asset});

  @override
  Widget build(BuildContext context) {
    return Container(
      // A faint light tint: visible as a slot, quiet enough to vanish once
      // the real photo replaces it.
      color: const Color(0x24FAFAFA),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.photo_camera_outlined, size: 28, color: kSetupBody),
          const SizedBox(height: 8),
          Text(
            asset == kSetupScreenPhotoAsset ? 'Monitor screen photo' : 'Monitor photo',
            style: _kLabel.copyWith(color: kSetupOnField),
          ),
          const SizedBox(height: 2),
          Text(
            'Placeholder: add $asset',
            textAlign: TextAlign.center,
            style: _kCaption.copyWith(color: kSetupOnField, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

// ── Lottie illustrations ────────────────────────────────────────────────────

/// The welcome page's monitor illustration.
const String kSetupWelcomeLottie = 'assets/Welcome.json';

/// The "before we start" page's illustration.
const String kSetupBeforeLottie = 'assets/Before we start.json';

/// The pairing-code page: one animation exported as two files. A plays when
/// the page opens and B takes over when A ends (see [SetupLottieSequence]).
const String kSetupCodeLottieA = 'assets/Enter Code1.json';
const String kSetupCodeLottieB = 'assets/Enter Code2.json';

/// The full-screen intro that opens the app.
const String kAppIntroLottie = 'assets/appintroanimation.json';

/// A Lottie illustration that plays through once and holds its last frame —
/// it never loops. Under reduce-motion it shows the finished frame at once.
/// Give it a new key to play it again (or to swap to another file).
///
/// With [play] false it loads and waits on its first frame; it starts when
/// [play] turns true. [SetupLottieSequence] uses that to chain files.
class SetupLottie extends StatefulWidget {
  final String asset;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;
  final bool play;

  /// Changing this value plays the animation again from its first frame.
  final int restart;

  /// Called once the last frame is reached (immediately under reduce-motion).
  final VoidCallback? onFinished;

  const SetupLottie({
    super.key,
    required this.asset,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.play = true,
    this.restart = 0,
    this.onFinished,
  });

  @override
  State<SetupLottie> createState() => _SetupLottieState();
}

class _SetupLottieState extends State<SetupLottie> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onFinished?.call();
    });
  bool _loaded = false;
  bool _started = false;

  @override
  void didUpdateWidget(SetupLottie oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.restart != widget.restart) {
      _started = false;
      _controller.value = 0;
    }
    _startIfReady();
  }

  /// Starts once, when the file has loaded and [SetupLottie.play] is true.
  void _startIfReady() {
    if (_started || !_loaded || !widget.play) return;
    _started = true;
    if (_reduceMotion(context)) {
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Lottie.asset(
        widget.asset,
        controller: _controller,
        height: widget.height,
        fit: widget.fit,
        alignment: widget.alignment,
        onLoaded: (composition) {
          _controller.duration = composition.duration;
          _loaded = true;
          _startIfReady();
        },
        errorBuilder: (context, _, _) => SizedBox(height: widget.height),
      ),
    );
  }
}

/// Several Lottie files exported as one continuous animation: each plays
/// once, in order, in exactly the same place and size, and the next takes
/// over on the very frame the last one ends.
///
/// Every file is loaded and laid out from the start (the waiting ones are
/// hidden on their first frame), so the hand-over is a single frame swap with
/// nothing to load and nothing that can shift.
///
/// By default the last file holds its final frame. With [loop] the sequence
/// goes round again after the last file, and [holdAfterEach] is how long each
/// file rests on its last frame before the next begins — time to read.
/// [onStepChanged] reports which file is showing (0 first, and on every
/// change).
class SetupLottieSequence extends StatefulWidget {
  final List<String> assets;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;
  final bool loop;
  final Duration holdAfterEach;

  /// How long to wait before the first file starts — for a page that
  /// brings the picture in with an entrance of its own.
  final Duration startDelay;
  final ValueChanged<int>? onStepChanged;

  /// Called once the last file has finished (never, when [loop] is set).
  final VoidCallback? onFinished;

  const SetupLottieSequence({
    super.key,
    required this.assets,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.loop = false,
    this.holdAfterEach = Duration.zero,
    this.startDelay = Duration.zero,
    this.onStepChanged,
    this.onFinished,
  });

  @override
  State<SetupLottieSequence> createState() => _SetupLottieSequenceState();
}

class _SetupLottieSequenceState extends State<SetupLottieSequence> {
  int _current = 0;

  /// Bumped each time a file becomes current again, so it replays from its
  /// first frame without reloading.
  late final List<int> _rounds = List.filled(widget.assets.length, 0);
  Timer? _hold;
  late bool _started = widget.startDelay == Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onStepChanged?.call(_current);
    });
    if (!_started) {
      _hold = Timer(widget.startDelay, () {
        if (mounted) setState(() => _started = true);
      });
    }
  }

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  void _onStepFinished(int index) {
    if (!mounted || index != _current) return;
    final isLast = index == widget.assets.length - 1;
    if (isLast && !widget.loop) {
      widget.onFinished?.call();
      return;
    }
    void advance() {
      if (!mounted) return;
      setState(() {
        _current = (index + 1) % widget.assets.length;
        _rounds[_current]++;
      });
      widget.onStepChanged?.call(_current);
    }

    _hold?.cancel();
    if (widget.holdAfterEach == Duration.zero) {
      advance();
    } else {
      _hold = Timer(widget.holdAfterEach, advance);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      alignment: widget.alignment,
      children: [
        for (var i = 0; i < widget.assets.length; i++)
          // Only the current file is drawn; the finished ones are dropped
          // from view the moment the next one starts, and the waiting ones
          // stay hidden on their first frame.
          Visibility(
            visible: i == _current,
            maintainState: true,
            maintainAnimation: true,
            maintainSize: true,
            child: SetupLottie(
              asset: widget.assets[i],
              height: widget.height,
              fit: widget.fit,
              alignment: widget.alignment,
              play: _started && i == _current,
              restart: _rounds[i],
              onFinished: () => _onStepFinished(i),
            ),
          ),
      ],
    );
  }
}

// ── Celebration (Done screen) ───────────────────────────────────────────────

/// The setup flow's closing moment: a #FAFAFA disc pops in with a bounce, a
/// ring bursts out, and the check draws itself on. Plays once; shows the
/// finished state immediately under reduce-motion.
class SetupCelebration extends StatefulWidget {
  const SetupCelebration({super.key});

  @override
  State<SetupCelebration> createState() => _SetupCelebrationState();
}

class _SetupCelebrationState extends State<SetupCelebration> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion(context)) {
      _c.value = 1;
    } else if (_c.status == AnimationStatus.dismissed) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(size: const Size(144, 112), painter: _CelebrationPainter(_c.value)),
        ),
      ),
    );
  }
}

class _CelebrationPainter extends CustomPainter {
  final double t;
  _CelebrationPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    const radius = 40.0;
    // The disc sits on the left edge so it lines up with the title below.
    final center = Offset(radius, size.height / 2);

    final burst = Curves.easeOutCubic.transform((t / 0.7).clamp(0.0, 1.0));
    if (burst > 0 && burst < 1) {
      canvas.drawCircle(
        center,
        radius + 16 * burst,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5 * (1 - burst)
          ..color = kSetupOnField.withValues(alpha: 0.5 * (1 - burst)),
      );
    }

    final pop = Curves.easeOutExpo.transform((t / 0.6).clamp(0.0, 1.0));
    final r = radius * pop;
    if (r > 0) canvas.drawCircle(center, r, Paint()..color = kSetupOnField);

    final draw = Curves.easeOutCubic.transform(((t - 0.3) / 0.4).clamp(0.0, 1.0));
    if (draw > 0) {
      final path = Path()
        ..moveTo(center.dx - 16, center.dy + 1)
        ..lineTo(center.dx - 5, center.dy + 12)
        ..lineTo(center.dx + 17, center.dy - 11);
      final metric = path.computeMetrics().first;
      canvas.drawPath(
        metric.extractPath(0, metric.length * draw),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = kSetupField,
      );
    }
  }

  @override
  bool shouldRepaint(_CelebrationPainter old) => old.t != t;
}

/// Marks a subtree as sitting on a white panel (the setup sheets), so
/// controls built for the orange field can switch to their on-white look.
class _PanelScope extends InheritedWidget {
  const _PanelScope({required super.child});

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_PanelScope>() != null;

  @override
  bool updateShouldNotify(_PanelScope oldWidget) => false;
}

// ── Buttons ─────────────────────────────────────────────────────────────────

/// Scales its child to 97% while pressed: a small tactile cue.
class _Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final ShapeBorder shape;
  const _Pressable({required this.child, required this.onTap, required this.shape});

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _down ? 0.97 : 1,
      duration: _reduceMotion(context) ? Duration.zero : const Duration(milliseconds: 120),
      child: Material(
        type: MaterialType.transparency,
        shape: widget.shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          onHighlightChanged: widget.onTap == null ? null : _set,
          splashColor: Colors.white.withValues(alpha: 0.12),
          highlightColor: Colors.transparent,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Orange-tinted disc with an arrow, riding at the end of the pill button.
class _ArrowDisc extends StatelessWidget {
  final bool loading;
  final bool enabled;
  final bool onPanel;
  const _ArrowDisc({required this.loading, required this.enabled, this.onPanel = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: onPanel
            ? (enabled ? const Color(0x33FAFAFA) : const Color(0x1AC2410C))
            : (enabled ? _kSetupAccentTint : const Color(0x1FFAFAFA)),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: loading
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: onPanel ? kSetupOnField : kSetupAccent),
            )
          : Icon(
              Icons.arrow_forward_rounded,
              size: 22,
              color: onPanel
                  ? (enabled ? kSetupOnField : const Color(0x99C2410C))
                  : (enabled ? kSetupAccent : const Color(0x99FAFAFA)),
            ),
    );
  }
}

/// Full-width #FAFAFA pill: the action's name in deep orange on the left,
/// an orange-tinted arrow disc on the right. While [loading] the disc spins and taps are ignored.
class SetupPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  /// False for a plain pill: the label centered, no arrow disc.
  final bool arrow;

  const SetupPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.arrow = true,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null || loading;
    // Inside a white sheet an off-white pill would vanish, so it flips to
    // solid deep orange with #FAFAFA text (about 5:1).
    final onPanel = _PanelScope.of(context);
    final Color fill = onPanel
        ? (enabled ? kSetupAccent : _kSetupAccentTint)
        : (enabled ? kSetupOnField : const Color(0x40FAFAFA));
    final Color labelColor = onPanel
        ? (enabled ? kSetupOnField : kSetupAccent)
        : (enabled ? kSetupAccent : const Color(0xCCFAFAFA));
    return Semantics(
      button: true,
      enabled: enabled && !loading,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 64,
        width: double.infinity,
        decoration: ShapeDecoration(
          color: fill,
          shape: const StadiumBorder(),
          shadows: enabled ? _kButtonShadow : null,
        ),
        child: _Pressable(
          shape: const StadiumBorder(),
          // Keep it tappable-looking while loading, but inert.
          onTap: loading ? () {} : onPressed,
          child: Padding(
            padding: EdgeInsets.only(left: arrow ? 28 : 24, right: arrow ? 8 : 24),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: arrow ? TextAlign.start : TextAlign.center,
                    style: _kLabel.copyWith(color: labelColor),
                  ),
                ),
                if (arrow) _ArrowDisc(loading: loading, enabled: enabled, onPanel: onPanel),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The welcome page's "move on" button, deliberately unlike the pills used
/// elsewhere: a translucent track with a big off-white knob resting at the
/// left, label beside it. Drag the knob to the right end: the track fills
/// off-white behind it, wiping over the label. Let go past about 70% (or
/// flick) and it runs the rest of the way and the next page starts just
/// before it lands; let go earlier and it springs back. Tapping only nudges
/// the knob to show it slides; assistive tech activates it directly.
/// Reduce-motion skips the run.
class SetupSlideButton extends StatefulWidget {
  final String label;
  final VoidCallback onPressed;
  const SetupSlideButton({super.key, required this.label, required this.onPressed});

  @override
  State<SetupSlideButton> createState() => _SetupSlideButtonState();
}

class _SetupSlideButtonState extends State<SetupSlideButton> with SingleTickerProviderStateMixin {
  static const double _height = 68;
  static const double _inset = 6;
  static const double _knob = _height - _inset * 2;
  static const Duration _runTime = Duration(milliseconds: 360);

  /// How far along the track the knob is, 0 to 1, driven by the finger
  /// while dragging and by an animation otherwise.
  late final AnimationController _run = AnimationController(vsync: this, duration: _runTime);

  /// Past this much (or a fast flick) a release finishes the slide.
  static const double _commitAt = 0.7;

  bool _busy = false; // the finishing run is under way; ignore input
  double _travel = 1; // knob travel in px, set by the last layout

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    if (_busy) return;
    _busy = true;
    HapticFeedback.mediumImpact();
    if (_reduceMotion(context)) {
      widget.onPressed();
    } else {
      // Quick off the mark, then a soft landing, over what is left to cover.
      final left = _runTime * (1 - _run.value);
      final landing = _run.animateTo(1, duration: left, curve: const Cubic(0.32, 0.72, 0, 1));
      await Future<void>.delayed(left * 0.8);
      if (!mounted) return;
      widget.onPressed();
      await landing;
    }
    if (!mounted) return;
    // Back to rest once the next page has covered this one.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    _run.value = 0;
    _busy = false;
  }

  void _springBack() {
    if (_busy) return;
    _run.animateBack(0, duration: const Duration(milliseconds: 240), curve: Curves.easeOutCubic);
  }

  /// A tap on the track: the knob hops toward the right and back, which
  /// shows it is meant to be dragged.
  Future<void> _nudge() async {
    if (_busy || _run.isAnimating) return;
    await _run.animateTo(0.16, duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
    if (mounted) _springBack();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_busy) return;
    _run.stop();
    _run.value = (_run.value + d.delta.dx / _travel).clamp(0.0, 1.0);
  }

  void _onDragEnd(DragEndDetails d) {
    if (_busy) return;
    if (_run.value >= _commitAt || d.primaryVelocity != null && d.primaryVelocity! > 900) {
      _go();
    } else {
      _springBack();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      onTap: _go,
      child: _Pressable(
        shape: const StadiumBorder(),
        onTap: _nudge,
        child: Container(
          height: _height,
          width: double.infinity,
          decoration: const ShapeDecoration(
            color: Color(0x33FAFAFA),
            shape: StadiumBorder(side: BorderSide(color: Color(0x4DFAFAFA), width: 1.5)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_height),
            child: LayoutBuilder(
              builder: (context, box) {
                final travel = box.maxWidth - _inset * 2 - _knob;
                _travel = travel;
                return Stack(
                  children: [
                    // The fill that follows the knob.
                    AnimatedBuilder(
                      animation: _run,
                      builder: (context, _) => Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: _inset + _knob + _inset + travel * _run.value,
                        child: const DecoratedBox(
                          decoration: ShapeDecoration(color: kSetupOnField, shape: StadiumBorder()),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      left: _inset + _knob + 18,
                      right: 20,
                      child: FadeTransition(
                        opacity: _run.drive(
                          Tween<double>(begin: 1, end: 0).chain(CurveTween(curve: const Interval(0, 0.5))),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: _kLabel.copyWith(color: kSetupOnField),
                              ),
                            ),
                            const Icon(Icons.keyboard_double_arrow_right_rounded, size: 24, color: kSetupOnField),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      left: _inset,
                      top: _inset,
                      child: RepaintBoundary(
                        child: AnimatedBuilder(
                          animation: _run,
                          builder: (context, child) =>
                              Transform.translate(offset: Offset(travel * _run.value, 0), child: child),
                          child: GestureDetector(
                            onHorizontalDragUpdate: _onDragUpdate,
                            onHorizontalDragEnd: _onDragEnd,
                            onHorizontalDragCancel: _springBack,
                            child: Container(
                              width: _knob,
                              height: _knob,
                              decoration: const BoxDecoration(
                                color: kSetupOnField,
                                shape: BoxShape.circle,
                                boxShadow: _kButtonShadow,
                              ),
                              alignment: Alignment.center,
                              child: const Icon(Icons.arrow_forward_rounded, size: 26, color: kSetupAccent),
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
        ),
      ),
    );
  }
}

/// Round #FAFAFA "next" button with a double chevron, for steps where the
/// action needs no name (the intro pages).
class SetupArrowButton extends StatelessWidget {
  final String semanticLabel;
  final VoidCallback onPressed;
  const SetupArrowButton({super.key, required this.semanticLabel, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Container(
        width: 72,
        height: 72,
        decoration: const ShapeDecoration(color: kSetupOnField, shape: CircleBorder(), shadows: _kButtonShadow),
        child: _Pressable(
          shape: const CircleBorder(),
          onTap: onPressed,
          child: const Center(child: Icon(Icons.keyboard_double_arrow_right_rounded, size: 30, color: kSetupAccent)),
        ),
      ),
    );
  }
}

/// Outlined #FAFAFA pill for the second choice under a primary button.
class SetupSecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const SetupSecondaryButton({super.key, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: kSetupOnField,
          side: const BorderSide(color: kSetupOnField, width: 1.5),
          shape: const StadiumBorder(),
          textStyle: _kLabel,
        ),
        child: Text(label),
      ),
    );
  }
}

/// Plain #FAFAFA text link, e.g. "Skip Wi-Fi setup".
class SetupTextLink extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  /// Left-aligned when it shares a row with a round button; centered under
  /// a full-width one.
  final bool alignStart;
  const SetupTextLink({super.key, required this.label, required this.onPressed, this.alignStart = false});

  @override
  Widget build(BuildContext context) {
    final button = TextButton(
      style: TextButton.styleFrom(
        foregroundColor: kSetupOnField,
        minimumSize: const Size(48, 48),
        padding: EdgeInsets.symmetric(horizontal: alignStart ? 0 : 16),
        shape: const StadiumBorder(),
        textStyle: _kCaption.copyWith(fontWeight: FontWeight.w600),
      ),
      onPressed: onPressed,
      child: Text(label, textAlign: alignStart ? TextAlign.start : TextAlign.center),
    );
    return alignStart ? button : SizedBox(width: double.infinity, child: button);
  }
}

// ── Lists, notices, fields ──────────────────────────────────────────────────

/// White rounded panel grouping rows, with inset dividers between them.
class SetupList extends StatelessWidget {
  final List<Widget> children;
  const SetupList({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(color: kSetupPanel, borderRadius: BorderRadius.circular(24), boxShadow: _kPanelShadow),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              // Inset to line up with the row text, past the icon.
              if (i > 0) const Divider(height: 1, thickness: 1, indent: 60, endIndent: 20, color: kSetupHairline),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// Tappable row inside a [SetupList]: devices, networks.
class SetupListTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback onTap;
  final bool muted;

  const SetupListTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.onTap,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashColor: const Color(0x14FA8B39),
      highlightColor: const Color(0x0FFA8B39),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 72),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
          child: Row(
            children: [
              Icon(icon, size: 24, color: muted ? kSetupMuted : kSetupInk),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _kLabel.copyWith(color: muted ? kSetupMuted : kSetupInk),
                    ),
                    if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, style: _kCaption)],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right_rounded, color: Color(0x592B1309)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Requirements said straight on the orange field, like [SetupChecklist] but
/// with a status per line: no panel, hairlines between and around the rows.
class SetupStatusList extends StatelessWidget {
  final List<Widget> children;
  const SetupStatusList({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    const rule = Divider(height: 1, thickness: 1, color: Color(0x4DFAFAFA));
    return Column(
      children: [
        rule,
        for (final child in children) ...[child, rule],
      ],
    );
  }
}

/// One line of a [SetupStatusList] ("Bluetooth", "Location"): a bare icon, a
/// title and caption, and on the right either a check (it's on) or the action
/// as plain text with an arrow. Tapping the line does the action while it's
/// off; once on it is inert and the check pops in. [onTap] null with [done]
/// false means there is nothing to tap (e.g. iOS can't switch Bluetooth on).
class SetupStatusRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool done;
  final String actionLabel;
  final VoidCallback? onTap;

  const SetupStatusRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.done,
    required this.actionLabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final reduce = _reduceMotion(context);
    final captionStyle = _kCaption.copyWith(color: kSetupOnField, fontWeight: FontWeight.w600);
    final Widget trailing = done
        ? const SizedBox(
            key: ValueKey('done'),
            width: 48,
            height: 48,
            child: Icon(Icons.check_rounded, size: 28, color: kSetupOnField),
          )
        : (onTap == null
              ? const SizedBox(key: ValueKey('wait'), width: 48, height: 48)
              : SizedBox(
                  key: const ValueKey('todo'),
                  height: 48,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(actionLabel, style: captionStyle),
                      const SizedBox(width: 4),
                      const Icon(Icons.arrow_forward_rounded, size: 18, color: kSetupOnField),
                    ],
                  ),
                ));
    return Semantics(
      button: !done && onTap != null,
      label: '$title. ${done ? 'On' : subtitle}',
      excludeSemantics: true,
      child: InkWell(
        onTap: done ? null : onTap,
        splashColor: const Color(0x1FFFFFFF),
        highlightColor: const Color(0x14FFFFFF),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 80),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Icon(icon, size: 24, color: kSetupOnField),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, style: _kLabel.copyWith(color: kSetupOnField)),
                      const SizedBox(height: 2),
                      Text(subtitle, style: captionStyle),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                AnimatedSwitcher(
                  duration: reduce ? Duration.zero : const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutCubic,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(scale: Tween<double>(begin: 0.8, end: 1).animate(animation), child: child),
                  ),
                  child: trailing,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Plain #FAFAFA lines separated by hairlines, straight on the orange field: a
/// short list said as text, with no panel or icons.
class SetupChecklist extends StatelessWidget {
  final List<String> items;
  const SetupChecklist({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const Divider(height: 1, thickness: 1, color: Color(0x4DFAFAFA)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: SizedBox(
              width: double.infinity,
              child: Text(items[i], style: _kLabel.copyWith(color: kSetupOnField)),
            ),
          ),
        ],
      ],
    );
  }
}

/// A short message. Tips and confirmations sit directly on the orange
/// field as an icon and a line of #FAFAFA; errors get a white panel so the red
/// stays legible.
class SetupNotice extends StatelessWidget {
  final String message;
  final SetupTone tone;
  const SetupNotice({super.key, required this.message, this.tone = SetupTone.neutral});

  @override
  Widget build(BuildContext context) {
    if (tone == SetupTone.danger) {
      return Semantics(
        liveRegion: true,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: kSetupPanel, borderRadius: BorderRadius.circular(20)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline_rounded, size: 20, color: kSetupDanger),
              const SizedBox(width: 12),
              Expanded(
                child: Text(message, style: _kCaption.copyWith(color: kSetupDanger)),
              ),
            ],
          ),
        ),
      );
    }
    final icon = tone == SetupTone.success ? Icons.check_circle_rounded : Icons.info_outline_rounded;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: kSetupOnField),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            message,
            style: _kCaption.copyWith(color: kSetupOnField, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// Spinner + status text for "working on it" states.
class SetupStatusLine extends StatelessWidget {
  final String text;
  const SetupStatusLine(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.25, color: kSetupOnField),
          ),
          const SizedBox(width: 12),
          Text(
            text,
            style: _kCaption.copyWith(fontWeight: FontWeight.w600, color: kSetupOnField),
          ),
        ],
      ),
    );
  }
}

/// White rounded field with a deep-orange focus ring.
InputDecoration setupInputDecoration({required String label, String? hint, String? errorText, Widget? suffixIcon}) {
  OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(20),
    borderSide: BorderSide(color: color, width: width),
  );
  return InputDecoration(
    labelText: label,
    hintText: hint,
    errorText: errorText,
    errorMaxLines: 3,
    filled: true,
    fillColor: kSetupPanel,
    labelStyle: _kBody.copyWith(color: kSetupMuted, fontWeight: FontWeight.w400),
    floatingLabelStyle: _kCaption.copyWith(fontWeight: FontWeight.w600, color: kSetupInk),
    // Placeholder only — lighter than entered text so a format hint never
    // reads as a value that's already been typed.
    hintStyle: const TextStyle(fontFamily: kSetupFont, color: Color(0x612B1309)),
    // Error text can land on the orange field, where red is illegible, so
    // it's set in #FAFAFA; the red border marks the field.
    errorStyle: _kCaption.copyWith(color: kSetupOnField, fontWeight: FontWeight.w600),
    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
    border: border(kSetupHairline, 1.5),
    enabledBorder: border(kSetupHairline, 1.5),
    disabledBorder: border(kSetupHairline, 1.5),
    focusedBorder: border(kSetupAccent, 2),
    errorBorder: border(kSetupDanger, 2),
    focusedErrorBorder: border(kSetupDanger, 2),
    suffixIcon: suffixIcon,
  );
}

/// Large, centered, letter-spaced style for codes read off the LCD.
const TextStyle kSetupCodeTextStyle = TextStyle(
  fontFamily: kSetupFont,
  fontSize: 22,
  letterSpacing: 4,
  fontWeight: FontWeight.w600,
  color: kSetupInk,
  fontFeatures: [FontFeature.tabularFigures()],
);

/// Bottom sheet shell shared by the setup sheets: drag handle, a title and
/// subtitle, then [builder]'s content.
Future<T?> showSetupSheet<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kSetupPanel,
    barrierColor: const Color(0x662B1309),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (sheetContext) => _withSetupFont(
      sheetContext,
      Padding(
        padding: EdgeInsets.fromLTRB(24, 12, 24, 16 + MediaQuery.of(sheetContext).viewInsets.bottom),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(color: kSetupHairline, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 24),
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: _kTitle),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: _kBody.copyWith(color: kSetupMuted, fontWeight: FontWeight.w400),
                ),
              ],
              const SizedBox(height: 24),
              _PanelScope(child: Builder(builder: builder)),
            ],
          ),
        ),
      ),
    ),
  );
}

// ── Code cells ──────────────────────────────────────────────────────────────

/// One white box per character on the orange field, split into groups with
/// a dash between them: the familiar verification-code entry.
///
/// A transparent [TextField] sits over the boxes and does the actual input
/// (keyboard, paste from the long-press menu, [inputFormatters]); the boxes
/// just draw [controller]'s text with any non-alphanumeric separators
/// stripped. The next empty box gets a deep-orange ring and a blinking caret.
/// When [errorText] appears the row shakes; [success] turns the boxes into
/// #FAFAFA outlines on the orange, the flow's confirmation moment.
class SetupCodeField extends StatefulWidget {
  final TextEditingController controller;
  final int length;
  final int groupSize;
  final String semanticLabel;
  final String? helperText;
  final String? errorText;
  final bool success;
  final bool enabled;

  /// Keeps focus and the keyboard up but ignores typing, e.g. while the
  /// entered code is being checked.
  final bool readOnly;
  final bool autofocus;
  final List<TextInputFormatter> inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  const SetupCodeField({
    super.key,
    required this.controller,
    required this.length,
    this.groupSize = 4,
    required this.semanticLabel,
    this.helperText,
    this.errorText,
    this.success = false,
    this.enabled = true,
    this.readOnly = false,
    this.autofocus = false,
    this.inputFormatters = const [],
    this.onChanged,
    this.onSubmitted,
  });

  @override
  State<SetupCodeField> createState() => _SetupCodeFieldState();
}

class _SetupCodeFieldState extends State<SetupCodeField> with SingleTickerProviderStateMixin {
  final _focus = FocusNode();
  late final AnimationController _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));

  @override
  void initState() {
    super.initState();
    _focus.addListener(_refresh);
    widget.controller.addListener(_refresh);
  }

  @override
  void didUpdateWidget(SetupCodeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
    if (widget.errorText != null && oldWidget.errorText == null) {
      HapticFeedback.mediumImpact();
      if (!_reduceMotion(context)) _shake.forward(from: 0);
    }
    if (widget.success && !oldWidget.success) HapticFeedback.lightImpact();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    _focus.dispose();
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chars = widget.controller.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final error = widget.errorText;
    final helper = widget.helperText;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedBuilder(
          animation: _shake,
          builder: (context, child) {
            final t = _shake.value;
            return Transform.translate(offset: Offset(math.sin(t * math.pi * 6) * 10 * (1 - t), 0), child: child);
          },
          child: LayoutBuilder(
            builder: (context, box) {
              const gap = 6.0;
              const groupGap = 20.0;
              final groups = (widget.length / widget.groupSize).ceil();
              final gapsWidth = gap * (widget.length - groups) + groupGap * (groups - 1);
              final cellWidth = math.min(48.0, (box.maxWidth - gapsWidth) / widget.length);

              return Stack(
                children: [
                  ExcludeSemantics(
                    child: Row(
                      children: [
                        for (var i = 0; i < widget.length; i++) ...[
                          if (i > 0 && i % widget.groupSize == 0)
                            SizedBox(
                              width: groupGap,
                              child: Center(
                                child: Container(
                                  width: 8,
                                  height: 2,
                                  decoration: BoxDecoration(
                                    color: kSetupOnField,
                                    borderRadius: BorderRadius.circular(1),
                                  ),
                                ),
                              ),
                            )
                          else if (i > 0)
                            const SizedBox(width: gap),
                          _CodeCell(
                            width: cellWidth,
                            char: i < chars.length ? chars[i] : null,
                            active:
                                widget.enabled &&
                                !widget.readOnly &&
                                _focus.hasFocus &&
                                (i == chars.length || (i == widget.length - 1 && chars.length == widget.length)),
                            error: error != null,
                            success: widget.success,
                          ),
                        ],
                      ],
                    ),
                  ),
                  // The real input, invisible, over the boxes: taps focus it
                  // and a long-press offers Paste.
                  Positioned.fill(
                    child: Theme(
                      data: Theme.of(context).copyWith(
                        textSelectionTheme: const TextSelectionThemeData(
                          selectionColor: Colors.transparent,
                          cursorColor: Colors.transparent,
                          selectionHandleColor: Colors.transparent,
                        ),
                      ),
                      child: TextField(
                        controller: widget.controller,
                        focusNode: _focus,
                        autofocus: widget.autofocus,
                        enabled: widget.enabled,
                        readOnly: widget.readOnly,
                        inputFormatters: widget.inputFormatters,
                        textCapitalization: TextCapitalization.characters,
                        keyboardType: TextInputType.text,
                        textInputAction: TextInputAction.done,
                        autocorrect: false,
                        enableSuggestions: false,
                        showCursor: false,
                        expands: true,
                        maxLines: null,
                        style: const TextStyle(color: Colors.transparent, fontSize: 1),
                        decoration: InputDecoration(
                          isCollapsed: true,
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          // Read out by screen readers; drawn invisibly.
                          hintText: widget.semanticLabel,
                          hintStyle: const TextStyle(color: Colors.transparent, fontSize: 1),
                        ),
                        onChanged: widget.onChanged,
                        onSubmitted: widget.onSubmitted,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        AnimatedSwitcher(
          duration: _reduceMotion(context) ? Duration.zero : const Duration(milliseconds: 200),
          child: error != null
              ? SetupNotice(key: ValueKey(error), tone: SetupTone.danger, message: error)
              : SizedBox(
                  key: ValueKey(helper),
                  width: double.infinity,
                  child: helper == null
                      ? null
                      : Text(
                          helper,
                          style: _kCaption.copyWith(color: kSetupOnField, fontWeight: FontWeight.w600),
                        ),
                ),
        ),
      ],
    );
  }
}

class _CodeCell extends StatelessWidget {
  final double width;
  final String? char;
  final bool active;
  final bool error;
  final bool success;

  const _CodeCell({
    required this.width,
    required this.char,
    required this.active,
    required this.error,
    required this.success,
  });

  @override
  Widget build(BuildContext context) {
    final reduceMotion = _reduceMotion(context);
    final filled = char != null;
    final border = success
        ? kSetupOnField
        : error
        ? kSetupDanger
        : active
        ? kSetupAccent
        : Colors.transparent;

    return AnimatedContainer(
      duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 180),
      width: width,
      height: 60,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // Empty boxes are slightly translucent so the filled ones read as
        // "done" at a glance.
        color: success ? const Color(0x26FAFAFA) : (filled || active ? kSetupPanel : const Color(0xB3FFFFFF)),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border, width: 2),
      ),
      child: filled
          ? TweenAnimationBuilder<double>(
              // Keyed per character so each new one pops in.
              key: ValueKey(char),
              tween: Tween(begin: reduceMotion ? 1 : 0.6, end: 1),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutExpo,
              builder: (context, s, child) => Transform.scale(scale: s, child: child),
              child: Text(
                char!,
                style: _kTitle.copyWith(
                  color: success ? kSetupOnField : kSetupInk,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            )
          : active
          ? const _Caret()
          : null,
    );
  }
}

/// Blinking deep-orange caret for the active code cell.
class _Caret extends StatefulWidget {
  const _Caret();

  @override
  State<_Caret> createState() => _CaretState();
}

class _CaretState extends State<_Caret> with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion(context)) {
      _blink.value = 0;
    } else if (!_blink.isAnimating) {
      _blink.repeat();
    }
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _blink,
      builder: (context, _) => Opacity(
        opacity: _blink.value < 0.5 ? 1 : 0,
        child: Container(
          width: 2,
          height: 26,
          decoration: BoxDecoration(color: kSetupAccent, borderRadius: BorderRadius.circular(1)),
        ),
      ),
    );
  }
}
