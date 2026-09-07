# 08 — Development workflow

## 1. Language policy

| Artefact | Language | Why |
|----------|----------|-----|
| Source code, identifiers, comments, docstrings | English | ecosystem default; agents produce better Dart with English context |
| `docs/`, `README.md`, `AGENTS.md`, CHANGELOG | English | future contributors |
| Commit messages | English, Conventional Commits (`feat(ble): request MTU 512 on Android`) | tooling, changelog generation |
| GitHub issues and pull requests (bootstrap phase) | **Korean** title + body; PR body ends with a one-line English summary | project owner reads/writes Korean; the English line keeps history greppable |
| In-app strings | English first, Korean via i18n (M6) | |
| Owner-facing summaries produced by agents | Korean | token efficiency for the owner; see `SUMMARY.ko.md` |

After public launch, issues from outside contributors may be in any language; maintainers reply in the issue's language.

## 2. Branching and PR flow

- `main` is protected; CI must pass. The workflow is `.github/workflows/ci.yml` (LO-04): one
  `ubuntu-latest` job on every pull request and every push to `main`, running `flutter pub get`
  → `flutter analyze` → `flutter test` → `flutter build apk --debug --target-platform android-arm64`.
  It reads the Flutter and JDK versions out of `mise.toml` instead of repeating them, so CI and a
  local checkout cannot drift apart. Analyze runs with `--no-fatal-infos --no-fatal-warnings`:
  errors fail the job, while the warnings and infos inherited from upstream do not. Clearing those
  is out of scope for LO-04 and is not filed as a backlog item yet. The debug APK is a compile
  check and is not uploaded — release artifacts come from `.github/workflows/release.yml`
  (LO-63), which runs on `v*` tags only. Neither workflow currently executes: GitHub Actions
  is disabled on this account for billing reasons, so both are validated with `actionlint` and
  by running the same commands locally.
- One branch per backlog item: `lo-12-ble-mtu`. One PR per branch, squash-merged.
- PR template (Korean) asks for: 목적, 변경 내용, 테스트 방법(에뮬레이터 불가 항목은 실기기 명시), 스크린샷/로그, 관련 이슈 (`Closes #n`).
- Every PR that touches `device/`, `audio/`, `session/`, or `platform/` must include a
  filled **device smoke checklist** (§5) in the description, because CI cannot exercise BLE.

## 3. Definition of done

1. Acceptance criteria in `06-roadmap.md` met and stated in the PR.
2. `flutter analyze` has zero warnings in changed files.
3. Unit tests added for any parser / state machine / repo change.
4. Docs updated if behaviour or protocol assumptions changed (`05-omi-ble-protocol.md` in particular).
5. No new `^` version ranges on native plugins (BLE, opus, sherpa, foreground task).

## 4. Working with AI coding agents

The backlog is written so that each issue is self-contained for an agent. When
delegating an issue:

1. Paste the issue body and point the agent at `AGENTS.md` (which links the docs).
2. Require the agent to state which document sections it relied on and to update them if wrong.
3. Agents cannot test BLE. They must produce: unit tests for pure logic, a `FakeOmiDevice`
   fixture where applicable, and the exact `adb logcat` filters / manual steps the owner
   should run on a phone.
4. The owner runs the device smoke checklist and pastes results into the PR (Korean is fine).

Suggested split: agents do M0, M3 (refactor + tests), M4–M6 logic; the owner personally
drives M1 and M2 on hardware because those milestones are dominated by device-specific
behaviour and permission dialogs that must be observed by a human.

## 5. Device smoke checklist (copy into PR)

```
기기: <제조사/모델/Android 버전>   펌웨어: <Omi firmware>   빌드: <commit>
[ ] 권한 요청 순서 정상 (알림 → BLE → (마이크))
[ ] 스캔에서 Omi 표시, 연결 10초 이내
[ ] logcat 에서 MTU >= 86 확인, 오디오 패킷 길이 83
[ ] 라이브 자막 2초 이내 표시
[ ] 화면 끄고 10분 후에도 자막 누적 (M2 이후)
[ ] 범위 이탈 → 복귀 시 30초 내 재연결 (M2 이후)
[ ] 더블탭 → 대화 저장 알림, History 에 표시
[ ] 싱글탭 → 질문 → 싱글탭 → 알림으로 답변
[ ] 배터리/펌웨어/게인/LED 읽기·쓰기
[ ] 앱 종료 후 재시작 시 자동 재연결
```

Useful logcat filters:

```bash
adb logcat -s flutter:V FlutterBluePlus:V BluetoothGatt:V
adb shell dumpsys activity services | grep -i foreground
adb shell dumpsys deviceidle whitelist | grep libreomi
```

## 6. Secrets and test accounts

- Deepgram key and OpenAI key are entered in-app only; never committed. CI has no keys;
  tests use fakes.
- For agents running on a laptop, `sqflite_common_ffi` is used in tests so no device DB is needed.

## 7. Releases (LO-63)

### 7.1 Versioning

`pubspec.yaml` holds `version: <name>+<code>`. LibreOmi restarts at `0.1.0+1`; upstream
omibutfree's `2.1.0` does not describe this fork and is not continued.

- `<name>` is semver, and is what the `vX.Y.Z` tag and the GitHub Release are named after.
- `<code>` becomes the Android `versionCode` and **only ever increases**, including across
  a version-name downgrade — Android and Play both refuse an update whose code went backwards.
  Bump it on every build that leaves this machine, not only on every version name.
- With `--split-per-abi` the Flutter Gradle plugin adds `1000 * ABI_VERSION` to the code per
  APK, so the arm64 and armeabi APKs of one build get distinct, ordered codes automatically.

### 7.2 Signing key

The key is the owner's, is never committed, and cannot be regenerated: **if it is lost, no
future build can update an installed app.** Back the keystore and its passwords up somewhere
that is not this repository and not this laptop alone.

Create it once:

```bash
keytool -genkey -v -keystore ~/libreomi-release.jks \
  -keyalg RSA -keysize 4096 -validity 10000 -alias libreomi
```

Then point the build at it with `android/key.properties` (git-ignored, and `.gitignore` also
covers `*.jks` / `*.keystore` so the keystore itself cannot be added by accident):

```properties
storeFile=/absolute/path/to/libreomi-release.jks
storePassword=<store password>
keyAlias=libreomi
keyPassword=<key password>
```

`android/app/build.gradle.kts` resolves signing material in this order:

1. the `LIBREOMI_KEYSTORE_PATH`, `LIBREOMI_KEYSTORE_PASSWORD`, `LIBREOMI_KEYSTORE_ALIAS` and
   `LIBREOMI_KEY_PASSWORD` environment variables — how CI injects the key from secrets;
2. `android/key.properties`;
3. neither: the release build falls back to the **debug** key and logs a Gradle warning
   naming the missing piece. This keeps `flutter build apk --release` working for contributors
   and for the CI compile check. A debug-signed APK must never be published.

`flutter build` filters Gradle's own output, so that warning is only visible under a direct
Gradle invocation (`cd android && ./gradlew :app:signingReport`). **Treat the signing
certificate as the authoritative check, never the absence of a warning.** `scripts/release.sh`
prints it on every run, and refuses to create a GitHub Release from debug-signed artifacts.

Check which key actually signed an APK — `scripts/release.sh` prints this, and warns loudly
when it sees `CN=Android Debug`:

```bash
# newest installed build-tools, the same one release.yml picks (release.sh prefers an
# apksigner already on PATH, then falls back to this)
"$(find "$ANDROID_HOME/build-tools" -mindepth 2 -maxdepth 2 -name apksigner | sort -V | tail -n1)" \
  verify --print-certs build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

For CI, the same keystore goes into repository secrets as `LIBREOMI_KEYSTORE_BASE64`
(`base64 -i ~/libreomi-release.jks`), `LIBREOMI_KEYSTORE_PASSWORD`, `LIBREOMI_KEYSTORE_ALIAS`
and `LIBREOMI_KEY_PASSWORD`.

### 7.3 Release checklist

1. Draft the notes: `scripts/changelog_draft.py --tag vX.Y.Z` prints a Keep a Changelog
   section from the merged PRs. Rewrite the (Korean) PR titles into English user-facing lines
   and paste them into `CHANGELOG.md`. Individual PRs deliberately do **not** touch
   `CHANGELOG.md`: parallel PRs would conflict in it on every merge.
2. Bump `version:` in `pubspec.yaml` per §7.1 and merge that with the changelog edit.
3. `scripts/release.sh --dry-run` — builds `app-arm64-v8a-release.apk`,
   `app-armeabi-v7a-release.apk` and `app-release.aab`, prints sizes, sha256 and the signing
   certificate, and uploads nothing. Confirm the certificate is *not* the debug key.
4. Install the arm64 APK on a phone and run the smoke checklist (§5) on two devices.
5. `git tag vX.Y.Z && git push origin vX.Y.Z`. That tag push is what
   `.github/workflows/release.yml` reacts to; while Actions is disabled on this account, run
   `scripts/release.sh` (without `--dry-run`) locally instead — it creates the same draft
   release with the same three artifacts attached.
6. Edit the draft release on GitHub: Korean notes plus the one-line English summary, per §1.
   Publish it.
7. Play internal testing takes `app-release.aab` and is out of scope for this repository's
   automation; upload it by hand via the Play Console
   (<https://support.google.com/googleplay/android-developer/answer/9859152>). Before that upload,
   re-read §8 and paste the current in-app disclosure text into the Play Console's sensitive
   permission declarations — Play compares what the form claims against what the app shows.

## 8. Play sensitive permissions and prominent disclosure (LO-64)

Play requires that an app which uses microphone, location or all-the-time background access
tells the user **inside the app, before the data is used**, what is collected and why, in a
screen the user cannot miss. LibreOmi does that with `lib/pages/permissions_rationale_page.dart`,
shown once on first launch (`SettingsService.rationaleShown`) and reachable afterwards from the
Live tab. The screen only *displays* permission state; each permission is still requested at the
point of use, which is what `docs/04-android-platform-notes.md` §3 requires.

**Keep this section and that page in sync.** The page is the disclosure; the text below is the
Play Console paraphrase of it. If one changes, change the other in the same PR.

### 8.1 Declaration draft (English, paste into the Play Console)

> LibreOmi records audio from a connected Omi wearable or from the phone's microphone, and only
> while the user has started a capture. The audio is transcribed either entirely on the device or,
> if the user enters their own Deepgram API key, by sending it to Deepgram. Conversation text is
> sent to an LLM endpoint only when the user supplies a key for one. LibreOmi has no server and no
> account: with no keys entered, no capture is sent to any service. Transcripts, conversations,
> memories, tasks and chat history are stored in the app's private SQLite database, and recordings
> synced from the wearable's SD card are stored as audio files in the app's private support
> directory. API keys are stored encrypted under a key held in the Android keystore. Android's
> automatic backup is left on (`allowBackup` default), so the database and the synced recordings
> are part of the user's Google account backup; the API keys and the downloaded speech models are
> excluded from it (`res/xml/backup_rules.xml`, `res/xml/data_extraction_rules.xml`). The user can
> export the four content tables as JSON or remove everything by clearing the app's data.
>
> Permissions and their purpose:
>
> - `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT` — discover and connect to the user's Omi wearable.
>   The scan is filtered to Omi devices and is never used to derive location; the manifest
>   carries `android:usesPermissionFlags="neverForLocation"`.
> - `ACCESS_FINE_LOCATION` (Android 11 and below only, `maxSdkVersion="30"`) — required by those
>   OS versions for any BLE scan. Location is never read.
> - `RECORD_AUDIO` — capture from the phone microphone when the user picks it as the source.
> - `POST_NOTIFICATIONS` — the ongoing capture notification and conversation-saved alerts.
> - `FOREGROUND_SERVICE` (`microphone` / `connectedDevice` types) — keep capture and transcription
>   running while the screen is off. No data is collected that is not already covered above.
> - `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` — optional; OEM battery managers otherwise stop the
>   capture service.

### 8.2 Before submitting

- Verify each bullet against `android/app/src/main/AndroidManifest.xml`; the manifest is the
  authority, this list is a copy.
- The exact-alarm opt-in (`SCHEDULE_EXACT_ALARM`, in flight in a separate branch) is deliberately
  **not** listed here or on the rationale screen: it is not in the manifest yet. Add a row to both
  when that branch merges.
- Fill the Data safety form from the same facts: audio and "other user-generated content" are
  collected, are not shared with third parties except the transcription/LLM endpoint the user
  configures themselves, and are not used for advertising or analytics.
- The backup claim is only as true as the two XML rule files. If a future issue adds a data
  directory (the way LO-50 added `<app support>/sdcard/`), decide whether it is excluded and
  update this section, the rationale screen and `docs/04-android-platform-notes.md` §9 together.
