#!/usr/bin/env python3
"""Create GitHub milestones and issues from docs/07-backlog.ko.md.

Usage:
  scripts/create_issues.py --repo owner/LibreOmi [--dry-run] [--only LO-12,LO-13]

Requires `gh` authenticated. Idempotent: skips issues whose title already exists.
"""
import argparse, json, re, subprocess, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
BACKLOG = ROOT / "docs" / "07-backlog.ko.md"

def gh(*args, check=True):
    r = subprocess.run(["gh", *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.exit(f"gh {' '.join(args)} failed:\n{r.stderr}")
    return r.stdout

def parse(text):
    milestones = []
    for m_block in re.split(r"^## ", text, flags=re.M)[1:]:
        head, _, rest = m_block.partition("\n")
        m_title = head.strip()
        desc_lines, issues = [], []
        parts = re.split(r"^### ", rest, flags=re.M)
        desc = parts[0].strip()
        for i_block in parts[1:]:
            i_head, _, i_body = i_block.partition("\n")
            i_title = i_head.strip()
            lines = i_body.strip("\n").split("\n")
            labels = []
            if lines and lines[0].startswith("라벨:"):
                labels = [l.strip().strip("`") for l in lines[0][len("라벨:"):].split(",") if l.strip()]
                lines = lines[1:]
            issues.append({"title": i_title, "labels": labels, "body": "\n".join(lines).strip()})
        milestones.append({"title": m_title, "description": desc, "issues": issues})
    return milestones

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    only = {s.strip() for s in a.only.split(",") if s.strip()}

    data = parse(BACKLOG.read_text(encoding="utf-8"))
    existing_ms = {} if a.dry_run else {
        m["title"]: m["number"] for m in json.loads(gh("api", f"repos/{a.repo}/milestones?state=all&per_page=100"))}
    existing_issues = set() if a.dry_run else {
        i["title"] for i in json.loads(gh("issue", "list", "-R", a.repo, "--state", "all", "--limit", "500", "--json", "title"))}
    labels = {l for m in data for i in m["issues"] for l in i["labels"]}
    if not a.dry_run:
        have = {l["name"] for l in json.loads(gh("label", "list", "-R", a.repo, "--limit", "200", "--json", "name"))}
        for l in sorted(labels - have):
            gh("label", "create", l, "-R", a.repo, "--color", "ededed", check=False)

    for m in data:
        ms_title = m["title"].split("—")[0].strip()  # "M1"
        full = m["title"]
        if a.dry_run:
            print(f"[milestone] {full}")
        elif full not in existing_ms:
            out = gh("api", f"repos/{a.repo}/milestones", "-f", f"title={full}", "-f", f"description={m['description']}")
            existing_ms[full] = json.loads(out)["number"]
        for i in m["issues"]:
            lo_id = i["title"].split("·")[0].strip()
            if only and lo_id not in only:
                continue
            body = i["body"] + f"\n\n---\n마일스톤 {ms_title} · 영어 로드맵: `docs/06-roadmap.md` ({lo_id})"
            if a.dry_run:
                print(f"  [issue] {i['title']}  labels={i['labels']}")
                continue
            if i["title"] in existing_issues:
                print(f"  skip (exists): {i['title']}")
                continue
            args = ["issue", "create", "-R", a.repo, "-t", i["title"], "-b", body, "-m", full]
            for l in i["labels"]:
                args += ["-l", l]
            print("  created:", gh(*args).strip())

if __name__ == "__main__":
    main()
