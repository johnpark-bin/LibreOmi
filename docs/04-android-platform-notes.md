# 04 — Android platform notes

Everything Android-specific that the upstream app never had to deal with.

## 1. Toolchain

| Component | Version | Note |
|-----------|---------|------|
| Flutter | latest **stable** (3.3x, Dart 3.9+) | pin via `mise`/`fvm`; upstream pubspec needs Dart `^3.9.2` |
| JDK | **17** (Temurin) | AGP 8.x requires 17; the machine currently has JDK 25, which Gradle may reject — install 17 alongside and set `org.gradle.java.home` or `JAVA_HOME` |
| Android SDK | platform 35, build-tools 35.x, cmdline-tools, platform-tools | `flutter doctor --android-licenses` |
| Android Studio | optional | useful for the emulator and logcat, not required |
| Physical phone | **required** | Emulators have no BLE. Android 12+ recommended (new permission model), ideally one Samsung and one Pixel |

`flutter doctor` must be clean before M1 starts.

## 2. SDK levels

- `minSdk 26` — notification channels, `AudioRecord` PCM, `foregroundServiceType`
  (API 29+, gracefully ignored below), sherpa-onnx and flutter_blue_plus both ≥ 21.
  Going lower buys almost no devices and costs permission branches.
- `targetSdk 35`, `compileSdk 35` — Google Play requires ≥ 35 for new apps/updates since
  Aug 2025.
- Kotlin/Gradle from the Flutter template (Kotlin DSL `build.gradle.kts`).

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
| `WAKE_LOCK` | all | no | partial wake lock while listening |
| `INTERNET` | all | no | Deepgram/OpenAI/model download |
| `SCHEDULE_EXACT_ALARM` | 31–32 granted, ≥ 33 denied by default | intent | exact task reminders. Prefer **inexact** alarms (`preciseAlarm: false`) and only offer exact as an opt-in |
| `VIBRATE` | all | no | haptic feedback |

Flow (`platform/permissions.dart`): on first launch request notifications; when the
user taps "Scan" request BLE (or location on ≤ 30); when they choose phone mic request
`RECORD_AUDIO`; when the first session starts, offer the battery-optimisation exemption
with an explanation screen. Never request everything at startup.

## 4. Foreground service

`flutter_foreground_task` (same as the official app). Manifest additions:

```xml
<service
    android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
    android:foregroundServiceType="connectedDevice|microphone"
    android:exported="false" />
```

- Start the service **before** starting BLE audio notifications or the mic stream.
- Use a dedicated low-importance notification channel for the persistent notification;
  keep AI responses / reminders on their own high-importance channels.
- On Android 14+, starting a `microphone`-type service from the background throws; the
  session must transition from a foreground UI action (or already be running).
- Stop the service when idle with no device connected, otherwise the persistent
  notification annoys users and Play reviewers.

## 5. BLE specifics (`flutter_blue_plus` on Android)

- `await device.connect(timeout: 10s, autoConnect: false)` for user-initiated connects;
  `autoConnect: true` for the saved device in the background (slower, but survives
  out-of-range and needs no scan → no location/scan permission traffic).
- Immediately after connect: `await device.requestMtu(512)`; verify the returned MTU
  is ≥ 86 (83-byte audio packet + 3-byte ATT header). If the phone refuses, show an
  error and do not start a session; truncated packets would silently corrupt audio.
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
  of `String.hashCode`.

## 7. Native libraries and APK size

- `sherpa_onnx_android` bundles `libonnxruntime.so` + `libsherpa-onnx-*.so` for
  arm64-v8a, armeabi-v7a, x86_64 (~15–20 MB per ABI uncompressed).
- Dev builds: `ndk { abiFilters += listOf("arm64-v8a") }`.
- Release: Android App Bundle for Play; for GitHub Releases build
  `flutter build apk --split-per-abi` and publish arm64 + armeabi-v7a.
- `opus_flutter_android` bundles libopus (small).
- If R8 minification is enabled, add keep rules for `com.k2fsa.sherpa.onnx.**` and the
  opus JNI class; simplest is `isMinifyEnabled = false` for v1.

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
  FGS apps. Add a Settings entry linking to https://dontkillmyapp.com/<vendor> and detect
  the manufacturer via `device_info_plus`.

## 12. Build commands (reference)

```bash
flutter create --platforms=android --org org.libreomi --project-name libreomi .
flutter pub get
flutter run --release -d <device-id>      # BLE only works on a real phone
flutter build apk --split-per-abi --release
flutter build appbundle --release
```
