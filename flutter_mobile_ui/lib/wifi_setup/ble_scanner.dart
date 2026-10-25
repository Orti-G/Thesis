import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../device_identity.dart';

/// Scans for the household's ESP32 while it's in Wi-Fi setup mode.
///
/// The firmware only advertises over BLE in setup mode (first boot, or after
/// holding BOOT for 3 seconds) and only under names starting with
/// "PROV_EM-" (e.g. "PROV_EM-1A2B") — a device already on Wi-Fi will not
/// show up here.
class BleScanner extends ChangeNotifier {
  static const String provNamePrefix = kProvNamePrefix;

  List<ScanResult> _devices = [];
  List<ScanResult> get devices => _devices;

  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<List<ScanResult>>? _scanResultsSub;
  StreamSubscription<bool>? _isScanningSub;

  /// True while a scan is running, and also while one is being prepared
  /// (permission prompts, the Location check). Without the second part the
  /// screen fell through to "We couldn't find it yet" during that gap.
  bool get isScanning => FlutterBluePlus.isScanningNow || _starting;
  bool _starting = false;

  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  BluetoothAdapterState get adapterState => _adapterState;
  bool get isAdapterReady => _adapterState == BluetoothAdapterState.on;

  /// The phone has no Bluetooth at all (confirmed by the plugin's own
  /// isSupported check, not guessed from an error) — no button on this
  /// screen can fix that.
  bool get isAdapterUnavailable => _adapterState == BluetoothAdapterState.unavailable;

  /// The last error from reading the adapter state, if any, shown on the
  /// Bluetooth screen so a stuck state can be diagnosed. Cleared once a
  /// real state arrives.
  String? adapterError;

  Timer? _adapterRetry;

  /// Set when the user denied a Bluetooth/location permission — scanning
  /// silently returns nothing in that case, so the UI needs to say why.
  /// [permissionPermanentlyDenied] means the OS won't show the prompt again
  /// and the user has to flip it in system settings.
  bool permissionDenied = false;
  bool permissionPermanentlyDenied = false;

  /// Whether this phone needs Location switched on to scan, so the setup
  /// page can show a Location row next to Bluetooth, and whether it is on
  /// right now. Android 11 and older always need it; newer phones only when
  /// a scan reports it (some phone makers still insist).
  bool locationNeeded = false;

  /// False until the first check finishes, so nothing shows a check too early.
  bool locationOn = false;
  Timer? _locationWatch;

  Future<void> _probeLocation() async {
    if (!Platform.isAndroid) return;
    final sdk = await _sdkInt();
    // Always track whether Location is really on, so the setup page never
    // shows a check for something that is off; [locationNeeded] only says
    // whether this phone requires it.
    locationNeeded = sdk != null && sdk <= 30;
    locationOn = await _locationServicesOn();
    notifyListeners();
    // Quick settings doesn't pause the app, so poll rather than wait for a resume.
    _locationWatch = Timer.periodic(const Duration(seconds: 2), (_) async {
      final on = await _locationServicesOn();
      if (on != locationOn) {
        locationOn = on;
        notifyListeners();
      }
    });
  }

  void init() {
    _probeLocation();
    _listenToAdapter();
    // startScan() returns as soon as the scan begins, not when its timeout
    // ends — listen here so "Searching..." flips to "No devices found".
    _isScanningSub = FlutterBluePlus.isScanning.listen((_) => notifyListeners());
  }

  /// Subscribes to adapter state changes. If reading the state throws, the
  /// stream ends, so record the error, check whether the phone has
  /// Bluetooth at all, and otherwise resubscribe after a short wait —
  /// previously an error here left the state stuck at "unknown", which
  /// looked exactly like "Bluetooth is off" and never recovered.
  void _listenToAdapter() {
    _adapterSub?.cancel();
    _adapterSub = FlutterBluePlus.adapterState.listen(
      (state) {
        _adapterState = state;
        adapterError = null;
        notifyListeners();
      },
      onError: (Object error) async {
        debugPrint('[BleScanner] adapterState error: $error');
        // First line only, capped: enough to diagnose, never a stack trace
        // across the screen (the full error is in the console above).
        final message = error.toString().split('\n').first;
        adapterError = message.length > 160 ? '${message.substring(0, 160)}…' : message;
        var supported = true;
        try {
          supported = await FlutterBluePlus.isSupported;
        } catch (_) {}
        if (!supported) _adapterState = BluetoothAdapterState.unavailable;
        notifyListeners();
        if (supported) {
          _adapterRetry?.cancel();
          _adapterRetry = Timer(const Duration(seconds: 2), _listenToAdapter);
        }
      },
    );
  }

  /// Android can switch the adapter on from inside the app; iOS can't, so
  /// the UI only shows a "Turn on" button where this is supported.
  bool get canTurnOnFromApp => Platform.isAndroid;

  Future<void> turnOnAdapter() async {
    // Ask only for what turning Bluetooth on needs (BLUETOOTH_CONNECT on
    // Android 12+, granted at install below that), so the Bluetooth prompt
    // comes first. Scanning and location permissions are asked for later,
    // in startScan(), once Bluetooth is actually on.
    if (!await _requestConnectPermission()) {
      notifyListeners();
      return;
    }
    try {
      await FlutterBluePlus.turnOn();
    } catch (_) {
      // User declined the system prompt — the adapter listener above keeps
      // the "Bluetooth is off" state showing.
    }
    // Re-sync in case a state change landed while the system dialog was up.
    _adapterState = FlutterBluePlus.adapterStateNow;
    notifyListeners();
  }

  /// Re-checks permissions without prompting — e.g. when the user comes
  /// back from system settings, so the screen moves on by itself once
  /// they've allowed access there.
  Future<void> refreshPermissions() async {
    if (!permissionDenied || !Platform.isAndroid) return;
    final granted = await Permission.bluetoothScan.isGranted && await Permission.bluetoothConnect.isGranted;
    if (!granted) return;
    permissionDenied = false;
    permissionPermanentlyDenied = false;
    notifyListeners();
  }

  /// Android 12+ needs BLUETOOTH_SCAN + BLUETOOTH_CONNECT; Android 11 and
  /// below also need location permission (with Location turned on) for BLE
  /// scan results to come back at all. iOS only needs the Info.plist usage
  /// description — no runtime permission_handler call is needed there.
  /// Just BLUETOOTH_CONNECT — what [turnOnAdapter] needs.
  Future<bool> _requestConnectPermission() async {
    if (!Platform.isAndroid) return true;
    final status = await Permission.bluetoothConnect.request();
    permissionDenied = !status.isGranted;
    permissionPermanentlyDenied = status.isPermanentlyDenied;
    return status.isGranted;
  }

  /// The "Allow Access" button: with Bluetooth on, ask for the scanning
  /// permissions (the screen's listener starts the scan once granted);
  /// with it off, go through the turn-on path, which asks for access first.
  Future<void> requestAccess() async {
    if (!isAdapterReady) return turnOnAdapter();
    await _requestPermissions();
    notifyListeners();
  }

  static const _systemSettings = MethodChannel('grid/system_settings');

  /// Opens Android's Location page (see MainActivity). Granting the
  /// location permission doesn't switch Location on; this does.
  Future<void> openLocationSettings() async {
    try {
      await _systemSettings.invokeMethod<bool>('openLocationSettings');
    } catch (_) {
      // Older builds without the channel: the screen's instructions still
      // say how to switch it on from quick settings.
    }
  }

  Future<int?> _sdkInt() async {
    try {
      return await _systemSettings.invokeMethod<int>('sdkInt');
    } catch (_) {
      return null;
    }
  }

  /// Asked one at a time, in order: Bluetooth ("Nearby devices") first, then
  /// Location on Android 11 and older only. A single batched request let
  /// Android show the Location prompt ahead of Bluetooth.
  Future<bool> _requestPermissions() async {
    if (!Platform.isAndroid) return true;
    final connect = await Permission.bluetoothConnect.request();
    final scan = await Permission.bluetoothScan.request();

    // BLUETOOTH_SCAN/CONNECT gate scanning on Android 12+ (and report as
    // granted on older versions). Location stays best-effort — a denial just
    // shows up as "No devices found" with the BOOT-button hint.
    final granted = connect.isGranted && scan.isGranted;

    permissionDenied = !granted;
    permissionPermanentlyDenied = !granted && (connect.isPermanentlyDenied || scan.isPermanentlyDenied);

    // Location is a Bluetooth-era requirement: only Android 11 and older are
    // asked for it. (Unknown version, e.g. an old native build, counts as old.)
    final sdk = await _sdkInt();
    if (granted && (sdk == null || sdk <= 30)) {
      await Permission.locationWhenInUse.request();
    }
    return granted;
  }

  Future<void> openPermissionSettings() => openAppSettings();

  Future<void> startScan({int timeout = 15}) async {
    if (_starting) return; // Already preparing one (e.g. the Location poll).
    _starting = true;
    try {
      await _startScan(timeout);
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  Future<void> _startScan(int timeout) async {
    _devices = [];
    scanError = null;
    notifyListeners();

    if (!await _requestPermissions()) {
      notifyListeners();
      return;
    }

    // Android 11 and below won't scan for nearby BLE devices with Location
    // turned off. Check first and show a "Turn on Location" step instead of
    // letting the scan throw. Android 12+ doesn't need Location, so it isn't
    // checked there; if a phone insists anyway, the scan's own error below
    // still brings the step up.
    final sdk = await _sdkInt();
    if (sdk == null || sdk <= 30) {
      if (!await _locationServicesOn()) {
        _setLocationOff(true);
        return;
      }
      _setLocationOff(false);
    }

    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }

    _scanResultsSub?.cancel();
    _scanResultsSub = FlutterBluePlus.onScanResults.listen((results) {
      if (results.isEmpty) return;
      for (final r in results) {
        final alreadyFound = _devices.any((d) => d.device.remoteId == r.device.remoteId);
        if (!alreadyFound) {
          _devices = [..._devices, r];
          notifyListeners();
        }
      }
    });

    FlutterBluePlus.cancelWhenScanComplete(_scanResultsSub!);

    try {
      await FlutterBluePlus.startScan(
        withKeywords: [provNamePrefix],
        timeout: Duration(seconds: timeout),
        continuousUpdates: true,
      );
    } catch (e) {
      // Previously unhandled, which left the screen stuck. Location can
      // still be switched off between the check above and here.
      _scanResultsSub?.cancel();
      debugPrint('[BleScanner] startScan error: $e');
      if (e.toString().contains('Location services')) {
        _setLocationOff(true);
        return;
      }
      // e.g. "Permission android.permission.ACCESS_FINE_LOCATION required
      // to scan devices" (Android 11 and below need location to scan).
      if (e.toString().contains('Permission')) {
        permissionDenied = true;
        // Once denied for good, asking again does nothing — the screen then
        // offers "Open Settings" instead.
        permissionPermanentlyDenied = await Permission.locationWhenInUse.isPermanentlyDenied;
        notifyListeners();
        return;
      }
      final message = e.toString().split('\n').first;
      scanError = message.length > 160 ? '${message.substring(0, 160)}…' : message;
    }

    notifyListeners();
  }

  /// Location services are off, so scanning can't run. While this is true
  /// the scanner checks every 2 seconds and starts scanning by itself once
  /// Location is switched on (e.g. from quick settings, which doesn't
  /// pause the app, so a resume callback alone would miss it).
  bool locationServicesOff = false;

  /// The last scan failure that isn't covered by a dedicated state.
  String? scanError;

  Timer? _locationPoll;

  Future<bool> _locationServicesOn() async {
    if (!Platform.isAndroid) return true;
    try {
      return await Permission.location.serviceStatus.isEnabled;
    } catch (_) {
      return true; // Can't tell; let the scan itself report a problem.
    }
  }

  void _setLocationOff(bool off) {
    locationServicesOff = off;
    if (off) locationNeeded = true;
    locationOn = !off;
    _locationPoll?.cancel();
    if (off) {
      _locationPoll = Timer.periodic(const Duration(seconds: 2), (_) async {
        if (await _locationServicesOn()) {
          _locationPoll?.cancel();
          startScan();
        }
      });
    }
    notifyListeners();
  }

  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    notifyListeners();
  }

  @override
  void dispose() {
    _adapterRetry?.cancel();
    _locationPoll?.cancel();
    _locationWatch?.cancel();
    _adapterSub?.cancel();
    _scanResultsSub?.cancel();
    _isScanningSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }
}
