import 'dart:async';
import 'dart:convert';

import 'package:esp_provisioning_ble/esp_provisioning_ble.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../device_identity.dart';
import '../household_scope.dart';
import 'transport_ble.dart';

/// One provisioning attempt, in the six stages the device's LCD also shows
/// (see the ESP32 ↔ Flutter Alignment Spec):
///
/// 1. pick the device (scan, outside this class)
/// 2. pair: BLE connect + Security 1 session with the PoP
/// 3. paired: setup ID out, device ID back, over the `setup-id` endpoint
/// 4. Wi-Fi: send credentials, apply, poll status
/// 5. connected: wait for `devices/<id>/sync == true` in Firebase
/// 6. device ID: saved locally, shown to the user
///
/// The setup-ID exchange has to happen before Wi-Fi is sent, because the
/// device shuts BLE down once it joins the network.
///
/// The PoP is unique to each device, shown on its LCD and typed in by the
/// user, so pairing requires standing in front of the unit.
enum ProvState {
  idle,
  connecting,
  sessionEstablishing,
  exchangingSetupId,
  paired,
  scanningWifi,
  wifiReady,
  configSending,
  polling,
  waitingForSync,
  online,

  /// Wrong PoP. The device keeps advertising, so the user can retype it.
  keyMismatch,

  /// BLE dropped before Wi-Fi was sent.
  disconnected,

  /// Couldn't connect, or the setup-ID exchange failed.
  failed,

  /// Wi-Fi didn't take (wrong password, no IP). The device restarts into
  /// setup mode or waits on its own screen, so the BLE session is gone.
  wifiFailed,

  /// Joined Wi-Fi but `sync` never turned true.
  syncTimeout,
}

class ProvisioningService extends ChangeNotifier {
  /// LCD shows "Couldn't connect" after 20 s without an IP; a little slack
  /// for BLE polling.
  static const _noIpTimeout = Duration(seconds: 25);
  static const _syncTimeout = Duration(seconds: 60);

  /// After a BLE drop mid-apply, how long to look for `sync` before calling
  /// it a failure. The firmware sometimes restarts instead of reporting a
  /// status, but BLE also shuts down on success, so check before failing.
  static const _postDropSyncWindow = Duration(seconds: 15);

  EspProv? _prov;
  TransportBLE? _transport;
  Timer? _statusTimer;
  Timer? _noIpTimer;
  Timer? _syncTimer;
  StreamSubscription<BluetoothConnectionState>? _bleStateSub;
  StreamSubscription<DatabaseEvent>? _syncSub;

  ProvState _state = ProvState.idle;
  ProvState get state => _state;

  String? errorMessage;
  List<WifiAP> wifiNetworks = [];

  /// Received from the device at step 3; saved to prefs only once `sync`
  /// confirms it (step 6).
  String? deviceId;

  /// Full BLE name, e.g. PROV_EM-1A2B.
  String? deviceName;

  bool _disposed = false;
  bool _checkingAfterDrop = false;

  void _setState(ProvState newState) {
    // BLE and Firebase callbacks can land after the screen has gone.
    if (_disposed) return;
    _state = newState;
    notifyListeners();
  }

  void _fail(ProvState state, String message) {
    errorMessage = message;
    _cancelTimers();
    _setState(state);
  }

  // ── Steps 2–3 ────────────────────────────────────────────────────────────

  Future<void> connectAndEstablishSession(BluetoothDevice device, {required String pop}) async {
    errorMessage = null;
    deviceName = device.platformName.isNotEmpty ? device.platformName : device.advName;
    _setState(ProvState.connecting);

    _transport = TransportBLE(device);
    if (!await _transport!.connect()) {
      await _teardownBle();
      _fail(ProvState.failed, 'Could not connect to the device.');
      return;
    }

    _prov = EspProv(
      transport: _transport!,
      security: Security1(pop: pop),
    );
    _setState(ProvState.sessionEstablishing);

    final sessionStatus = await _prov!.establishSession();
    switch (sessionStatus) {
      case EstablishSessionStatus.connected:
        break;
      case EstablishSessionStatus.disconnected:
        await _teardownBle();
        _fail(ProvState.disconnected, 'Connection lost.');
        return;
      case EstablishSessionStatus.keymismatch:
        await _teardownBle();
        _fail(ProvState.keyMismatch, 'Wrong pairing code.');
        return;
    }

    _watchBle(device);
    _setState(ProvState.exchangingSetupId);

    try {
      deviceId = await _exchangeSetupId();
    } catch (e) {
      if (_state != ProvState.exchangingSetupId) return; // BLE drop already handled
      debugPrint('[Provisioning] setup-id exchange failed: ${e.runtimeType}');
      await _teardownBle();
      _fail(ProvState.failed, "Couldn't finish pairing with the device. Try again.");
      return;
    }
    _setState(ProvState.paired);
  }

  /// Sends this install's setup ID (36 raw UTF-8 bytes) on the encrypted
  /// session and returns the device ID (9 raw bytes, e.g. K7QM-4XPD).
  /// `ERR` means the device didn't get 36 bytes: resend once, then give up.
  /// Never log the setup ID.
  Future<String> _exchangeSetupId() async {
    final setupId = await getOrCreateSetupId();
    final request = Uint8List.fromList(utf8.encode(setupId));

    for (var attempt = 0; attempt < 2; attempt++) {
      final encrypted = await _prov!.security.encrypt(request);
      final response = await _transport!.sendReceive(SETUP_ENDPOINT, encrypted);
      final reply = utf8.decode(await _prov!.security.decrypt(response), allowMalformed: true);
      if (reply == 'ERR') continue;
      if (isValidDeviceId(reply)) return reply;
      throw const FormatException('Device ID reply did not match the expected format');
    }
    throw StateError('Device rejected the setup ID twice');
  }

  /// BLE drops mean different things depending on the step: before Wi-Fi
  /// it's a lost connection; while applying Wi-Fi it's usually a restart
  /// after a wrong password (or BLE shutting down on success); after that
  /// it's expected.
  void _watchBle(BluetoothDevice device) {
    _bleStateSub?.cancel();
    _bleStateSub = device.connectionState.listen((s) {
      if (s != BluetoothConnectionState.disconnected) return;
      switch (_state) {
        case ProvState.exchangingSetupId:
        case ProvState.paired:
        case ProvState.scanningWifi:
        case ProvState.wifiReady:
          _fail(ProvState.disconnected, 'Connection lost.');
        case ProvState.configSending:
        case ProvState.polling:
          _onBleLostWhileApplying();
        default:
          break;
      }
    });
  }

  // ── Steps 3–4 ────────────────────────────────────────────────────────────

  /// The ESP32 is 2.4GHz only, so 5GHz networks won't show up here even if
  /// the phone itself sees them.
  Future<void> scanWifi() async {
    errorMessage = null;
    _setState(ProvState.scanningWifi);
    try {
      wifiNetworks = await _prov!.startScanWiFi();
    } catch (e) {
      if (_state != ProvState.scanningWifi) return;
      wifiNetworks = [];
      errorMessage = 'Could not scan for Wi-Fi networks.';
    }
    if (_state == ProvState.scanningWifi) _setState(ProvState.wifiReady);
  }

  Future<void> sendConfig(String ssid, String password, {String? bssid}) async {
    errorMessage = null;
    _setState(ProvState.configSending);
    try {
      if (bssid != null) {
        await _prov!.sendWifiConfig(ssid: ssid, password: password, bssid: bssid);
      } else {
        await _prov!.sendWifiConfig(ssid: ssid, password: password);
      }
      await _prov!.applyWifiConfig();
    } catch (e) {
      if (_state == ProvState.configSending) _onBleLostWhileApplying();
      return;
    }
    if (_state == ProvState.configSending) _pollStatus();
  }

  void _pollStatus() {
    _setState(ProvState.polling);
    _statusTimer?.cancel();
    _noIpTimer?.cancel();
    _noIpTimer = Timer(_noIpTimeout, () {
      if (_state != ProvState.polling) return;
      _teardownBle();
      _fail(ProvState.wifiFailed, "Couldn't connect, check the device screen.");
    });

    _statusTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      if (_state != ProvState.polling) {
        timer.cancel();
        return;
      }
      final ConnectionStatus status;
      try {
        status = await _prov!.getStatus();
      } catch (e) {
        timer.cancel();
        if (_state == ProvState.polling) _onBleLostWhileApplying();
        return;
      }
      if (_state != ProvState.polling) return;

      switch (status.state) {
        case WifiConnectionState.Connected:
          _waitForSync(_syncTimeout, onTimeout: ProvState.syncTimeout);
        case WifiConnectionState.Connecting:
          break; // keep polling
        case WifiConnectionState.ConnectionFailed:
          _teardownBle();
          _fail(
            ProvState.wifiFailed,
            status.failedReason == WifiConnectFailedReason.AuthError
                ? 'Wrong password, reconnect to the device.'
                : "Couldn't connect, check the device screen.",
          );
        case WifiConnectionState.Disconnected:
          _teardownBle();
          _fail(ProvState.wifiFailed, "Couldn't connect, check the device screen.");
      }
    });
  }

  /// Treated as a failure (wrong password, device restarting into setup)
  /// unless `sync` turns true shortly after, i.e. BLE just shut down
  /// because the device came online.
  void _onBleLostWhileApplying() {
    if (_state != ProvState.configSending && _state != ProvState.polling) return;
    // Both the BLE listener and a failed write/poll can report the same
    // drop; only the first starts the check.
    if (_checkingAfterDrop) return;
    _checkingAfterDrop = true;
    _cancelTimers();
    _setState(ProvState.polling);
    _waitForSync(_postDropSyncWindow, onTimeout: ProvState.wifiFailed, silent: true);
  }

  // ── Steps 5–6 ────────────────────────────────────────────────────────────

  /// Waits for `devices/<id>/sync == true`. [silent] keeps the current
  /// state on screen (the post-drop check) instead of showing step 5.
  void _waitForSync(Duration timeout, {required ProvState onTimeout, bool silent = false}) {
    _cancelTimers();
    final id = deviceId;
    if (id == null) {
      _fail(ProvState.failed, 'Something went wrong. Try again.');
      return;
    }
    errorMessage = null;
    if (!silent) _setState(ProvState.waitingForSync);

    _syncSub = FirebaseDatabase.instance.ref('devices/$id/sync').onValue.listen((event) {
      final v = event.snapshot.value;
      if (v == true || v == 'true') _onDeviceOnline(id);
    }, onError: (Object e) => debugPrint('[Provisioning] sync listener error: $e'));

    _syncTimer = Timer(timeout, () {
      _teardownBle();
      _fail(
        onTimeout,
        onTimeout == ProvState.syncTimeout
            ? "Device joined Wi-Fi but can't reach the server."
            : 'Wrong password, reconnect to the device.',
      );
    });
  }

  /// Step 5 timed out: give the device another minute.
  void keepWaitingForSync() {
    if (_state == ProvState.syncTimeout) {
      _waitForSync(_syncTimeout, onTimeout: ProvState.syncTimeout);
    }
  }

  Future<void> _onDeviceOnline(String id) async {
    if (_state == ProvState.online) return;
    _cancelTimers();
    final prefs = await SharedPreferences.getInstance();
    await HouseholdScope.save(id);
    await prefs.setBool('wifiSetupCompleted', true);
    await _teardownBle();
    _setState(ProvState.online);
  }

  // ── Cleanup ──────────────────────────────────────────────────────────────

  void _cancelTimers() {
    _statusTimer?.cancel();
    _noIpTimer?.cancel();
    _syncTimer?.cancel();
    _syncSub?.cancel();
    _syncSub = null;
  }

  /// Drops the BLE link without reporting it as a failure.
  Future<void> _teardownBle() async {
    await _bleStateSub?.cancel();
    _bleStateSub = null;
    final prov = _prov;
    final transport = _transport;
    _prov = null;
    _transport = null;
    try {
      // EspProv.dispose() drops the BLE link; if pairing failed before it
      // was created, the transport may still be connected on its own.
      if (prov != null) {
        await prov.dispose();
      } else {
        await transport?.disconnect();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTimers();
    _teardownBle();
    super.dispose();
  }
}
