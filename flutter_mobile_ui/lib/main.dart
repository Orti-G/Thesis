import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:firebase_core/firebase_core.dart';

// ── IMPORT YOUR ACTUAL FILES HERE ─────────────────────────────────────────
import 'dashboard.dart';

// Fix for the ambiguous import error: giving this import a prefix
import 'billing.dart' as billing;

import 'alert.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

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

// ── 1. WELCOME SCREEN WITH LOTTIE ─────────────────────────────────────────
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  static const Color accentColor = Color(0xFFFA8B39);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late AnimationController _lottieController;

  bool _showButton = false;

  @override
  void initState() {
    super.initState();

    _lottieController = AnimationController(vsync: this);

    _lottieController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() {
          _showButton = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _lottieController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,

      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,

          children: [
            Center(
              child: Lottie.asset(
                'assets/Comp 1.json',

                controller: _lottieController,

                width: 500,
                height: 500,

                onLoaded: (composition) {
                  _lottieController
                    ..duration = composition.duration
                    ..forward();
                },
              ),
            ),

            AnimatedOpacity(
              opacity: _showButton ? 1.0 : 0.0,

              duration: const Duration(milliseconds: 500),

              child: SizedBox(
                width: 220,
                height: 45,

                child: ElevatedButton(
                  onPressed: _showButton
                      ? () {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const MainScreen(),
                            ),
                          );
                        }
                      : null,

                  style: ElevatedButton.styleFrom(
                    backgroundColor: HomePage.accentColor,
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
            ),

            const SizedBox(height: 16),
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

  // Since we are creating instances of classes, we use 'late'
  // so it initializes when needed
  late final List<Widget> _screens = [
    // IMPORTANT:
    // Make sure the class inside dashboard.dart
    // is actually named "Dashboard"

    const Dashboard(),

    // Using the "billing." prefix fixes
    // the ambiguous import error
    billing.BillingScreen(),

    const AlertsScreen(),

    const Center(
      child: Text("Settings"),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,

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
        padding: const EdgeInsets.only(
          left: 24,
          right: 24,
          bottom: 28,
        ),

        child: Container(
          height: 72,

          decoration: BoxDecoration(
            color: Colors.white,

            borderRadius: BorderRadius.circular(40),

            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.10),
                blurRadius: 24,
                offset: const Offset(0, 6),
              ),
            ],
          ),

          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,

            children: [
              _buildNavItem(
                index: 0,
                icon: Icons.home_rounded,
                label: 'Home',
              ),

              _buildNavItem(
                index: 1,
                icon: Icons.receipt_long_outlined,
                label: 'Billing',
              ),

              _buildNavItem(
                index: 2,
                icon: Icons.notifications_outlined,
                label: 'Alerts',
              ),

              _buildNavItem(
                index: 3,
                icon: Icons.settings_outlined,
                label: 'Settings',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required int index,
    required IconData icon,
    required String label,
  }) {
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

              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),

              decoration: BoxDecoration(
                color:
                    isSelected ? primaryOrange : Colors.transparent,

                borderRadius: BorderRadius.circular(30),
              ),

              child: Icon(
                icon,
                size: 22,
                color:
                    isSelected ? Colors.white : navIconColor,
              ),
            ),

            const SizedBox(height: 2),

            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),

              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected
                    ? FontWeight.w700
                    : FontWeight.w500,
                color:
                    isSelected ? Colors.black87 : navIconColor,
              ),

              child: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}