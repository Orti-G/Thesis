import 'package:flutter/material.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Theme styling mirroring billing.dart & dashboard.dart
  final Color primaryOrange = const Color(0xFFF26E22);
  final Color creamBg = const Color(0xFFFFFDF9);
  final Color textDark = const Color(0xFF1E1E1E);

  // Hardcoded Initial states mimicking current application values
  final TextEditingController _serverController =
      TextEditingController(text: 'http://35.209.250.46:8000/forecast');
  final TextEditingController _tierCapController =
      TextEditingController(text: '200');
  
  double _graphRefreshRate = 2.0; // Current timer loop is 2s
  double _maxDataPoints = 20.0;   // Current limit is 20
  
  bool _anomalyNotifications = true;
  bool _tierCrossingAlerts = true;

  @override
  void dispose() {
    _serverController.dispose();
    _tierCapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: creamBg,
      body: SafeArea(
        child: SingleChildScrollView(
          // FIXED: Adjusted bottom padding to 70.0 to fix the massive white gap under the button
          padding: const EdgeInsets.only(top: 24.0, left: 20.0, right: 20.0, bottom: 70.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionHeader('Billing & Rates'),
              _buildSettingsCard(
                child: Column(
                  children: [
                    _buildTextFieldTile(
                      label: 'Monthly Tier Cap (kWh)',
                      subtitle: 'Used to calculate percentage thresholds',
                      controller: _tierCapController,
                      keyboardType: TextInputType.number,
                      icon: Icons.flash_on,
                    ),
                    const Divider(height: 24),
                    _buildReadOnlyTile(
                      label: 'System Currency',
                      value: 'Philippine Peso (₱)',
                      icon: Icons.payments_outlined,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              _buildSectionHeader('API & Server Connectivity'),
              _buildSettingsCard(
                child: _buildTextFieldTile(
                  label: 'Forecast Backend Server',
                  subtitle: 'Endpoint IP for predictive analytics tracking',
                  controller: _serverController,
                  keyboardType: TextInputType.url,
                  icon: Icons.dns_outlined,
                  obscureText: true,
                ),
              ),
              const SizedBox(height: 24),

              _buildSectionHeader('Dashboard Analytics Graph'),
              _buildSettingsCard(
                child: Column(
                  children: [
                    _buildSliderTile(
                      label: 'Live Refresh Speed',
                      subtitle: '${_graphRefreshRate.toStringAsFixed(1)} seconds',
                      value: _graphRefreshRate,
                      min: 1.0,
                      max: 10.0,
                      divisions: 9,
                      icon: Icons.timer_outlined,
                      onChanged: (val) => setState(() => _graphRefreshRate = val),
                    ),
                    const Divider(height: 24),
                    _buildSliderTile(
                      label: 'Max Display Data Points',
                      subtitle: '${_maxDataPoints.round()} entries visible',
                      value: _maxDataPoints,
                      min: 10.0,
                      max: 50.0,
                      divisions: 8,
                      icon: Icons.auto_graph,
                      onChanged: (val) => setState(() => _maxDataPoints = val),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              _buildSectionHeader('Alert Preferences'),
              _buildSettingsCard(
                child: Column(
                  children: [
                    _buildSwitchTile(
                      label: 'Anomaly Safety Alerts',
                      subtitle: 'Logs real-time system variance markers',
                      value: _anomalyNotifications,
                      icon: Icons.warning_amber_rounded,
                      onChanged: (val) => setState(() => _anomalyNotifications = val),
                    ),
                    const Divider(height: 24),
                    _buildSwitchTile(
                      label: 'Tier Escalation Warning',
                      subtitle: 'Warn when energy crosses threshold points',
                      value: _tierCrossingAlerts,
                      icon: Icons.notification_important_outlined,
                      onChanged: (val) => setState(() => _tierCrossingAlerts = val),
                    ),
                  ],
                ),
              ),
              // FIXED: Reduced spacing step right above the button from 40 to 20
              const SizedBox(height: 20),
              
              // Static Safe Changes Indicator Button
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: () {}, 
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryOrange,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text(
                    'Save Configurations',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── REUSABLE COMPONENT BUILDERS MATCHING APPLICATION THEME ──

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 14,
          color: textDark.withValues(alpha: 0.6),
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildSettingsCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildTextFieldTile({
    required String label,
    required String subtitle,
    required TextEditingController controller,
    required TextInputType keyboardType,
    required IconData icon,
    bool obscureText = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          backgroundColor: primaryOrange.withValues(alpha: 0.1),
          child: Icon(icon, color: primaryOrange, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(color: textDark, fontWeight: FontWeight.w700, fontSize: 14),
              ),
              Text(
                subtitle,
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 44,
                child: TextField(
                  controller: controller,
                  keyboardType: keyboardType,
                  obscureText: obscureText,
                  style: TextStyle(fontSize: 14, color: textDark, fontWeight: FontWeight.w600),
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    filled: true,
                    fillColor: creamBg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSliderTile({
    required String label,
    required String subtitle,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required IconData icon,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        CircleAvatar(
          backgroundColor: primaryOrange.withValues(alpha: 0.1),
          child: Icon(icon, color: primaryOrange, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(color: textDark, fontWeight: FontWeight.w700, fontSize: 14),
              ),
              Text(
                subtitle,
                style: TextStyle(color: primaryOrange, fontWeight: FontWeight.w600, fontSize: 12),
              ),
              SliderTheme(
                data: SliderThemeData(
                  activeTrackColor: primaryOrange,
                  inactiveTrackColor: primaryOrange.withValues(alpha: 0.1),
                  thumbColor: primaryOrange,
                  overlayColor: primaryOrange.withValues(alpha: 0.12),
                ),
                child: Slider(
                  value: value,
                  min: min,
                  max: max,
                  divisions: divisions,
                  onChanged: onChanged,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSwitchTile({
    required String label,
    required String subtitle,
    required bool value,
    required IconData icon,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        CircleAvatar(
          backgroundColor: primaryOrange.withValues(alpha: 0.1),
          child: Icon(icon, color: primaryOrange, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(color: textDark, fontWeight: FontWeight.w700, fontSize: 14),
              ),
              Text(
                subtitle,
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
              ),
            ],
          ),
        ),
        Switch.adaptive(
          value: value,
          activeColor: primaryOrange,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildReadOnlyTile({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Row(
      children: [
        CircleAvatar(
          backgroundColor: primaryOrange.withValues(alpha: 0.1),
          child: Icon(icon, color: primaryOrange, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(color: textDark, fontWeight: FontWeight.w700, fontSize: 14),
              ),
              Text(
                value,
                style: TextStyle(color: textDark, fontWeight: FontWeight.w500, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }
}