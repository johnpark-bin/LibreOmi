/// Pure-Dart ownership rules for tearing down a failed connection attempt.
///
/// This file intentionally has no dependency on `package:flutter_blue_plus`
/// so it can be unit tested without a BLE stack or a Flutter widget test
/// harness. `BleService` holds at most one connection at a time and records
/// its owner in `_connectedDevice`; a connection attempt that fails has to
/// know whether it is still that owner before it resets any shared state,
/// because a later attempt may have taken the service over while this one
/// was still awaiting the radio.
library;

/// What a failed connection attempt is allowed to do.
enum TeardownAction {
  /// The attempt still owns the service (or nobody does): release the link
  /// *and* reset the shared state back to disconnected.
  resetService,

  /// Another device owns the service now: release only this attempt's own
  /// link and leave the shared state — including the live subscriptions —
  /// to its owner.
  releaseLinkOnly,
}

/// Decides what the teardown of a failed attempt on [failedDeviceId] may do,
/// given the device that currently owns the service ([serviceOwnerId], null
/// when no attempt has claimed it).
///
/// A null owner must still reset: an attempt that failed before it could
/// claim the service would otherwise leave the state stuck at `connecting`
/// with nothing left to emit a disconnect, which silently kills
/// auto-reconnect for the rest of the process.
TeardownAction teardownActionFor({
  required String? serviceOwnerId,
  required String failedDeviceId,
}) {
  if (serviceOwnerId == null) return TeardownAction.resetService;
  return serviceOwnerId == failedDeviceId
      ? TeardownAction.resetService
      : TeardownAction.releaseLinkOnly;
}
