import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

/// Counts this open dashboard as one viewer on the device's LCD by writing
/// `devices/<id>/viewers/<sessionId> = true`. The VM reads the count about
/// every 10 s.
///
/// Each session gets a fresh random ID — never the setup ID — and a new one
/// on every resume. The onDisconnect removal is registered *before* the key
/// is written: the other order can leave a permanent stale viewer if the
/// app dies in between. Brief overcounts after a crash or hot restart clear
/// on their own once the server notices the dropped connection.
class ViewerPresence {
  DatabaseReference? _ref;

  /// start/stop run one after another, so a quick pause/resume can't
  /// interleave its writes.
  Future<void> _queue = Future.value();

  void start(String deviceId) => _queue = _queue.then((_) => _start(deviceId));

  void stop() => _queue = _queue.then((_) => _stop());

  Future<void> _start(String deviceId) async {
    if (_ref != null) return;
    final ref = FirebaseDatabase.instance.ref('devices/$deviceId/viewers/${const Uuid().v4()}');
    _ref = ref;
    try {
      await ref.onDisconnect().remove();
      await ref.set(true);
    } catch (e) {
      debugPrint('[ViewerPresence] register failed: $e');
    }
  }

  Future<void> _stop() async {
    final ref = _ref;
    if (ref == null) return;
    _ref = null;
    try {
      await ref.remove();
      await ref.onDisconnect().cancel();
    } catch (e) {
      debugPrint('[ViewerPresence] remove failed: $e');
    }
  }
}
