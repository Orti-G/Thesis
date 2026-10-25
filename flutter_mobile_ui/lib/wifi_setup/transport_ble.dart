import 'dart:typed_data';

import 'package:esp_provisioning_ble/esp_provisioning_ble.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// BLE transport for esp_provisioning_ble, built on flutter_blue_plus.
///
/// This implements the package's abstract `ProvTransport` (connect,
/// checkConnect, disconnect, sendReceive) against a real GATT connection to
/// the ESP32. The endpoint UUIDs below match Espressif's standard BLE
/// provisioning transport. Custom endpoints (like the firmware's `setup-id`)
/// are numbered after the standard ones, so `setup-id` is expected at ff54;
/// the endpoint names the device publishes in each characteristic's User
/// Description descriptor take precedence over this table.
class TransportBLE implements ProvTransport {
  final BluetoothDevice device;
  final String serviceUUID;
  final Map<String, String> endpointTable;

  late final Map<String, BluetoothCharacteristic> _characteristics;

  static const defaultServiceUUID = '021a9004-0382-4aea-bff4-6b3f1c5adfb4';

  static const defaultEndpoints = {
    'prov-scan': 'ff50',
    'prov-session': 'ff51',
    'prov-config': 'ff52',
    'proto-ver': 'ff53',
    'setup-id': 'ff54',
  };

  /// GATT Characteristic User Description, where ESP-IDF's protocomm puts
  /// each endpoint's name.
  static final Guid _userDescriptionUuid = Guid('2901');

  TransportBLE(this.device, {this.serviceUUID = defaultServiceUUID, this.endpointTable = defaultEndpoints});

  String _buildCharUUID(String endpointHex) {
    final hex = int.parse(endpointHex, radix: 16).toRadixString(16).padLeft(4, '0');
    return '${serviceUUID.substring(0, 4)}$hex${serviceUUID.substring(8)}';
  }

  @override
  Future<bool> connect() async {
    await disconnect();

    try {
      // FlutterBluePlus 2.x requires declaring which license tier applies.
      // `nonprofit` covers personal use, nonprofits, and educational
      // institutions — which is what a thesis/capstone project falls under.
      // Switch to `License.commercial` if this ever ships as a for-profit
      // product with 15+ employees (see the package's LICENSE for terms).
      await device.connect(license: License.nonprofit, autoConnect: false);
    } catch (e) {
      return false;
    }

    try {
      await device.requestMtu(256);
    } catch (_) {
      // Non-fatal — falls back to the default MTU if negotiation fails.
    }

    try {
      final services = await device.discoverServices();
      _cacheCharacteristics(services);
      await _mapNamedEndpoints(services);
    } catch (e) {
      return false;
    }

    return device.isConnected;
  }

  void _cacheCharacteristics(List<BluetoothService> services) {
    _characteristics = {};

    final targetUUIDs = {for (final entry in endpointTable.entries) _buildCharUUID(entry.value): entry.key};

    for (final service in services) {
      for (final char in service.characteristics) {
        final uuid = char.uuid.toString().toLowerCase();
        final endpointName = targetUUIDs[uuid];
        if (endpointName != null) {
          _characteristics[endpointName] = char;
        }
      }
    }
  }

  /// Maps characteristics by the endpoint name in their User Description
  /// descriptor, so a firmware that numbers its custom endpoints
  /// differently still resolves. Best effort: the UUID table stays as the
  /// fallback for any descriptor that can't be read.
  Future<void> _mapNamedEndpoints(List<BluetoothService> services) async {
    final provServices = services.where((s) => s.uuid.str128.toLowerCase() == serviceUUID.toLowerCase());
    for (final char in provServices.expand((s) => s.characteristics)) {
      for (final descriptor in char.descriptors) {
        if (descriptor.uuid != _userDescriptionUuid) continue;
        try {
          final name = String.fromCharCodes(await descriptor.read()).trim();
          if (name.isNotEmpty) _characteristics[name] = char;
        } catch (_) {
          // Keep the UUID-table mapping for this one.
        }
      }
    }
  }

  @override
  Future<Uint8List> sendReceive(String? epName, Uint8List? data) async {
    final char = _characteristics[epName ?? ''];
    if (char == null) {
      throw StateError('Characteristic not found for endpoint: $epName');
    }

    if (data != null && data.isNotEmpty) {
      await char.write(data.toList(), withoutResponse: false);
    }

    final response = await char.read();
    return Uint8List.fromList(response);
  }

  @override
  Future<bool> disconnect() async {
    if (device.isConnected) {
      try {
        await device.disconnect();
        return true;
      } catch (e) {
        return false;
      }
    }
    return true;
  }

  @override
  Future<bool> checkConnect() async {
    return device.isConnected;
  }
}
