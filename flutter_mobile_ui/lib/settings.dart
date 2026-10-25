import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'device_id_screen.dart';
import 'household_scope.dart';
import 'main.dart';
import 'remote_reset.dart';
import 'wifi_setup/setup_preview_screen.dart';
import 'wifi_setup/wifi_setup_screens.dart';

/// Where "Contact the team" writes to.
// TODO: placeholder address; replace with the team's real support inbox.
const String kSupportEmail = 'grid.support@example.com';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final Color primaryOrange = const Color(0xFFF26E22);
  final Color bgColor = const Color(0xFFFAFAFA);
  final Color textDark = const Color(0xFF1E1E1E);
  static const Color _bodyInk = Color(0xFF444444);
  static const Color _hairline = Color(0xFFECECEC);
  static const Color _mutedInk = Color(0xFF5F6368);
  static const Color _headerOrange = Color(0xFFFA8B39);
  static const Color _orangeInk = Color(0xFFC2501A);
  static const Color _iconWell = Color(0xFFF1F3F4);

  static const int _tapsToUnlock = 5;

  /// Developer options (Test Mode and its tools) stay hidden until unlocked
  /// once by tapping Version in About. The unlock is saved, so it survives
  /// closing the app; "Hide developer options" puts it back.
  static const String _devUnlockedKey = 'dev_options_unlocked';

  late final TextEditingController _nicknameController;
  bool _testMode = false;
  String _nickname = 'My Home';
  String? _deviceId;

  // Live `devices/<id>/sync`. A reset is only possible while it's true:
  // the VM flips it to false as soon as a reset is delivered, and it only
  // comes back once the device is provisioned again and posts a reading.
  StreamSubscription<DatabaseEvent>? _syncSub;
  bool _deviceOnline = false;
  // False until the first `sync` answer, so "offline" help never flashes
  // while the screen is still finding out.
  bool _syncKnown = false;

  // Whether this phone set the monitor up (its owner). Decides what the one
  // Wi-Fi tile does: owners change Wi-Fi through a remote reset, everyone
  // else runs setup. Null until the first answer comes in.
  StreamSubscription<bool>? _ownerSub;
  bool? _isOwner;

  int _aboutTapCount = 0;
  bool _devModeUnlocked = false;

  // Read from the installed app, i.e. pubspec's `version:` plus the build
  // number stamped by tool/build.ps1.
  String _versionLabel = '…';

  @override
  void initState() {
    super.initState();
    _nickname = nicknameNotifier.value;
    _nicknameController = TextEditingController(text: _nickname);
    _testMode = testModeNotifier.value;
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(() => _versionLabel =
          '${info.version} (build ${info.buildNumber})');
    });
    _loadWifiSetupStatus();
  }

  Future<void> _loadWifiSetupStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final deviceId = HouseholdScope.id;
    final devUnlocked = prefs.getBool(_devUnlockedKey) ?? false;
    if (!mounted) return;
    final deviceChanged = deviceId != _deviceId;
    setState(() {
      _deviceId = deviceId;
      _devModeUnlocked = devUnlocked;
    });
    if (deviceChanged) _watchSync();
    // Test Mode left on from before the unlock was saved would otherwise
    // keep showing sample data with its switch hidden.
    if (!devUnlocked && _testMode) await _onTestModeChanged(false);
  }

  void _watchSync() {
    _syncSub?.cancel();
    _syncSub = null;
    _ownerSub?.cancel();
    _ownerSub = null;
    final id = _deviceId;
    if (id == null || HouseholdScope.isLegacy) {
      setState(() {
        _deviceOnline = false;
        _syncKnown = false;
        _isOwner = false;
      });
      return;
    }
    setState(() {
      _isOwner = null;
      _syncKnown = false;
    });
    _ownerSub = watchIsOwner(id).listen(
      (owner) {
        if (mounted && owner != _isOwner) setState(() => _isOwner = owner);
      },
      onError: (Object e) {
        debugPrint('[Settings] owner listener error: $e');
        // Can't tell: fall back to setup, which works for anyone.
        if (mounted) setState(() => _isOwner = false);
      },
    );
    _syncSub = FirebaseDatabase.instance
        .ref('devices/$id/sync')
        .onValue
        .listen(
          (event) {
            final v = event.snapshot.value;
            final online = v == true || v == 'true';
            if (mounted && (online != _deviceOnline || !_syncKnown)) {
              setState(() {
                _deviceOnline = online;
                _syncKnown = true;
              });
            }
          },
          onError: (Object e) => debugPrint('[Settings] sync listener error: $e'),
        );
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    _ownerSub?.cancel();
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _saveNickname(String value) async {
    final nickname = value.trim().isEmpty ? 'My Home' : value.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nickname', nickname);
    nicknameNotifier.value = nickname;
    setState(() => _nickname = nickname);
  }

  Future<void> _editNickname() async {
    _nicknameController.text = _nickname;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(
                primary: primaryOrange,
              ),
        ),
        child: AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Household Nickname', style: TextStyle(color: textDark)),
          content: TextField(
            controller: _nicknameController,
            autofocus: true,
            cursorColor: primaryOrange,
            style: TextStyle(color: textDark),
            decoration: InputDecoration(
              hintText: "e.g. Lyndon's Home",
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.grey[400]!),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: primaryOrange, width: 2),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: TextStyle(color: Colors.grey[600])),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, _nicknameController.text),
              child: Text('Save', style: TextStyle(color: primaryOrange, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      await _saveNickname(result);
    }
  }

  Future<void> _onTestModeChanged(bool val) async {
    setState(() => _testMode = val);
    testModeNotifier.value = val;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('test_mode', val);
  }

  // ── Wi-Fi: one tile ──────────────────────────────────────────────────────
  // Not the owner (a viewer, or skipped straight to linking): set up Wi-Fi,
  // which also makes this phone the owner. The owner: change Wi-Fi, which
  // remotely resets the monitor and runs setup again in one go.

  Future<void> _handleWifiSetupTap() async {
    final previousId = _deviceId;
    await showWifiSetupFlow(context);
    await _afterSetupFlow(previousId);
  }

  Future<void> _handleChangeWifiTap() async {
    final deviceId = _deviceId;
    if (deviceId == null || !_deviceOnline) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Change Wi-Fi?', style: TextStyle(color: textDark)),
        content: Text(
          'Your monitor will forget its Wi-Fi and restart into setup mode, and '
          "you'll connect it again right away. Stay next to your monitor.",
          style: TextStyle(color: Colors.grey[700], height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: TextStyle(color: Colors.grey[600])),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Continue', style: TextStyle(color: primaryOrange, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await showChangeWifiFlow(context, deviceId);
    await _afterSetupFlow(deviceId);
  }

  /// After either flow: re-read what setup saved and, if it provisioned a
  /// different unit, rebuild the app shell so every tab listens to it.
  Future<void> _afterSetupFlow(String? previousId) async {
    await _loadWifiSetupStatus();
    if (!mounted || _deviceId == null || _deviceId == previousId) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const MainScreen()), (route) => false);
  }

  /// Opens the mail app with the app version and linked device already in
  /// the message, so the team doesn't have to ask for them.
  Future<void> _contactTeam() async {
    final body = '\n\n---\nGRID $_versionLabel\nLinked to: $_linkedLabel';
    final uri = Uri.parse(
      'mailto:$kSupportEmail?subject=${Uri.encodeComponent('GRID help')}&body=${Uri.encodeComponent(body)}',
    );
    var opened = false;
    try {
      opened = await launchUrl(uri);
    } catch (e) {
      debugPrint('[Settings] mailto failed: $e');
    }
    if (opened || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('No email app found. Write to $kSupportEmail')));
  }

  void _handleAboutTap() {
    _showAboutSheet();
  }

  void _showAboutSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  'GRID',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5, color: textDark),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'The companion app to the GRID device, a whole-house power monitor. It shows your live usage, '
                'where this month\'s bill is heading, and anything unusual.',
                style: TextStyle(fontSize: 14, height: 1.45, color: _bodyInk),
              ),
              const SizedBox(height: 16),
              // Tapping Version five times unlocks the developer options.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _handleVersionTap,
                child: _buildAboutRow(label: 'Version', value: _versionLabel),
              ),
              _buildAboutRow(label: 'Thesis', value: 'Smart Household Electrical Monitoring System'),
              _buildAboutRow(label: 'Developers', value: 'Eddh Delapeña, Lyndon Salcedo, Mark Ortigueras'),
              const SizedBox(height: 16),
              const Text(
                'GRID is independent. It isn\'t affiliated with or endorsed by Meralco.',
                style: TextStyle(fontSize: 13, height: 1.45, color: _mutedInk),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A label over its value, with a hairline under it: the same rhythm as
  /// the Settings list, stacked because these values run long.
  Widget _buildAboutRow({required String label, required String value}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _mutedInk)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, height: 1.3, color: textDark)),
        ],
      ),
    );
  }

  void _handleVersionTap() {
    if (_devModeUnlocked) return;

    setState(() => _aboutTapCount++);

    final remaining = _tapsToUnlock - _aboutTapCount;

    if (remaining <= 0) {
      setState(() => _devModeUnlocked = true);
      SharedPreferences.getInstance().then((prefs) => prefs.setBool(_devUnlockedKey, true));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Developer options unlocked — find them in Settings')),
      );
      return;
    }

    if (_aboutTapCount >= 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$remaining more tap${remaining == 1 ? '' : 's'} to unlock developer options')),
      );
    }
  }

  /// Hides the developer options again and switches Test Mode off, so the
  /// app can't be left showing sample data with no way to see why.
  Future<void> _hideDeveloperOptions() async {
    if (_testMode) await _onTestModeChanged(false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_devUnlockedKey, false);
    if (!mounted) return;
    setState(() {
      _devModeUnlocked = false;
      _aboutTapCount = 0;
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Developer options hidden. Tap Version in About 5 times to bring them back.')),
      );
  }


  // The Meter Face: an orange header field holding the home name, then white
  // hairline cards on the ground. Only a device that looks offline gets a
  // state card; everything else is plain rows.
  @override
  Widget build(BuildContext context) {
    final linked = _deviceId != null && !HouseholdScope.isLegacy;
    final showOfflineHelp = linked && _syncKnown && !_deviceOnline;

    return Scaffold(
      backgroundColor: bgColor,
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          _buildHeader(context),
          Padding(
            // Bottom space so the last row clears the floating nav.
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showOfflineHelp) ...[
                  _buildOfflineCard(),
                  const SizedBox(height: 12),
                ],
                _buildCard([
                  _buildRow(label: 'Household', value: _linkedLabel, onTap: () => switchDevice(context)),
                  if (!HouseholdScope.isLegacy) _buildWifiRow(),
                ]),
                const SizedBox(height: 12),
                _buildCard([
                  _buildRow(
                    label: 'Contact the team',
                    note: 'Something not working, or a question?',
                    onTap: _contactTeam,
                  ),
                  _buildRow(label: 'About', onTap: _handleAboutTap),
                ]),
                // Developer options: not drawn at all until unlocked.
                if (_devModeUnlocked) ...[
                  const SizedBox(height: 28),
                  Semantics(
                    header: true,
                    child: Text(
                      'Developer options',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: textDark),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildCard([
                    _buildRow(
                      label: 'Test Mode',
                      note: 'This setting is for developers only',
                      onTap: () => _onTestModeChanged(!_testMode),
                      trailing: Switch.adaptive(
                        value: _testMode,
                        activeThumbColor: primaryOrange,
                        onChanged: _onTestModeChanged,
                      ),
                    ),
                    if (_testMode)
                      _buildRow(
                        label: 'Preview Setup Screens',
                        note: 'Every first-run setup page, without a device',
                        onTap: () =>
                            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SetupPreviewScreen())),
                      ),
                    _buildRow(
                      label: 'Hide developer options',
                      note: 'Turns Test Mode off and hides these until unlocked again',
                      onTap: _hideDeveloperOptions,
                      showChevron: false,
                    ),
                  ]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Flat Header Orange to the status bar, the title, and the home name in a
  /// glass tile (gradient, no blur: there is nothing behind it to blur).
  Widget _buildHeader(BuildContext context) {
    return Container(
      color: _headerOrange,
      padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + 16, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: const Text(
              'Settings',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5, color: Colors.white),
            ),
          ),
          const SizedBox(height: 16),
          Semantics(
            button: true,
            label: 'Home name, $_nickname. Tap to rename.',
            excludeSemantics: true,
            child: Material(
              color: Colors.transparent,
              child: Ink(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.4)),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Colors.white.withValues(alpha: 0.3), Colors.white.withValues(alpha: 0.08)],
                  ),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: _editNickname,
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 48),
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Home name',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _nickname,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.5,
                                  height: 1.2,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Icon(Icons.edit_outlined, size: 22, color: Colors.white),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The state card for a linked GRID device that isn't reporting.
  Widget _buildOfflineCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(color: _iconWell, shape: BoxShape.circle),
            child: const Icon(Icons.wifi_off_rounded, size: 22, color: _mutedInk),
          ),
          const SizedBox(height: 12),
          Semantics(
            header: true,
            child: Text(
              'Your GRID device looks offline',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, height: 1.3, color: textDark),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Check that it has power and that your home Wi-Fi is working. '
            'It should reconnect by itself once both are back.',
            style: TextStyle(fontSize: 14, height: 1.45, color: _bodyInk),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _contactTeam,
              style: TextButton.styleFrom(foregroundColor: _orangeInk, minimumSize: const Size(48, 48)),
              child: const Text('Contact the team', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
            ),
          ),
        ],
      ),
    );
  }

  /// A white card with the hairline rule and 20px radius; rows inside are
  /// told apart by an inset hairline. The Material clips the ripples.
  Widget _buildCard(List<Widget> rows) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) children.add(const Divider(height: 1, thickness: 1, indent: 16, endIndent: 16, color: _hairline));
      children.add(rows[i]);
    }
    return Material(
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: _hairline),
      ),
      child: Column(children: children),
    );
  }

  /// Which household or device this phone is showing, in words.
  String get _linkedLabel {
    final id = _deviceId;
    if (id == null) return 'Not linked';
    if (HouseholdScope.isLegacy) return 'Original household';
    return id;
  }

  // The one Wi-Fi row. For the owner it's "Change", dimmed while `sync` is
  // false: an offline device can't take the remote reset. While ownership is
  // still being checked it shows dimmed and does nothing, so the wording
  // doesn't flip a moment after the screen opens. Anyone else gets the
  // reason in the note rather than a silently dead row.
  Widget _buildWifiRow() {
    final owner = _isOwner;

    if (_deviceId == null || owner == false) {
      return _buildRow(
        label: 'Wi-Fi',
        value: 'Set up',
        note: _deviceId == null ? null : 'Only the phone that set up your GRID device can change its Wi-Fi.',
        onTap: _handleWifiSetupTap,
      );
    }

    final available = owner == true && _deviceOnline;
    return Opacity(
      opacity: available ? 1.0 : 0.4,
      child: _buildRow(
        label: 'Wi-Fi',
        value: 'Change',
        note: owner == null
            ? null
            : _deviceOnline
            ? 'Restarts your GRID device into setup'
            : 'Available when your GRID device is online',
        onTap: available ? _handleChangeWifiTap : null,
      ),
    );
  }

  /// A label on the left and its current [value] on the right. [note] is one
  /// quiet line below the label. At least 56dp tall, and the value shrinks to
  /// an ellipsis rather than pushing the label off.
  Widget _buildRow({
    required String label,
    String? value,
    String? note,
    Widget? trailing,
    bool showChevron = true,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // With a value, the label takes only what it needs and the value gets
            // the rest, so long values (a device ID) are not clipped early.
            Flexible(
              fit: value == null ? FlexFit.tight : FlexFit.loose,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, height: 1.3, color: textDark),
                  ),
                  if (note != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      note,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w400, height: 1.35, color: _mutedInk),
                    ),
                  ],
                ],
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w400, color: _mutedInk),
                ),
              ),
            ],
            if (trailing != null)
              trailing
            else if (showChevron) ...[
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, size: 22, color: _mutedInk),
            ],
          ],
        ),
      ),
    );
  }
}
