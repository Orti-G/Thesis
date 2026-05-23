import 'package:flutter/material.dart';

class Dashboard extends StatelessWidget {
  const Dashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        backgroundColor: const Color(0xFFFA8B39), // Using your accent color
        foregroundColor: Colors.white,
      ),
      body: const Center(
        child: Text(
          'You are not Welcome, Guest!  kalbo ka naman adsfsds fluutdder  ',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}