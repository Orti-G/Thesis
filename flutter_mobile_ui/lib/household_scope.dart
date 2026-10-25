import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_identity.dart';

/// Made-up code that puts the app in legacy mode for the household whose IoT
/// device has no device ID. Typing it on the Device ID screen skips the
/// `devices/<ID>/sync` check and BLE setup, and every read goes to the
/// original Firebase project at the database root, as the app always did.
///
/// Must fit [kDeviceIdPattern] (XXXX-XXXX, no I, O, 0 or 1) so the input
/// field accepts it.
const String kLegacyHouseholdCode = 'LGCY-KR22';

/// Name of the second Firebase app that points at the original project.
const String kLegacyFirebaseAppName = 'legacy';

/// Backend the original household's data and alerts come from.
const String kLegacyApiBaseUrl = 'http://35.209.250.46:8000';

/// Which household or device the app is showing, and where its data lives.
///
/// - Legacy household ([kLegacyHouseholdCode]): original Firebase project,
///   root paths (`live_reading`, `history/today`, ...).
/// - Any other linked device: default Firebase project, `devices/<id>/...`.
///
/// Screens build every Firebase path through [ref] instead of hardcoding it.
class HouseholdScope {
  HouseholdScope._();

  static String? _id;

  /// Reads the saved ID. Call once before `runApp`.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _id = prefs.getString(kDeviceIdPrefsKey);
  }

  /// Remembers [id] as the linked household or device.
  static Future<void> save(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kDeviceIdPrefsKey, id);
    _id = id;
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kDeviceIdPrefsKey);
    _id = null;
  }

  /// The linked ID, or null before linking.
  static String? get id => _id;

  static bool get isLinked => _id != null;

  static bool get isLegacy => _id == kLegacyHouseholdCode;

  static FirebaseDatabase get db =>
      isLegacy ? FirebaseDatabase.instanceFor(app: Firebase.app(kLegacyFirebaseAppName)) : FirebaseDatabase.instance;

  /// [path] relative to this household's data. Empty [path] gives the
  /// household root (the database root in legacy mode).
  static DatabaseReference ref([String path = '']) {
    if (isLegacy) return path.isEmpty ? db.ref() : db.ref(path);
    final base = 'devices/${_id ?? '_unlinked'}';
    return db.ref(path.isEmpty ? base : '$base/$path');
  }

  static String get apiBaseUrl => kLegacyApiBaseUrl;
}
