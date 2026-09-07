#!/usr/bin/env python3
"""Draft a Keep a Changelog section from merged GitHub pull requests.

This script shells out to the `gh` CLI to list merged pull requests since a
given date (or since the nearest `v*` git tag reachable from HEAD if no
date is given -- see --since below), then
prints a Keep a Changelog (https://keepachangelog.com/en/1.1.0/) section to
stdout, grouped into Added / Changed / Fixed / Removed by each PR title's
Conventional Commits prefix (feat -> Added, fix -> Fixed,
refactor/perf/chore/build/ci/docs/test -> Changed).

USAGE

    scripts/changelog_draft.py [--since YYYY-MM-DD] [--tag vX.Y.Z]
                                [--repo OWNER/NAME] [--limit N]

    --since   Only include PRs merged on or after this date. If omitted, the
              date is taken from `git log -1 --format=%aI <tag>` of the nearest
              `v*` tag reachable from HEAD (`git describe --match 'v*'`); if
              there is no such tag, all merged PRs are included. Note that
              "reachable from HEAD" is not the same as "newest": pass --since
              explicitly when drafting from a branch that does not contain the
              previous release tag.
    --tag     If given, the section header is "## [X.Y.Z] - YYYY-MM-DD" using
              today's date. Otherwise the header is "## [Unreleased]".
    --repo    GitHub repo in OWNER/NAME form. Default: johnpark-bin/LibreOmi.
    --limit   Maximum number of merged PRs to fetch. Default: 200.

IMPORTANT

  - This script writes ONLY to stdout. It never modifies CHANGELOG.md. A
    human (or an agent acting on the human's behalf) is expected to review
    the draft, edit it, and paste it into CHANGELOG.md by hand.
  - PR titles in this repository are written in Korean. This script does
    NOT translate them -- it prints the raw title text next to each PR
    link. Whoever pastes the draft into CHANGELOG.md must rewrite each line
    into concise, user-facing English before committing.
  - Requires the GitHub CLI (`gh`) to be installed and authenticated. No
    other third-party dependencies are used -- standard library only.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import date

DEFAULT_REPO = "johnpark-bin/LibreOmi"
DEFAULT_LIMIT = 200

# Conventional Commits prefix -> Keep a Changelog section.
PREFIX_TO_SECTION = {
    "feat": "Added",
    "fix": "Fixed",
    "refactor": "Changed",
    "perf": "Changed",
    "chore": "Changed",
    "build": "Changed",
    "ci": "Changed",
    "docs": "Changed",
    "test": "Changed",
    "remove": "Removed",
    "revert": "Changed",
}

SECTION_ORDER = ["Added", "Changed", "Fixed", "Removed"]

# Matches a Conventional Commits style prefix at the start of a title, e.g.
# "feat(ble): ..." or "fix: ...". Titles without a recognizable prefix (this
# repo also uses plain "LO-12 · ..." titles) fall back to "Changed" so
# nothing is silently dropped from the draft.
PREFIX_RE = re.compile(r"^([a-zA-Z]+)(\([^)]*\))?\s*:\s*")


def run_gh(args: list[str]) -> str:
    """Run a `gh` CLI command and return its stdout, or exit 1 on failure."""
    try:
        result = subprocess.run(
            ["gh"] + args,
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        print(
            "error: the GitHub CLI ('gh') was not found on PATH. "
            "Install it from https://cli.github.com/ and authenticate with "
            "'gh auth login' before running this script.",
            file=sys.stderr,
        )
        sys.exit(1)

    if result.returncode != 0:
        # Print gh's own stderr for context, but never echo any token or
        # credential material -- gh does not print those on failure, and we
        # do not construct or forward any ourselves.
        print("error: 'gh' command failed:", file=sys.stderr)
        print(result.stderr.strip(), file=sys.stderr)
        sys.exit(1)

    return result.stdout


def resolve_since(since: str | None) -> str | None:
    """Resolve the --since date, defaulting to the date of the nearest v* tag reachable from HEAD."""
    if since:
        return since

    try:
        tag_result = subprocess.run(
            ["git", "describe", "--tags", "--match", "v*", "--abbrev=0"],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        print(
            "error: git was not found on PATH; cannot derive --since from tags.",
            file=sys.stderr,
        )
        sys.exit(1)

    if tag_result.returncode != 0:
        # No v* tag exists yet -- collect every merged PR.
        return None

    tag = tag_result.stdout.strip()
    if not tag:
        return None

    log_result = subprocess.run(
        ["git", "log", "-1", "--format=%aI", tag],
        capture_output=True,
        text=True,
        check=False,
    )
    if log_result.returncode != 0 or not log_result.stdout.strip():
        return None

    # %aI is an ISO 8601 timestamp; keep just the date portion for the
    # gh search query.
    tag_date_iso = log_result.stdout.strip()
    return tag_date_iso[:10]


def fetch_merged_prs(repo: str, since: str | None, limit: int) -> list[dict]:
    """Fetch merged PRs from `repo`, optionally filtered by merge date."""
    args = [
        "pr",
        "list",
        "--repo",
        repo,
        "--state",
        "merged",
        "--limit",
        str(limit),
        "--json",
        "number,title,mergedAt,url",
    ]
    if since:
        args += ["--search", f"merged:>={since}"]

    output = run_gh(args)
    try:
        prs = json.loads(output)
    except json.JSONDecodeError as exc:
        print(f"error: could not parse 'gh pr list' output as JSON: {exc}", file=sys.stderr)
        sys.exit(1)

    return prs


def classify(title: str) -> str:
    """Map a PR title to a Keep a Changelog section name."""
    match = PREFIX_RE.match(title.strip())
    if match:
        prefix = match.group(1).lower()
        if prefix in PREFIX_TO_SECTION:
            return PREFIX_TO_SECTION[prefix]
    # No recognizable Conventional Commits prefix (e.g. "LO-12 · ...").
    # Default to "Changed" so every PR still shows up in the draft; a human
    # reviewing the draft can re-file it into Added/Fixed/Removed as needed.
    return "Changed"


def build_section(prs: list[dict], header: str) -> str:
    """Render the grouped Keep a Changelog section as a string."""
    groups: dict[str, list[dict]] = {name: [] for name in SECTION_ORDER}
    for pr in prs:
        section = classify(pr.get("title", ""))
        groups[section].append(pr)

    # Sort each group by PR number for stable, reviewable output.
    for prs_in_group in groups.values():
        prs_in_group.sort(key=lambda p: p.get("number", 0))

    lines = [header, ""]
    any_entries = False
    for section in SECTION_ORDER:
        entries = groups[section]
        if not entries:
            continue
        any_entries = True
        lines.append(f"### {section}")
        lines.append("")
        for pr in entries:
            number = pr.get("number")
            title = pr.get("title", "").strip()
            url = pr.get("url", "")
            lines.append(f"- {title} ([#{number}]({url}))")
        lines.append("")

    if not any_entries:
        lines.append("_No merged pull requests found for this range._")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Draft a Keep a Changelog section from merged GitHub PRs (stdout only).",
    )
    parser.add_argument("--since", help="Only include PRs merged on or after this date (YYYY-MM-DD).")
    parser.add_argument("--tag", help="Release tag/version for the header, e.g. v0.1.0.")
    parser.add_argument("--repo", default=DEFAULT_REPO, help=f"GitHub repo (default: {DEFAULT_REPO}).")
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT, help=f"Max PRs to fetch (default: {DEFAULT_LIMIT}).")
    args = parser.parse_args()

    since = resolve_since(args.since)
    prs = fetch_merged_prs(args.repo, since, args.limit)

    if args.tag:
        version = args.tag.lstrip("v")
        today = date.today().isoformat()
        header = f"## [{version}] - {today}"
    else:
        header = "## [Unreleased]"

    section = build_section(prs, header)
    sys.stdout.write(section)


if __name__ == "__main__":
    main()
