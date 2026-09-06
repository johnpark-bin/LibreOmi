/// Deprecated location of the Omi BLE protocol constants and helpers.
///
/// The single source of truth moved to `lib/device/omi_gatt.dart` in LO-30
/// (see docs/03-architecture.md §1). This file stays as a re-export so the
/// existing imports keep compiling; it is deleted in LO-31 once every call
/// site has been repointed.
library;

export '../../device/omi_gatt.dart';
