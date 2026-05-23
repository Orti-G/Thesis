import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

// ── IMPORT YOUR ACTUAL FILES HERE ─────────────────────────────────────────
import 'dashboard.dart';
import 'billing.dart'; // This connects your navigation to your real billing file
import 'alert.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: HomePage(),
    );
  }
}

// ── 1. WELCOME SCREEN WITH LOTTIE ──────────────────────────────────────────
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static const Color accentColor = Color(0xFFFA8B39);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // LOTTIE ANIMATION
            Center(
              child: Lottie.asset(
                'assets/Comp 1.json',
                width: 500,
                height: 500,
                repeat: false,
              ),
            ),

            // CONTINUE AS GUEST BUTTON
            SizedBox(
              width: 220,
              height: 45,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const MainScreen(),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor,
                  foregroundColor: Colors.white,
                  elevation: 3,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(40),
                  ),
                ),
                child: const Text(
                  'TRY BETA NOW',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // LOGIN / SIGN UP BUTTON

          ],
        ),
      ),
    );
  }
}

// ── 2. MAIN APP NAVIGATION WRAPPER ─────────────────────────────────────────
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedNavIndex = 0;
  final Color primaryOrange = const Color(0xFFF26E22);
  final Color navIconColor = const Color(0xFF8C6B5E);

  // List of screens corresponding to your nav items
  final List<Widget> _screens = [
    const Dashboard(),                     // Index 0: Home (from dashboard.dart)
    const BillingScreen(),                 // Index 1: Billing (now pointing to billing.dart)
    const AlertsScreen(),   // Index 2: Alerts (Placeholder)
    const Center(child: Text("Settings")), // Index 3: Settings (Placeholder)
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true, // Ensures content goes behind the floating navbar
      body: IndexedStack(
        index: _selectedNavIndex,
        children: _screens,
      ),
      bottomNavigationBar: _buildFloatingNavBar(),
    );
  }

  // ── FLOATING NAV BAR BUILDER ───────────────────────────────────────────────
  Widget _buildFloatingNavBar() {
    return Container(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.only(left: 24, right: 24, bottom: 28),
        child: Container(
          height: 72,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(40),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.10),
                blurRadius: 24,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildNavItem(index: 0, icon: Icons.home_rounded, label: 'Home'),
              _buildNavItem(index: 1, icon: Icons.receipt_long_outlined, label: 'Billing'),
              _buildNavItem(index: 2, icon: Icons.notifications_outlined, label: 'Alerts'),
              _buildNavItem(index: 3, icon: Icons.settings_outlined, label: 'Settings'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem({required int index, required IconData icon, required String label}) {
    final bool isSelected = _selectedNavIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedNavIndex = index),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 72,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? primaryOrange : Colors.transparent,
                borderRadius: BorderRadius.circular(30),
              ),
              child: Icon(
                icon,
                size: 22,
                color: isSelected ? Colors.white : navIconColor,
              ),
            ),
            const SizedBox(height: 2),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? Colors.black87 : navIconColor,
              ),
              child: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}

// Note: The dummy "BillingScreen" class has been deleted from here 
// so your code links directly to the one declared inside 'billing.dart'.