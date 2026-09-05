# AGENTS.md — conventions for AI coding agents

This file is read by Claude Code, Codex, Cursor, and similar tools. Keep it short; the
detail lives in `docs/`.

## What this project is

LibreOmi: Flutter app (Dart only, no custom platform channels unless a doc says so)
that connects to Omi wearables over BLE, transcribes audio (Deepgram or on-device
sherpa-onnx), and stores conversations/memories/tasks in local SQLite. Android is the
primary target; iOS must stay buildable. Forked from `kbdevs/omibutfree` (MIT).

## Read before coding

- `docs/03-architecture.md` — module layout and interfaces you must respect.
- `docs/04-android-platform-notes.md` — permissions, foreground service, MTU, build.
- `docs/05-omi-ble-protocol.md` — the only place protocol constants are documented.
- `docs/06-roadmap.md` — the work item you are implementing and its acceptance criteria.
- `docs/08-dev-workflow.md` — language policy, PR expectations, device checklist.

## Rules

- Code, comments, commit messages: English. Issues/PR text: Korean (see workflow doc).
- Never add `Platform.isAndroid` branches inside `device/`, `audio/`, `transcription/`,
  `intelligence/`; platform differences belong in `platform/`.
- Do not change pinned versions of `flutter_blue_plus`, `opus_flutter`, `sherpa_onnx`,
  `flutter_foreground_task` without a dedicated issue.
- Every parser or state machine change needs a unit test. BLE cannot be tested in CI:
  provide `FakeOmiDevice` fixtures and list manual steps for the owner.
- Keep `flutter analyze` clean. Run `flutter test` before opening a PR.
- If a doc turns out to be wrong, fix the doc in the same PR and say so.

## Commands

```bash
mise install                 # flutter + java 17 (see mise.toml)
flutter pub get
flutter analyze
flutter test
flutter run -d <android-device-id>
```
