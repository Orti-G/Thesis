import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

// ── IMPORTS FOR YOUR ACTUAL FILES ─────────────────────────────────────────
import 'dashboard.dart';
import 'billing.dart' as billing;
import 'alert.dart';
import 'settings.dart';
import 'onboarding_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

final ValueNotifier<bool> testModeNotifier = ValueNotifier(false);
final ValueNotifier<String> nicknameNotifier = ValueNotifier('My Home'); // <-- Your separate splash layout file

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  final prefs = await SharedPreferences.getInstance();
  testModeNotifier.value = prefs.getBool('test_mode') ?? false;
  nicknameNotifier.value = prefs.getString('nickname') ?? 'My Home';

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      // Setting this to OnboardingScreen makes it the first thing that opens
      home: OnboardingScreen(), 
    );
  }
}

// ── MAIN APP NAVIGATION WRAPPER ─────────────────────────────────────────
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