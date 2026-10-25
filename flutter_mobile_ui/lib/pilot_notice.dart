import 'dart:ui';

import 'package:flutter/material.dart';

import 'household_scope.dart';

/// The first-month pilot: forecasts, bills and alerts need about a month of
/// readings, so those screens aren't live yet. While this is true, Billing
/// sits behind a blur with a plain message laid over it, and the Alerts
/// screen shows the same message and doesn't pull anomaly data at all (nor
/// does the nav bar's red dot). Flip it to false when the features go live
/// and all of that goes away. The legacy household (see household_scope.dart)
/// is never gated.
const bool _kPilotMode = true;

/// The pilot only applies to linked BLE devices: the legacy household's data
/// is already live, so its screens are never gated.
bool get kPilotPreview => _kPilotMode && !HouseholdScope.isLegacy;

const Color _pilotAccentText = Color(0xFFB8470F);
const Color _pilotInk = Color(0xFF1E1E1E);

/// The message for a screen that isn't live yet, set as plain text with no
/// card or pill around it: a big headline, what is going on, and what does
/// work today. Meant to sit straight on a blurred page (see [PilotGate]) or
/// on a plain one.
class PilotBanner extends StatelessWidget {
  final String headline;
  final String body;

  /// What a household can use today, said in one line.
  final String liveNow;

  const PilotBanner({
    super.key,
    this.headline = 'Coming soon',
    required this.body,
    this.liveNow = 'Live usage and the hour-by-hour graph',
  });

  @override
  Widget build(BuildContext context) {
    if (!kPilotPreview) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'PILOT · FIRST MONTH',
          textAlign: TextAlign.start,
          style: TextStyle(
            color: _pilotAccentText,
            fontSize: 12,
            height: 1.2,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          headline,
          textAlign: TextAlign.start,
          style: const TextStyle(
            color: _pilotInk,
            fontSize: 44,
            height: 1.05,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.4,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          body,
          textAlign: TextAlign.justify,
          style: TextStyle(
            color: _pilotInk.withValues(alpha: 0.82),
            fontSize: 16,
            height: 1.45,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (liveNow.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text(
            'WORKING NOW ON HOME',
            textAlign: TextAlign.start,
            style: TextStyle(
              color: _pilotInk.withValues(alpha: 0.6),
              fontSize: 11,
              height: 1.2,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            liveNow,
            textAlign: TextAlign.start,
            style: const TextStyle(color: _pilotInk, fontSize: 15, height: 1.4, fontWeight: FontWeight.w700),
          ),
        ],
      ],
    );
  }
}

/// Puts a not-yet-live screen behind a blur and lays the [notice] text
/// straight over it, with nothing boxed around the words. The blurred page
/// can't be touched (no pull to refresh, no taps), so nothing acts on
/// numbers that aren't real yet.
class PilotGate extends StatelessWidget {
  final Widget child;
  final Widget notice;
  const PilotGate({super.key, required this.child, required this.notice});

  @override
  Widget build(BuildContext context) {
    if (!kPilotPreview) return child;
    return Stack(
      children: [
        IgnorePointer(
          child: ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: 9, sigmaY: 9), child: child),
        ),
        // A veil pushes the page back so the words read cleanly.
        const Positioned.fill(
          child: IgnorePointer(child: ColoredBox(color: Color(0x73FFFFFF))),
        ),
        PilotNoticeLayer(notice: notice),
      ],
    );
  }
}

/// Where the pilot note sits: the same distance from the top of the screen
/// on every pilot screen, so it doesn't jump up or down when you switch
/// between them. Doesn't catch touches.
class PilotNoticeLayer extends StatelessWidget {
  final Widget notice;
  const PilotNoticeLayer({super.key, required this.notice});

  /// Share of the screen height above the note.
  static const double _top = 0.30;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: EdgeInsets.fromLTRB(32, MediaQuery.sizeOf(context).height * _top, 32, 16),
            child: notice,
          ),
        ),
      ),
    );
  }
}

/// Like [PilotGate] but for one section inside a scrolling page: blurs
/// [child] and lays [notice] over it, while the rest of the page stays sharp
/// and usable. The blurred section can't be touched.
class PilotSection extends StatelessWidget {
  final Widget child;
  final Widget notice;
  const PilotSection({super.key, required this.child, required this.notice});

  @override
  Widget build(BuildContext context) {
    if (!kPilotPreview) return child;
    return Stack(
      children: [
        IgnorePointer(
          child: ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: 9, sigmaY: 9), child: child),
        ),
        const Positioned.fill(
          child: IgnorePointer(child: ColoredBox(color: Color(0x73FFFFFF))),
        ),
        PilotNoticeLayer(notice: notice),
      ],
    );
  }
}