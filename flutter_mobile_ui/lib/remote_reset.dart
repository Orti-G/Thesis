import 'dart:async';
import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'device_identity.dart';

enum RemoteResetResult {
  /// 200: owner verified, delivered on the device's next POST.
  queued,

  /// 403, or this install never provisioned a device (no setup ID).
  notOwner,

  /// 404: the device has no registered owner yet.
  noOwner,

  /// 409: the device can't take a reset right now (e.g. one was already
  /// delivered and it hasn't been provisioned again). The VM explains why.
  conflict,

  /// Build has no APP_API_KEY.
  notConfigured,

  /// 401 / 422 / anything else, or the request didn't go through.
  error,
}

/// [message] carries the VM's own explanation where it gives one (409).
typedef RemoteResetResponse = ({RemoteResetResult result, String? message});

/// What happened to the device after a queued reset.
enum ResetDelivery {
  /// `sync` went true → false: the device took the command and restarted.
  restarted,

  /// `sync` never went true → false: the device was offline and the
  /// command expired.
  offline,

  /// The device stayed online but never restarted.
  notDelivered,
}

/// Asks the VM to make [deviceId] forget its Wi-Fi and restart into setup
/// mode. The VM checks the setup ID against the registered owner.
Future<RemoteResetResponse> sendResetWifi(String deviceId) async {
  if (kAppApiKey.isEmpty) return (result: RemoteResetResult.notConfigured, message: null);

  // Read rather than create: without a setup ID this phone can't be the
  // owner, so there's nothing to send.
  final prefs = await SharedPreferences.getInstance();
  final setupId = prefs.getString(kSetupIdPrefsKey);
  if (setupId == null) return (result: RemoteResetResult.notOwner, message: null);

  try {
    final response = await http
        .post(
          Uri.parse('$kVmBaseUrl/devices/$deviceId/command'),
          headers: {'Content-Type': 'application/json', 'X-API-Key': kAppApiKey},
          body: jsonEncode({'setup_id': setupId, 'command': 'reset_wifi'}),
        )
        .timeout(const Duration(seconds: 15));

    switch (response.statusCode) {
      case 200:
        return (result: RemoteResetResult.queued, message: null);
      case 403:
        return (result: RemoteResetResult.notOwner, message: null);
      case 404:
        return (result: RemoteResetResult.noOwner, message: null);
      case 409:
        return (result: RemoteResetResult.conflict, message: _errorMessageFrom(response.body));
      default:
        // Never log the request body; it carries the setup ID.
        debugPrint('[RemoteReset] /command returned ${response.statusCode}');
        return (result: RemoteResetResult.error, message: null);
    }
  } catch (e) {
    debugPrint('[RemoteReset] /command failed: ${e.runtimeType}');
    return (result: RemoteResetResult.error, message: null);
  }
}

/// Pulls a human-readable message out of an error body: FastAPI's
/// `{"detail": "..."}`, a `message`/`error` field, or plain text.
String? _errorMessageFrom(String body) {
  final text = body.trim();
  if (text.isEmpty) return null;
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) {
      for (final key in const ['detail', 'message', 'error']) {
        final value = decoded[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
      return null;
    }
    if (decoded is String && decoded.trim().isNotEmpty) return decoded.trim();
  } on FormatException {
    // Not JSON: use it as-is if it's short enough to show.
    if (text.length <= 200) return text;
  }
  return null;
}

/// True while this install is [deviceId]'s registered owner: its setup ID's
/// hash matches `devices/<id>/owner_hash`. Live, so it follows ownership
/// moving to or away from this phone. A viewer who never provisioned has no
/// setup ID, and none is created here.
Stream<bool> watchIsOwner(String deviceId) {
  return FirebaseDatabase.instance.ref('devices/$deviceId/owner_hash').onValue.asyncMap((event) async {
    // Re-read each time: this phone may have just become the owner by
    // provisioning, which is when its setup ID first appears.
    final prefs = await SharedPreferences.getInstance();
    final setupId = prefs.getString(kSetupIdPrefsKey);
    return setupId != null && event.snapshot.value == ownerHashOf(setupId);
  });
}

/// Watches `devices/<id>/sync` after a queued reset. The VM drops the
/// command after ~120 s if the device never picks it up, so give up a bit
/// after that.
Future<ResetDelivery> watchResetDelivery(String deviceId) async {
  final done = Completer<ResetDelivery>();
  var sawOnline = false;

  final sub = FirebaseDatabase.instance.ref('devices/$deviceId/sync').onValue.listen((event) {
    final v = event.snapshot.value;
    final online = v == true || v == 'true';
    if (online) {
      sawOnline = true;
    } else if (sawOnline && !done.isCompleted) {
      done.complete(ResetDelivery.restarted);
    }
  }, onError: (Object e) => debugPrint('[RemoteReset] sync listener error: $e'));

  final timer = Timer(const Duration(seconds: 130), () {
    if (!done.isCompleted) done.complete(sawOnline ? ResetDelivery.notDelivered : ResetDelivery.offline);
  });

  try {
    return await done.future;
  } finally {
    timer.cancel();
    await sub.cancel();
  }
}
