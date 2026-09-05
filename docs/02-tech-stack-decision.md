# 02 — Tech stack decision

## Decision

**Fork `omibutfree` as a Flutter project and add Android as the primary target.**
Keep Dart as the only application language. Do not rewrite in Kotlin.

## Options considered

| | A. Fork Flutter app, add Android | B. Native Kotlin rewrite (Compose) | C. Kotlin Multiplatform / React Native | D. Upstream PR to omibutfree |
|---|---|---|---|---|
| Effort to first working build | **Days** (platform shell + MTU + permissions) | Weeks–months (~9k lines to re-implement + BLE/Opus/STT integrations) | Months; no reusable code | Same as A, but blocked on an inactive maintainer |
| Reuse of existing code | ~90 % | 0 % (models/prompts as reference only) | 0 % | ~100 % |
| BLE stack | `flutter_blue_plus` (mature, Android + iOS) | Android BluetoothGatt or Nordic BLE library | react-native-ble-plx / KMP wrappers | same as A |
| Opus decoding | `opus_flutter` (bundled libopus) | libopus via JNI, or Android `MediaCodec` (API 21+) | varies | same as A |
| On-device STT | `sherpa_onnx` Dart package (already integrated) | sherpa-onnx Kotlin API (exists, less documented) | sherpa-onnx has no first-class KMP/RN binding | same as A |
| Background execution | `flutter_foreground_task` (what the official Omi app uses) | Native foreground service (best control) | plugin-dependent | same as A |
| iOS build retained | Yes, same tree | No | Yes (KMP), but iOS UI separate | Yes |
| Maintainability by one person + AI agents | High: one language, huge Dart corpus, upstream Omi app is also Flutter so patterns transfer | Medium: two toolchains if iOS ever matters | Low | Depends on maintainer |
| Risk | Plugin rot; Flutter background limits | Highest scope risk | Highest ecosystem risk | Governance risk |

## Why A

1. **The port is small.** Analysis (`01-upstream-analysis.md` §1, §4) shows every
   dependency already ships an Android implementation and the Dart code has no
   iOS-only branches. The user's concern that "Flutter still has different iOS and
   Android implementations" is true *inside the plugins*, not in this app's code.
2. **The official Omi app is Flutter too.** It solves the same Android problems
   (foreground service, MTU 512, permission set) with the same package ecosystem, so
   there is a proven reference for every Android-specific piece we need.
3. **Compatibility is the stated priority.** Staying in Dart keeps one codebase that
   can produce both Android and iOS builds, and keeps the door open to merging fixes
   from upstream `omibutfree` or borrowing from the official app.
4. **AI-assisted development favours a single, well-trodden stack.** Every issue in
   the backlog can be handed to a coding agent with a Dart-only scope.

## Why not B

A native rewrite would re-implement BLE, Opus, sherpa-onnx integration, SQLite,
notifications, and ~4.5k lines of UI before reaching feature parity, with no
compensating benefit for a personal-use client. Native code gives finer control over
the foreground service and Doze, but `flutter_foreground_task` is sufficient (the
official app shipped on it for years before adding a native service for companion-
device features we do not need).

## Constraints adopted with the decision

- **Flutter stable, Dart 3.x.** Pin the Flutter version in `.fvmrc`/`mise.toml` so
  agents and CI use the same SDK.
- **Android minSdk 26, targetSdk 35, compileSdk 35.** See `04-android-platform-notes.md`.
- **Keep `provider`.** Switching state management is churn with no user value; split
  `AppProvider` instead (`03-architecture.md`).
- **Keep `sqflite` and the v3 schema** for the first release; migrate to `drift` only
  if typed queries become a pain point.
- **Pin plugin versions** in `pubspec.yaml` (no `^` on BLE, opus, sherpa) and upgrade
  deliberately. `flutter_blue_plus` 2.x changed APIs; start on the 1.36.x line that
  upstream uses, upgrade as a dedicated task.
- **MIT license retained**, upstream copyright preserved in `LICENSE` and `README`.
- **iOS is "kept buildable", not "supported".** No iOS-only work until Android ships.

## Known risks and mitigations

| Risk | Mitigation |
|------|------------|
| OEM battery managers (Samsung, Xiaomi, OnePlus) kill the foreground service | Request battery-optimisation exemption, show dontkillmyapp guidance in Settings, `autoConnect: true` reconnect, persistent notification |
| Android BLE flakiness (GATT 133, bonding prompts, MTU refused) | Retry with backoff, cache characteristics, request `ConnectionPriority.high` during streaming, test on ≥2 phones |
| APK size from sherpa-onnx native libs (~15–20 MB per ABI) | `abiFilters arm64-v8a` for dev; App Bundle / split APKs for release; models downloaded on demand |
| `opus_flutter` / `sherpa_onnx` plugin maintenance | Pin versions; both have active upstreams; fallback is Android `MediaCodec` Opus decoder via a small platform channel |
| Flutter runs all logic in the main isolate; heavy STT can jank UI | Run sherpa/whisper decoding in a background isolate (`Isolate.run`) in M4 |
| Upstream drifts (official Omi firmware protocol changes) | Protocol constants isolated in one file (`05-omi-ble-protocol.md`), firmware version shown in Device Settings |
