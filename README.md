# LibreOmi

Open-source, privacy-first Android companion app for Omi wearables (Friend / DevKit),
derived from [kbdevs/omibutfree](https://github.com/kbdevs/omibutfree) (MIT).

LibreOmi keeps the upstream design goals — local SQLite storage, bring-your-own
API keys, optional fully-offline transcription — and adds a first-class Android
target. The codebase stays Flutter, so the iOS build remains possible from the
same tree.

## Status

Planning phase. No application code has been written in this repository yet.
The design documents below are the source of truth for the implementation work.

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
