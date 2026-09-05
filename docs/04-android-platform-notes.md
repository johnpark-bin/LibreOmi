# 04 — Android platform notes

Everything Android-specific that the upstream app never had to deal with.

## 1. Toolchain

Pinned in `mise.toml` at the repository root; `mise install` reproduces it. The versions below
are the ones this project was actually set up and verified with (2026-09-06).

| Component | Version | Note |
|-----------|---------|------|
| Flutter | **3.47.2** stable (Dart 3.13.2) | pinned in `mise.toml`; never the moving `stable` alias, so a fresh clone builds what was tested |
| JDK | **Temurin 17** (`java = "temurin-17"`) | AGP 8.x requires 17. mise exports `JAVA_HOME`, which is what Gradle reads; Flutter's own tooling needs the separate `--jdk-dir` step below |
| Android SDK | platform 36 (and 35), build-tools 36.0.0 (and 35.0.0), platform-tools, cmdline-tools 22.0 | installed under `$HOME/Library/Android/sdk`; `ANDROID_HOME` is injected by `mise.toml` |
| Android Studio | optional | useful for the emulator and logcat, not required |
| Physical phone | **required** | Emulators have no BLE. Android 12+ recommended (new permission model), ideally one Samsung and one Pixel |

`flutter doctor` must have Flutter, Android toolchain and Android licenses green before M1
starts. The Xcode entry is not a gate for this project (Android is the primary target).

### First-time machine setup (macOS)

`mise install` covers Flutter and the JDK. The Android SDK is not a mise tool, so it is
installed once per machine with `sdkmanager`:

```bash
mise trust                                     # once per clone, before mise reads mise.toml
mise install                                   # flutter 3.47.2 + temurin-17

brew install --cask android-commandlinetools   # bootstrap sdkmanager only

export ANDROID_HOME="$HOME/Library/Android/sdk"
sdkmanager --sdk_root="$ANDROID_HOME" \
    "platform-tools" \
    "platforms;android-36" "build-tools;36.0.0" \
    "platforms;android-35" "build-tools;35.0.0" \
    "cmdline-tools;22.0"

# Note the inner quoting: JAVA_HOME must be expanded by mise, not by your outer shell.
mise exec -- sh -c 'flutter config --jdk-dir "$JAVA_HOME"'
mise exec -- flutter doctor --android-licenses
mise exec -- flutter doctor -v
```

Everything lands under `$HOME` or the Homebrew prefix; nothing is installed system-wide and no
shell rc file is modified.

Four details are not obvious and cost time if rediscovered:

- **Platform 36 is required even though we ship `targetSdk 35`.** Flutter 3.47's
  `flutter doctor` fails the Android toolchain with *"Flutter requires Android SDK 36 and the
  Android BuildTools 28.0.3"* unless `platforms;android-36` is installed, because Flutter's
  Gradle plugin compiles against 36 and the check looks at the highest installed platform.
  `targetSdk` is a manifest value and needs no installed platform at all. Platform 35 and
  build-tools 35.0.0 are kept only so that dropping back to `compileSdk 35` needs no
  re-download; nothing currently requires them.
- **Do not install `cmdline-tools;latest`.** Version 23.0 delegates to the new `android` CLI
  and answers `sdkmanager --licenses` with *"The --licenses option is no longer needed"*.
  Flutter 3.47.2 parses that output for the literal string *"All SDK package licenses
  accepted."*, so it can only conclude *"Android license status unknown"* and the toolchain
  never goes green (flutter/flutter#191487). `cmdline-tools;22.0` still prints the expected
  string. Revisit this pin once a stable Flutter ships the disk-based fallback that currently
  exists only on `master`.
- **`JAVA_HOME` alone does not decide which JDK Flutter uses.** Flutter resolves it as
  `flutter config --jdk-dir` → Android Studio's bundled JBR → `JAVA_HOME` → `PATH`, so on a
  machine with Android Studio installed it silently picks the JBR (JDK 25 here) and ignores the
  pinned 17. Only `flutter config --jdk-dir` pins it. This is separate from Gradle, which reads
  `JAVA_HOME` directly. LO-03 created `android/` and built a debug APK with
  `mise exec -- flutter build apk --debug`; Gradle picked up the mise-provided Temurin 17 from
  `JAVA_HOME` with no extra configuration, so `org.gradle.java.home` stays unnecessary.
- **`flutter config` is global, not per-project.** It writes `~/.config/flutter/settings` for
  every Flutter project on the machine, storing an absolute path that contains the exact JDK
  patch build. Because `java = "temurin-17"` floats within 17.x, re-run the `--jdk-dir` command
  after a JDK patch bump, or Flutter falls back to Android Studio's JBR again.

If `flutter doctor` warns about multiple `adb` binaries, it is because Homebrew's
`android-platform-tools` cask is installed alongside the SDK's own `platform-tools`. It is a
warning only and does not fail the toolchain check.

## 2. SDK levels

- `minSdk 26` — notification channels, `AudioRecord` PCM, `foregroundServiceType`
  (API 29+, gracefully ignored below), sherpa-onnx and flutter_blue_plus both ≥ 21.
  Going lower buys almost no devices and costs permission branches.
- `targetSdk 35` — Google Play requires ≥ 35 for new apps/updates since Aug 2025.
- `compileSdk 36` — not a Play requirement but a Flutter one: Flutter 3.47.2's Gradle plugin
  compiles against 36, and `flutter doctor` fails the Android toolchain without
  `platforms;android-36` (see §1). Compiling against 36 while targeting 35 is the normal
  Android arrangement. The template does not write literals at all — it emits
  `flutter.compileSdkVersion` / `flutter.minSdkVersion` / `flutter.targetSdkVersion`, which
  follow whatever Flutter version is installed (`targetSdk` would drift to 36). LO-03
  therefore pinned all three literally in `android/app/build.gradle.kts`.
- Kotlin/Gradle from the Flutter template (Kotlin DSL `build.gradle.kts`).
- **`android.ndk.suppressMinSdkVersionError=21` in `android/gradle.properties` is required.**
  `opus_flutter_android` (pulled in by the pinned `opus_flutter 3.0.1`) still declares
  `minSdk 19`, and the NDK that Flutter 3.47.2 provisions (r28c) refuses to build for
  anything below 21, failing the whole build at configuration time with `[CXX1110] Platform
  version 19 is unsupported by this NDK`. Suppressing it is safe here because the
  application's own `minSdk 26` is what ends up in the merged manifest. Remove the flag if
  `opus_flutter` is ever unpinned and updated.
- **The same plugin also needs its `compileSdk` raised from the root Gradle file.**
  `opus_flutter_android` compiles against android-33, while the AndroidX artifacts it depends
  on (`androidx.core 1.13.1`, `androidx.fragment 1.7.1`, …) require 34 or later, so
  `:opus_flutter_android:checkDebugAarMetadata` fails with 15 AAR-metadata issues. LO-03 added
  a `subprojects { afterEvaluate { … } }` hook in `android/build.gradle.kts` that lifts that
  one module up to `compileSdk 36`. It is deliberately scoped to `opus_flutter_android` so
  that a second plugin needing the same treatment fails loudly instead of being fixed
  silently. It has to be registered *before* the
  template's `subprojects { project.evaluationDependsOn(":app") }` block — that block
  evaluates `:app` eagerly, and a later `afterEvaluate` on an already-evaluated project
  throws. `minSdk`/`targetSdk` are untouched; only the compile SDK moves.

## 3. Permission matrix

| Permission | API range | Runtime? | Why |
|------------|-----------|----------|-----|
| `BLUETOOTH`, `BLUETOOTH_ADMIN` | ≤ 30 | no | legacy BLE |
| `ACCESS_FINE_LOCATION` | ≤ 30 (scan needs it) | yes | legacy BLE scan; on 31+ not needed when `BLUETOOTH_SCAN` has `neverForLocation` |
| `BLUETOOTH_SCAN` (`usesPermissionFlags="neverForLocation"`) | ≥ 31 | yes | scanning |
| `BLUETOOTH_CONNECT` | ≥ 31 | yes | connect, read name |
| `RECORD_AUDIO` | all | yes | phone-mic mode only; request lazily |
| `POST_NOTIFICATIONS` | ≥ 33 | yes | all notifications incl. the foreground-service one |
| `FOREGROUND_SERVICE` | ≥ 28 | no | |
| `FOREGROUND_SERVICE_CONNECTED_DEVICE` | ≥ 34 | no | BLE session service type |
| `FOREGROUND_SERVICE_MICROPHONE` | ≥ 34 | no | phone-mic session service type; on 34+ a mic FGS must be started while the app is in the foreground |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | ≥ 23 | intent | keep BLE alive in Doze; Play policy allows it for "connected device" apps |
| `WAKE_LOCK` | all | no | partial wake lock while listening (`allowWakeLock: true`) |
| `RECEIVE_BOOT_COMPLETED` | all | no | **merged out**: contributed by `flutter_foreground_task`, unused because boot start is out of scope (see §4) |
| `INTERNET` | all | no | Deepgram/OpenAI/model download |
| `SCHEDULE_EXACT_ALARM` | 31–32 granted, ≥ 33 denied by default | intent | exact task reminders. Prefer **inexact** alarms (`preciseAlarm: false`) and only offer exact as an opt-in |
| `VIBRATE` | all | no | haptic feedback |

Flow (`platform/permissions.dart`): on first launch request notifications; when the
user taps "Scan" request BLE (or location on ≤ 30); when they choose phone mic request
`RECORD_AUDIO`; when the first session starts, offer the battery-optimisation exemption
with an explanation screen. Never request everything at startup.

## 4. Foreground service

`flutter_foreground_task 11.0.2` (same plugin as the official app), pinned to an exact
version because `08-dev-workflow.md` §3 forbids new `^` ranges on native plugins.
Manifest additions inside `<application>`:

```xml
<meta-data
    android:name="org.libreomi.app.NOTIFICATION_ICON"
    android:resource="@drawable/ic_notification" />
<service
    android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
    android:foregroundServiceType="connectedDevice|microphone"
    android:stopWithTask="true"
    android:exported="false" />
```

The manifest declares the union of the types; each session requests the subset it needs
through `startService(serviceTypes: …)`. The plugin resolves the small status-bar icon
through the `<meta-data>` entry above (`NotificationIcon(metaDataName: …)`), not by
resource name — without it the notification falls back to the launcher icon.

The plugin's own manifest contributes `RECEIVE_BOOT_COMPLETED` for its optional boot
receiver. A boot receiver is out of scope for v1 (`03-architecture.md` §5) and the
service is configured with `autoRunOnBoot: false`, so the app manifest merges the
permission out with `tools:node="remove"`.

Dart side, in `lib/platform/`:

| File | Role |
|------|------|
| `background_reasons.dart` | `BackgroundReason`, reason set → service types, notification text and its 30 s update throttle. Pure, unit-tested. |
| `background_runner.dart` | The `BackgroundRunner` interface (`03-architecture.md` §2). |
| `android_foreground_runner.dart` | The plugin wrapper. |
| `noop_background_runner.dart` | Every non-Android platform. |
| `background_runner_factory.dart` | Picks the implementation; one of the `platform/` files allowed a `Platform.isAndroid` branch. |
| `fake_background_runner.dart` | Recording fake for tests. |

Options used (`ForegroundTaskOptions`): `eventAction: nothing()` — the task handler is
empty on purpose, see `03-architecture.md` §5 item 2 — `allowWakeLock: true` (LO-24's
partial wake lock), `allowWifiLock: false`, `autoRunOnBoot: false`,
`autoRunOnMyPackageReplaced: false`, `allowAutoRestart: false`. The service must also die
with the app task, but that is set **only** as `android:stopWithTask="true"` on the
`<service>`, never through the plugin's Dart option of the same name.

Both of those are deliberate. Left at the defaults, `ForegroundService.onTaskRemoved`
sets a 1 s restart alarm and `onDestroy` a 5 s one, and the service comes back in a fresh
engine running the empty task handler — with no `AppProvider`, no BLE and no transcriber
behind it. That is a persistent notification claiming to record that the app cannot take
down, i.e. exactly what LO-24 forbids; an auto-restart could not resume the session
anyway, because the session lives in the main isolate and not in the task handler.

The manifest flag alone is enough: `ForegroundServiceUtils.isSetStopWithTaskFlag` falls
back to `ServiceInfo.FLAG_STOP_WITH_TASK` whenever the preference is absent, which makes
`onTaskRemoved` call `stopSelf()`, keeps `onDestroy` from arming the restart alarm, and
returns `START_NOT_STICKY`. Passing `stopWithTask: true` from Dart would additionally make
`onStartCommand` install `TrackVisibilityUtils`, which stops the service as soon as no
activity is resumed — that is every screen-off, i.e. precisely the case LO-20 exists to
survive. Do not set it there.

The trade-off of the manifest flag is that swiping the app out of recents ends the
session; the screen going off, which is what LO-20 is about, does not remove the task.
`AppProvider._init()` additionally calls `stop()` once at start-up to reap a service
orphaned by a process that died without stopping it.

- Start the service **before** starting BLE audio notifications or the mic stream.
- Reason sets: an Omi BLE session uses `{connectedDevice}`; a phone-mic session uses
  `{connectedDevice, microphone}`.
- The persistent notification reuses the low-importance `session` channel (§6). Android
  keeps the first definition of a channel id, so the plugin's own channel options are
  effectively a no-op as long as `awesome_notifications` registers the channel under the
  literal id `session` — worth confirming on a device that Settings → Notifications lists
  exactly one "Session" channel. Its notification id is 1 000 000, above the range
  `NotificationService` uses for instant notifications; task reminders derive ids across
  the whole 31-bit range and could in principle collide, which LO-35 removes.
- Notification text is `<source> · <mm:ss>`, e.g. `Omi connected · 12:34`, refreshed from
  transcript segments and connection changes but rate-limited to one update per 30 s
  unless the source part itself changed.
- Foreground services cannot generally be started from the background since API 31; the
  Omi path starts one from the BLE connection callback, so it depends on the
  battery-optimisation exemption (LO-11 / #15) to be reliable. `startService` returns a
  failure result rather than throwing, and `AndroidForegroundRunner` logs it and lets the
  session continue in the foreground.
- On Android 14+, a `microphone`-type service additionally may only be started while the
  app is in the foreground; the phone-mic session is only ever reached from a button tap.
  `requiresForegroundStart()` states which reason sets that applies to and is used to
  annotate the failure log — it is a documented rule, not an enforced guard.
- Stop the service as soon as the session leaves listening, whether or not a device is
  still connected — an idle app must show no persistent notification (LO-24), otherwise
  it annoys users and Play reviewers.

## 5. BLE specifics (`flutter_blue_plus` on Android)

- `await device.connect(timeout: 10s, autoConnect: false)` for user-initiated connects;
  `autoConnect: true` for the saved device in the background (slower, but survives
  out-of-range and needs no scan → no location/scan permission traffic).
- Immediately after connect: `await device.requestMtu(512)`; verify the returned MTU
  is ≥ 86 (83-byte audio packet + 3-byte ATT header). If the phone refuses, show an
  error and do not start a session; truncated packets would silently corrupt audio.
  Note that `flutter_blue_plus`' `connect()` already defaults to `mtu: 512` and issues
  that request itself, so pass `connect(mtu: null)` and negotiate explicitly — otherwise
  the MTU is exchanged twice per connect and the returned value is never observed
  (`BleService.connect`, `lastMtu`).
- `await device.requestConnectionPriority(connectionPriorityRequest: ConnectionPriority.high)`
  while streaming; reset to `balanced` when idle to save battery.
- GATT error 133 / 257 on connect are common: retry up to 3× with 1–2 s delay; if
  persistent, `FlutterBluePlus.turnOff/On` is not allowed on 33+ — ask the user to toggle
  Bluetooth.
- Some phones need bonding for notifications on custom services — Omi does not; do not
  call `createBond`.
- Keep `FlutterBluePlus.setLogLevel(LogLevel.warning)` in release; verbose logs slow the
  notification path.
- Scan: use `withServices: [omi service uuid]` **and** a name filter; Android scan
  throttling kicks in after 5 scans in 30 s, so never scan in a tight loop.

## 6. Notifications

- `awesome_notifications` needs a monochrome small icon:
  `android/app/src/main/res/drawable/ic_notification.xml` (white glyph, transparent bg),
  passed as `'resource://drawable/ic_notification'`.
- The upstream `soundSource: 'resource://raw/res_custom_notification'` must either get a
  real file in `res/raw/` or be removed. Remove for v1.
- Channels: `session` (low, persistent FGS), `ai_responses` (max), `task_reminders` (high),
  `device` (default: battery, disconnect).
- Reminder IDs: add an integer `notification_id` column (autoincrement) to `tasks` instead
  of `String.hashCode`. That column arrives with LO-35; until then LO-16 derives the id from
  the persisted `created_at` in `lib/services/notification_ids.dart`, because `String.hashCode`
  is not stable across restarts and a reminder scheduled before one could not be cancelled
  after it.
- Task reminders are scheduled inexact (`preciseAlarm: false`, `allowWhileIdle: true`) so the
  app needs neither `SCHEDULE_EXACT_ALARM` nor `USE_FULL_SCREEN_INTENT`. Delivery may lag the
  due time by minutes; an exact-alarm opt-in is a follow-up.

## 7. Native libraries and APK size

- `sherpa_onnx_android` bundles `libonnxruntime.so` + `libsherpa-onnx-*.so` for
  arm64-v8a, armeabi-v7a, x86_64 (~15–20 MB per ABI uncompressed). That dominates the APK.
  Measured on clean builds at LO-10: an all-ABI debug APK is 215.8 MiB (arm64-v8a 71.7 MiB,
  armeabi-v7a 45.5 MiB, x86_64 60.8 MiB of packaged `lib/`), and dropping the two unused ABIs
  takes it to 109.4 MiB. Measure on a clean build only — AGP repacks `app-debug.apk`
  incrementally, so an APK from an incremental build keeps stale bytes and reports the old size
  even after the ABIs are gone. `--target-platform android-arm64` gets only to ~146 MiB, because
  it narrows Flutter's own engine libraries and leaves the plugin AARs' ABIs alone.
- **Debug builds keep arm64-v8a only, and `ndk { abiFilters }` is the wrong tool for it.**
  The Flutter Gradle plugin resets `defaultConfig.ndk.abiFilters` to all three supported ABIs
  while it is being applied (`FlutterPlugin.configureAbiWithoutSplits`, Flutter 3.47.2), and AGP
  merges the `defaultConfig` and build-type filter sets as a *union*. A narrower
  `abiFilters` on `buildTypes.debug` is therefore silently inert — LO-10 measured an unchanged
  all-ABI APK with it in place. Putting the filter in `defaultConfig` would win, but it would
  also pin the release APK to arm64 and collide with the `--split-per-abi` release flow below.
  What works, per build type and after the plugin has run, is AGP's per-variant packaging hook in
  `android/app/build.gradle.kts`:

  ```kotlin
  androidComponents {
      onVariants(selector().withBuildType("debug")) { variant ->
          variant.packaging.jniLibs.excludes.addAll(
              "**/armeabi-v7a/**", "**/x86_64/**"
          )
      }
  }
  ```

  Development phones are arm64; drop `armeabi-v7a` from the exclude list if an older test device
  shows up. A debug build installed on a device whose ABI was excluded fails at runtime with
  `UnsatisfiedLinkError` when the first native library is loaded, not at build or install time,
  so the symptom does not point at this setting on its own. Note this trims what is *packaged*,
  not what is built, so it shrinks the APK and the install step rather than Gradle's compile time.
  The list only needs the ABIs Flutter itself supports (`PLATFORM_ABI_LIST` is armeabi-v7a,
  arm64-v8a, x86_64) — x86 can never reach the APK, because the plugin's `defaultConfig` filter
  already excludes it.
- Release: every ABI stays in the build. Android App Bundle for Play; for GitHub Releases
  build `flutter build apk --split-per-abi` and publish arm64 + armeabi-v7a (LO-63).
- `opus_flutter_android` bundles libopus (small).
- R8 is off for v1: `buildTypes.release` sets `isMinifyEnabled = false` and
  `isShrinkResources = false` explicitly. Turning minification on would require keep rules for
  `com.k2fsa.sherpa.onnx.**` and the opus JNI class, and a wrongly stripped JNI entry point
  fails at runtime rather than at build time, so it needs a device to verify. Revisit when
  release size actually matters.

## 8. Storage paths

- `getApplicationDocumentsDirectory()` on Android = `/data/data/<pkg>/app_flutter` —
  private, backed up by Auto Backup (models would bloat backups; exclude via
  `android:fullBackupContent` or store models in `getApplicationSupportDirectory()`).
- SD-card sync `.bin` files: `getApplicationSupportDirectory()/sdcard/`.
- STT models: `getApplicationSupportDirectory()/models/<name>/`; show size and a delete
  button in Settings.
- Export: write JSON to cache dir and share via `share_plus`; optionally SAF
  (`file_picker` save) later.

## 9. Secrets

- Replace plaintext SharedPreferences for `deepgram_api_key` / `openai_api_key` with
  `flutter_secure_storage` (`encryptedSharedPreferences: true`). One-time migration on
  first launch of the new version.
- Exclude secure-storage files from Auto Backup.

## 10. Audio (phone mic)

- `record` → `AudioRecord` PCM16 16 kHz mono; request `RECORD_AUDIO` first.
- Set `audio_session` to `AVAudioSessionCategory.record`-equivalent Android config
  (`AndroidAudioAttributes` usage `voiceCommunication` is not needed; plain
  `media`/`unknown` with `AudioFocus` gain is fine).
- The microphone-type FGS is mandatory for background capture on 30+.

## 11. Doze, App Standby, and OEM killers

- Even with an FGS, Doze may defer network (Deepgram/OpenAI) during deep idle; the BLE
  link itself survives. Finalization requests should use a retry queue (M2).
- Samsung "Sleeping apps", Xiaomi "Battery saver", OnePlus, Huawei aggressively kill
  FGS apps. LO-21 detects `Build.MANUFACTURER` via `device_info_plus` and shows a
  per-vendor guidance page (`lib/pages/battery_guidance_page.dart`) built from the table in
  `lib/platform/battery_optimization.dart`, reachable from Settings > Background reliability.
- dontkillmyapp.com is **not** uniformly `/<vendor>`: Honor, Redmi and POCO have no page of
  their own (they 404) and are folded into `/huawei` and `/xiaomi`, as is Black Shark; realme
  does have its own `/realme`; anything unrecognised falls back to `/general`. Verify a slug
  before adding a vendor.
- The exemption itself is the `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` intent, fired through
  `permission_handler`'s `Permission.ignoreBatteryOptimizations`. It is offered once, right
  before the first session starts, and is reachable again from Settings afterwards.

## 12. Build commands (reference)

All commands run through `mise exec --` so they use the pinned Flutter and JDK 17 rather than
whatever happens to be on `PATH`. Inside a shell where mise is already activated the prefix can
be dropped.

```bash
mise install                              # once per clone: flutter 3.47.2 + temurin-17
mise exec -- flutter doctor -v            # Flutter / Android toolchain / licenses must be green

mise exec -- flutter create --platforms=android --org org.libreomi --project-name libreomi .
mise exec -- flutter pub get
mise exec -- flutter analyze
mise exec -- flutter test
mise exec -- flutter run --release -d <device-id>   # BLE only works on a real phone
mise exec -- flutter build apk --split-per-abi --release
mise exec -- flutter build appbundle --release
```
