import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart'; 
import 'main.dart'; // Contains your MainScreen / Dashboard

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  @override
  void initState() {
    super.initState();
    _startSplashTimer();
  }

  void _startSplashTimer() async {
    // Set this duration to match the length of your Lottie animation
    await Future.delayed(const Duration(seconds: 3));
    
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => const MainScreen(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Keeping your signature vibrant brand orange color for consistency
      backgroundColor: const Color.fromARGB(255, 255, 255, 255), 
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(40.0),
          child: Lottie.asset(
            'assets/Comp 1.json', // Path to your local file
            // Alternatively, use Lottie.network('https://your-url.json') if hosted online
            fit: BoxFit.contain,
            repeat: false, // Prevents it from looping endlessly before switching screens
          ),
        ),
      ),
    );
  }
}