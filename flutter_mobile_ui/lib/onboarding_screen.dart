import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'main.dart'; // Contains your MainScreen / Dashboard
import 'disclaimer_dialog.dart';

class OnboardingScreen extends StatefulWidget {
  final VideoPlayerController videoController;

  const OnboardingScreen({super.key, required this.videoController});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final VideoPlayerController _controller = widget.videoController;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller.initialize().then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
      _controller.play();

      Future.delayed(_controller.value.duration, () {
        if (mounted) {
          _proceedAfterVideo();
        }
      });
    });
  }

  Future<void> _proceedAfterVideo() async {
    final prefs = await SharedPreferences.getInstance();
    final hasSeenDisclaimer = prefs.getBool('hasSeenDisclaimer') ?? false;

    if (!hasSeenDisclaimer && mounted) {
      await showDialog(
        context: context,
        barrierDismissible: false, // must tap Close
        builder: (_) => const DisclaimerDialog(),
      );
      await prefs.setBool('hasSeenDisclaimer', true);
    }

    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const MainScreen()),
      );
    }
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
      body: _ready
          ? Stack(
              children: [
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
              ],
            )
          : const SizedBox.expand(), // plain black, no spinner — feels instant
    );
  }
}