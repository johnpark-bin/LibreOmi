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
mise trust                   # once per clone, before mise reads mise.toml
mise install                 # flutter 3.47.2 + temurin-17 (see mise.toml)
mise exec -- flutter doctor -v
mise exec -- flutter pub get
mise exec -- flutter analyze
mise exec -- flutter test
mise exec -- flutter run -d <android-device-id>
```

The Android SDK is not a mise tool — install it once per machine with the `sdkmanager` steps
in `docs/04-android-platform-notes.md` §1 before the Android toolchain check goes green.

<!-- graft:start -->
## Graft — repo context graph

This repo is indexed in `graft/`: small linked markdown nodes that explain each
system and carry exact file:line spans, kept in sync with the code through git.

For ANY task here — understanding how something works, finding where code lives,
or scoping a change — get context from the graph before grepping or opening
source files. Re-ask freely (it's cheap) and reuse literal identifiers you
already have (symbol, error string, file name) as the query. New to this repo?
Run `graft map` first — a token-budgeted orientation (dir clusters, hubs,
hotspots), no LLM, no key.

- Run `graft ask "<your question>" --source` → ranked nodes with the relevant
  code spans inlined (each hit's ≤8-line crux by default; `--full` for whole
  definitions when the crux isn't enough). Match the tool to the task shape:
  for understanding or editing, the top node IS the answer — cite its
  `covers:` file:line spans and edit straight from `--source`. For
  exhaustive tasks ("every occurrence / every caller of this pattern"), ranked
  results are top-N, not complete — run `graft grep "<literal>"` instead
  (exhaustive over indexed files, grouped by enclosing symbol), falling back
  to raw `grep -rn` only for unindexed files.
- `graft skeleton <file>` → every definition's signature + span, ~10× cheaper
  than reading the file; use it to skim an API surface.
- `graft callers <symbol>` gives precomputed, exact edges — who calls this.
  Add `--direction out` for what it calls, or `--depth N` to walk
  transitively for the full blast radius. For structural questions, skip
  ranking and use this directly.
- Or browse: `graft/INDEX.md` lists every node; follow the links.
- Monorepos and folders of multiple repos rank fairly across sub-projects —
  hits carry `[scope/]` labels naming which one they're from. Narrow with
  `graft ask "<task>" --in <scope>/` once you know where you're working.

If a returned span is truncated ("+N more lines"), open the file at that exact
range before finalizing. Only open source files when a node genuinely lacks a
needed detail, and then at the exact file:line the node points to — never
re-read whole files.

After big code changes, refresh the graph with `graft build` (deterministic,
no API key, $0).
<!-- graft:end -->
