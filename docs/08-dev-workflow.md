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
  check and is not uploaded — release
  artifacts are LO-63.
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

## 7. Release checklist (M6)

1. Bump `version:` in `pubspec.yaml`; update `CHANGELOG.md` (English).
2. `flutter build apk --split-per-abi --release` with signing env vars.
3. Run the smoke checklist on two phones.
4. Tag `vX.Y.Z`; GitHub Release with APKs and the Korean + English notes.
