import 'package:flutter/material.dart';

import 'wifi_setup/setup_ui.dart';

/// First-run privacy note, shown as a modal after the intro video.
///
/// Typography follows the setup flow (Plus Jakarta Sans, sizes 22 / 16,
/// weights 400 / 600): a quiet title, then three short paragraphs whose
/// opening phrase is semibold so the note can be skimmed or read through.
///
/// Leaving: the card drops away while a full-screen GRID-orange wash rises
/// behind it (~320ms), so the setup page that follows is the same colour as
/// what is on screen. [onAccepted], when given, then starts that page by
/// replacing this dialog route (the page fades in over the wash); without it
/// the dialog simply pops. Reduce-motion skips the movement.
class DisclaimerDialog extends StatefulWidget {
  /// Called once the exit animation has finished. It must replace or pop the
  /// dialog route; if null, the dialog pops itself.
  final VoidCallback? onAccepted;

  /// False when the page behind is not orange (the intro video's black):
  /// the card just slides away, with no orange wash rising behind it.
  final bool wash;

  const DisclaimerDialog({super.key, this.onAccepted, this.wash = true});

  @override
  State<DisclaimerDialog> createState() => _DisclaimerDialogState();
}

class _DisclaimerDialogState extends State<DisclaimerDialog> with SingleTickerProviderStateMixin {
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  bool _leaving = false;

  static const TextStyle _title = TextStyle(
    fontFamily: kSetupFont,
    fontSize: 22,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    color: kSetupInk,
  );

  static const TextStyle _body = TextStyle(
    fontFamily: kSetupFont,
    fontSize: 16,
    height: 1.5,
    fontWeight: FontWeight.w400,
    color: kSetupInk,
  );

  static const TextStyle _lead = TextStyle(fontWeight: FontWeight.w600);

  static const List<(String, String)> _points = [
    ('GRID is independent. ', "It isn't affiliated with or endorsed by Meralco."),
    (
      'Your readings come from your monitor. ',
      "Bill estimates use Meralco's public rates, so treat them as a guide, not an official bill.",
    ),
    (
      'Your data stays in this app. ',
      "It's kept in secure cloud storage and used only for monitoring and forecasting. "
          "It isn't shared with Meralco or anyone else.",
    ),
  ];

  @override
  void dispose() {
    _exit.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    if (_leaving) return;
    _leaving = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _exit.value = 1;
    } else {
      await _exit.forward();
    }
    if (!mounted) return;
    final next = widget.onAccepted;
    if (next != null) {
      next();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final wash = CurvedAnimation(parent: _exit, curve: Curves.easeOutCubic);
    // The card finishes leaving a little before the wash is fully opaque.
    final leave = CurvedAnimation(parent: _exit, curve: const Interval(0, 0.7, curve: Curves.easeOutCubic));

    final card = TweenAnimationBuilder<double>(
      duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      tween: Tween<double>(begin: 1.0, end: 0.0),
      builder: (context, value, child) {
        return Transform.translate(
          // Slides up from the bottom edge to its resting position.
          offset: Offset(0, value * MediaQuery.sizeOf(context).height),
          child: child,
        );
      },
      child: AnimatedBuilder(
        animation: leave,
        builder: (context, child) {
          return Opacity(
            opacity: 1 - leave.value,
            child: Transform.translate(offset: Offset(0, reduceMotion ? 0 : leave.value * 48), child: child),
          );
        },
        child: _card(context),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.wash) FadeTransition(opacity: wash, child: const ColoredBox(color: kSetupField)),
        SafeArea(child: card),
      ],
    );
  }

  Widget _card(BuildContext context) {
    return Dialog(
      backgroundColor: kSetupPanel,
      surfaceTintColor: kSetupPanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(header: true, child: const Text('Before you start', style: _title)),
            const SizedBox(height: 16),
            // Scrolls when the system font size is large; the button stays put.
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < _points.length; i++) ...[
                      if (i > 0) const SizedBox(height: 16),
                      Text.rich(
                        TextSpan(
                          style: _body,
                          children: [
                            TextSpan(text: _points[i].$1, style: _lead),
                            TextSpan(text: _points[i].$2),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kSetupAccent,
                  foregroundColor: kSetupOnField,
                  elevation: 0,
                  shape: const StadiumBorder(),
                  textStyle: const TextStyle(fontFamily: kSetupFont, fontSize: 16, fontWeight: FontWeight.w600),
                ),
                onPressed: _accept,
                child: const Text('I understand'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
