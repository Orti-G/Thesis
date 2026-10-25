import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_database/firebase_database.dart';

import 'device_identity.dart';
import 'household_scope.dart';
import 'wifi_setup/intro_screens.dart' show NameHomeScreen;
import 'wifi_setup/setup_ui.dart';

// The saved-ID key and the ID format live in device_identity.dart.

/// Formats free typing into XXXX-XXXX: uppercases everything, strips
/// anything outside the device ID alphabet (no I, O, 0 or 1, which the
/// firmware never uses), caps it at 8 characters, and
/// auto-inserts the hyphen after the 4th. Works fine for pasted values
/// too (e.g. from a QR code down the line) since it just re-derives the
/// formatting from the raw characters each time.
class _DeviceIdInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final stripped = newValue.text.toUpperCase().replaceAll(RegExp(r'[^A-HJ-NP-Z2-9]'), '');
    final raw = stripped.length > 8 ? stripped.substring(0, 8) : stripped;

    final buffer = StringBuffer();
    for (int i = 0; i < raw.length; i++) {
      if (i == 4) buffer.write('-');
      buffer.write(raw[i]);
    }

    final formatted = buffer.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

/// The Device ID step, shared by the end of the setup flow and the
/// standalone [DeviceIdEntryScreen]. The ID is typed into eight code boxes
/// and checked against Firebase — `devices/<ID>/sync` must exist — as soon
/// as the last box fills, before anything is saved locally, so a typo never
/// gets remembered. A match turns the boxes green for a beat ("Found it!")
/// before [onLinked] runs; the caller decides where to go next.
class DeviceIdStep extends StatefulWidget {
  final int? step;
  final int? totalSteps;
  final bool showBack;
  final String title;

  /// Replaces the default instructions under the title.
  final String? subtitle;
  final VoidCallback onLinked;

  /// Setup preview only: start in this state with a sample ID, and never
  /// check Firebase or save anything.
  final DeviceIdPreview? preview;

  const DeviceIdStep({
    super.key,
    this.step,
    this.totalSteps,
    this.showBack = false,
    required this.title,
    this.subtitle,
    required this.onLinked,
    this.preview,
  });

  @override
  State<DeviceIdStep> createState() => _DeviceIdStepState();
}

/// The states the setup preview can show [DeviceIdStep] in.
enum DeviceIdPreview { empty, checking, notFound, found }

const String _kNotFoundError = 'Device not found. Check the ID against the monitor\'s screen.';

class _DeviceIdStepState extends State<DeviceIdStep> {
  final _controller = TextEditingController();
  bool _isValidating = false;
  bool _linked = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final preview = widget.preview;
    if (preview == null || preview == DeviceIdPreview.empty) return;
    _controller.text = 'K7QM-4XPD';
    _isValidating = preview == DeviceIdPreview.checking;
    _errorText = preview == DeviceIdPreview.notFound ? _kNotFoundError : null;
    _linked = preview == DeviceIdPreview.found;
  }

  bool get _looksIdShaped => isValidDeviceId(_controller.text);

  void _onChanged(String _) {
    // Editing clears the last error; filling the last box submits.
    setState(() => _errorText = null);
    if (_looksIdShaped && !_isValidating) _submit();
  }

  Future<void> _submit() async {
    // Trim defensively — covers a pasted value with stray leading/trailing
    // whitespace even though typing through the formatter above can't
    // produce any.
    final enteredId = _controller.text.trim().toUpperCase();
    if (!isValidDeviceId(enteredId) || widget.preview != null) return;

    // The original household has no device ID to verify: its code skips the
    // Firebase lookup and links straight away.
    if (enteredId == kLegacyHouseholdCode) {
      await HouseholdScope.save(enteredId);
      await _showLinked();
      return;
    }

    setState(() {
      _isValidating = true;
      _errorText = null;
    });

    try {
      // once() rather than get(): on Android, get() can hang forever when
      // the database can't be reached, which left the button spinning.
      // The timeout turns any stall into the "couldn't reach" error below.
      final event = await FirebaseDatabase.instance
          .ref('devices/$enteredId/sync')
          .once()
          .timeout(const Duration(seconds: 10));
      final snapshot = event.snapshot;

      if (!mounted) return;

      if (snapshot.exists) {
        await HouseholdScope.save(enteredId);
        await _showLinked();
      } else {
        setState(() {
          _isValidating = false;
          _errorText = _kNotFoundError;
        });
      }
    } catch (e) {
      // Timeout, offline, or a rules/permission error — the console line
      // says which.
      debugPrint('[DeviceIdStep] Firebase check for $enteredId failed: $e');
      if (!mounted) return;
      setState(() {
        _isValidating = false;
        _errorText = "Couldn't reach the server. Check your connection and try again.";
      });
    }
  }

  Future<void> _showLinked() async {
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    setState(() => _linked = true);
    // Let the "Found it!" state land before moving on.
    await Future.delayed(const Duration(milliseconds: 900));
    if (mounted) widget.onLinked();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SetupScaffold(
      step: widget.step,
      totalSteps: widget.totalSteps,
      showBack: widget.showBack && !_linked,
      // The photo shows where the ID appears; it folds away once the
      // keyboard opens.
      hero: const SetupPhoto(asset: kSetupScreenPhotoAsset, height: 168),
      title: _linked ? 'Found it!' : widget.title,
      subtitle: _linked
          ? 'Your monitor is linked to this phone.'
          : widget.subtitle ?? "Type the Device ID from your monitor's screen.",
      content: [
        SetupCodeField(
          controller: _controller,
          length: 8,
          semanticLabel: 'Device ID, 8 characters',
          helperText: _isValidating && !_linked ? 'Checking…' : 'Shown under DEVICE ID, like K7QM-4XPD',
          errorText: _errorText,
          success: _linked,
          enabled: !_linked,
          readOnly: _isValidating,
          inputFormatters: [_DeviceIdInputFormatter()],
          onChanged: _onChanged,
          onSubmitted: (_) => _looksIdShaped ? _submit() : null,
        ),
      ],
      bottom: SetupPrimaryButton(
        label: 'Link Monitor',
        loading: _isValidating,
        onPressed: _looksIdShaped ? _submit : null,
      ),
    );
  }
}

/// Standalone version of the Device ID step, outside the setup flow — used
/// by [switchDevice] and as onboarding's fallback if the flow somehow ends
/// without a saved ID.
class DeviceIdEntryScreen extends StatelessWidget {
  /// Shows a Back arrow (and lets system Back work) when this was opened from
  /// Settings, so switching can be cancelled. Onboarding's fallback has
  /// nothing to return to.
  final bool canGoBack;
  const DeviceIdEntryScreen({super.key, this.canGoBack = false});

  @override
  Widget build(BuildContext context) {
    return DeviceIdStep(
      title: 'Link your monitor',
      showBack: canGoBack,
      // Offer a new home name for the newly linked household or device; the
      // text box leads and keeping the current name is the quiet option.
      onLinked: () => Navigator.of(context).pushReplacement(
        setupRoute(builder: (_) => const NameHomeScreen(skipLabel: 'Keep current name')),
      ),
    );
  }
}

/// Call this from a Settings "Switch device" option. Opens the entry screen on
/// top of Settings and leaves the saved ID alone: the current household or
/// device is only replaced once a new ID links, so Back cancels the switch.
Future<void> switchDevice(BuildContext context) async {
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DeviceIdEntryScreen(canGoBack: true)));
}
