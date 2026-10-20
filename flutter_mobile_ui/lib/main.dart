import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

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

// Startup handshake between the splash and the main screen built behind it:
// the dashboard flips `dashboardReadyNotifier` once its first Firebase reads
// have answered, and `splashDoneNotifier` flips once the splash has faded
// away — anything that pops up UI on its own waits for that.
final ValueNotifier<bool> dashboardReadyNotifier = ValueNotifier(false);
final ValueNotifier<bool> splashDoneNotifier = ValueNotifier(false);

// ── FCM / LOCAL NOTIFICATIONS SETUP ───────────────────────────────────────
const String kBackendBaseUrl = 'http://35.209.250.46:8000'; // TODO: move to config if this changes per env

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel highChannel = AndroidNotificationChannel(
  'high_channel',
  'Urgent Alerts',
  description: 'Severe energy anomalies and the GRID device going offline',
  importance: Importance.high,
);

const AndroidNotificationChannel mediumChannel = AndroidNotificationChannel(
  'medium_channel',
  'Billing & Reviews',
  description: 'Meralco bracket warnings and anomalies waiting for your answer',
  importance: Importance.defaultImportance,
);

const AndroidNotificationChannel lowChannel = AndroidNotificationChannel(
  'low_channel',
  'Info & Rates',
  description: 'Monthly Meralco rate changes and other updates',
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

  // Create (but don't await) the splash video here so it starts loading
  // as early as possible without blocking app startup on it.
  final videoController = VideoPlayerController.asset('assets/grid_animation.mp4');

  runApp(MyApp(videoController: videoController));
}

class MyApp extends StatelessWidget {
  final VideoPlayerController videoController;

  const MyApp({super.key, required this.videoController});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // Splash video on top, main screen already loading underneath
      home: _AppRoot(videoController: videoController),
    );
  }
}

/// Builds the main screen straight away, underneath the splash, so the
/// dashboard loads its data while the video plays. The splash only fades
/// out once it reports finished (video, disclaimer and dashboard data).
class _AppRoot extends StatefulWidget {
  final VideoPlayerController videoController;

  const _AppRoot({required this.videoController});

  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> {
  bool _fadingOut = false;
  bool _splashGone = false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const MainScreen(),
        if (!_splashGone)
          IgnorePointer(
            ignoring: _fadingOut,
            child: AnimatedOpacity(
              opacity: _fadingOut ? 0 : 1,
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOut,
              onEnd: () {
                setState(() => _splashGone = true);
                splashDoneNotifier.value = true;
              },
              child: OnboardingScreen(
                videoController: widget.videoController,
                onFinished: () => setState(() => _fadingOut = true),
              ),
            ),
          ),
      ],
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
    // Built behind the splash now, so hold the notification-permission
    // prompt until the splash has cleared.
    if (splashDoneNotifier.value) {
      _setupFCM();
    } else {
      splashDoneNotifier.addListener(_onSplashDone);
    }
  }

  void _onSplashDone() {
    if (!splashDoneNotifier.value) return;
    splashDoneNotifier.removeListener(_onSplashDone);
    _setupFCM();
  }

  @override
  void dispose() {
    splashDoneNotifier.removeListener(_onSplashDone);
    super.dispose();
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
        // Local (foreground-shown) notification tapped. The payload is the
        // push's JSON-encoded data map (older builds sent just the type).
        Map<String, dynamic> data;
        try {
          data = jsonDecode(details.payload ?? '') as Map<String, dynamic>;
        } catch (_) {
          data = {'type': details.payload};
        }
        _handleNotificationTap(data);
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

      final String? type = message.data['type'];
      final AndroidNotificationChannel channel = _channelForType(type);

      // Keep an open review list current without pulling the user away.
      if (type == 'anomaly' || type == 'review') {
        anomalyReviewRequest.value = AnomalyReviewRequest(showInbox: false);
      }

      flutterLocalNotificationsPlugin.show(
        id: message.hashCode,
        title: message.notification?.title ?? '⚠️ Anomalya',
        body: message.notification?.body ?? '',
        payload: jsonEncode(message.data),
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
  // display on. Falls back to mediumChannel if type is missing/unrecognized.
  AndroidNotificationChannel _channelForType(String? type) {
    switch (type) {
      case 'anomaly':
      case 'device':
        return highChannel;
      case 'rates':
      case 'forecast':
        return lowChannel;
      case 'review':
      case 'bracket':
      case 'tier_warning':
      default:
        return mediumChannel;
    }
  }

  // Notification tap → route to the relevant tab based on type.
  // Uses the IndexedStack, not Navigator, since MainScreen owns navigation
  // via _selectedNavIndex rather than routes. All data values are strings.
  void _handleNotificationTap(Map<String, dynamic> data) {
    debugPrint('Notification tapped — type: ${data['type']}');
    switch (data['type']) {
      case 'anomaly':
        _goToTab(2); // Alerts
        anomalyReviewRequest.value = AnomalyReviewRequest(
          focusEventId: int.tryParse('${data['event_id']}'),
        );
        break;
      case 'review':
        // "12,15": open the list; jump to the card only when there's one.
        final ids = '${data['event_ids'] ?? ''}'
            .split(',')
            .map((id) => int.tryParse(id.trim()))
            .whereType<int>()
            .toList();
        _goToTab(2); // Alerts
        anomalyReviewRequest.value = AnomalyReviewRequest(
          focusEventId: ids.length == 1 ? ids.single : null,
        );
        break;
      case 'bracket':
      case 'tier_warning':
      case 'forecast':
        _goToTab(1); // Billing
        break;
      case 'rates':
        _goToTab(4); // Analytics: rates advisory + news feed
        break;
      case 'device':
        _goToTab(0); // Dashboard, which shows the offline sheet if needed
        deviceStatusRequest.value++;
        break;
      default:
        _goToTab(0);
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
                  color: Colors.black.withValues(alpha: 0.10),
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
                  color: Colors.white.withValues(alpha: 0.80),
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