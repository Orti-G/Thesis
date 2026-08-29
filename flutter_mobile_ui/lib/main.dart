import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

// ── IMPORTS FOR YOUR ACTUAL FILES ─────────────────────────────────────────
import 'dashboard.dart';
import 'billing.dart' as billing;
import 'alert.dart';
import 'settings.dart';
import 'onboarding_screen.dart';
import 'advisories.dart';
import 'package:shared_preferences/shared_preferences.dart';

final ValueNotifier<bool> testModeNotifier = ValueNotifier(false);
final ValueNotifier<String> nicknameNotifier = ValueNotifier('My Home'); // <-- Your separate splash layout file

// ── FCM / LOCAL NOTIFICATIONS SETUP ───────────────────────────────────────
const String kBackendBaseUrl = 'http://35.209.250.46:8000'; // TODO: move to config if this changes per env

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel highChannel = AndroidNotificationChannel(
  'high_channel',
  'Anomaly Alerts',
  description: 'Notifications for detected energy anomalies',
  importance: Importance.high,
);

const AndroidNotificationChannel mediumChannel = AndroidNotificationChannel(
  'medium_channel',
  'Billing Warnings',
  description: 'Notifications for Meralco tier-crossing warnings',
  importance: Importance.defaultImportance,
);

const AndroidNotificationChannel lowChannel = AndroidNotificationChannel(
  'low_channel',
  'Bill Forecasts',
  description: 'Notifications for projected bill estimates',
  importance: Importance.low,
);

// Must be top-level — not inside any class
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // OS shows the notification automatically when app is background/terminated.
  // Add background-only logic here if you ever need it (e.g. local logging).
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  // Register background message handler as early as possible.
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

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

  // Screens stay in their ORIGINAL index order (Settings = index 3,
  // Advisories/Analytics = index 4) so nothing elsewhere in the app that
  // references a tab by index breaks. Only the nav bar's *visual* order
  // is changed below — Settings still reports index 3, it just renders
  // in the last slot of the row.
  late final List<Widget> _screens = [
    const Dashboard(),
    billing.BillingScreen(),
    AlertsScreen(),
    const SettingsScreen(),
    AdvisoriesScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _setupFCM();
  }

  // ── FCM SETUP ────────────────────────────────────────────────────────
  Future<void> _setupFCM() async {
    final FirebaseMessaging fcm = FirebaseMessaging.instance;

    // 1 — Request permission
    final NotificationSettings settings = await fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus != AuthorizationStatus.authorized) {
      debugPrint('❌ Notification permission denied');
      return;
    }

    // Create the Android notification channel and init local notifications.
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    await flutterLocalNotificationsPlugin.initialize(
      settings: const InitializationSettings(android: androidSettings),
      onDidReceiveNotificationResponse: (details) {
        // Local (foreground-shown) notification tapped.
        // payload carries the same "type" string sent from the backend.
        _handleNotificationTap({'type': details.payload});
      },
    );

    final androidPlugin = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(highChannel);
    await androidPlugin?.createNotificationChannel(mediumChannel);
    await androidPlugin?.createNotificationChannel(lowChannel);

    // 2 — Get token and register with backend
    final String? token = await fcm.getToken();
    if (token != null) {
      debugPrint('📱 FCM Token: $token');
      await _registerToken(token);
    }

    // 3 — Re-register automatically when the token refreshes
    fcm.onTokenRefresh.listen((newToken) async {
      await _registerToken(newToken);
    });

    // 4 — FOREGROUND: app open and visible — OS won't show a banner,
    // so we show one ourselves via flutter_local_notifications.
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('📩 Foreground message: ${message.notification?.title}');

      final AndroidNotificationChannel channel =
          _channelForType(message.data['type']);

      flutterLocalNotificationsPlugin.show(
        id: message.hashCode,
        title: message.notification?.title ?? '⚠️ Anomalya',
        body: message.notification?.body ?? '',
        payload: message.data['type'],
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channel.id,
            channel.name,
            channelDescription: channel.description,
            importance: channel.importance,
            priority: Priority.high,
            icon: '@mipmap/ic_launcher',
          ),
        ),
      );
    });

    // 5 — BACKGROUND: app open but minimized, user taps the OS notification
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('📩 Background notification tapped');
      _handleNotificationTap(message.data);
    });

    // 6 — TERMINATED: app was fully closed, user tapped notification to open it
    final RemoteMessage? initialMessage = await fcm.getInitialMessage();
    if (initialMessage != null) {
      debugPrint('📩 Terminated notification tapped — app opened');
      _handleNotificationTap(initialMessage.data);
    }
  }

  Future<void> _registerToken(String token) async {
    try {
      await http.post(
        Uri.parse('$kBackendBaseUrl/register-token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'token': token}),
      );
      debugPrint('✅ Token registered with backend');
    } catch (e) {
      debugPrint('⚠️ Token registration failed: $e');
    }
  }

  // Maps a push payload's "type" field to the Android channel it should
  // display on. Falls back to highChannel if type is missing/unrecognized.
  AndroidNotificationChannel _channelForType(String? type) {
    switch (type) {
      case 'tier_warning':
        return mediumChannel;
      case 'forecast':
        return lowChannel;
      case 'anomaly':
      default:
        return highChannel;
    }
  }

  // Notification tap → route to the relevant tab based on type.
  // Uses the IndexedStack, not Navigator, since MainScreen owns navigation
  // via _selectedNavIndex rather than routes.
  void _handleNotificationTap(Map<String, dynamic> data) {
    switch (data['type']) {
      case 'anomaly':
        debugPrint(
            'Navigate to anomaly screen — Power: ${data['power_avg']}W at ${data['timestamp']}');
        _goToTab(2); // Alerts
        break;
      case 'tier_warning':
      case 'forecast':
        debugPrint('Navigate to billing screen — type: ${data['type']}');
        _goToTab(1); // Billing
        break;
      default:
        _goToTab(2); // Alerts as a safe default
    }
  }

  void _goToTab(int index) {
    if (mounted) {
      setState(() => _selectedNavIndex = index);
    }
  }

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
    const EdgeInsets navPadding = EdgeInsets.only(left: 12, right: 12, bottom: 28);

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
                      index: 4,
                      icon: Icons.bar_chart_rounded,
                      label: 'Analytics',
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
        width: 58,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
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
                    size: 20,
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
                fontSize: 10,
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