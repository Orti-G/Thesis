import 'package:flutter/material.dart';

/// A number that rolls each changed digit into place, like the number
/// wheels on an electric meter. Digits use tabular figures so nothing
/// shifts sideways while they turn.
class RollingNumber extends StatelessWidget {
  const RollingNumber(this.text, {super.key, required this.style});

  final String text;
  final TextStyle style;

  static bool _isDigit(String c) => '0123456789'.contains(c);

  @override
  Widget build(BuildContext context) {
    // Measure with the same merged style the Text widgets render with (the
    // theme's line height included), so each wheel cell is exactly one line.
    final digitStyle = DefaultTextStyle.of(context).style.merge(
      style.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
    );
    final probe = TextPainter(
      text: TextSpan(text: '0', style: digitStyle),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final digitSize = probe.size;
    probe.dispose();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final chars = text.split('');

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Invisible copy: sizes the stack, gives the row its baseline and
        // reads the value to screen readers.
        Opacity(
          opacity: 0,
          alwaysIncludeSemantics: true,
          child: Text(text, style: digitStyle),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: IgnoreBaseline(
            child: ExcludeSemantics(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < chars.length; i++)
                    if (_isDigit(chars[i]))
                      // Keyed by place value, so a wheel keeps its position
                      // when the number gains a digit.
                      _DigitWheel(
                        key: ValueKey(chars.length - i),
                        digit: int.parse(chars[i]),
                        style: digitStyle,
                        size: digitSize,
                        reduceMotion: reduceMotion,
                      )
                    else
                      Text(chars[i], style: digitStyle),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DigitWheel extends StatelessWidget {
  const _DigitWheel({
    super.key,
    required this.digit,
    required this.style,
    required this.size,
    required this.reduceMotion,
  });

  final int digit;
  final TextStyle style;
  final Size size;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: digit.toDouble()),
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      builder: (context, position, wheel) {
        final window = ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            maxHeight: double.infinity,
            child: Transform.translate(
              offset: Offset(0, -position * size.height),
              child: wheel,
            ),
          ),
        );
        // Mid-turn, neighbouring digits fade out at the window's edges
        // instead of being cut off; at rest the mask is skipped.
        final turning = position != position.roundToDouble();
        return SizedBox.fromSize(
          size: size,
          child: turning
              ? ShaderMask(
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x00FFFFFF),
                      Color(0xFFFFFFFF),
                      Color(0xFFFFFFFF),
                      Color(0x00FFFFFF),
                    ],
                    stops: [0.0, 0.3, 0.7, 1.0],
                  ).createShader(rect),
                  child: window,
                )
              : window,
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var d = 0; d <= 9; d++)
            SizedBox.fromSize(
              size: size,
              child: Text('$d', style: style),
            ),
        ],
      ),
    );
  }
}

/// Label that cross-fades when [mode] flips but updates in place within a
/// mode, so a scrubbed "By 4 PM" ticks over without flashing.
class SwapText extends StatelessWidget {
  const SwapText({
    super.key,
    required this.mode,
    required this.text,
    required this.style,
    required this.duration,
  });

  final bool mode;
  final String text;
  final TextStyle style;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerLeft,
        children: [...previous, ?current],
      ),
      child: Text(
        text,
        key: ValueKey(mode),
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
