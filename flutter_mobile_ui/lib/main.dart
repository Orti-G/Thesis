import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

// ── IMPORT YOUR ACTUAL FILES HERE ─────────────────────────────────────────
import 'dashboard.dart';
import 'billing.dart' as billing;
import 'alert.dart';
import 'settings.dart';
import 'onboarding_screen.dart'; // <-- Added the import for your new layout

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
                width: 300,
                height: 300,
                onLoaded: (composition) {
                  _lottieController
                    ..duration = composition.duration
                    ..forward();
                },
              ),
            ),
            
            // ── NEW ANIMATED TEXT ADDED HERE ──
            AnimatedOpacity(
              opacity: _showButton ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 600),
              child: AnimatedSlide(
                offset: _showButton ? Offset.zero : const Offset(0, 0.5),
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeOutCubic,
                child: const Padding(
                  padding: EdgeInsets.only(bottom: 24.0),
                  child: Text(
                    'Kuryente Usage & Residential Observation',
                    style: TextStyle(
                      fontSize: 15, // Small
                      fontWeight: FontWeight.bold, // Bold
                      color: Colors.grey, // Gray color
                    ),
                  ),
                ),
              ),
            ),

            // ── NEW GLASS-EFFECT BUTTON ──
            AnimatedOpacity(
              opacity: _showButton ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 800), // Slightly delayed after text
              child: Container(
                width: 220,
                height: 48,
                decoration: BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: HomePage.accentColor.withOpacity(0.15),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(40),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
                    child: TextButton(
                      onPressed: _showButton
                          ? () {
                              // ROUTE TO ONBOARDING INSTEAD OF MAINSCREEN DIRECTLY
                              Navigator.pushReplacement(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => const OnboardingScreen(),
                                ),
                              );
                            }
                          : null,
                      style: TextButton.styleFrom(
                        // Semi-transparent base to create the glass tint
                        backgroundColor: HomePage.accentColor.withOpacity(0.18),
                        foregroundColor: HomePage.accentColor,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(40),
                          // The crisp fine border makes the glass look defined
                          side: BorderSide(
                            color: HomePage.accentColor.withOpacity(0.4),
                            width: 1.5,
                          ),
                        ),
                      ),
                      child: const Text(
                        'TRY BETA NOW',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
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
  final Color badgeRed = const Color(0xFFE53935);

  final DatabaseReference _anomalyRef =
      FirebaseDatabase.instance.ref().child('anomaly_alert');

  late final List<Widget> _screens = [
    const Dashboard(),
    billing.BillingScreen(),
    AlertsScreen(),
    const SettingsScreen(),
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

  Widget _buildFloatingNavBar() {
    const double navHeight = 72.0;
    const double navBorderRadius = 40.0;
    const EdgeInsets navPadding = EdgeInsets.only(left: 24, right: 24, bottom: 28);

    return Padding(
      padding: navPadding,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            height: navHeight,
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(navBorderRadius),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.10),
                  blurRadius: 24,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(navBorderRadius),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8.0, sigmaY: 8.0),
              child: Container(
                height: navHeight,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.80),
                  borderRadius: BorderRadius.circular(navBorderRadius),
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
                    StreamBuilder<DatabaseEvent>(
                      stream: _anomalyRef.onValue,
                      builder: (context, snapshot) {
                        bool showRedDot = false;
                        if (snapshot.hasData && snapshot.data?.snapshot.value != null) {
                          final data = snapshot.data!.snapshot.value as Map<dynamic, dynamic>;
                          showRedDot = data['is_anomaly'] ?? false;
                        }
                        return _buildNavItem(
                          index: 2,
                          icon: Icons.notifications_outlined,
                          label: 'Alerts',
                          showBadge: showRedDot,
                        );
                      },
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
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem({
    required int index,
    required IconData icon,
    required String label,
    bool showBadge = false,
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
                color: isSelected ? primaryOrange : Colors.transparent,
                borderRadius: BorderRadius.circular(30),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(
                    icon,
                    size: 22,
                    color: isSelected ? Colors.white : navIconColor,
                  ),
                  if (showBadge)
                    Positioned(
                      top: -2,
                      right: -2,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: badgeRed,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected ? primaryOrange : Colors.white,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                ],
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