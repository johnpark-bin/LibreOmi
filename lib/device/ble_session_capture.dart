/// The debug "Capture BLE session" hook (LO-31).
///
/// When the developer toggle in Settings is on, [DeviceManager] hands every
/// connected device to a [BleSessionCapture], which records the device's
/// notifications in the replay format `FakeOmiDevice` reads back
/// (`test/fixtures/README.md`).
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'fake_omi_device.dart';
import 'omi_device.dart';
import 'omi_gatt.dart';

/// Records a live device session to somewhere `FakeOmiDevice` can replay it.
///
/// Implementations must be inert when the toggle is off: [start] is called on
/// every connection, so the decision to record belongs here rather than at the
/// call site.
abstract class BleSessionCapture {
  /// Begins recording [device], if capture is enabled. Never throws — a
  /// failing capture must not take a working connection down with it.
  Future<void> start(OmiDevice device);

  /// Stops recording and flushes whatever was captured. Safe to call when
  /// nothing is being recorded.
  Future<void> stop();
}

/// [BleSessionCapture] that writes the JSONL fixture format
/// (`test/fixtures/README.md`) to an injected sink.
///
/// The sink is injected rather than opened here, both so a test can capture
/// into a `StringBuffer` and because picking an on-disk location is a
/// `platform/` concern, not a `device/` one (`docs/03-architecture.md` §1):
/// `platform/ble_capture_file.dart` wires the real app-support-directory file
/// for production use.
class JsonlBleSessionCapture implements BleSessionCapture {
  JsonlBleSessionCapture({
    required bool Function() enabled,
    required Future<StringSink?> Function() openSink,
    Future<void> Function()? closeSink,
  })  : _enabled = enabled,
        _openSink = openSink,
        _closeSink = closeSink;

  final bool Function() _enabled;
  final Future<StringSink?> Function() _openSink;
  final Future<void> Function()? _closeSink;

  StringSink? _sink;
  int? _startTimeMs;
  final List<StreamSubscription<void>> _subscriptions = [];

  @override
  Future<void> start(OmiDevice device) async {
    // Guarded inside the try: `_enabled` reads SharedPreferences, which
    // throws if settings are not loaded yet, and `start` is called
    // fire-and-forget so a throw here would surface as an unhandled error.
    try {
      if (!_enabled()) return;
      // A duplicate `connected` event, or a fast disconnect/reconnect, must
      // not stack a second set of subscriptions on the first: that would
      // write every notification twice and orphan the first file unflushed.
      await stop();
      _sink = await _openSink();
      if (_sink == null) return;
      _startTimeMs = DateTime.now().millisecondsSinceEpoch;

      _subscriptions.add(device.audioPackets.listen(
        (bytes) => _write(CaptureChannel.audio, bytes),
        onError: (Object _) {},
      ));
      _subscriptions.add(device.buttonEvents.listen(
        (event) => _writeButton(event),
        onError: (Object _) {},
      ));
      _subscriptions.add(device.batteryLevel.listen(
        (level) => _write(CaptureChannel.battery, [level]),
        onError: (Object _) {},
      ));
      final storage = device.storage;
      if (storage != null) {
        _subscriptions.add(storage.rawPackets.listen(
          (bytes) => _write(CaptureChannel.storage, bytes),
          onError: (Object _) {},
        ));
      }
    } catch (error, stackTrace) {
      developer.log(
        'JsonlBleSessionCapture: failed to start capture',
        error: error,
        stackTrace: stackTrace,
        name: 'ble_session_capture',
      );
      await stop();
    }
  }

  void _writeButton(ButtonEvent event) {
    // The capture format records raw notification bytes; re-encode the
    // decoded event back to the 4-byte little-endian payload the device
    // actually sent, so a fixture built from a capture round-trips through
    // FakeOmiDevice's own parseButtonEvent call.
    final code = event.code < 0 ? 0 : event.code;
    _write(CaptureChannel.button, [code, 0, 0, 0]);
  }

  void _write(CaptureChannel channel, List<int> bytes) {
    final sink = _sink;
    final startTimeMs = _startTimeMs;
    if (sink == null || startTimeMs == null) return;
    try {
      final timeMs = DateTime.now().millisecondsSinceEpoch - startTimeMs;
      final line = encodeCaptureLine(CapturedEvent(
        timeMs: timeMs,
        channel: channel,
        bytes: Uint8List.fromList(bytes),
      ));
      sink.writeln(line);
    } catch (error, stackTrace) {
      developer.log(
        'JsonlBleSessionCapture: failed to write capture line',
        error: error,
        stackTrace: stackTrace,
        name: 'ble_session_capture',
      );
    }
  }

  @override
  Future<void> stop() async {
    // Detached synchronously before the first `await`, the same way
    // `BleService._cleanupSubscriptions()` does it: `start()` calls `stop()`,
    // so two stops can be in flight at once, and clearing the list after the
    // loop would let one of them mutate the other's iterator.
    final subscriptions = List.of(_subscriptions);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    try {
      await _closeSink?.call();
    } catch (error, stackTrace) {
      developer.log(
        'JsonlBleSessionCapture: failed to close capture sink',
        error: error,
        stackTrace: stackTrace,
        name: 'ble_session_capture',
      );
    }
    _sink = null;
    _startTimeMs = null;
  }
}
