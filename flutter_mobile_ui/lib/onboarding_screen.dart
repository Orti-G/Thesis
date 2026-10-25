import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'main.dart'; // dashboardReadyNotifier
import 'device_id_screen.dart';
import 'disclaimer_dialog.dart';
import 'household_scope.dart';
import 'wifi_setup/intro_screens.dart' show kIntroSeenPrefsKey;
import 'wifi_setup/wifi_setup_screens.dart';

/// Intro video shown over the main screen at launch. The main screen is
/// already built underneath (see `_AppRoot` in main.dart) so the dashboard
/// can load while this plays; [onFinished] fires once the video, the
/// first-run disclaimer and the dashboard's first data are all done, and
/// the parent fades this away.
class OnboardingScreen extends StatefulWidget {
  final VideoPlayerController videoController;
  final VoidCallback onFinished;

  const OnboardingScreen({
    super.key,
    required this.videoController,
    required this.onFinished,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  // Upper bound on holding the last frame for dashboard data — on a dead
  // connection the dashboard falls back to its own empty/offline states.
  static const Duration _maxDataWait = Duration(seconds: 6);

  late final VideoPlayerController _controller = widget.videoController;
  bool _ready = false;
  bool _showLoader = false;

  @override
  void initState() {
    super.initState();
    _controller.initialize().then(
      (_) {
        if (!mounted) return;
        setState(() => _ready = true);
        _controller.play();

        Future.delayed(_controller.value.duration, () {
          if (mounted) {
            _proceedAfterVideo();
          }
        });
      },
      // No video to play — move on rather than sit on a black screen.
      onError: (_) {
        if (mounted) _proceedAfterVideo();
      },
    );
  }

  Future<void> _proceedAfterVideo() async {
    final prefs = await SharedPreferences.getInstance();
    final hasSeenDisclaimer = prefs.getBool('hasSeenDisclaimer') ?? false;

    if (!hasSeenDisclaimer && mounted) {
      await showDialog(
        context: context,
        barrierDismissible: false, // must tap Close
        builder: (_) => const DisclaimerDialog(wash: false),
      );
      await prefs.setBool('hasSeenDisclaimer', true);
    }

    // Setup is required until a household or device is linked (first launch,
    // reinstall, cleared data). The legacy code is entered through the same
    // flow, via "Skip to linking".
    if (!HouseholdScope.isLinked) {
      if (!mounted) return;
      final showIntro = !(prefs.getBool(kIntroSeenPrefsKey) ?? false);
      await showWifiSetupFlow(context, firstRun: true, showIntro: showIntro);
      if (!mounted) return;
      splashDoneNotifier.value = true;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => HouseholdScope.isLinked ? const MainScreen() : const DeviceIdEntryScreen(),
        ),
      );
      return;
    }

    await _waitForDashboard();

    if (mounted) widget.onFinished();
  }

  // Holds on the video's last frame until the dashboard underneath has its
  // first data, so it's never revealed half-empty. The loader only shows
  // up if the wait is long enough to notice.
  Future<void> _waitForDashboard() async {
    if (dashboardReadyNotifier.value) return;

    final loaded = Completer<void>();
    void onReady() {
      if (dashboardReadyNotifier.value && !loaded.isCompleted) {
        loaded.complete();
      }
    }

    final loaderTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _showLoader = true);
    });
    dashboardReadyNotifier.addListener(onReady);
    await loaded.future.timeout(_maxDataWait, onTimeout: () {});
    dashboardReadyNotifier.removeListener(onReady);
    loaderTimer.cancel();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_ready)
            SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _controller.value.size.width,
                  height: _controller.value.size.height,
                  child: VideoPlayer(_controller),
                ),
              ),
            ),
          // Before the video is ready: plain black, no spinner — feels instant.
          if (_showLoader)
            Align(
              alignment: const Alignment(0, 0.75),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 250),
                builder: (_, opacity, child) =>
                    Opacity(opacity: opacity, child: child),
                child: Lottie.asset(
                  'assets/spark loading.json',
                  width: 40,
                  height: 40,
                  fit: BoxFit.contain,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
