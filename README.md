# LibreOmi

Open-source, privacy-first Android companion app for Omi wearables (Friend / DevKit),
derived from [kbdevs/omibutfree](https://github.com/kbdevs/omibutfree) (MIT).

LibreOmi keeps the upstream design goals — local SQLite storage, bring-your-own
API keys, optional fully-offline transcription — and adds a first-class Android
target. The codebase stays Flutter, so the iOS build remains possible from the
same tree.

## Status

Bootstrap phase (M0). The upstream Flutter application sources have been imported;
no Android platform folder exists yet and the app has not been built or run from
this repository. The design documents below remain the source of truth for the
implementation work.

### Upstream import

The application code in `lib/`, `assets/`, `test/`, `ios/`, `pubspec.yaml`,
`pubspec.lock`, `analysis_options.yaml` and `flutter_launcher_icons.yaml` was
copied verbatim from upstream:

- Source: <https://github.com/kbdevs/omibutfree>
- Commit: `98b912f4e46f03bcad818646b51c8f10f35563fe` ("failed swift transformation")
- Imported: 2026-09-06

Upstream history was **not** carried over. The files were brought in as a single
commit and the upstream commit hash above is the provenance record; use it to diff
against upstream. Attribution is kept in `LICENSE`, which carries both the upstream
(kbdevs) and the LibreOmi copyright lines.

Deliberately not imported: the abandoned native SwiftUI rewrite (`OmiLocal/`), the
agent-loop state (`.ralph/`), the author's build logs and codesign scripts
(`build_log.txt`, `fix_build.sh`), a stale submodule pointer (`omi`), the upstream
`README.md` and `.gitignore` (this repository keeps its own), macOS Finder
duplicate artefacts (`ios/Pods 2/`, `ios/Flutter/Flutter 2.podspec`,
`Flutter 3.podspec`, `flutter_export_environment 2.sh`,
`flutter_export_environment 3.sh`, `.flutter-plugins-dependencies 2`), and
`.metadata` (regenerated when the Android platform folder is created).

The imported Dart code is unmodified, including `name: omi_local` in `pubspec.yaml`
and the `package:omi_local/...` imports; renaming is tracked separately (LO-03).

## Documents

| # | Document | Purpose |
|---|----------|---------|
| 01 | [docs/01-upstream-analysis.md](docs/01-upstream-analysis.md) | What omibutfree is, how it works, what is portable, what is broken |
| 02 | [docs/02-tech-stack-decision.md](docs/02-tech-stack-decision.md) | Options considered and why we fork the Flutter app instead of rewriting |
| 03 | [docs/03-architecture.md](docs/03-architecture.md) | Target module layout, interfaces, data flow, background execution design |
| 04 | [docs/04-android-platform-notes.md](docs/04-android-platform-notes.md) | Permissions by API level, foreground service, BLE MTU, build toolchain, gotchas |
| 05 | [docs/05-omi-ble-protocol.md](docs/05-omi-ble-protocol.md) | Omi BLE GATT reference as used by this app |
| 06 | [docs/06-roadmap.md](docs/06-roadmap.md) | Milestones, work items, acceptance criteria, ordering |
| 07 | [docs/07-backlog.ko.md](docs/07-backlog.ko.md) | GitHub issue backlog (Korean), one entry per work item |
| 08 | [docs/08-dev-workflow.md](docs/08-dev-workflow.md) | Branching, language policy, PR flow, device test checklist, AI-agent usage |
| — | [SUMMARY.ko.md](SUMMARY.ko.md) | Korean summary for the project owner: decisions, rationale, what only you can do |
| — | [AGENTS.md](AGENTS.md) | Conventions for AI coding agents working in this repo |

## Language policy

- Code, identifiers, comments, commit messages, and `docs/`: **English**.
- GitHub issues and pull requests during the bootstrap phase: **Korean** (see `docs/08-dev-workflow.md`).

## License

MIT, same as upstream. Upstream copyright notice must be preserved.
