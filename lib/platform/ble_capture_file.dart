/// Where a debug BLE session capture is written on disk.
///
/// `device/` may only depend on its own plugin and `core`
/// (`docs/03-architecture.md` §1), so choosing an on-disk location — an
/// app-support-directory file, via `path_provider` — lives here and is
/// injected into the `device/` recorder.
library;

import 'dart:developer' as developer;
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../device/ble_session_capture.dart';

/// A [JsonlBleSessionCapture] that writes to
/// `<app support>/ble_session_<timestamp>.jsonl`.
///
/// The file is opened only when [enabled] is true at capture-start time, so
/// nothing is created while the developer toggle is off. Every IO failure is
/// logged and swallowed: a failing capture must never take a working
/// connection down with it.
JsonlBleSessionCapture appSupportBleSessionCapture({
  required bool Function() enabled,
}) {
  IOSink? sink;
  return JsonlBleSessionCapture(
    enabled: enabled,
    openSink: () async {
      try {
        final dir = await getApplicationSupportDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final file = File('${dir.path}/ble_session_$timestamp.jsonl');
        sink = file.openWrite(mode: FileMode.writeOnlyAppend);
        return sink;
      } catch (error, stackTrace) {
        developer.log(
          'appSupportBleSessionCapture: failed to open capture file',
          error: error,
          stackTrace: stackTrace,
          name: 'ble_session_capture',
        );
        return null;
      }
    },
    closeSink: () async {
      try {
        await sink?.flush();
        await sink?.close();
      } catch (error, stackTrace) {
        developer.log(
          'appSupportBleSessionCapture: failed to close capture file',
          error: error,
          stackTrace: stackTrace,
          name: 'ble_session_capture',
        );
      } finally {
        sink = null;
      }
    },
  );
}
