import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Values shared with the ESP32 firmware and the VM (see the
/// "ESP32 ↔ Flutter Alignment Spec"). Both sides must use these exactly.

/// Setup-mode BLE names are `PROV_EM-XXXX`, XXXX from the chip MAC.
const String kProvNamePrefix = 'PROV_EM-';

/// Custom provisioning endpoint for the setup ID ↔ device ID exchange.
/// Named after the firmware's own SETUP_ENDPOINT so the two are easy to
/// match up.
// ignore: constant_identifier_names
const String SETUP_ENDPOINT = 'setup-id';

/// VM base URL for the remote reset call.
const String kVmBaseUrl = 'https://thesis-energy.duckdns.org';

/// App key for the VM's `/command` route, supplied at build time with
/// `--dart-define-from-file=secrets.json` (gitignored; copy
/// secrets.example.json) so it never lands in git.
const String kAppApiKey = String.fromEnvironment('APP_API_KEY');

const String kSetupIdPrefsKey = 'setup_id';
const String kDeviceIdPrefsKey = 'device_id';

/// XXXX-XXXX from an alphabet without I, O, 0 or 1.
final RegExp kDeviceIdPattern = RegExp(r'^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$');

bool isValidDeviceId(String id) => kDeviceIdPattern.hasMatch(id);

/// This install's owner identity: a lowercase UUID v4, created once and
/// never regenerated. It is a secret — never display or log it, and only
/// send it to the BLE `setup-id` endpoint and the VM `/command` call.
Future<String> getOrCreateSetupId() async {
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getString(kSetupIdPrefsKey);
  if (existing != null && existing.length == 36) return existing;

  final created = const Uuid().v4().toLowerCase();
  await prefs.setString(kSetupIdPrefsKey, created);
  return created;
}

/// Lowercase hex SHA-256 of [setupId], the form stored at
/// `devices/<id>/owner_hash`.
String ownerHashOf(String setupId) => sha256.convert(utf8.encode(setupId)).toString();
