import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'main.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final Color primaryOrange = const Color(0xFFF26E22);
  final Color bgColor = const Color(0xFFFAFAFA);
  final Color textDark = const Color(0xFF1E1E1E);

  static const int _tapsToUnlock = 5;

  late final TextEditingController _nicknameController;
  bool _testMode = false;
  String _nickname = 'My Home';

  int _aboutTapCount = 0;
  bool _devModeUnlocked = false;

  @override
  void initState() {
    super.initState();
    _nickname = nicknameNotifier.value;
    _nicknameController = TextEditingController(text: _nickname);
    _testMode = testModeNotifier.value;
  }

  @override
  void dispose() {
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

  void _handleAboutTap() {
    _showAboutSheet();
  }

  void _handleLockedTestModeTap() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Locked — tap "About" a few times to unlock')),
    );
  }

  void _showAboutSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'About',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: textDark),
            ),
            const SizedBox(height: 16),
            _buildAboutRow(
              icon: Icons.bolt_outlined,
              label: 'KURO',
              value: 'Kuryente Usage and Residential Observation',
            ),
            const Divider(height: 24),
            _buildAboutRow(
              icon: Icons.dashboard_outlined,
              label: 'What it does',
              value: 'Smart Household Electrical Monitoring System',
            ),
            const Divider(height: 24),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _handleVersionTap,
              child: _buildAboutRow(
                icon: Icons.info_outline,
                label: 'Version',
                value: '1.0.0 (Thesis Prototype)',
              ),
            ),
            const Divider(height: 24),
            _buildAboutRow(
              icon: Icons.people_outline,
              label: 'Developers',
              value: 'Eddh Delapeña, Lyndon Salcedo, Mark Ortigueras',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAboutRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 22, color: primaryOrange),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: textDark)),
              const SizedBox(height: 2),
              Text(value, style: TextStyle(fontSize: 14, color: Colors.grey[600])),
            ],
          ),
        ),
      ],
    );
  }

  void _handleVersionTap() {
    if (_devModeUnlocked) return;

    setState(() => _aboutTapCount++);

    final remaining = _tapsToUnlock - _aboutTapCount;

    if (remaining <= 0) {
      setState(() => _devModeUnlocked = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Diagnostic mode unlocked')),
      );
      return;
    }

    if (_aboutTapCount >= 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$remaining more tap${remaining == 1 ? '' : 's'} to unlock diagnostic mode')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 16.0),
                children: [
                  _buildTile(
                    icon: Icons.home_outlined,
                    label: _nickname,
                    onTap: _editNickname,
                    trailing: Icon(Icons.chevron_right, size: 24, color: Colors.grey[400]),
                  ),
                  _buildTile(
                    icon: Icons.info_outline,
                    label: 'About',
                    onTap: _handleAboutTap,
                    trailing: Icon(Icons.chevron_right, size: 24, color: Colors.grey[400]),
                  ),
                  _buildTestModeTile(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTestModeTile() {
    final locked = !_devModeUnlocked;

    return Opacity(
      opacity: locked ? 0.4 : 1.0,
      child: InkWell(
        onTap: locked ? _handleLockedTestModeTap : null,
        borderRadius: BorderRadius.circular(12),
        splashColor: Colors.transparent,
        highlightColor: Colors.grey.withValues(alpha: 0.05),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(locked ? Icons.lock_outline : Icons.science_outlined,
                      size: 24, color: primaryOrange),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'Test Mode',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: textDark),
                    ),
                  ),
                  IgnorePointer(
                    ignoring: locked,
                    child: Switch.adaptive(
                      value: _testMode,
                      activeColor: primaryOrange,
                      onChanged: locked ? null : _onTestModeChanged,
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 40, top: 4),
                child: Text(
                  'This setting is for developers only',
                  style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTile({
    required IconData icon,
    required String label,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      splashColor: Colors.transparent,
      highlightColor: Colors.grey.withValues(alpha: 0.05),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 16.0),
        child: Row(
          children: [
            Icon(icon, size: 24, color: primaryOrange),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: textDark),
              ),
            ),
            if (trailing != null) trailing,
          ],
        ),
      ),
    );
  }
}